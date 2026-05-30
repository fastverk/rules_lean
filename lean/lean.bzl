"""Bazel rules for Lean 4.

Four user-facing rules:
  lean_toolchain         — registers a Lean compiler binary + runtime tree.
                           Normally produced by `lake_workspace` (see lake.bzl);
                           can also be declared by hand against a hermetic
                           lean tarball.
  lean_prebuilt_library  — exposes a tree of prebuilt .olean files as a
                           LeanInfo provider consumable via the `deps` attr.
                           The `path_marker` file's parent directory becomes
                           the LEAN_PATH entry.
  lean_test              — stages a set of .lean sources into a module-path
                           layout and invokes the compiler on an entry point.
                           Returns 0 if all type-check, nonzero otherwise.
                           Accepts `deps = [LeanInfo]` and prepends each
                           dep's import root to LEAN_PATH.
  lean_emit              — like lean_test, but the entry file defines
                           `main : IO Unit`; runs it and captures stdout to
                           a declared output file. The Lean kernel becomes
                           the source of truth for emitted artifacts (SQL,
                           TTL, Markdown). Same `deps` plumbing as lean_test.

Design choice: one bundled lean_test per package rather than a per-file
lean_library + transitive .olean tracking. Lean already does fast
incremental type-checking; the value of fine-grained Bazel actions is not
worth the staging-tree complexity at small-to-medium scale.
"""

# Used by `lean_regen_test` (see bottom of this file) — kept up here
# to satisfy Bazel's "all load()s before any other top-level statement"
# rule.
load("@bazel_skylib//rules:diff_test.bzl", _diff_test = "diff_test")

LeanToolchainInfo = provider(
    doc = "Lean 4 compiler binary + runtime tree.",
    fields = {
        "lean": "File: the lean compiler binary (executable).",
        "runtime": "depset[File]: stdlib oleans, shared libs, etc.",
    },
)

LeanInfo = provider(
    doc = "A Lean library: a directory of importable .olean files, exposed " +
          "via a marker file whose parent directory is the LEAN_PATH entry.",
    fields = {
        "markers": "depset[File]: each marker's parent directory IS a LEAN_PATH entry.",
        "files": "depset[File]: all .olean files (and the marker) needed when this lib is consumed.",
    },
)

def _lean_prebuilt_library_impl(ctx):
    marker = ctx.file.path_marker
    files = ctx.files.srcs + [marker]
    info = LeanInfo(
        markers = depset([marker]),
        files = depset(files),
    )
    return [
        DefaultInfo(files = depset(files)),
        info,
    ]

lean_prebuilt_library = rule(
    implementation = _lean_prebuilt_library_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "All files in the prebuilt-olean tree (typically `glob([\"lib/**\"])`).",
        ),
        "path_marker": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "Anchor file inside the import-root directory. The marker's parent is the LEAN_PATH entry.",
        ),
    },
)

def _collect_dep_lean_info(deps):
    """Aggregate LeanInfo across deps. Returns (markers, files) depsets."""
    markers = []
    files = []
    for dep in deps:
        info = dep[LeanInfo]
        markers.append(info.markers)
        files.append(info.files)
    return depset(transitive = markers), depset(transitive = files)

def _lean_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(
        leantc = LeanToolchainInfo(
            lean = ctx.executable.lean,
            runtime = ctx.attr.runtime[DefaultInfo].files,
        ),
    )]

lean_toolchain = rule(
    implementation = _lean_toolchain_impl,
    attrs = {
        "lean": attr.label(
            executable = True,
            cfg = "exec",
            allow_single_file = True,
            mandatory = True,
        ),
        "runtime": attr.label(mandatory = True),
    },
)

def _module_path(src_short_path, file_package):
    """Relativize a source file against its OWN package to get its module path.

    The result is used to stage the file + derive its Lean module name.
    `file_package` is the package of the file itself (`src.owner.package`),
    NOT the consuming rule's package. This lets a rule mix sources from
    different packages — in particular cross-repo kernel sources like
    `@polyglot_ast//lean:Polyglot/C/Ast.lean` (package `lean`) consumed by
    a rule in a differently-named package (e.g. `//engine`). Both stage to
    `Polyglot/C/Ast.lean` regardless of the consumer's package.

    Handles external-repo sources where Bazel produces a short_path like
    `../<repo>+/<package>/<file>`; the `../<repo>+/` prefix is stripped
    first, leaving `<package>/<file>` which is then package-relativized.
    """
    if src_short_path.startswith("../"):
        rest = src_short_path[len("../"):]
        slash = rest.find("/")
        if slash >= 0:
            src_short_path = rest[slash + 1:]
    if file_package == "":
        return src_short_path
    if not src_short_path.startswith(file_package + "/"):
        fail("source %s is not inside its package %s" % (src_short_path, file_package))
    return src_short_path[len(file_package) + 1:]

