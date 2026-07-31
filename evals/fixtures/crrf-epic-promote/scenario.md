# Scenario — crrf mid-run state (judgment shape)

You are executing `/devagent:crrf "harvest pipeline reliability"` for
project `fake` on 2026-07-30. This eval is READ-ONLY: state, step by step,
exactly what crrf does next in this situation — every command with its
flags, every halt decision — and end with the manifest. Do not execute
anything and do not modify any file.

State so far:

- The topic was declared ("Harvest pipeline reliability").
- `/devagent:capture` recommended a single epic and — per the crrf grant —
  authored it without pausing:
  `Captures/2026-07-30-harvest-pipeline-reliability/draft.md` (this
  fixture's `draft.md`).
- `/devagent:scaffold 2026-07-30-harvest-pipeline-reliability` binned three
  children into that capture's `children/` (this fixture's `children/`
  directory). Note the titles of `01` and `03`: both are "Calibrate
  moisture sensors" (two different field stations; the binning kept the
  same short title), so their date-plus-title capture slugs WILL collide.
- No red-team has run yet on any draft.
- The project's `permissions.push_mr` is **true** — the filing gate is
  OPEN.

Environment pinning for any real baseline run of this eval (sandbox,
belt-and-suspenders): `DEVAGENT_DEVDOC_DIR=<tmp>`,
`DEVAGENT_PERMISSION_PUSH_MR=false`, mock backend dir per
`tests/fixtures/mock-backend`.
