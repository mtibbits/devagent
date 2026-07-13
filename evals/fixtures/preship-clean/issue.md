# example/repo#905 — checklist-mark must reject an out-of-range step number

- State: open
- Author: @someone

---

## Scope
`checklist-mark.sh` silently no-ops when given a step number that does not exist
in the checklist, so a typo (`mark 99 x`) looks like it succeeded. Add a guard:
if the step number is not present in the checklist, die with a clear message.

## Acceptance criteria
- [ ] checklist-mark.sh dies when the step number is absent from the checklist
- [ ] a bats case proves the die (mutation-proven RED against the ungated script)
- [ ] a valid step number still marks as before (regression case)
