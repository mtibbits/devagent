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

### Fixed — 2026-08-07
- **Evidence runs now measure the checkout the issue's work lives in, or
  refuse (#571).** `run-suite.sh` used to `cd` into the configured
  `source_dir` regardless of where it was invoked, so a suite run from a git
  worktree or second clone silently produced a green artifact about the wrong
  tree (observed in Issue-553) — a failure #572's scope guard cannot see,
  because it fires even when the project resolves correctly. Both evidence
  scripts now resolve `state.worktree_path`-else-`source_dir`
  (`active_tree_resolve`) and refuse with `TREE MISMATCH` when invoked from
  another checkout of the *same* project (a linked worktree, else an
  equal-`origin` clone; remote-less and differing-origin shapes fail open by
  documented decision — note this fires even for an explicitly-scoped
  invocation, unlike the scope guard). A mid-run HEAD move also refuses, and
  the suite-count artifact carries a canonical `tree:` stamp that
  `preship-evidence.sh` cross-checks (a stamp naming a tree absent in the
  checking environment warns and falls back to the head comparison —
  cross-environment evidence stays shippable). Per-call escape:
  `DEVAGENT_TREE_GUARD_OVERRIDE=1` (truth-valued). Spec §7.5.
- **Unscoped scripts no longer silently act on the global pointer's project
  (#572).** The 14 write-, verify- or transition-capable resolving scripts
  (triage: `docs/resolver-scope-triage.md`, sweep-tested) now refuse a bare
  invocation when `$PWD` demonstrably belongs to a DIFFERENT configured
  project than the one the pointer/env resolved — dying with a message naming
  both projects, both active issues, and the resolution source. An explicit
  scope (positional or `--project`) is never questioned; an undecidable cwd
  allows with a warning naming the resolved project and source; the per-call
  escape is `DEVAGENT_SCOPE_GUARD_OVERRIDE=1` (truth-valued). `next.sh` guards
  before its pointer refresh, so a mismatched bare chain neither dispatches
  nor moves the pointer. `checklist-init.sh` gains `--project`; the four
  workflow docs that invoked these scripts bare now pass the scope. Spec §7.5.

### Fixed — 2026-08-06
- **Workflow-script calls now auto-approve on Claude Code ≥ 2.1.223 (#548).**
  All 57 `allowed-tools` grants (54 commands + 3 skills) moved to the
  probe-verified quoted two-token form
  `Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)`.
  Two measured facts drove the form: (1) `${CLAUDE_PLUGIN_ROOT}` now substitutes
  inside `allowed-tools` (#533's 2.1.211 negative flipped — measured, not
  documented upstream); (2) matching is a literal prefix match, so the grant
  must carry the same QUOTED shape the command bodies emit — the old unquoted
  form never matched, and the issue's proposed `${CLAUDE_SKILL_DIR}` target
  never substitutes for command files at all (it would have broken all 54).
  Live-verified end-to-end against the real plugin (stream-json, hermetic
  settings); re-asked on every CC upgrade by the new filled
  `plugin-root-grant-automatch` smoke rung. Both permission-caveat docs homes
  rewritten to the positive; verified-against re-stamped to 2.1.223. Evidence:
  Issue-548 `decision-skill-dir-probe.md`.

### Fixed — 2026-08-04
- **An EMPTY `## Workflow flags` heading no longer leaves the block open
  (#553).** The block ended at the next `#` heading, or at a blank line once at
  least one key had been seen. That `seen` gate exists because terminating on
  the FIRST blank silently dropped every flag in the markdown-conventional
  heading/blank/keys form (#535 redmr). The residual: with an EMPTY heading no
  key has been seen at the blank either, so the block stayed open across prose
  and a later col-1 `key: value` prose line parsed as a live flag. Since #561's
  `implementation-model`/`checking-model` keys are die-class, that had stopped
  being a spurious warning and become a hard `pull.sh` failure — reproduced by
  this issue's own body, whose fenced EXAMPLE made a real scaffold warn. The
  block now also ends, while no key has been seen, at the first non-blank line
  that is not a col-1 key. **No currently-valid body changes meaning:** the rule
  fires only inside the no-key-yet window, so any block whose first in-block
  non-blank line is a key parses bit-for-bit as before. The one trade-off, and
  it is warn-LESS: a block that opens with a MALFORMED key line — mis-cased
  (`Tier:`), indented, or a list item — now closes there and silently drops the
  legitimate keys below it, where before those keys were read. No fixture
  carries that shape; a warn-on-close follow-up is recorded on the issue. See
  spec §6.3. Both rules the issue
  proposed were falsified by execution first — one never fires on the
  reproducer, the other reintroduces the #535 regression — because the two
  shapes share their first three lines and no rule keyed on a blank can
  separate them. One line per state machine, in `flags_get` and
  `flags_validate` alike, with an anti-drift guard asserting it lands in both.

### Fixed — 2026-08-01
- **The mandatory/optional step-split claim is reconciled and now guarded
  (#566).** The "Current capabilities" line still carried the pre-#562 split —
  a mandatory count one higher than today's, naming only two optional steps —
  and now matches spec §6.3, the README, and `docs-site/workflow.md`. The #558
  entry below drops its incidental step-split count, and the docs site drops a
  redundant word-form count — two places where the number carried no weight for
  a reader. The remaining homes keep the number, because a reader of the README
  or the site wants it in front of them; they stay correct by being swept rather
  than by being removed. `tests/checklist-numbering.bats` now sweeps every prose
  home of the claim across the tracked tree — subject set
  derived from the predicate, expected value derived from
  `templates/checklist-standard.md` — so the next optionality change reddens
  instead of drifting silently.

### Added — 2026-07-31
- **`/devagent:crrf` — autonomous capture → red-team → revise → file (#559).**
  An orchestration alias over the existing verbs: invoking it IS the
  operator's bounded autonomy grant (topic declared first; the capture
  skill's multi-epic confirmation answered in advance; scaffolded children
  promoted to their own captures; at most two revise cycles per draft;
  premise-level red-team findings halt before filing; the `push_mr` gate
  delegated to `file.sh` exit 4, never `--yes`; every run ends with a
  kept/discarded manifest). Pinned by `tests/crrf.bats`; the behavioral half
  is baselined by three `crrf-*` eval cases.

### Added — 2026-07-29
- **Per-issue model steering for both step classes, plus a `tier:` compat
  shim (#561).** Two new `## Workflow flags` keys, orthogonal to `tier:`
  (which remains the checklist-template selector):

  | Key | Class | Steps |
  |---|---|---|
  | `implementation-model: <token>` | *thinking* | 2 draft · 9 implement · 10 quality · 11 document · 14 draftmr |
  | `checking-model: <token>` | *checking* | 5 improve · 15 review · 16 redmr · 17 preship |

  Legal tokens: `sonnet opus haiku fable inherit`, validated fail-closed before
  any file write. Both resolve into the per-issue `.devagent-step-models`
  marker at first scaffold, whose format now accepts keyed
  `checking:` / `thinking:` lines in addition to the legacy bare token.

  **Enforcement differs by step and the key names under-promise it:**
  `checking-model` is fully enforced (all four checking steps dispatch and
  consume the tier as their Agent-tool `model:` override), while
  `implementation-model` is enforced for **draft only** and **advisory** for
  9/10/11/14 — those run inline and a session cannot swap its own model, so
  the tier appears only as the `next`/`catchup` hint.

- **`tier: <model>-checking` no longer breaks `pull`.** That form is a model
  annotation from a convention predating #537's claim on the `tier:` key
  (koopman-gnn), and #537 made those bodies die pre-path — blocking the pull
  of already-drafted issues (observed: koopman-gnn#106). `pull.sh` now warns,
  leaves the template on the project default chain, and reads it as
  `checking-model: <model>`. The shim is **permanent grammar and warns
  always** — the warning is the migration nudge, and a removal date would
  orphan capture drafts that are not yet filed. Any other unknown `tier:`
  value still dies listing the legal tier names.

- **Forge labels now steer models (#561).** Both backends already fetched the
  label set and rendered it into `issue.md`'s `- Labels:` line; nothing
  consumed it, so a label-only project got no steering at all (observed:
  factorAI#85 ran every checking step at the config floor despite a
  `tier:check-fable` label). Recognized at first scaffold:
  `tier:impl-<model>` (thinking), `tier:check-<model>` and
  `tier:<model>-checking` (checking). Read once from the `- Labels:` HEADER
  line, so a `- Labels:` line in the body or a tracker comment never steers.

  Per-class precedence: body key > body `tier:` shim > label > the
  `step_models` config chain. Fail-closed: an illegal model token dies, and
  two labels steering one class to different models die naming both — even
  when a body key would have won that class. Never-die: an unrecognized
  `tier:*` label warns and is ignored, a non-`tier:` label is silent.

  **Upgrading:** nothing to do. A body with no new keys and no recognized
  steering labels resolves byte-identically to before (verified by a
  two-checkout capture-diff over all 24 steps × 3 marker states), and legacy
  bare-token markers keep their exact semantics. If your project stamps
  `tier:*` labels, note they now take effect at first pull; later label edits
  never retro-edit an existing marker, and hand-editing the marker remains
  the post-scaffold path.

### Fixed — 2026-07-29
- **Draft dispatch no longer treats a bad per-issue marker as "stay inline"
  (#561).** The step-2 tier was resolved with `$(… || true)`, mapping rc 1
  (bad/unreadable marker) to the same empty string as rc 3 (nothing
  configured). Since #561 makes the marker's structural faults apply to the
  thinking class, rc 1 became reachable at step 2 — so a broken keyed marker
  would have silently disabled dispatch at the one place
  `implementation-model` is enforced. `docs/draft-dispatch-contract.md` and
  `commands/draft.md` now read the exit code, and **rc 1 stops**.

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
  described as **24-step** throughout (24 numbered step commands). Execution
  order is unchanged — dispatch is by step NAME and file order was always the
  authority.

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
- **58 slash commands** driving a fixed **24-step issue workflow** (21 mandatory,
  plus the optional research step 1, spike step 3, and mergetoall step 19),
  with all state preserved on disk so you can switch issues — or hand one to a
  fresh session — without losing context.
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
