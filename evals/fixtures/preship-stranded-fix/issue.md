# example/repo#904 — ship.sh must refuse to push a dirty tree

- State: open
- Author: @someone

---

## Scope
`ship.sh` pushes the branch even when tracked files are modified in the working
tree, which can strand review/redmr fixes that were never committed. Add a hard
gate: if `git status --porcelain` shows any modified tracked file, die before push.

## Acceptance criteria
- [ ] ship.sh dies with a clear message when tracked files are modified
- [ ] a bats case proves the die (mutation-proven RED against the ungated script)
- [ ] untracked-only trees still push (devdoc artifacts are not tracked source)
