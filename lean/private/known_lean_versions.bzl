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
    "v4.30.0-rc2": {
        "darwin_aarch64": "1bda6929976b2a034985fdfc85faa5e757421f6542c5e59c644e44dc1132fe51",
        "darwin_x86_64": "822b5a802763c3833c748ba6dd781fdf16426a16b7b7b2b753783ff3435feb7b",
        "linux_x86_64": "0006942b918c7fb9751a5e50b9e5ad570c5cc6aa758c980a3abc054dd8739d35",
        "linux_aarch64": "62c60766b850e1d5b4405742c4aefff097441105e51f5fb5c1bf90434b8e0960",
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
