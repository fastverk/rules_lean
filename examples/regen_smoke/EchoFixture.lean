/-
Smoke for `lean_emit.data` (rules_lean v0.3.3). Reads `fixture.txt`
from the action's work directory (staged via the `data` attr) and
echoes it verbatim. The diff_test verifies the echoed content matches
`expected_echo.txt`, which is just `fixture.txt`'s content — proving
the data file is reachable from the entry's relative-path `readFile`.
-/

def main : IO Unit := do
  let s ← IO.FS.readFile "fixture.txt"
  IO.print s
