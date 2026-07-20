# {{ISSUE_ID}} — Workflow checklist

State key: [ ] pending  [x] done  [-] skipped  [!] stuck  [~] in-progress  [?] blocked-external  [P] parked

Template: oneshot
Created: {{CREATED_AT}}
Active revision: 1

Boundary: a one-shot is an operational action, not a repo change — commit/ship
rows are absent by design; an action that produces a diff belongs in the
standard tier (escalate with `revise.sh --retier standard`). Document (step 9)
is the verify beat: it must record execution evidence (command output,
service-answers proof), not just narrate intent.

## Revision 1

- [ ]  0. pull
- [ ]  7. implement
- [ ]  9. document
- [ ] 19. lessonslearned
- [ ] 20. cleanup

## Log