# Bash helper (POSIX / bash 3.2 compatible — macOS ships bash 3.2, so no
# associative arrays) that compiles a set of staged `.lean` files in
# *dependency order* regardless of the order `srcs` was listed in. Lean needs a
# module's imports already compiled to `.olean` before it, but the analysis
# phase can't read file contents to sort — so we derive the order at execution
# time: parse each file's `import` lines, keep only edges to modules that are
# themselves in the set, and `tsort` the result. This makes `glob()` work in
# `srcs` and removes the "order matters" footgun. Relies only on
# grep/sed/cut/tsort/mktemp, consistent with the rest of these generated scripts.
#
# Reads `$LEAN_BIN`; takes ROOT dir, a log prefix, then the rel paths as args.
_TOPO_COMPILE_FN = r'''__lean_topo_compile() {
  local ROOT="$1"; local PFX="$2"; shift 2
  local RELS=("$@")
  local TD; TD=$(mktemp -d)
  local MODS="$TD/mods" EDGES="$TD/edges" MAP="$TD/map"
  : > "$MODS"; : > "$EDGES"; : > "$MAP"
  local rel mod imp imports olean order
  for rel in "${RELS[@]}"; do
    mod=$(printf '%s' "$rel" | sed -E 's/\.lean$//; s#/#.#g')
    printf '%s\n' "$mod" >> "$MODS"
    printf '%s\t%s\n' "$mod" "$rel" >> "$MAP"
  done
  for rel in "${RELS[@]}"; do
    mod=$(printf '%s' "$rel" | sed -E 's/\.lean$//; s#/#.#g')
    # Edge from a sentinel so isolated nodes (no in-set imports) still appear.
    printf '@@leanroot@@ %s\n' "$mod" >> "$EDGES"
    imports=$(grep -E '^import[[:space:]]' "$ROOT/$rel" 2>/dev/null | sed -E 's/^import[[:space:]]+([A-Za-z0-9_.]+).*/\1/' || true)
    for imp in $imports; do
      if grep -qxF "$imp" "$MODS"; then printf '%s %s\n' "$imp" "$mod" >> "$EDGES"; fi
    done
  done
  order=$(tsort "$EDGES") || { echo "ERROR: import cycle among Lean srcs ($PFX)" >&2; rm -rf "$TD"; exit 3; }
  for mod in $order; do
    [ "$mod" = "@@leanroot@@" ] && continue
    rel=$(grep -F "$(printf '%s\t' "$mod")" "$MAP" | head -1 | cut -f2-)
    olean="${rel%.lean}.olean"
    echo "[$PFX] lean --root=$ROOT -o $olean $rel" >&2
    "$LEAN_BIN" --root="$ROOT" -o "$ROOT/$olean" "$ROOT/$rel"
  done
  rm -rf "$TD"
}'''

def _topo_compile_block(root_expr, log_prefix, rels):
    """Function definition + an invocation compiling `rels` under `root_expr` in
    import-topological order. `rels` are package-relative `.lean` paths."""
    args = " ".join(['"{}"'.format(r) for r in rels])
    return '{fn}\n__lean_topo_compile "{root}" "{pfx}" {args}'.format(
        fn = _TOPO_COMPILE_FN,
        root = root_expr,
        pfx = log_prefix,
        args = args,
    )

