import Lake.Load.Manifest

/-!
# `RulesLean.Workspace` — introspect Lake workspaces.

Wraps Lake's `Manifest` API to give Bazel rules + standalone tools
structured access to a resolved Lake workspace.

Defines `RulesLean.Workspace` rather than `RulesLean.Lake` to avoid
shadowing the upstream `Lake` namespace inside our own namespace
scope (the `Lake.Manifest` references below would otherwise resolve
to `RulesLean.Lake.Manifest` and silently miss the upstream type).

## What's exposed

* `loadManifest` / `loadManifest?` / `parseManifest` — wrappers over
  Lake's loaders.
* `directRequires` / `inheritedRequires` — split a manifest's
  packages by `inherited` flag.
* `packageByName?` / `packageRev?` / `packageUrl?` — accessors.
* `oleanRootRelative` — compute a package's olean directory under
  the Lake 5+ layout convention.

## What's not (yet) exposed

* Namespace→package index — needs filesystem inspection of each
  package's olean root.
* Cross-package dep edges (mathlib requires batteries etc.) — not
  in the manifest format; would need to parse each package's
  lakefile.
-/

namespace RulesLean.Workspace

/--
Load a `lake-manifest.json` from disk into Lake's structured
`Manifest`. Throws on parse failure.
-/
def loadManifest (path : System.FilePath) : IO Lake.Manifest :=
  Lake.Manifest.load path

/--
Same as `loadManifest`, but returns `none` if the file is missing.
Other errors still throw.
-/
def loadManifest? (path : System.FilePath) : IO (Option Lake.Manifest) :=
  Lake.Manifest.load? path

/-- Parse a `Manifest` from a JSON string. -/
def parseManifest (data : String) : Except String Lake.Manifest :=
  Lake.Manifest.parse data

/-- Top-level `require` packages (direct deps of the workspace root). -/
def directRequires (m : Lake.Manifest) : Array Lake.PackageEntry :=
  m.packages.filter (!·.inherited)

/-- Transitively-pulled-in packages (inherited from another package's deps). -/
def inheritedRequires (m : Lake.Manifest) : Array Lake.PackageEntry :=
  m.packages.filter (·.inherited)

/-- Find a package entry by name. -/
def packageByName? (m : Lake.Manifest) (name : Lean.Name) : Option Lake.PackageEntry :=
  m.packages.find? (·.name == name)

/-- The git rev a package is pinned to, if it's a git dep. -/
def packageRev? (entry : Lake.PackageEntry) : Option String :=
  match entry.src with
  | Lake.PackageEntrySrc.git _ rev _ _ => some rev
  | Lake.PackageEntrySrc.path _ => none

/-- The git URL of a package entry, if it's a git dep. -/
def packageUrl? (entry : Lake.PackageEntry) : Option String :=
  match entry.src with
  | Lake.PackageEntrySrc.git url _ _ _ => some url
  | Lake.PackageEntrySrc.path _ => none

/--
Compute the canonical olean-root directory for a package under the
Lake 5+ layout: `<packagesDir>/<name>/.lake/build/lib/lean`.

Workspace-relative; callers prepend the workspace root. Returns
`none` if the manifest's `packagesDir?` isn't set.
-/
def oleanRootRelative (m : Lake.Manifest) (entry : Lake.PackageEntry)
    : Option System.FilePath := do
  let packagesDir ← m.packagesDir?
  let pkgDir := entry.name.toString
  some (packagesDir / pkgDir / ".lake" / "build" / "lib" / "lean")

end RulesLean.Workspace
