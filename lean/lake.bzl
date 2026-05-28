"""Lake integration for rules_lean.

`lake_workspace` is a repository rule that materializes any Lake workspace
(lakefile + lake-manifest.json) into a Bazel-managed external repo,
downloads the matching Lean toolchain, resolves Lake packages, and exposes
each resolved package as its own `lean_prebuilt_library` target.

Generated targets in `@<name>//:`:

  - `:lean_toolchain` / `:lean_toolchain_def` — register via
    `register_toolchains(...)`.
  - `:<package>` — one `lean_prebuilt_library` per Lake package found under
    `.lake/packages/<package>/`. Target names preserve Lake's directory
    casing (e.g. `:mathlib`, `:batteries`, `:Cli`, `:LeanSearchClient`).
    Consumers depend on multiple packages by listing all needed names.

Fast path for mathlib-based workspaces: if `.lake/packages/mathlib/` is
present after `lake update`, the rule runs `lake exe cache get` to pull
prebuilt oleans from the Reservoir cache (covering mathlib + its transitive
deps). For non-mathlib packages and workspaces, `lake build` produces
oleans from source.

Use via the module extension:

    lake = use_extension("@rules_lean//lean:lake.bzl", "lake")
    lake.workspace(
        name = "lake_deps",
        lean_toolchain = "//:lean-toolchain",
        lakefile = "//:lakefile.lean",
        lake_manifest = "//:lake-manifest.json",
    )
    use_repo(lake, "lake_deps")
    register_toolchains("@lake_deps//:lean_toolchain_def")

    # In a BUILD.bazel:
    lean_test(
        name = "smoke",
        srcs = ["Smoke.lean"],
        entry = "Smoke.lean",
        deps = ["@lake_deps//:mathlib", "@lake_deps//:batteries"],
    )

Hermeticity:
  - The Lean toolchain is downloaded with a known sha256 (see
    private/known_lean_versions.bzl) when the version is pinned there.
    Unpinned versions download unverified (warning emitted).
  - Lake dep revs are pinned by the user's committed lake-manifest.json.
  - Mathlib oleans (when applicable) are content-addressed by mathlib's
    commit hash in the upstream Reservoir cache; integrity is verified by
    Lake.

Constraints on the lakefile passed in:
  - Should be a *deps-only* lakefile (the rule creates a placeholder
    package source). Build directives (`lean_lib`, `lean_exe`) for the
    user's own code don't belong here — those live in Bazel BUILD files
    via the `lean_test` / `lean_emit` rules.
"""

load("//lean/private:known_lean_versions.bzl", "KNOWN_LEAN_VERSIONS", "PLATFORM_ASSETS")

LEAN_RELEASE_BASE = "https://github.com/leanprover/lean4/releases/download"

def _detect_platform(rctx):
    os_name = rctx.os.name.lower()
    arch = rctx.os.arch.lower()
    if "mac" in os_name or "darwin" in os_name:
        if arch in ("aarch64", "arm64"):
            return "darwin_aarch64"
        return "darwin_x86_64"
    if "linux" in os_name:
        if arch in ("aarch64", "arm64"):
            return "linux_aarch64"
        return "linux_x86_64"
    fail("rules_lean: unsupported platform os=%s arch=%s" % (os_name, arch))

def _parse_lean_toolchain(content):
    """Parse a `lean-toolchain` file. Returns the version tag (with leading 'v')."""
    line = content.strip().split("\n")[0].strip()
    if ":" not in line:
        fail("lean-toolchain: expected 'leanprover/lean4:vX.Y.Z', got %r" % line)
    _, version = line.split(":", 1)
    version = version.strip()
    if not version.startswith("v"):
        version = "v" + version
    return version

def _download_lean(rctx, version, platform):
    asset_template = PLATFORM_ASSETS.get(platform)
    if not asset_template:
        fail("rules_lean: no asset template for platform %s" % platform)
    asset = asset_template.format(v = version.lstrip("v"))
    sha = KNOWN_LEAN_VERSIONS.get(version, {}).get(platform, "")
    url = "{base}/{ver}/{asset}".format(base = LEAN_RELEASE_BASE, ver = version, asset = asset)
    if not sha:
        # buildifier: disable=print
        print("rules_lean: WARNING — no pinned sha256 for Lean %s on %s; downloading unverified. " %
              (version, platform) +
              "Add an entry to known_lean_versions.bzl for hermetic builds.")
    rctx.download_and_extract(
        url = url,
        sha256 = sha,
        output = "lean_toolchain",
        stripPrefix = asset.removesuffix(".zip"),
    )