def _lean_test_impl(ctx):
    tc = ctx.toolchains["@rules_lean//lean:toolchain_type"].leantc
    name = ctx.label.name
    pkg = ctx.label.package
    workspace_name = ctx.workspace_name

    # `ctx.label.workspace_name` is the canonical name of the *target's*
    # repo (e.g. "rules_postgres+" for `@rules_postgres//lean:smoke_test`)
    # or empty when the target is in the root module. When the target
    # lives in an external module, runfiles stage the Lean tree under
    # `${RUNFILES_DIR}/<target_repo>/<root_rel>` rather than under
    # `_main` or the root workspace name — so the runner script needs
    # this as an additional candidate location for WS_ROOT.
    target_repo = ctx.label.workspace_name

    staged_files = []
    rel_paths = []
    entry_rel = None
    for src in ctx.files.srcs:
        rel = _module_path(src.short_path, src.owner.package)
        staged = ctx.actions.declare_file("{}_root/{}".format(name, rel))
        ctx.actions.symlink(output = staged, target_file = src)
        staged_files.append(staged)
        rel_paths.append(rel)
        if rel == ctx.attr.entry:
            entry_rel = rel

    if entry_rel == None:
        fail("entry %r not found among srcs (got %s)" % (ctx.attr.entry, rel_paths))

    dep_markers, dep_files = _collect_dep_lean_info(ctx.attr.deps)
    dep_marker_short_paths = [m.short_path for m in dep_markers.to_list()]

    # Compile in import-topological order (so `srcs` may be a `glob()`), not
    # input-list order.
    compile_lines = _topo_compile_block("$LEAN_ROOT", "lean_test", rel_paths)

    dep_lean_path_lines = "\n".join([
        ('dep_sp="{sp}"; ' +
         'if [[ "$dep_sp" == "../"* ]]; then dep_abs="${{RUNFILES_DIR}}/${{dep_sp#../}}"; ' +
         'else dep_abs="${{WS_ROOT}}/${{dep_sp}}"; fi; ' +
         'dep_dir="$(dirname "$dep_abs")"; ' +
         'export LEAN_PATH="$dep_dir${{LEAN_PATH:+:$LEAN_PATH}}"').format(sp = sp)
        for sp in dep_marker_short_paths
    ])

    runner = ctx.actions.declare_file(name + ".sh")
    ctx.actions.write(
        output = runner,
        is_executable = True,
        content = """#!/bin/bash
# Generated by lean_test.
set -euo pipefail

if [[ -z "${{RUNFILES_DIR:-}}" ]]; then
  if [[ -d "$0.runfiles" ]]; then
    RUNFILES_DIR="$0.runfiles"
  fi
fi

WS_ROOT=""
for cand in "${{RUNFILES_DIR}}/_main" "${{RUNFILES_DIR}}/{ws_name}" "${{RUNFILES_DIR}}/{target_repo}"; do
  if [[ -d "$cand/{root_rel}" ]]; then
    WS_ROOT="$cand"
    break
  fi
done
if [[ -z "$WS_ROOT" ]]; then
  echo "ERROR: cannot locate staged Lean root under $RUNFILES_DIR" >&2
  exit 2
fi

LEAN_ROOT="$WS_ROOT/{root_rel}"
LEAN_BIN="$WS_ROOT/{lean_path}"
[[ -x "$LEAN_BIN" ]] || LEAN_BIN="${{RUNFILES_DIR}}/{lean_path}"

# Writable scratch copy: runfiles entries may be symlinks into Bazel's
# read-only sandbox, but lean wants to write .olean alongside .lean.
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
cp -RL "$LEAN_ROOT/." "$SCRATCH/"
LEAN_ROOT="$SCRATCH"

export LEAN_PATH="$LEAN_ROOT${{LEAN_PATH:+:$LEAN_PATH}}"

{dep_lean_path_lines}

echo "[lean_test] root=$LEAN_ROOT entry={entry} LEAN_PATH=$LEAN_PATH" >&2
{compile_lines}
echo "[lean_test] OK" >&2
""".format(
            ws_name = workspace_name,
            target_repo = target_repo or workspace_name,
            root_rel = "{}/{}_root".format(pkg, name),
            entry = entry_rel,
            lean_path = tc.lean.short_path,
            compile_lines = compile_lines,
            dep_lean_path_lines = dep_lean_path_lines if dep_marker_short_paths else "# (no deps)",
        ),
    )

    runfiles = ctx.runfiles(files = staged_files + [tc.lean]).merge_all([
        ctx.runfiles(transitive_files = tc.runtime),
        ctx.runfiles(transitive_files = dep_files),
    ])
    return [DefaultInfo(executable = runner, runfiles = runfiles)]

lean_test = rule(
    implementation = _lean_test_impl,
    test = True,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".lean"],
            mandatory = True,
            doc = "All .lean files in the proof tree. Module path is derived from the file's path relative to this BUILD.bazel's package. Compiled in import-topological order, so list order is irrelevant — `glob([\"**/*.lean\"])` is fine.",
        ),
        "entry": attr.string(
            mandatory = True,
            doc = "Path of the entry-point .lean file relative to the package.",
        ),
        "deps": attr.label_list(
            providers = [LeanInfo],
            doc = "Prebuilt Lean libraries. Each dep's import root is prepended to LEAN_PATH.",
        ),
    },
    toolchains = ["@rules_lean//lean:toolchain_type"],
)

