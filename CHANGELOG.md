# Changelog

All notable changes to devAgent are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

devAgent is currently versioned by its **git commit SHA** (the marketplace entry
carries no pinned `version`), so every commit on `master` is a release and
`claude plugin update` tracks new commits without a reinstall. When a stable
release cadence is adopted (a go-public decision — see #532, ratified
2026-07-20: SHA-tracking stays until then), tagged versions (`claude plugin
tag`) will get their own dated sections below.

## [Unreleased]

### Changed — 2026-07-29
- **Step 19 (`mergetoall`) is now optional and off by default.** Checklist
  templates (standard, perf, docs-only) and revision blocks scaffold the row
  pre-marked `[-]` (skipped); configuring the per-project `all_prs_branch`
  flips it back to `[ ]` pending at scaffold time (pull, revise, and
  `--retier` all apply the same filter). The workflow is now counted as
  21 mandatory + 3 optional steps.

  **Upgrading:** if you rely on step 19 without `all_prs_branch` set (e.g.
  invoking `/devagent:mergetoall` manually), set `all_prs_branch` in
  `[project.<name>]` — otherwise new checklists and revision blocks ship the
  row skipped and `/devagent:next --auto` sails past it. Checklists
  scaffolded before this release are untouched: a pending row 19 stays
  pending, and `mergetoall.sh`'s runtime auto-skip still covers the
  unconfigured and zero-diff cases at dispatch. A manual per-issue opt-in
  (`checklist-mark.sh --by-name mergetoall` back to pending) does NOT survive
  `/devagent:revise` — the new revision block re-applies the config-derived
  glyph, matching research/spike semantics.

### Changed — 2026-07-26 (#558)
- **Workflow steps are renumbered to execution order.** Checklist numbers are
  now POSITIONS, not permanent IDs: the standard template reads `0 pull` …
  `23 cleanup` top-to-bottom. Old `21 preship` is now `17`, optional old
  `22 research` is now `1`, and old `23 spike` is now `3`. The workflow is
  described as **24-step** throughout (24 numbered step commands, 22 of them
  mandatory). Execution order is unchanged — dispatch is by step NAME and
  file order was always the authority.

  **Upgrading with work in flight — run the migrator first.** A checklist
  scaffolded before this release carries the old numbers. The seven script
  **self-marks** now **hard-stop** on it rather than marking the wrong row
  (`checklist_mark` refuses when the number's row name does not match the
  calling step), and command-doc handoffs mark by NAME, which is
  scheme-proof. Callers outside those two classes (e.g. `unstuck.sh`'s
  file-wide `[!]` scan) are NOT guarded — one more reason to migrate before
  resuming:

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/migrate-checklist-numbering.sh" --dry-run --all
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/migrate-checklist-numbering.sh" --all
  ```

  It is keyed by step NAME (correct on old, a no-op on current, safe on a
  mixed file), idempotent, and reversible with `--reverse` if you roll #558
  back. `--all` covers projects present in `config.toml`; pass any other issue
  directory explicitly. Completed checklists are skipped by design.
  `/devagent:revise` remains an alternative — it opens a fresh, correctly
  numbered revision block — but the migrator is the direct remedy the
  hard-stop message names.

  Without migrating, the older symptom also applies: `[project.<name>.step_models]` tier
  resolution is keyed to the step NUMBER read from the checklist, so an
  old-numbered checklist resolves the WRONG model class: old `3 improve`,
  `13 review` and `21 preship` fall back to the default tier, and old
  `14 redmr` resolves as *thinking*. Run `/devagent:revise` to regenerate the
  checklist's revision block with current numbering before relying on a tier
  override. Steps that can be invoked outside a revision block (`research`,
  `spike`) now read and mark by NAME (`checklist-mark.sh --by-name`), so a
  checklist holding both schemes cannot be mis-marked.

  Numeric per-step keys in `[project.<name>.step_models]` (e.g.
  `"13" = "opus"`) must be remapped by hand; the class keys (`thinking` /
  `checking` / `default`) are unaffected.

### Added — 2026-07-25 (#461)
- `docs-site/`: six audience-facing onboarding pages (what is devAgent,
  install, quickstart, workflow reference, configuration, multi-project &
  concurrency) plus a content-drift policy, guarded by `tests/docs-site.bats`
  (line-1 derive headers, both-sides token pins with README, a step table
  derived from `templates/checklist-standard.md`, command-arity pins).
  Static markdown only — Pages deployment is the #404 sibling child.

### Changed — 2026-07-25 (#541)
- superpowers demoted from declared dependency to recommended plugin: the
  manifest carries no `dependencies` key (measured at CC 2.1.211: dependencies
  never auto-install and an unresolved one silently disables the whole plugin);
  draft / implement / review gain built-in fallbacks + a one-line install
  nudge, and `/devagent:doctor` WARNs when the plugin is absent or disabled.
  Pre-#541 installs sit at `✘ failed to load` under the old cached manifest:
  run `claude plugin update devagent@devagent` once to heal (measured —
  the update alone flips the plugin to `✔ enabled`, superpowers still absent).

Current capabilities as of this commit:

### Core
- **57 slash commands** driving a fixed **24-step issue workflow** (22 mandatory,
  plus the optional research step 1 and spike step 3), with all
  state preserved on disk so you can switch issues — or hand one to a fresh
  session — without losing context.
- `next`/`capture`/`ship` converted from commands to user-invocable skills with
  `references/`; `next` thinned 5,764 → 2,209 chars whole-file (operative body
  5,565 → 1,916, pinned under 2,000 by #439's size canary).
- Backends: **GitHub, GitLab, and JIRA** (issue trackers + code forges).
- Subsystems: capture + issue red-team, revision, WBS, status reports, and an
  auth subsystem (PAT / SSH-key lifecycle).

### Plugin conformance & distribution readiness
- `.claude-plugin/plugin.json` manifest with no hard dependencies — `superpowers`
  is recommended, not declared (#541; the pre-#541 manifest declared it).
- SHA-versioned marketplace entry (no pinned `version`) so `/plugin update`
  works without uninstall + reinstall.
- Every command routes its scripts through `${CLAUDE_PLUGIN_ROOT}` (works from a
  marketplace install), enforced by a CI canary.
- `allowed-tools` scoped past a blanket `Bash` grant, on commands and skills
  alike.
- Invocation control: the 14 internal `core-*` skills are hidden from the `/`
  menu (`user-invocable: false`), and `auth`/`init`/`use` are operator-timed
  (`disable-model-invocation: true`).
- `argument-hint` autocomplete grammar on every command.
- Packaging: LICENSE (MIT), this CHANGELOG, and a README install section.