def _stage_lake_workspace(rctx):
    """Stage lakefile + manifest + lean-toolchain + placeholder package source into lake_ws/."""

    # Use the user's actual filenames so Lake recognizes them.
    lakefile_basename = rctx.path(rctx.attr.lakefile).basename
    manifest_basename = rctx.path(rctx.attr.lake_manifest).basename

    rctx.symlink(rctx.attr.lakefile, "lake_ws/" + lakefile_basename)
    rctx.symlink(rctx.attr.lake_manifest, "lake_ws/" + manifest_basename)
    rctx.symlink(rctx.attr.lean_toolchain, "lake_ws/lean-toolchain")

    # Lake refuses to operate without at least one source file matching the
    # package. The placeholder is a minimal valid Lean module.
    rctx.file("lake_ws/_RulesLeanPlaceholder.lean", "-- generated by rules_lean\n")

def _run_lake(rctx, args, timeout, env):
    lake_bin = str(rctx.path("lean_toolchain/bin/lake"))
    result = rctx.execute(
        [lake_bin] + args,
        working_directory = "lake_ws",
        environment = env,
        timeout = timeout,
        quiet = False,
    )
    return result

def _lake_env(rctx):
    bin_dir = str(rctx.path("lean_toolchain/bin"))
    return {
        "PATH": "{bin}:{rest}".format(bin = bin_dir, rest = rctx.os.environ.get("PATH", "/usr/bin:/bin")),
        "LEAN_HOME": str(rctx.path("lean_toolchain")),
        "ELAN_TOOLCHAINS": "",  # discourage elan from intervening
    }

def _list_lake_packages(rctx):
    """Return list of package directory names under lake_ws/.lake/packages/."""
    pkgs_dir = rctx.path("lake_ws/.lake/packages")
    if not pkgs_dir.exists:
        return []
    result = rctx.execute(["ls", "-1", str(pkgs_dir)])
    if result.return_code != 0:
        return []
    return [line for line in result.stdout.strip().split("\n") if line]

def _write_package_markers(rctx, packages):
    """Drop a `.marker` file at each package's olean root for lean_prebuilt_library.

    Returns the list of (package_name, lib_dir) that actually have oleans.
    """
    ready = []
    for pkg in packages:
        lib = "lake_ws/.lake/packages/{pkg}/.lake/build/lib/lean".format(pkg = pkg)
        if not rctx.path(lib).exists:
            continue
        rctx.file("{lib}/.marker".format(lib = lib), "")
        ready.append((pkg, lib))
    return ready

def _generate_build_file(rctx, packages):
    """Emit a BUILD.bazel exposing the toolchain + one prebuilt_library per package."""
    lines = [
        'load("@rules_lean//lean:lean.bzl", "lean_prebuilt_library", "lean_toolchain")',
        "",
        'package(default_visibility = ["//visibility:public"])',
        "",
        "filegroup(",
        '    name = "lean_bin",',
        '    srcs = ["lean_toolchain/bin/lean"],',
        ")",
        "",
        "filegroup(",
        '    name = "runtime",',
        "    srcs = glob(",
        "        [",
        '            "lean_toolchain/bin/**",',
        '            "lean_toolchain/lib/**",',
        '            "lean_toolchain/include/**",',
        "        ],",
        "        allow_empty = True,",
        "    ),",
        ")",
        "",
        "lean_toolchain(",
        '    name = "lean_toolchain",',
        '    lean = ":lean_bin",',
        '    runtime = ":runtime",',
        ")",
        "",
        "toolchain(",
        '    name = "lean_toolchain_def",',
        '    toolchain = ":lean_toolchain",',
        '    toolchain_type = "@rules_lean//lean:toolchain_type",',
        ")",
        "",
    ]
    for pkg, lib in packages:
        lines += [
            "lean_prebuilt_library(",
            '    name = "{name}",'.format(name = pkg),
            '    srcs = glob(["{lib}/**"], allow_empty = True),'.format(lib = lib),
            '    path_marker = "{lib}/.marker",'.format(lib = lib),
            ")",
            "",
        ]

    # Exposes the module-level imports manifest produced by RulesLean's
    # oleanImports CLI. Consumed by downstream tooling that wants to ask
    # "what does .olean X import?" without parsing oleans themselves.
    # See //lean/lib/RulesLean/Olean.lean for the library API.
    lines += [
        "filegroup(",
        '    name = "lake_imports_manifest",',
        '    srcs = ["lake_imports_manifest.tsv"],',
        ")",
        "",
        "exports_files([",
        '    "lake_imports_manifest.tsv",',
        "])",
        "",
    ]
    rctx.file("BUILD.bazel", "\n".join(lines))

    # Also emit packages.bzl exporting the full package-label set, so
    # consumers `load("@<ws>//:packages.bzl", "LAKE_PACKAGES")` instead of
    # hand-maintaining the list. Derived from the resolved Lake packages —
    # bump mathlib/cslib/etc. and this updates automatically. Labels are
    # canonical (`@@<repo>//:<pkg>`) so they resolve from any load context
    # regardless of the apparent name the consumer chose in `use_repo`.
    pkg_labels = ['    "@@{name}//:{pkg}",'.format(name = rctx.name, pkg = pkg) for pkg, _ in packages]
    rctx.file("packages.bzl", "\n".join([
        '"""Auto-generated by rules_lean\'s `lake.workspace` extension.',
        "",
        "`LAKE_PACKAGES` is the full set of resolved Lake package targets in",
        "this workspace, as labels usable directly in `lean_test` / `lean_emit`",
        "`deps`. Derived from the lake-manifest, so bumping a dependency that",
        "adds/removes transitive packages keeps the list correct with no manual",
        "edits.",
        '"""',
        "",
        "LAKE_PACKAGES = [",
    ] + pkg_labels + [
        "]",
        "",
    ]))