def _lean_emit_impl(ctx):
    tc = ctx.toolchains["@rules_lean//lean:toolchain_type"].leantc
    name = ctx.label.name
    pkg = ctx.label.package
    output = ctx.outputs.out

    rel_paths = []
    entry_rel = None
    for src in ctx.files.srcs:
        rel = _module_path(src.short_path, src.owner.package)
        rel_paths.append((src, rel))
        if rel == ctx.attr.entry:
            entry_rel = rel

    if entry_rel == None:
        fail("entry %r not found among srcs (got %s)" %
             (ctx.attr.entry, [r for (_, r) in rel_paths]))

    # `data` files: staged alongside srcs in the work dir but NOT
    # compiled. Lets the entry script open them at runtime via a
    # workspace-relative path (the action runs from $WORK). Used e.g.
    # for `.dat` / `.txt` fixture inputs.
    #
    # External-repo data files (e.g. `@some_repo//path:file`) have
    # short_paths like `../+canon+some_repo/path/file`. We strip the
    # leading `../<repo>/` so the file lands under $WORK at its
    # natural workspace-relative path. Workspace-local data uses its
    # short_path verbatim. No package-prefix check (data files are
    # arbitrary fixtures, not Lean modules — they don't need to live
    # inside the rule's package).
    data_paths = []
    for d in ctx.files.data:
        sp = d.short_path
        if sp.startswith("../"):
            rest = sp[len("../"):]
            slash = rest.find("/")
            if slash >= 0:
                sp = rest[slash + 1:]
        data_paths.append((d, sp))

    dep_markers, dep_files = _collect_dep_lean_info(ctx.attr.deps)
    dep_lean_path_dirs = [m.path[:m.path.rfind("/")] for m in dep_markers.to_list()]

    cmd_lines = [
        "set -euo pipefail",
        "WORK=$(mktemp -d)",
        "trap 'rm -rf \"$WORK\"' EXIT",
        # Resolve `lean` to an absolute path BEFORE any cd. The compile
        # / --run commands use this so the `cd "$WORK"` step below
        # doesn't break the toolchain lookup.
        'LEAN_BIN="$(pwd)/{lean}"'.format(lean = tc.lean.path),
        # Same for the output target.
        'OUT_ABS="$(pwd)/{out}"'.format(out = output.path),
        # Exec root, captured before any `cd`. Dep LEAN_PATH dirs below
        # are exec-root-relative; the `--run` step cds into $WORK, so
        # they must be absolutized here or Lean can't find dep oleans
        # (mathlib etc.) at runtime.
        'EXEC_ROOT="$(pwd)"',
    ]

    for src, rel in rel_paths:
        cmd_lines.append('mkdir -p "$WORK/$(dirname {rel})"'.format(rel = rel))
        cmd_lines.append('cp "{src}" "$WORK/{rel}"'.format(src = src.path, rel = rel))

    for src, rel in data_paths:
        cmd_lines.append('mkdir -p "$WORK/$(dirname {rel})"'.format(rel = rel))
        cmd_lines.append('cp "{src}" "$WORK/{rel}"'.format(src = src.path, rel = rel))

    lean_path_parts = ["$WORK"] + ['$EXEC_ROOT/' + d for d in dep_lean_path_dirs]
    cmd_lines.append(
        'export LEAN_PATH="{}${{LEAN_PATH:+:$LEAN_PATH}}"'.format(":".join(lean_path_parts)),
    )

    # Compile in import-topological order (so `srcs` may be a `glob()`).
    cmd_lines.append(_topo_compile_block("$WORK", "lean_emit", [rel for (_, rel) in rel_paths]))

    # Run from $WORK so the entry script's relative file-opens
    # resolve to the staged `data` files.
    cmd_lines.append(
        '(cd "$WORK" && "$LEAN_BIN" --root="$WORK" --run "{entry}") > "$OUT_ABS"'
            .format(entry = entry_rel),
    )

    inputs = depset(
        direct = (
            [src for (src, _) in rel_paths] +
            [src for (src, _) in data_paths] +
            [tc.lean]
        ),
        transitive = [tc.runtime, dep_files],
    )

    ctx.actions.run_shell(
        outputs = [output],
        inputs = inputs,
        command = "\n".join(cmd_lines),
        mnemonic = "LeanEmit",
        progress_message = "Lean emit %s" % name,
    )

    return [DefaultInfo(files = depset([output]))]

