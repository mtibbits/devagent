<!-- derived-from: README.md -->
# What is devAgent

devAgent is a Claude Code plugin that runs development work through a fixed,
auditable issue workflow and keeps all of its state on disk — so you can
switch between issues, or hand one to a fresh session, without losing
context. It provides **57 slash commands** driving a **22-step workflow**,
and works against GitHub, GitLab, and JIRA trackers and forges, layering
capture, issue red-team, revision, WBS, and status-report subsystems on top
of the core loop.

## Why a fixed workflow

Ad-hoc agent sessions lose their state when the context window ends. devAgent
trades improvisation for auditability:

- **Every issue gets a `checklist.md`** that tracks its progress through the
  workflow, step by step. Any session — today's or next week's — can pick an
  issue up exactly where it stopped.
- **Steps are permanently numbered IDs.** Each step leaves an on-disk
  artifact (a plan, a scope evaluation, review findings, an MR body), so the
  full history of a change is reviewable after the fact.
- **Fresh-session handoff is built in.** `/devagent:where` shows the active
  issue and its next step; `/devagent:catchup` rehydrates one issue on a
  single screen.
- **Review feedback loops back into the plan.** `/devagent:revise` opens a
  new revision pass that pulls reviewer comments and re-runs the workflow
  from the draft step.

## The shape of the loop

- **Plan** — `0 pull` · `22 research` _(optional, flagged)_ · `1 draft` ·
  `23 spike` _(optional, flagged)_ · `2 scope` · `3 improve` · `4 prune` ·
  `5 tighten`
- **Implement** — `6 branch` · `7 implement` · `8 quality` · `9 document` ·
  `10 commit` · `11 analyze`
- **Ship** — `12 draftmr` · `13 review` · `14 redmr` · `21 preship` ·
  `15 ship`
- **Integrate & close** — `16 mergetoall` · `17 updatewbs` · `18 impact` ·
  `19 lessonslearned` · `20 cleanup`

## Where to go next

- [Install](./install.md) — prerequisites, supported platforms, and the
  two-command install.
- [Quickstart](./quickstart.md) — from empty config to a merged-ready MR.
- [Workflow reference](./workflow.md) — the full step table, checklist
  glyphs, and the revision loop.
- [Configuration](./configuration.md) — `config.toml`, the five-verb backend
  contract, and the template registry.
- [Multi-project & concurrency](./concurrency.md) — session pins, the shared
  pointer, and parking.
