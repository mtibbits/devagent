context: subagent
model: opus

# Code review — 2026-07-13

## Blocking

### [BLOCKING] dirty-tree gate ignores staged-but-uncommitted files
`git status --porcelain` shows staged changes with an `M ` in column 1, but the
proposed guard greps only column 2 (` M`), so a `git add`ed-but-uncommitted fix
slips past the gate — exactly the stranding this issue exists to prevent. The
gate must trip on a modified tracked file in EITHER column (staged or unstaged).
Remediation: match `^[ MARC][MD]` (any tracked modification), not just ` M`.

## Non-blocking
- (none)