lean_emit = rule(
    implementation = _lean_emit_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".lean"],
            mandatory = True,
        ),
        "entry": attr.string(
            mandatory = True,
            doc = "Path of the entry-point .lean file (relative to the package) defining `main : IO Unit`. Stdout is captured to `out`.",
        ),
        "out": attr.output(
            mandatory = True,
            doc = "The emitted artifact (one file). Filename should reflect the artifact kind.",
        ),
        "deps": attr.label_list(providers = [LeanInfo]),
        "data": attr.label_list(
            allow_files = True,
            doc = "Non-Lean files staged alongside `srcs` in the action's work directory (NOT compiled). The Lean entry runs from that directory, so it can `IO.FS.readFile` them by their package-relative path. Typical use: fixture `.dat` / `.txt` / `.json` inputs the entry processes.",
        ),
    },
    toolchains = ["@rules_lean//lean:toolchain_type"],
)

# =============================================================================
# lean_regen_test: assert a committed file matches the current
# `lean_emit` output for a given Lean main. Captures the "Lean spec is
# the source of truth; the committed Rust/C/whatever was emitted from
# it" idiom that consumers like rules_postgres' Pg.Ir cluster gates
# build their `Gate 1 — regen idempotence` checks on.
#
# Expands to a `lean_emit` (running Lean as a sandboxed Bazel action +
# capturing stdout) plus a skylib `diff_test` (byte-exact comparison
# against the committed `expected` label). Fails the build whenever
# the committed file has drifted from what the Lean source-of-truth
# currently emits — exactly the failure mode `Lean spec edited, regen
# forgotten` introduces.
#
# Usage:
#
#   load("@rules_lean//lean:lean.bzl", "lean_regen_test")
#
#   lean_regen_test(
#       name = "regen_int_arith",                # diff_test target name
#       srcs = [...],                            # ordered .lean deps
#       entry = "Pg/Ir/Emit/IntArith.lean",      # has `main : IO Unit`
#       expected = "//rust/pg_int4_arith:lib_rs",
#   )
#
# `bazel test //path:regen_int_arith` fails with the diff if the Lean
# emit and `expected` disagree.
# =============================================================================
def lean_regen_test(name, srcs, entry, expected, out = None, deps = None, data = None, tags = None):
    """Assert a committed file matches the current `lean_emit` output.

    Args:
      name: target name for the generated diff_test (e.g.
        `regen_int_arith`). The helper `lean_emit` is named
        `<name>_emit`.
      srcs: list of `.lean` source labels needed to compile the
        entry. Compiled in import-topological order, so list order
        is irrelevant (a `glob()` is fine). Must include the entry.
      entry: path of the entry-point `.lean` file (relative to the
        rule's package) defining `main : IO Unit`. Stdout is captured.
      expected: Bazel label of the committed file the lean_emit
        output is diffed against.
      out: optional filename for the emitted artifact (defaults to
        `<name>_emit.out`).
      deps: optional list of `LeanInfo`-providing deps for prebuilt
        olean closures (passed through to `lean_emit`).
      tags: optional tags propagated to the generated `diff_test`
        target only.
    """
    if out == None:
        out = name + "_emit.out"

    emit_name = name + "_emit"

    lean_emit(
        name = emit_name,
        srcs = srcs,
        entry = entry,
        out = out,
        deps = deps if deps else [],
        data = data if data else [],
    )

    _diff_test(
        name = name,
        file1 = ":" + emit_name,
        file2 = expected,
        tags = tags if tags else [],
    )

# =============================================================================
# lean_main_test: compile + run a Lean entry as a test. Passes iff
# the entry's `main : IO UInt32` exits 0. No expected-output diff
# needed — exit code IS the test result.
#
# Use case: gates that check a Lean script self-validates (e.g.
# round-trip stability, structural equivalence) where the script
# already returns the right exit code. Drops the need for a
# committed `expected.txt` fixture.
# =============================================================================

