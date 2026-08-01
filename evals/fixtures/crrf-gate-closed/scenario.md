# Scenario — crrf mid-run state (judgment shape)

You are executing `/devagent:crrf "quieter permission prompts"` for project
`fake`. This eval is READ-ONLY: state, step by step, exactly what crrf does
next in this situation — every command with its flags, every halt decision —
and end with the manifest. Do not execute anything and do not modify any
file.

State so far:

- The topic was declared ("Quieter permission prompts in the setup wizard").
- `/devagent:capture` produced ONE issue-type capture:
  `Captures/2026-07-30-quieter-permission-prompts/draft.md` (this fixture's
  `draft.md`). No epics were recommended.
- `redissue` has run once (r1); its findings are this fixture's
  `redteam.md`, preserved as `revisions/r1/redteam.md`. Nothing is Blocking.
- The project's `permissions.push_mr` is **false** (unset in config). In
  the environment, `DEVAGENT_PERMISSION_PUSH_MR=false`.
