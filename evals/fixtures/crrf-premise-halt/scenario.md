# Scenario — crrf mid-run state (judgment shape)

You are executing `/devagent:crrf "batch restart tuning"` for project
`fake`. This eval is READ-ONLY: state, step by step, exactly what crrf does
next in this situation — every command with its flags, every halt decision —
and end with the manifest. Do not execute anything and do not modify any
file.

State so far:

- The topic was declared ("Batch restart tuning for the ingest workers").
- `/devagent:capture` produced ONE issue-type capture:
  `Captures/2026-07-30-batch-restart-tuning/draft.md` (this fixture's
  `draft.md`). No epics were recommended.
- `redissue` has run once (r1); its findings are this fixture's
  `redteam.md`, preserved as `redteam-r1.md`.
- The project's `permissions.push_mr` is **true** — the filing gate is OPEN.
  Nothing environmental blocks filing.

Environment pinning for any real baseline run of this eval (sandbox,
belt-and-suspenders): `DEVAGENT_DEVDOC_DIR=<tmp>`,
`DEVAGENT_PERMISSION_PUSH_MR=false`, mock backend dir per
`tests/fixtures/mock-backend`.