def _lean_main_test_impl(ctx):
    tc = ctx.toolchains["@rules_lean//lean:toolchain_type"].leantc
    name = ctx.label.name
    pkg = ctx.label.package

    rel_paths = []
    entry_rel = None
    for src in ctx.files.srcs:
        rel = _module_path(src.short_path, src.owner.package)
        rel_paths.append((src, rel))
        if rel == ctx.attr.entry:
            entry_rel = rel

    if entry_rel == None:
        fail("entry %r not found among srcs (got %s)" %
             (ctx.attr.entry, [r for (_, r) in rel_paths]))

    data_paths = []
    for d in ctx.files.data:
        sp = d.short_path
        if sp.startswith("../"):
            rest = sp[len("../"):]
            slash = rest.find("/")
            if slash >= 0:
                sp = rest[slash + 1:]
        data_paths.append((d, sp))

    dep_markers, dep_files = _collect_dep_lean_info(ctx.attr.deps)
    dep_lean_path_dirs = [m.path[:m.path.rfind("/")] for m in dep_markers.to_list()]

    runner = ctx.actions.declare_file(name + ".sh")
    lines = [
        "#!/bin/bash",
        "set -euo pipefail",
        "WORK=$(mktemp -d)",
        "trap 'rm -rf \"$WORK\"' EXIT",
        # Resolve lean binary via runfiles. RUNFILES_DIR is set by Bazel's
        # test runner; fall back to <runner>.runfiles for local invocation.
        'if [[ -z "${RUNFILES_DIR:-}" ]]; then RUNFILES_DIR="$0.runfiles"; fi',
        # Find the workspace root that contains the lean binary.
        'for cand in "$RUNFILES_DIR"/_main "$RUNFILES_DIR"/*; do',
        '  if [[ -x "$cand/{lean}" ]]; then LEAN_BIN="$cand/{lean}"; break; fi'
            .format(lean = tc.lean.short_path),
        'done',
        '[[ -n "${LEAN_BIN:-}" ]] || { echo "lean binary not found in runfiles" >&2; exit 2; }',
    ]

    # Stage srcs.
    for src, rel in rel_paths:
        lines += [
            'mkdir -p "$WORK/$(dirname {rel})"'.format(rel = rel),
            'cp "$RUNFILES_DIR"/_main/{sp} "$WORK/{rel}" 2>/dev/null || \\'.format(sp = src.short_path, rel = rel),
            '  cp "$RUNFILES_DIR"/*/{sp} "$WORK/{rel}"'.format(sp = src.short_path, rel = rel),
        ]

    # Stage data files at their workspace-relative path.
    for src, rel in data_paths:
        lines += [
            'mkdir -p "$WORK/$(dirname {rel})"'.format(rel = rel),
            'cp "$RUNFILES_DIR"/_main/{sp} "$WORK/{rel}" 2>/dev/null || \\'.format(sp = src.short_path, rel = rel),
            '  cp "$RUNFILES_DIR"/*/{sp} "$WORK/{rel}"'.format(sp = src.short_path, rel = rel),
        ]

    lean_path_parts = ["$WORK"] + dep_lean_path_dirs
    lines.append('export LEAN_PATH="{}"'.format(":".join(lean_path_parts)))

    # Compile in import-topological order (so `srcs` may be a `glob()`), then
    # run from $WORK; exit code propagates.
    lines.append(_topo_compile_block("$WORK", "lean_main_test", [rel for (_, rel) in rel_paths]))
    lines.append('cd "$WORK" && exec "$LEAN_BIN" --root="$WORK" --run "{entry}"'.format(entry = entry_rel))

    ctx.actions.write(output = runner, content = "\n".join(lines) + "\n", is_executable = True)

    runfiles = ctx.runfiles(
        files = (
            [src for (src, _) in rel_paths] +
            [src for (src, _) in data_paths] +
            [tc.lean]
        ),
    ).merge_all([
        ctx.runfiles(transitive_files = tc.runtime),
        ctx.runfiles(transitive_files = dep_files),
    ])
    return [DefaultInfo(executable = runner, runfiles = runfiles)]

lean_main_test = rule(
    implementation = _lean_main_test_impl,
    test = True,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".lean"],
            mandatory = True,
            doc = "All .lean files needed to compile the entry. Compiled in import-topological order, so list order is irrelevant (a `glob()` is fine).",
        ),
        "entry": attr.string(
            mandatory = True,
            doc = "Path of the entry-point .lean file (relative to the package) defining `main : IO UInt32` (test result = exit code).",
        ),
        "deps": attr.label_list(providers = [LeanInfo]),
        "data": attr.label_list(
            allow_files = True,
            doc = "Non-Lean files staged at their workspace-relative path in the action's work directory. The Lean entry runs from that directory, so it can `IO.FS.readFile` them.",
        ),
    },
    toolchains = ["@rules_lean//lean:toolchain_type"],
)
