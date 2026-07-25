<!-- derived-from: README.md -->
# What is devAgent

devAgent is a Claude Code plugin that runs development work through a fixed,
auditable issue workflow and keeps all of its state on disk — so you can
switch between issues, or hand one to a fresh session, without losing
context. It provides **57 slash commands** driving a **22-step workflow**,
and works against GitHub, GitLab, and JIRA issue trackers — with GitHub and
GitLab as code forges — layering capture, issue red-team, revision, WBS, and
status-report subsystems on top of the core loop.

## Why a fixed workflow

Ad-hoc agent sessions lose their state when the context window ends. devAgent
trades improvisation for auditability:

- **Every issue gets a `checklist.md`** that tracks its progress through the
  workflow, step by step. Any session — today's or next week's — can pick an
  issue up exactly where it stopped.
- **Steps are permanently numbered IDs.** Each step leaves an on-disk
  artifact (a plan, a scope evaluation, review findings, an MR body), so the
  full history of a change is reviewable after the fact.
- **Fresh-session handoff is built in.** `/devagent:where` and
  `/devagent:catchup` rehydrate the active issue in a fresh session.
- **Review feedback loops back into the plan.** `/devagent:revise` opens a
  new revision pass — see [the revision loop](./workflow.md).

## The shape of the loop

Four phases — **Plan → Implement → Ship → Integrate & close** — carry an
issue from a drafted, adversarially-checked plan through implementation,
review, and an opened MR, to integration, impact measurement, and close-out.
The [workflow reference](./workflow.md) tables every numbered step.

## Where to go next

- [Install](./install.md) — prerequisites, supported platforms, and the
  two-command install.
- [Quickstart](./quickstart.md) — from empty config to a merge-ready MR.
- [Workflow reference](./workflow.md) — the full step table, checklist
  glyphs, and the revision loop.
- [Configuration](./configuration.md) — `config.toml`, the five-verb backend
  contract, and the template registry.
- [Multi-project & concurrency](./concurrency.md) — session pins, the shared
  pointer, and parking.
