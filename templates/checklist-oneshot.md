# {{ISSUE_ID}} — Workflow checklist

State key: [ ] pending  [x] done  [-] skipped  [!] stuck  [~] in-progress  [?] blocked-external  [P] parked

Template: oneshot
Created: {{CREATED_AT}}
Active revision: 1

Boundary: a one-shot is an operational action, not a repo change — commit/ship
rows are absent by design; an action that produces a diff belongs in the
standard tier (escalate with `revise.sh --retier standard`, which restarts the
issue at draft). While this checklist's `Template:` reads `oneshot`, that is
enforced mechanically, not by prose: `scripts/oneshot-zerodiff.sh` checks that
the source tree carries no unpublished change (on the base branch, no commits
beyond `default_baseline`, no uncommitted paths) and cleanup (step 23) REFUSES
to close on a `violated` or `indeterminate` verdict (#595); a retier lifts this
paragraph's claim along with the tier — read the `Template:` line, not this
prose. It cannot attribute a change to this issue (the tree is shared), so it
reports what it found and asks you to judge; a tree left on a sibling issue's
branch is the routine `indeterminate` — check out the base and re-run. Document
(step 11) is the verify beat: it must record execution evidence (command
output, service-answers proof) — including that verdict — not just narrate
intent.

## Revision 1

- [ ]  0. pull
- [ ]  9. implement
- [ ] 11. document
- [ ] 22. lessonslearned
- [ ] 23. cleanup

## Log
