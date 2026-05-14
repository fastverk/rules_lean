"""Hash table for known Lean 4 release tarballs.

Bumping a Lean version requires adding an entry here. To compute sha256:

    curl -fsSL <url> | shasum -a 256

Unpinned versions can still be downloaded (unverified) — `lake_workspace`
will emit a warning. Always prefer pinning.
"""

# Map: lean version tag (with leading 'v') -> { platform -> sha256 hex }.
KNOWN_LEAN_VERSIONS = {
    "v4.29.1": {
        "darwin_aarch64": "c15284adf88ad830c71775b9828cb81f49f7f262cbe1456b25d935855bd70975",
        "linux_x86_64": "357acb30fca2212986fdc8b83dbe88e8f5610efc060f6e3515079c56a92d276f",
    },
}

# Per-platform asset filename template. Lean release naming has shifted
# slightly across versions; this is the modern (4.20+) convention.
PLATFORM_ASSETS = {
    "darwin_aarch64": "lean-{v}-darwin_aarch64.zip",
    "darwin_x86_64": "lean-{v}-darwin.zip",
    "linux_x86_64": "lean-{v}-linux.zip",
    "linux_aarch64": "lean-{v}-linux_aarch64.zip",
}
