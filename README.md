# devAgent

Claude Code plugin that preserves workflow state across issue switches. See
`docs/superpowers/specs/2026-05-19-devagent-plugin-design.md` for the design
spec. v1 is built in 10 incremental plans under `docs/superpowers/plans/`.

This plan (Plan 01) ships only the foundation:
`/devagent:init`, `/devagent:doctor`, and the `checklist-*` family.