def _lake_workspace_impl(rctx):
    platform = _detect_platform(rctx)
    toolchain_content = rctx.read(rctx.path(rctx.attr.lean_toolchain))
    version = _parse_lean_toolchain(toolchain_content)

    _download_lean(rctx, version, platform)
    _stage_lake_workspace(rctx)

    env = _lake_env(rctx)

    # Resolve deps. Lake respects the existing lake-manifest.json if revs match
    # the lakefile; otherwise it updates the manifest. Materializes
    # .lake/packages/<pkg>/ as side effect.
    update = _run_lake(rctx, ["update"], timeout = 1200, env = env)
    if update.return_code != 0:
        fail("rules_lean: `lake update` failed.\nstdout:\n%s\nstderr:\n%s" %
             (update.stdout, update.stderr))

    packages = _list_lake_packages(rctx)
    if not packages:
        # Dep-free workspace: the lakefile declares no `require`s because the
        # project's Lean sources import only Lean 4 core (no mathlib/batteries).
        # That's valid — there's nothing to fetch or source-build. Emit just the
        # toolchain (+ an empty imports manifest / dep BUILD) and return. The
        # registered `:lean_toolchain_def` is all a dep-free consumer needs.
        _build_ruleslean_library(rctx, env)
        _generate_imports_manifest(rctx, [], env)
        _generate_build_file(rctx, [])
        return

    # Fast path: if mathlib is in the dep graph, run its `cache get` exe to pull
    # prebuilt oleans for mathlib + its transitive deps from the Reservoir
    # cache. For non-mathlib workspaces, this command does not exist, so skip.
    if "mathlib" in packages:
        cache = _run_lake(rctx, ["exe", "cache", "get"], timeout = 3600, env = env)
        if cache.return_code != 0 and not rctx.attr.allow_source_build:
            fail("rules_lean: `lake exe cache get` failed (cache miss for this " +
                 "mathlib rev?).\nSet `allow_source_build = True` to fall back " +
                 "to `lake build` (slow).\nstdout:\n%s\nstderr:\n%s" %
                 (cache.stdout, cache.stderr))

    # For any package whose oleans aren't yet on disk (no mathlib cache hit, or
    # non-mathlib workspace), source-build via `lake build <pkg>`. Skipped
    # unless allow_source_build (slow); otherwise the missing-oleans state will
    # surface as a clear error when lean_test/lean_emit can't find imports.
    if rctx.attr.allow_source_build:
        for pkg in packages:
            lib = "lake_ws/.lake/packages/{p}/.lake/build/lib/lean".format(p = pkg)
            if rctx.path(lib).exists:
                continue
            build = _run_lake(rctx, ["build", pkg], timeout = 7200, env = env)
            if build.return_code != 0:
                fail("rules_lean: `lake build %s` failed.\nstdout:\n%s\nstderr:\n%s" %
                     (pkg, build.stdout, build.stderr))

    ready = _write_package_markers(rctx, packages)
    if not ready:
        fail("rules_lean: no package oleans found under " +
             "lake_ws/.lake/packages/*/.lake/build/lib/lean/. " +
             "Cache get may have failed silently; consider allow_source_build = True.")

    _build_ruleslean_library(rctx, env)
    _generate_imports_manifest(rctx, ready, env)
    _generate_build_file(rctx, ready)

