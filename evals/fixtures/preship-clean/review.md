context: subagent
model: opus

# Code review — 2026-07-13

## Blocking

### [BLOCKING] guard must run before the sed, or a bad step still rewrites nothing silently
The absence check has to happen BEFORE the `sed` mark write. If the grep for the
step line is placed after the sed, an absent step number produces an empty sed
match and the script still exits 0 — the silent no-op this issue targets.
Remediation: grep for `^- \[.\] *<N>\.` and die on no-match BEFORE the sed.

## Non-blocking
- (none)
