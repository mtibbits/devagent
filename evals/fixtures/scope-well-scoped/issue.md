# example/repo#901 — doctor should report the resolved analyze family per project

- State: open
- Author: @someone
- Labels:

---

## Scope
`/devagent:doctor` prints config validity but not which `analyze` family
(cmake/shellcheck/none) each project resolved to. Add one read-only line per
project to the doctor report so the operator can confirm the step-11 family
without opening config.toml.

## Acceptance criteria
- [ ] doctor prints `analyze: <family>` per project
- [ ] read-only (no config writes)
- [ ] one bats case asserting the line appears