def _build_ruleslean_library(rctx, env):
    """Stage the RulesLean library source and build it with the consumer's Lean toolchain.

    The library at @rules_lean//lean/lib/ ships its own lakefile and Lake project.
    We stage it into `ruleslean_lib/` (a sibling of `lake_ws/`) and invoke
    `lake build oleanImports` to compile both the library and the CLI executable.

    Cost: ~3-5s cold per lake_workspace materialization. The cached `.lake/build/`
    persists across builds.
    """

    # The library lives at @rules_lean//lean/lib/. We need the whole directory;
    # rctx.path() on the lakefile gives us a starting point, then copy the tree.
    lakefile_path = rctx.path(Label("@rules_lean//lean/lib:lakefile.lean"))
    src_dir = str(lakefile_path.dirname)

    cp = rctx.execute(["cp", "-RL", src_dir, "ruleslean_lib"])
    if cp.return_code != 0:
        fail("rules_lean: failed to stage RulesLean library source from %s: %s" %
             (src_dir, cp.stderr))

    lake_bin = str(rctx.path("lean_toolchain/bin/lake"))
    result = rctx.execute(
        [lake_bin, "build", "oleanImports"],
        working_directory = "ruleslean_lib",
        environment = env,
        timeout = 600,
        quiet = False,
    )
    if result.return_code != 0:
        fail(("rules_lean: building the RulesLean library / oleanImports CLI " +
              "failed.\nstdout:\n%s\nstderr:\n%s") %
             (result.stdout, result.stderr))

def _generate_imports_manifest(rctx, ready, env):
    """Run oleanImports over every package's olean tree and write the manifest.

    For each (`package`, olean root) pair, enumerate every `.olean` file and
    pipe the path list through the freshly-built `oleanImports` binary. The
    resulting `<path>\\t<imported-module>` lines aggregate into
    `lake_imports_manifest.tsv` at the @lake_deps repo root, exposed via the
    generated BUILD.
    """
    olean_paths = []
    for _, lib in ready:
        result = rctx.execute(
            ["sh", "-c", "find {lib} -name '*.olean' -type f".format(lib = lib)],
        )
        if result.return_code != 0:
            continue
        for line in result.stdout.strip().split("\n"):
            if line:
                olean_paths.append(line)

    if not olean_paths:
        rctx.file("lake_imports_manifest.tsv", "")
        return

    rctx.file("olean_paths.txt", "\n".join(olean_paths) + "\n")

    cli_bin = "ruleslean_lib/.lake/build/bin/oleanImports"
    if not rctx.path(cli_bin).exists:
        # buildifier: disable=print
        print("rules_lean: WARNING — oleanImports binary not at %s; manifest empty" % cli_bin)
        rctx.file("lake_imports_manifest.tsv", "")
        return

    # Pipe paths through the CLI. stderr is collected but per-file errors
    # don't fail the rule — a single bad olean shouldn't block analysis.
    result = rctx.execute(
        ["sh", "-c", "'%s' < olean_paths.txt" % str(rctx.path(cli_bin))],
        environment = env,
        timeout = 600,
    )
    if result.return_code != 0:
        # buildifier: disable=print
        print("rules_lean: WARNING — oleanImports CLI exited %d; manifest empty.\nstderr:\n%s" %
              (result.return_code, result.stderr))
        rctx.file("lake_imports_manifest.tsv", "")
        return

    rctx.file("lake_imports_manifest.tsv", result.stdout)

lake_workspace = repository_rule(
    implementation = _lake_workspace_impl,
    attrs = {
        "lean_toolchain": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The `lean-toolchain` file. Drives both Lake's toolchain choice and the Lean binary Bazel downloads.",
        ),
        "lakefile": attr.label(
            allow_single_file = [".lean", ".toml"],
            mandatory = True,
            doc = "The lakefile (deps-only — no library/exe directives for the user's own code).",
        ),
        "lake_manifest": attr.label(
            allow_single_file = [".json"],
            mandatory = True,
            doc = "The committed lake-manifest.json (pins git revs of every Lake dep).",
        ),
        "allow_source_build": attr.bool(
            default = False,
            doc = "If True, run `lake build <pkg>` for every package whose oleans " +
                  "aren't covered by `lake exe cache get`. Slow for large packages " +
                  "(mathlib from source is ~30 min); fast and necessary for custom " +
                  "Lake deps that have no upstream cache.",
        ),
    },
    doc = "Materializes a Lake workspace as a Bazel external repo. " +
          "Produces `:lean_toolchain_def` + one `lean_prebuilt_library` " +
          "per resolved Lake package (target name = Lake's directory name).",
)

def _lake_extension_impl(mctx):
    for mod in mctx.modules:
        for tag in mod.tags.workspace:
            lake_workspace(
                name = tag.name,
                lean_toolchain = tag.lean_toolchain,
                lakefile = tag.lakefile,
                lake_manifest = tag.lake_manifest,
                allow_source_build = tag.allow_source_build,
            )

_workspace_tag = tag_class(attrs = {
    "name": attr.string(mandatory = True),
    "lean_toolchain": attr.label(mandatory = True),
    "lakefile": attr.label(mandatory = True),
    "lake_manifest": attr.label(mandatory = True),
    "allow_source_build": attr.bool(default = False),
})

lake = module_extension(
    implementation = _lake_extension_impl,
    tag_classes = {"workspace": _workspace_tag},
)
