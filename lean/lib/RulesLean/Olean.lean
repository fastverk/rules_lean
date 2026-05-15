import Lean

/-!
# `RulesLean.Olean` — introspect compiled `.olean` files.

Reads the metadata embedded in compiled `.olean` files using Lean's
own `Lean.readModuleData` API. Fast (header-only reads, no body
deserialization) and faithful — same view Lean itself uses at
elaboration time.

## What's exposed

* `imports` — the modules a given `.olean` directly imports.
* `transitiveImports` — closed under a caller-supplied
  `(moduleName → path)` resolver.

## What's deferred to follow-up versions

* Exported constants (the symbol table). Requires reading the
  full module body, not just the header.
* Axiom-dependency graph (which axioms each constant transitively
  depends on). Same.
* Content hash of the module data. Already used internally by Lean's
  incremental machinery; will expose as a clean accessor.
-/

namespace RulesLean.Olean

open Lean

/--
Read the `.olean` at `path` and return its declared imports.

Touches only the module header — no body decode, so fast even on
mathlib-scale libraries (~5s for 7878 oleans on Apple Silicon).
Errors propagate as plain `IO.userError`; failed reads are the
caller's problem to swallow.
-/
unsafe def imports (path : System.FilePath) : IO (Array Import) := do
  let (modData, _) ← readModuleData path
  return modData.imports

/--
The same data as `imports`, but flattened to plain module names — the
common case where callers only want the imported `Name`s, not the
full `Import` records (which also carry runtime/transitively-public
flags we rarely need).
-/
unsafe def importModuleNames (path : System.FilePath) : IO (Array Name) := do
  let imps ← imports path
  return imps.map Import.module

/--
Transitive import closure over a caller-supplied resolver.

`resolve` maps a module name to its `.olean` path; if the resolver
returns `none`, the module is treated as a leaf (typically because
it's outside the Lake workspace we're considering — e.g., Init from
the toolchain stdlib that we don't want to walk into).

Returns the set of module names reachable from `start`, including
`start` itself. Order is unspecified; uses a worklist with
deduplication.

Cycle-safe: each module is visited at most once.
-/
unsafe def transitiveImports
    (start : Name)
    (resolve : Name → IO (Option System.FilePath))
    : IO (Array Name) := do
  let mut visited : Std.HashSet Name := {}
  let mut worklist : Array Name := #[start]
  while !worklist.isEmpty do
    let some mod := worklist.back? | break
    worklist := worklist.pop
    if visited.contains mod then
      continue
    visited := visited.insert mod
    match ← resolve mod with
    | none => pure ()  -- unresolved: treat as leaf
    | some path =>
      let imps ← importModuleNames path
      for imp in imps do
        if !visited.contains imp then
          worklist := worklist.push imp
  return visited.toArray

/--
Initialise Lean's search path against the toolchain sysroot.

Callers that invoke `imports` or `readModuleData` directly must do
this once at program start, otherwise the module deserialization
fails to resolve transitive header references. Wraps `findSysroot` +
`initSearchPath` so callers don't have to remember the incantation.
-/
unsafe def initialise : IO Unit := do
  let sysroot ← findSysroot
  initSearchPath sysroot []

end RulesLean.Olean
