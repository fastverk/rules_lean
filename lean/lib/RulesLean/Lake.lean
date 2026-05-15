import Lake

/-!
# `RulesLean.Lake` — introspect Lake workspaces.

Will wrap Lake's own APIs to give Bazel rules + standalone tools
structured access to a resolved Lake workspace: the manifest, the
package graph, per-package olean roots, and the namespace→package
mapping that lets you resolve a module name to its containing
package.

## Status

**v0.1 stub.** `import Lake` is wired but the public surface is
empty — content lands as the tree-shaking infrastructure surfaces
concrete needs. Specifically planning:

* Manifest parsing — Lake's `lake-manifest.json` loader, returning a
  structured view of every package in the workspace (URL, git rev,
  `inherited` flag). The Lake API shape varies across Lean releases
  (4.29 differs from 4.30+); the right wrapper depends on which
  Lean version a consumer's `lake_workspace` materializes.
* Per-package olean-root discovery (`.lake/packages/<pkg>/.lake/
  build/lib/lean/` per the Lake 5+ layout convention).
* Namespace→package index (top-level Lean namespace → providing
  Lake package), derived from the resolved workspace.

## Why use Lake's APIs vs. parsing JSON/lakefile by hand

Lake's manifest schema evolves between Lean versions (`inputRev`,
`inherited`, `scope` were added at different points). Going through
Lake's own loaders gives the same view Lake itself uses, with
version-tolerant parsing — at the cost of API shape drift between
Lean releases.
-/

namespace RulesLean.Lake

-- (stubs land here as APIs are needed)

end RulesLean.Lake
