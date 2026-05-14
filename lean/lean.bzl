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

def _module_path(src_short_path, package):
    """Strip the rule's package prefix; what remains is the module-path layout."""
    if not src_short_path.startswith(package + "/"):
        fail("source %s is not inside package %s" % (src_short_path, package))
    return src_short_path[len(package) + 1:]

def _lean_test_impl(ctx):
    tc = ctx.toolchains["@rules_lean//lean:toolchain_type"].leantc
    name = ctx.label.name
    pkg = ctx.label.package
    workspace_name = ctx.workspace_name

    staged_files = []
    rel_paths = []
    entry_rel = None
    for src in ctx.files.srcs:
        rel = _module_path(src.short_path, pkg)
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

    compile_lines = "\n".join([
        ('  echo "[lean_test] lean --root=$LEAN_ROOT -o {olean} {src}" >&2\n' +
         '  "$LEAN_BIN" --root="$LEAN_ROOT" -o "$LEAN_ROOT/{olean}" "$LEAN_ROOT/{src}"').format(
            src = rel,
            olean = rel.removesuffix(".lean") + ".olean",
        )
        for rel in rel_paths
    ])

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
for cand in "${{RUNFILES_DIR}}/_main" "${{RUNFILES_DIR}}/{ws_name}"; do
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
            doc = "All .lean files in the proof tree. Module path is derived from the file's path relative to this BUILD.bazel's package.",
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
        rel = _module_path(src.short_path, pkg)
        rel_paths.append((src, rel))
        if rel == ctx.attr.entry:
            entry_rel = rel

    if entry_rel == None:
        fail("entry %r not found among srcs (got %s)" %
             (ctx.attr.entry, [r for (_, r) in rel_paths]))

    dep_markers, dep_files = _collect_dep_lean_info(ctx.attr.deps)
    dep_lean_path_dirs = [m.path[:m.path.rfind("/")] for m in dep_markers.to_list()]

    cmd_lines = ["set -euo pipefail", "WORK=$(mktemp -d)", "trap 'rm -rf \"$WORK\"' EXIT"]

    for src, rel in rel_paths:
        cmd_lines.append('mkdir -p "$WORK/$(dirname {rel})"'.format(rel = rel))
        cmd_lines.append('cp "{src}" "$WORK/{rel}"'.format(src = src.path, rel = rel))

    lean_path_parts = ["$WORK"] + dep_lean_path_dirs
    cmd_lines.append(
        'export LEAN_PATH="{}${{LEAN_PATH:+:$LEAN_PATH}}"'.format(":".join(lean_path_parts)),
    )

    for _, rel in rel_paths:
        olean = rel.removesuffix(".lean") + ".olean"
        cmd_lines.append(
            '"{lean}" --root="$WORK" -o "$WORK/{olean}" "$WORK/{rel}"'
                .format(lean = tc.lean.path, olean = olean, rel = rel),
        )

    cmd_lines.append(
        '"{lean}" --root="$WORK" --run "$WORK/{entry}" > "{out}"'
            .format(lean = tc.lean.path, entry = entry_rel, out = output.path),
    )

    inputs = depset(
        direct = [src for (src, _) in rel_paths] + [tc.lean],
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
    },
    toolchains = ["@rules_lean//lean:toolchain_type"],
)
