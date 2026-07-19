# devAgent Plugin — Design Spec

**Date:** 2026-05-19
**Status:** Draft for review
**Author:** Matt Tibbits (with Claude)
**Scope:** v1 of the `devAgent` Claude Code plugin
**Repo:** `~/src/devAgent`

---

## 1. Purpose

`devAgent` is a Claude Code plugin that documents the current state of
in-progress development work so the operator can shift between
priority issues without losing the context of what to do next.

The plugin packages a workflow that has already been run ~50+ times by
hand. It does not invent new process. It captures existing process as
slash commands, scripts, and skills so each step can be resumed,
audited, and reproduced from a small set of on-disk artifacts.

**Principal value props (in priority order):**

1. **Context preservation across issue switches.** Operator can drop
   an issue, work something else for a week, and resume with no loss
   of state via `/devagent:catchup`, `/devagent:where`,
   `/devagent:next`.
2. **Token economy.** Mechanical work (issue fetch, branch creation,
   commit, push, static analysis) is scripted, not LLM-driven. The
   model is invoked only where judgment is required.
3. **Reproducibility.** Each issue's progression through the pipeline
   leaves an auditable trail in one directory; pipeline state is
   independent of session.
4. **Multi-project, multi-backend portability.** Works against
   GitHub today, GitLab and a future custom tracker tomorrow, JIRA
   for projects where ticket and code hosts diverge.

## 2. Non-goals

- Not a project management tool. WBS / status reports are
  byproducts, not the product.
- Not a CI system. The plugin invokes static analyzers, sanitizers,
  and test suites but does not orchestrate cloud builds.
- Not an MR review bot. Red-team and code-review are operator-invoked
  steps, not background processes.
- Not a replacement for `git`. Plugin scripts wrap git operations for
  the specific workflow but do not abstract git itself.
- Not session-aware. The plugin is invoked from Claude Code sessions
  but its state lives on disk and is consumed by anything (cron,
  VSCode extension, second session) that can read those files.

## 3. Top-level layout

### 3.1 Plugin directory (`~/src/devAgent/`)

```
devAgent/
├── .claude-plugin/marketplace.json
├── README.md
├── docs/
│   ├── specs/2026-05-19-devagent-plugin-design.md   (this file)
│   ├── draft-dispatch-contract.md   # #441: the #284 planner dispatch contract, loaded conditionally by commands/draft.md's stub
│   └── checking-dispatch-contract.md # #528: the checking-class dispatch contract, single-sourced from the improve/redmr/preship pointer stubs
├── commands/                # one .md file per command-form slash command (52)
├── skills/                  # core-* internal skills (`user-invocable: false`), PLUS the
│                            #   user-invocable slash-command skills next/capture/ship
│                            #   (SKILL.md + references/, #452) — 52 + 3 = the 55 slash commands
├── agents/                  # #458/#527: dedicated checker agents auto-discovered from this root
│                            #   (preship-verifier, redteam-reviewer, plan-improver): pinned
│                            #   effort (deliberately NO model pin — §7.4 rung 5) +
│                            #   disallowedTools, bound by the core-preship/core-redmr/
│                            #   core-improve skills' `context: fork` + `agent:`. NB plugin.json
│                            #   must NOT gain an "agents" key — it REPLACES this default scan
│                            #   rather than adding.
├── hooks/                   # PreToolUse hooks: git-guard.sh (opt-in git-reflex guard, #352); hooks.json
├── scripts/
│   ├── lib/                 # shared helpers (config-loader.sh, checklist.sh, log.sh)
│   ├── issue/               # tracker backends: github.sh, gitlab.sh, jira.sh, custom.sh
│   ├── code/                # forge backends: github.sh, gitlab.sh, custom.sh
│   ├── auth/                # PAT/SSH lifecycle: github.sh, gitlab.sh, jira.sh, custom.sh
│   ├── pull.sh, branch.sh, commit.sh, ship.sh, mergetoall.sh,
│   │   cleanup.sh, sync.sh, statusreport.sh, doctor.sh, ...
│   ├── analyze-static.sh    # wraps existing static_analysis_diff.py
│   ├── analyze-sanitizers.sh
│   └── checklist-{init,advance,mark,log,stuck,unstuck}.sh
├── templates/               # plugin-shipped default artifacts
│   ├── coding_standards.md
│   ├── commit_template.md   (relocated from ~/src/devAgent/commitMessageTemplate.md)
│   ├── mr_template.md       (relocated from ~/src/devAgent/PULL_REQUEST_TEMPLATE.md)
│   ├── redteam_mr.md        (relocated from ~/src/devAgent/pr-redteam-prompt.md)
│   ├── redteam_issue_{shared,light,standard,full}.md   # #443: tier-split issue red-team (shared core + light/standard/full dimension parts, loaded per triage); a monolithic redteam_issue.md override still shadows all tiers
│   ├── issue_template-bug.md, -feature.md, -docs.md, -perf.md, -chore.md
│   ├── epic_template.md
│   ├── imPlan_template.md
│   ├── actualWork_template.md
│   ├── lessonsLearned_template.md
│   ├── wbs_template.md
│   └── statusreport_template.md
├── tests/                   # bats for shell, pytest for python helpers
├── evals/                   # skill-steering evals (#460): evals.json + fixtures/ + run-eval.sh; MANUAL/local, NON-CI-gating (model runs non-deterministic). tests/evals-structure.bats guards the structure only.
└── static_analysis_diff.py  (existing; wrapped by analyze-static.sh)
```

### 3.2 Global config (`~/.claude/devagent/config.toml`)

One file, all projects. Predictable location mirrors `~/.claude/settings.json`.

```toml
[defaults]
checklist_template = "standard"          # standard | docs-only | research | perf
ship_as_draft      = false               # default; overridable per-project and per-invocation
# git_guard        = true                # opt-in git-reflex guard (#352); the hooks/git-guard.sh
                                         #   PreToolUse hook denies reflexive destructive git on a
                                         #   dirty tree. Default off. A [project.<name>] git_guard
                                         #   value overrides this for the active project (#433).

[project.volk]
source_dir       = "~/src/volk"
source_remote    = "git@gitlab.com:mtibbits/volk.git"   # our fork
upstream_remote  = "https://github.com/gnuradio/volk"
devdoc_dir       = "~/src/devDoc/volk"
devdoc_remote    = "git@gitlab.com:mtibbits/devDoc.git"  # optional
fork_first       = true
ship_as_draft    = true                  # always open MRs as draft on this project
include_coauthor = false                 # strip Co-Authored-By from commit msg + PR body (default true)
default_baseline = "origin/main"
all_prs_branch   = "dev/all-prs"
branch_prefix_map = { bug = "fix", feature = "feat", docs = "docs", perf = "perf", chore = "chore" }

[project.volk.permissions]
push_mr            = true
merge_mr           = true
commit_devdoc      = true
transition_issue   = true
cleanup_on_merge   = false

[project.volk.issue_source]              # tracker for new issues from upstream
backend     = "github"                   # github | gitlab | jira | custom
repo        = "gnuradio/volk"
dir_prefix  = "Issue-"

[project.volk.issue_source_fork]         # tracker for fork-only issues
backend     = "github"
repo        = "mtibbits/volk"
dir_prefix  = "Issue-Fork-"

[project.volk.code_source]               # where branches push, MRs file
backend     = "github"
upstream    = "gnuradio/volk"
fork        = "mtibbits/volk"

[project.volk.issue_workflow]
on_draft_start = "In Progress"
on_ship        = "In Review"
on_merge       = "Done"

[project.volk.issue_workflow.github_labels]      # only used when issue backend = "github"
in_progress = "status: in-progress"
in_review   = "status: in-review"
done        = "status: done"
remove_others_in_namespace = "status:"

[project.volk.paths]                     # artifact overrides, relative to devdoc_dir
coding_standards = "codingStandards.md"
commit_template  = "commitMessageTemplate.md"
# unspecified artifacts fall through to <devdoc>/templates/ then plugin templates/

[project.volk.step_models]               # optional model tiers per step class (#150/#151/#291); see §7.4
checking = "opus"                        # improve(3) / review(13) / redmr(14) / preship(21)
# thinking = "opus"                      # draft(1) / implement(7) / quality(8) / document(9) / draftmr(12)
# "13"     = "fable"                     # a numeric per-step override wins over its class tier
```

`include_coauthor` (per-project bool, default `true`) is a **strip-guard**, not a generator:
devAgent never adds a `Co-Authored-By` trailer, but the driving model may. When set `false`,
`commit.sh` and `ship.sh` remove any `Co-Authored-By:` line from the commit message and the PR
body (case-insensitive); `Signed-off-by` (DCO) is always preserved. Per-project only — there is no
`[defaults]` layer. Set `false` for AI-attribution-averse upstreams (e.g. `volk`).

### 3.3 Per-project state (`~/.claude/devagent/state/<project>.toml`)

Mutable. Out of git. One active issue per project.

```toml
active_issue   = "Issue-676"             # or "Issue-Fork-42"; null when idle
issue_dir      = "~/src/devDoc/volk/Issue-676"
branch         = "fix/676-foo-bar"
baseline_sha   = "ed15328"
worktree_path  = "~/src/volk-wt/issue-676"   # set if worktree-based
last_step      = 7
last_step_name = "implement"
mr_url         = "https://github.com/gnuradio/volk/pull/842"   # set after ship
revision       = 1
updated_at     = "2026-05-19T14:32:00-04:00"

[parked]                                  # explicitly parked, distinct from idle
"Issue-Fork-12" = true
"Issue-203"     = true
```

Parked issues are represented as boolean-true keys under a `[parked]`
table rather than a TOML array. Rationale: per-issue add/remove is a
direct key write/delete (no read-splice-write of an array), which
composes better with future per-issue metadata (e.g.,
`[parked."Issue-12"]` table with `parked_at`, `reason`, etc.) if we
ever need it. Order is not preserved; v1 does not depend on order.

Per-issue context (#98, #240): the keys `branch`, `baseline_sha`,
`worktree_path`, `mr_url`, `revision`, `pending_comments_file`,
`last_step`, `last_step_name` belong to the active issue, not the
project (`STATE_ISSUE_KEYS`, `scripts/lib/state.sh:142`). Since #240 the
**`[context.<issue>]` sub-table is the authoritative home** of these
keys; the top-level copies are a compatibility **mirror**, maintained
only while that issue is the shared `active_issue`. Per-key reads follow
this truth table (`state.sh:165–174`):

| lookup condition | read result |
|---|---|
| `[context.<issue>]` has the key | the table value (always wins) |
| table miss, issue == `active_issue` | the top-level value (adopt-on-first-write migration for pre-#240 state) |
| table miss, issue != `active_issue` | the `state_init` per-key default |

The mirror predicate is evaluated INSIDE the write lock (`set-many-if`,
#240/#327), so a concurrent `pull` cannot flip `active_issue` mid-write
and launder one issue's keys into another. Consequence for tools/agents:
read and write per-issue keys via `state_issue_{get,set}` (or the
`[context.<issue>]` table directly) — hand-editing the top-level keys is
ignored whenever a context entry exists.

The snapshot/restore helpers (`state_context_{save,restore,clear}`,
`scripts/lib/state.sh`) drive the lifecycle: `park` snapshots the active
issue into its `[context.<issue>]` and resets the top level to defaults;
`resume` restores the snapshot and deletes it; `pull`/`resume` snapshot a
displaced in-flight issue AND park it, tagging it in a top-level
`[displaced]` marker table so the advertised recovery
(`/devagent:resume` | `/devagent:switch`, which both key on `[parked]`)
finds it (#415). A displacement-park is distinguished from an operator
park by that marker: re-pulling a **displacement**-parked issue RESTORES
its snapshot (resume semantics), while re-pulling an **operator**-parked
issue GCs it (fresh start, the #98 MAJ-1 invariant). Every path that makes
an issue active or ends a park (`park`, `resume`, `pull` restore/GC,
`cleanup`) clears the `[displaced]` marker so it cannot leak. `cleanup`
resets to defaults. `[context]` is deliberately separate from `[parked]`:
saved context is orthogonal to parked-ness, and `state_list_parked` lists
only scalar keys. A future full `[issues.<id>]` nesting (Epic #61 end state)
would re-point
these helpers without changing callers.

All writes to state files go through `scripts/lib/_toml.py`, which
holds an exclusive lock (`fcntl.flock` on POSIX, `msvcrt.locking` on
Windows) on a sibling `.lock` file across the entire read-modify-write
cycle and writes via tempfile + atomic `rename`. Readers do not need to
lock — POSIX guarantees `rename` atomicity, so they see either the prior
consistent state or the next. Windows lacks that guarantee (a reader
holding the file open makes the replace, or its own open, raise a
transient sharing violation), so the racing sites bounded-retry that
transient error on Windows only (`_retry_windows_share`, #293); on POSIX
the retry is a passthrough.

Adjacent state files:

- `~/.claude/devagent/state/<project>.statusreport.toml` — `last_pin`, `last_pin_by`
- `~/.claude/devagent/state/<project>.reaped.toml` — content hashes of items already reaped into captures (for idempotence)

### 3.4 Secrets (`~/.claude/devagent/secrets/`)

```
volk.github.pat       # mode 600, dir mode 700
volk.gitlab.pat
volk.jira.pat
volk.ssh              # symlink to ~/.ssh/<key> if SSH used
```

Scripts never read tokens directly. They invoke `auth/<backend>.sh exec
<project> -- <cmd>` which sets the relevant env var (`GH_TOKEN`,
`GITLAB_TOKEN`, etc.) and executes. Tokens never appear in `ps`, shell
history, or argv.

A future `--keyring` mode swaps file storage for libsecret/Keychain.
Caller contract unchanged.

### 3.5 Per-issue directory (`<devdoc>/<dir_prefix><N>/`)

```
Issue-676/
├── checklist.md                         # the canonical workflow tracker
├── issue.md                             # raw fetched issue + comments
├── intent.md            # #284: operator-intent digest for dispatched planning
├── .devagent-step-models  # optional: one model-tier token pinning this issue's checking steps (#291; §7.4)
├── imPlan.md
├── imPlan-potentialFutureEnhancements.md
├── actualWork.md
├── mr.md
├── analysis/
│   ├── 2026-05-19-cppcheck.txt
│   ├── 2026-05-19-clang-tidy.txt
│   └── 2026-05-19-asan.txt
├── revisions/                           # populated by /devagent:revise
│   └── r2/comments.md
└── STUCK                                # sentinel; present iff a step is [!]
```

### 3.6 Per-capture directory (pre-issue, `<devdoc>/Captures/<slug>/`)

```
Captures/2026-05-19-corn-planting/
├── draft.md                             # the captured issue or epic
├── redteam.md                           # populated by /devagent:redissue
├── filed.toml                           # populated by /devagent:file: issue_num, url
└── (for epics) children/
    ├── 01-prepare-soil.md
    ├── 02-plant-seed.md
    └── ...
```

### 3.7 Plugin manifest `userConfig` (enable-time seed) — #459

`.claude-plugin/plugin.json` declares a `userConfig` block that Claude prompts for at
plugin-enable time (verified on claude 2.1.75: the validator recognizes `userConfig` and
requires a `title` per option). Two keys, both seeds:

```json
"userConfig": {
  "devdoc_root":     { "type": "directory", "title": "devDoc root",     "default": "" },
  "default_project": { "type": "string",    "title": "Default project", "default": "" }
}
```

Claude exports the answers to `scripts/init.sh` as `CLAUDE_PLUGIN_OPTION_DEVDOC_ROOT`
and `CLAUDE_PLUGIN_OPTION_DEFAULT_PROJECT`.

**Precedence — config.toml WINS.** These options SEED the `/devagent:init` interview only:
`devdoc_root` supplies the `devdoc dir` prompt default (an explicit answer / the
`DA_INIT_DEVDOC_DIR` short-circuit still wins), and `default_project` names the project
only when `init.sh` runs with no positional argument. `init.sh` dies if
`[project.<name>]` already exists (init.sh:33), so config.toml is never overwritten and
there are never two live sources for the devdoc root. Existing installs (config.toml
present) see no behavior change. `commands/init.md` states this rule for operators;
`tests/userconfig-seed.bats` pins it.

**`${CLAUDE_PLUGIN_DATA}` — evaluated, REJECTED for devAgent state.** The update-surviving
plugin data dir (`~/.claude/plugins/data/devagent-devagent/`) was verified present on
2.1.75 but is not adopted: devAgent's config + state already live at a fixed,
update-surviving `~/.claude/devagent/` (config.toml single source of truth #328,
`_active.toml` cross-session pointer, per-project state under user-home, NOT the plugin
cache). Adopting `${CLAUDE_PLUGIN_DATA}` would FORK the state location and break that
contract for no benefit. (AC live-smokes: the enable-dialog appearing and cross-update
persistence are operator actions; the mechanism, `validate`, seed logic, and precedence
are verified here. AC1 `--strict` is version-gated — absent on 2.1.75, #447 — so
non-strict `claude plugin validate` PASS-with-userConfig is the recorded evidence.)

## 4. Configuration vs artifacts

Two distinct concerns, deliberately separated:

- **Configuration** lives in `config.toml`. It is operational state:
  flags, paths, URLs, permissions, backend selections. Edited by
  hand or via `/devagent:init`.
- **Artifacts** are content templates the workflow reads or fills in:
  coding standards, issue templates, MR templates, red-team prompts,
  WBS templates, status report templates. Resolved in this order:

  1. Per-project explicit path from `config.toml [project.<name>.paths]`
  2. `<devdoc>/templates/<name>.md`
  3. `~/src/devAgent/templates/<name>.md` (plugin-shipped fallback)

Operators override artifacts at the project level by dropping a file
into `<devdoc>/templates/`. The plugin-shipped versions provide working
defaults so a new project is functional on day one.

### 4.1 Template placeholders

`commit_template.md` supports four placeholders, substituted by
`scripts/commit.sh` at commit time:

| Placeholder | Source | Example value |
|-------------|--------|---------------|
| `{{type}}` | `.devagent-type` → `branch_prefix_map` lookup | `perf` |
| `{{title}}` | `.devagent-title` verbatim | `add AVX2+FMA tier to volk_32fc_magnitude_32f` |
| `{{issue}}` | `active_issue` directory name (includes prefix) | `Issue-Fork-62` |
| `{{note}}` | Operator `$NOTE` from slash-command tail | *(may be empty)* |

**Caution:** `{{issue}}` is the full directory name, not the bare
issue number. A template that writes `#{{issue}}` produces
`#Issue-Fork-62`, not `#62`.

## 5. Checklist format

### 5.1 States

| Glyph | Meaning |
|-------|---------|
| `[ ]` | pending |
| `[x]` | done |
| `[-]` | skipped (deliberately not applicable) |
| `[!]` | stuck (needs human; STUCK file exists) |
| `[~]` | in-progress (started, not finished) |
| `[?]` | blocked-on-external (waiting on CI, reviewer, upstream) |
| `[P]` | parked (deliberately set aside for another issue) |

`where` and `next` treat states as follows:

- `[ ]`, `[~]` — resumable; `next` will execute
- `[?]` — current step is waiting on external; `next` offers to park
  the issue and surface other projects' actionable work (since most
  workflow steps depend on prior steps, advancing past `[?]` is
  rarely meaningful)
- `[!]` — halt until cleared via `/devagent:unstuck`
- `[-]`, `[x]` — already disposed; `next` advances past
- `[P]` — only meaningful at the issue level (issue is parked);
  `next` skips parked issues when scanning projects

### 5.2 Layout

```markdown
# Issue-676 — Workflow checklist

State key: [ ] pending  [x] done  [-] skipped  [!] stuck  [~] in-progress  [?] blocked-external  [P] parked

Template: standard
Created: 2026-05-19 14:01
Active revision: 1

## Revision 1

- [x]  0. pull            — origin · gnuradio/volk#676
- [x]  1. draft           — imPlan.md (3 changes proposed)
- [x]  2. scope           — 1 recommendation merged
- [~]  3. improve         ← active
- [ ]  4. prune
- [ ]  5. tighten
- [ ]  6. branch
- [ ]  7. implement
- [ ]  8. quality
- [ ]  9. document
- [ ] 10. commit
- [ ] 11. analyze
- [ ] 12. draftmr
- [ ] 13. review
- [ ] 14. redmr
- [ ] 21. preship
- [ ] 15. ship
- [ ] 16. mergetoall
- [ ] 17. updatewbs
- [ ] 18. impact
- [ ] 19. lessonslearned
- [ ] 20. cleanup

## Log
- 2026-05-19 14:01  pull: fetched gnuradio/volk#676, scaffold created
- 2026-05-19 14:08  draft: imPlan.md written (3 changes)
- 2026-05-19 14:14  scope: added validation criterion for return-code path
- 2026-05-19 14:32  improve: started — analyzing edge cases
```

Log is append-only, one sentence per entry max, ISO date + 24h time,
step name as second token. Format is fixed so `statusreport.sh` can
parse it.

### 5.3 STUCK file

Present iff any step is `[!]`. Format:

```
Step:        14 redmr
Reason:      red team produced 46 blocking issues, need triage strategy
Last good:   step 13 review (2026-05-19 16:42)
Suggested:   read analysis/2026-05-19-redmr.md; group findings by severity; pick top 3
Created:     2026-05-19 17:08
```

Cleared by `/devagent:unstuck`, which removes the file, flips `[!]`
back to `[~]` or `[ ]` (operator chooses), and appends a log entry.

## 6. Commands

Every command is prefixed `/devagent:` (resolves naming collisions
with Claude Code built-ins and other plugins).

### 6.1 Invocation grammar

```
/devagent:<verb> [project] [issue-dir] [free-form note words ...]
```

There is no argument-parsing script — the standalone bash parser was
removed (#121/#122). The driving model applies this grammar and hands each
script its already-resolved positional arguments (project, issue-dir; a note
travels via the `NOTE` env var, not argv). The rules below define that
resolution, left to right:

1. If first token matches a `project.<name>` in `config.toml`, consume as project.
2. If next token matches `^Issue(-Fork)?-\d+$`, consume as issue dir.
3. Remaining tokens, joined with spaces, become `$NOTE`.

Defaults when omitted:
- project → active project from state, or the only configured project if exactly one
- issue → current `active_issue` for that project

Escape hatch for ambiguity: `--` separator stops positional consumption.

```
/devagent:ship volk Issue-676 please make the redteam changes
              ──┬─ ─────┬──── ─────────────────┬──────────────
              project   issue                  $NOTE

/devagent:ship volk -- please ship despite the lint warning
              ──┬─    ─────────────────┬───────────────────
              project                  $NOTE
```

`$NOTE` is:
- Passed to skill-type commands as user-intent context
- Written into the checklist log entry for script-type commands

### 6.2 Family A — Capture (pre-issue / epic authoring)

| Command | Type | Notes |
|---|---|---|
| `/devagent:capture <text>` | script + skill | Model decides issue vs epic; may propose "this is 7 epics" with scaffolds |
| `/devagent:capture issue <text>` | script + skill | Force-type to issue |
| `/devagent:capture epic <text>` | script + skill | Force-type to epic |
| `/devagent:scaffold <capture-slug>` | skill | Bin an epic capture into child issue drafts |
| `/devagent:redissue <capture-slug>` | skill | Run the tier-split issue red-team (`redteam_issue_shared` + the triage tier's cumulative dimension parts, or a monolithic `redteam_issue` override) against the draft, write `redteam.md` |
| `/devagent:file <capture-slug> [origin\|fork]` | script | `issue/<backend>.sh create`; respects `permissions.push_mr`-style gate |
| `/devagent:reap [project]` | script + skill | Harvest follow-ups into `Captures/`; idempotent via content hashes |

### 6.3 Family B — Workflow (the 22 steps)

| # | Command | Type | Implementation |
|---|---|---|---|
| 0 | `/devagent:pull` | script | `pull.sh` + `issue/<backend>.sh fetch`; scaffolds Issue dir |
| 1 | `/devagent:draft` | skill | `superpowers:writing-plans` (inline) or a dispatched planner per the #284 contract; writes `imPlan.md`; triggers `on_draft_start` |
| 2 | `/devagent:scope` | skill | `core-scope` — 6-question evaluation, edits imPlan |
| 3 | `/devagent:improve` | skill | `core-improve` (fork → `devagent:plan-improver`, #527) — bugs, side effects, ambiguities; the #286 pothole tripwire lives in the agent, which self-resolves the register |
| 4 | `/devagent:prune` | skill | `core-prune` — moves extras to `imPlan-potentialFutureEnhancements.md` |
| 5 | `/devagent:tighten` | skill | `core-tighten` — final review pass on pruned plan |
| 6 | `/devagent:branch` | script + skill | `branch.sh` (prefix from `branch_prefix_map`); `superpowers:using-git-worktrees` |
| 7 | `/devagent:implement` | skill | `superpowers:executing-plans` |
| 8 | `/devagent:quality` | skill | `simplify` + project's `coding_standards.md` |
| 9 | `/devagent:document` | skill | `core-document-actual-work` — terse when no deviation |
| 10 | `/devagent:commit` | script | `commit.sh` — `commit_template.md`, `-s` (DCO), strips `(1M context)` |
| 11 | `/devagent:analyze` | script | the project's `analyze` family — `cmake` \| `shellcheck` \| `none` (§18); depends on commit per §11 |
| 12 | `/devagent:draftmr` | skill | `core-draft-mr`, fills `mr_template.md` |
| 13 | `/devagent:review` | skill | `superpowers:requesting-code-review` |
| 14 | `/devagent:redmr` | skill | `core-redmr` using `templates/redteam_mr.md`; also carries the always-run **spec-touch question** (#435) — a diff that adds/renames/removes a config key, command, hook, or top-level directory with no matching spec change is flagged `[MAJOR]` |
| 21 | `/devagent:preship` | skill | `core-preship` — fresh-context AC/findings/push-preview verification + the **spec-touch verification** (#435; adds/renames/removes of a spec-relevant surface must carry a spec change or FAIL); ordering enforced by next.sh dispatch AND a ship.sh hard gate on non-terminal preship (absent step ⇒ no gate) (#149) |
| 15 | `/devagent:ship` | script | `ship.sh` — honors `permissions.push_mr` and `ship_as_draft`; triggers `on_ship`; if `fork_first=true`, fork first then reference upstream |
| 16 | `/devagent:mergetoall` | script | `mergetoall.sh` — honors `permissions.merge_mr`; squash-on-merge |
| 17 | `/devagent:updatewbs` | skill | alias to `/devagent:wbs update` |
| 18 | `/devagent:impact` | skill | `core-impact` — quantify and record |
| 19 | `/devagent:lessonslearned` | skill | `core-lessons-learned` |
| 20 | `/devagent:cleanup` | script | `cleanup.sh` — restore tree, commit/push devdoc, clear `active_issue` |

### 6.4 Family C — Revision (post-MR feedback)

| Command | Type | Notes |
|---|---|---|
| `/devagent:comments` | script | `code/<backend>.sh mr-comments`; writes to `revisions/r<N>/comments.md` |
| `/devagent:revise` | script + skill | Increments revision; appends new "## Revision N" block to checklist; resumes from `draft` with comments in context |

### 6.5 Family D — Context / state helpers

| Command | Behavior |
|---|---|
| `/devagent:init <project>` | Interactive bootstrap of a new `project.<name>` entry |
| `/devagent:where [project]` | Reports active issue + last step + next step; offers "Continue?" but does **not** execute |
| `/devagent:next [project]` | Executes the next actionable step on the active issue |
| `/devagent:use <project>` | Deliberately switches the global active-project pointer (`state/_active.toml`), then prints the resolved state (#349). The one arg-driven pointer writer; warns when a `DEVAGENT_ACTIVE_PROJECT` env pin shadows the change (env beats the pointer for this session, #434) |
| `/devagent:status [project\|--all]` | Multi-project dashboard: active, stuck, parked, idle |
| `/devagent:catchup [issue]` | Synthesizes issue.md + imPlan + actualWork + last comments + last 5 log entries into one-screen rehydration |
| `/devagent:park [issue]` | Marks `[P]`, saves state, clears `active_issue` |
| `/devagent:resume <issue>` | Reactivates a parked issue as `active_issue` |
| `/devagent:switch <issue>` | Sugar: park current + resume target in one call |
| `/devagent:stuck "reason"` | Marks `[!]`, writes STUCK file |
| `/devagent:unstuck` | Removes STUCK, flips `[!]` to operator's choice of `[~]` or `[ ]` |
| `/devagent:doctor [project]` | Validates `config.toml`, backend auth, reachability; reports issues without changing state |
| `/devagent:depends <A> on <B>` | Records `Issue-A depends on Issue-B`; `where`/`next` warns if shipping with open deps |
| `/devagent:depends list [project]` | Prints dependency graph |
| `/devagent:grep <pattern> [project]` | Greps across all issue dirs (issue.md, imPlan, actualWork, mr, checklist) |
| `/devagent:history [project] [issue]` | Concatenated log view |
| `/devagent:template list\|show <name>` | Inspect resolved artifact templates |
| `/devagent:sync [project\|--all]` | Async merge detection; transitions issues whose MRs were merged outside our session, unblocks `[?]` closeout steps, and prints a `CLOSEOUT:` nudge routing to `/devagent:next --auto` (#363; executes no closeout steps itself) |
| `/devagent:statusreport [project]` | Generates status report, advances pin, commits to devdoc |
| `/devagent:wbs <init\|update\|show>` | WBS authoring/render (see §13) |
| `/devagent:auth <create\|store\|rotate\|destroy\|status> [project] [backend]` | Auth subsystem entry points |

## 7. Chaining

### 7.1 `--auto` and `--through`

Any executing command accepts:

- `--auto` — continue chaining through end-of-workflow without
  prompting between steps. Equivalent to `--through cleanup`.
- `--through <step>` — chain up to and including `<step>`, then stop.

Without either flag, every step ends with:

```
✅ step 7 (implement) — done.
   log: 2026-05-19 14:32  implement: 3 files changed, all tests pass
   STUCK: no

Next up: step 8 (quality). Continue? [Y/n/skip/stuck]
```

`Y` (or Enter) chains; `n` halts; `skip` marks `[-]` and offers next;
`stuck` prompts for reason and marks `[!]`.

### 7.2 What `--auto` does and does not do

`--auto` **suppresses** the inter-step "Continue?" prompt.

`--auto` does **not**:
- Bypass permission gates. If `permissions.push_mr=false`, `ship`
  still halts and prompts `y/N`.
- Continue past a step that exits `[!]`. STUCK halts the chain.
- Continue past a step whose script exits non-zero.
- Override `$NOTE`. `$NOTE` is preserved across the chain and passed
  to each step verbatim.

### 7.3 External chaining

The VSCode extension at work launches one Claude Code session per
`/devagent:next` invocation and provides a UI break between sessions
for priority shifts. The plugin treats that extension as a downstream
consumer, not a dependency. The plugin's contract is the same whether
chaining happens via `--auto`, via external session orchestration, or
via the operator typing `/devagent:next` between steps.

### 7.4 Step model tiers (`step_models`)

An optional `[project.<name>.step_models]` table steers which model tier
runs each step (surfacing #150; dispatch #151; per-issue override #291).
Implemented in `scripts/lib/config.sh:96–172` (`step_models_tier`) and
`scripts/step-model.sh`. The table is entirely optional — **absent, output
is byte-identical to no tiering** (the resolver returns "no tier" and the
step runs at the session model).

Steps map to three fixed classes by canonical step number:

| Class | Steps |
|---|---|
| `thinking` | 1 draft · 7 implement · 8 quality · 9 document · 12 draftmr |
| `checking` | 3 improve · 13 review · 14 redmr · 21 preship |
| `default` | everything else |

A step's tier is resolved in this order (first hit wins):

1. **Per-issue marker** (`<issue-dir>/.devagent-step-models`, #291) — a
   single tier token, honored for **checking-class steps only**. The
   reserved token `inherit` forces session-model inheritance (escapes a
   project `checking` pin). A present-but-empty or multi-token marker is a
   hard error (never a silent fallback).
2. **Per-step override** — `step_models.<N>` (a numeric key, e.g. `"13"`).
3. **Class tier** — `step_models.<class>` (`thinking` / `checking` / `default`).
4. **Default tier** — `step_models.default`, when the class tier is unset.
5. **Step default — any step whose skill binds an agent** (#458). When a
   step's skill carries `context: fork` + `agent:`, the step's COMMAND WRAPPER
   carries a default model in its dispatch table (today `opus` for improve,
   redmr and preship), passed as an explicit Agent-tool `model` parameter when nothing
   resolves. The property is the binding, not the step number: converting a
   further step needs no edit here. For every other step, an unresolved tier
   still means "inherit the session model".

   The default deliberately does NOT live in the agent's frontmatter, and the
   agents carry no `model:` pin (only `effort`). Measured at 2.1.211: the Agent
   tool's `model` parameter is a closed enum (`sonnet|opus|haiku|fable`) with no
   `inherit` value — the literal fails validation — and omitting it resolves to
   the agent definition's model BEFORE the parent's, so a frontmatter pin would
   make rung 1's reserved `inherit` escape unsatisfiable on every dispatch
   shape. Unpinned, the skill-fork inherits the session model
   (transcript-verified), which is exactly what the `inherit` marker demands.

If none resolves, the step inherits the session model — except steps 3/14/21, per
rung 5. Tiers are advisory for surfacing steps (`next` / `catchup` print the
hint) and load-bearing for the dispatch contract (§7.5), which uses the resolved
tier as the subagent's model override.

**What #458 subsumes, precisely:** only the *fallback interpretation* for the
bound steps, and only in the CALLERS (`commands/improve.md` since #527,
`commands/redmr.md`, `commands/preship.md`). `step-model.sh` keeps owning tier resolution: rungs 1–4
resolve identically for every step, and it still exits nonzero with empty output
when nothing resolves.

Because rung 5 is not "inherit", the resolver's three no-tier states stopped
being interchangeable, so they are **distinct exit codes** rather than stderr
prose a caller must parse (#458): `0` a tier is on stdout · `2` the reserved
per-issue `inherit` marker (rung 1's escape hatch — the operator explicitly
wants the session model) · `3` nothing resolved · `1` error (bad marker; a stop
condition, never an inherit). A caller whose fallback IS inherit — step 13,
`next.sh`, `catchup.sh` — may keep collapsing every nonzero via `|| true`, which
stays correct and is pinned by a test. A caller with a step default MUST
discriminate: `2` still inherits (it dispatches via the bound skill, whose
unpinned fork runs at the session model), `3` takes the wrapper's explicit
default. Collapsing the two would silently defeat the only way to opt out of a
pinned tier.
The marker (#291) and the config tables therefore behave exactly as before —
**marker > per-step > class > default > agent default** — and existing projects
with a `step_models` entry for 3/14/21 see no change at all.

**Live behavior change** for a project that resolves NO tier for 3/14/21 (a fresh
install: `templates/config.toml.skel` ships `step_models` commented out): those
steps previously ran at the session model and now run at the wrapper-carried
step default. Projects that set a `checking` tier — as every project shipped in the
reference config does — are unaffected.

**Failure mode this binding is exposed to: silently-ignored frontmatter.** These
are harness surfaces, and a field that is *accepted but not enforced* buys no
isolation. `claude plugin validate --strict` does **not** close this: verified at
Claude Code 2.1.211, it validates `plugin.json` / `marketplace.json` only and
never opens an agent file — a bogus field, or the wrong-scope spelling
`disallowed-tools` (agents take camelCase `disallowedTools`; the hyphenated form
is the SKILL.md spelling), produces byte-identical validator output. **The live
smoke test on the installed version is the gate**, not the validator: dispatch
the agent, have it attempt a Write, and confirm a structural refusal.

**Residual, stated and adjudicated (#529):** the checker agents retain `Bash` —
they must run git, diffs, and the evidence/register scripts. Write/Edit denial
is therefore *tool-level* isolation, not a filesystem sandbox; a determined
agent could still write via shell redirection. The denial removes the accident,
not the capability. Issue-529 adjudicated this residual as ACCEPTED (threat
model: accidental self-inflicted mutation, not an adversary; decision doc in
the issue archive, incl. the re-verified rejection of dropping Bash and the
deferred worktree-isolation option). Each agent header carries the caveat. The
agents' return-don't-write prompt contract is the load-bearing layer; §8.1's
hooks (`git-guard.sh`, `preship-dirty-tree.sh`) add partial, opt-in *detection*
for the destructive-git and untracked-file shapes only — an in-place edit of a
tracked file is not detected, and the record accepts that.

### 7.5 Dispatch contract (checking + thinking steps)

Two step classes dispatch their work to a fresh-context subagent rather
than running inline; the normative per-step detail lives in the command /
skill files, summarized here so the mechanism is discoverable:

- **Checking steps** (improve 3, review 13, redmr 14, preship 21; #151):
  run in FRESH CONTEXT whenever the harness offers a subagent — a checker
  that reads the artifacts from disk instead of inheriting the author's
  conversation is what makes the check adversarial. Dispatch is
  unconditional; the model override is the §7.4 tier (empty ⇒ inherit, except
  3/14/21 ⇒ agent default, §7.4 rung 5). **Steps 3, 14 and 21 are bound
  structurally** (#458/#527): `skills/core-improve`, `skills/core-redmr` and
  `skills/core-preship` carry
  `context: fork` + `agent: devagent:<agent>`, so invoking the skill IS the
  fresh-context dispatch — the harness supplies the agent's system prompt, its
  pinned effort, and its Write/Edit denial, instead of the mechanism depending
  on the model choosing to spawn a generic subagent correctly. (The model
  default is wrapper-carried, not agent-pinned — §7.4 rung 5 has the measured
  reason.) Those agents cannot
  write files: they RETURN the artifact body and the wrapper writes it verbatim,
  so authorship stays with the checker.
- **Thinking steps** — `draft` today (#284): the *inverse* — inline is the
  fully-informed default, and dispatch is an opt-in *up-delegation* keyed
  on a non-empty §7.4 `thinking` tier. Intent is packaged to
  `<issue-dir>/intent.md` (goals / constraints / rejected alternatives /
  answers), never pasted as conversation. Because a dispatched planner
  cannot ask the operator, it uses the two-round **question-return
  protocol** (writes `## Open questions`, the main session answers into
  `intent.md`, bounded at two rounds then inline fallback). This protocol
  is draft-only — checkers do not use `intent.md`.

Shared contract elements: a dispatched artifact's first two lines are the
provenance header (`context: subagent|inline`, `model: <tier>|inherit|…`);
and a garbled report is linted (`scripts/dispatch-lint.sh`), archived, and
re-dispatched once, then the step goes `[!]` (#360). The lint's PRIMARY
mechanism is the file-carried artifact contract (#458 — a relay through another
model session is not verbatim); as a narrow backstop it rejects the ELISION
shape class (#530): an elision/omission marker line outside a code fence, or a
body with fewer than 5 DISTINCT substantive lines (replacing the older raw
non-empty-line floor, which padding could clear). Normative detail:
`docs/draft-dispatch-contract.md` for the thinking path (#441: extracted from
`commands/draft.md`, which now carries a conditional-load stub — the contract is
read only when the step-1 tier is non-empty OR the operator instructs dispatch)
and, for the checking path, `docs/checking-dispatch-contract.md` (#528: extracted
from the `commands/improve.md` / `commands/redmr.md` / `commands/preship.md`
wrappers, which now carry a pointer stub + per-step delta block, mirroring the
thinking path's stub) — #458 moved the redmr/preship contracts skill→command and
#527 completed the pattern for improve, because the duties they describe (tier
resolution, the verbatim artifact write, dispatch-lint, the failure protocol)
bind the MAIN session, while their skills became fork prompts bound to the agents
that carry the procedure.

**Why review (step 13) is the one unbound checking step** — the asymmetry is a
boundary, not an oversight:

- **Step 13 (review)** cannot be converted as things stand: `commands/review.md`
  wraps the upstream `superpowers:requesting-code-review` skill, which devAgent
  does not own and cannot add frontmatter to. Binding it would first require
  vendoring that contract.

## 8. Permission gates

Defined per project in `[project.<name>.permissions]`. Each gate:

- `true` → proceed silently
- `false` → print plan + prompt `y/N` before each remote-visible action
- unset → treat as `false`

Exception — `transition_issue`: a `false` value does **not** prompt
`y/N`. The outward transitions it gates (`on_draft_start`, `on_merge`)
fire in autonomous/batch contexts where no operator is present to
answer, so `false` means **skip + warn (fail-closed)** instead
(#219/#141/#325).

Gates enforced by the script that performs the gated action, not by
the chaining layer. `--auto` cannot suppress a gate. `$NOTE` cannot
override a gate. The only way to change a gate is to edit
`config.toml`.

Gate set:

| Gate | Used by |
|---|---|
| `push_mr` | `ship.sh` |
| `merge_mr` | `mergetoall.sh` |
| `commit_devdoc` | `cleanup.sh`, `statusreport.sh` |
| `transition_issue` | the autonomous outward transitions: `on_draft_start` (`transition-draft-start.sh`, #325) and `on_merge` (`sync.sh`, #219). **Not** `on_ship` — `ship.sh` fires it ungated (consent rides the ship action, #219). |
| `cleanup_on_merge` | `sync.sh` (opt-in to auto-cleanup post-merge) |

### 8.1 Hooks surface (PreToolUse / SessionStart) — #453 scaffold

Deterministic enforcement lives in `hooks/`: `hooks/hooks.json` registers the
plugin's hooks (each `command` handler is a bash script under `hooks/`, invoked as
`"${CLAUDE_PLUGIN_ROOT}"/hooks/<name>.sh` with a per-hook `timeout: 5`). The layout
is settled by #352/#396; `hooks/lib/hook-common.sh` single-sources the shared
conventions every guard child inherits (the guidance: *when a skill stops steering
behavior, enforce with a hook*). Adding a hook EXTENDS `hooks.json`, never replaces it.

**Conventions (all hooks honor them):**
- **Fail-open.** exit 0 = allow, exit 2 = deny. Every error / unreadable / timeout /
  uncertain path returns the fail-safe (allow); ONLY a confirmed match denies. No
  `set -e` in a hook.
- **Opt-in, default-off.** Gated by a `[defaults].<key>` / `[project.<active>].<key>`
  config bool (`hook_enabled`, env-pin > pointer per #433, anchored-strict per #432);
  absent/unreadable ⇒ disabled. Enabling one never changes behavior for a
  non-opted-in session. git-guard.sh's `git_guard` is the reference gate.
- **Per-call override.** A single tool call bypasses a hook via its override env
  (e.g. `DEVAGENT_GIT_GUARD_OVERRIDE=1`).
- **String-match only.** Hooks match the raw command string; `git -C`, aliases,
  `bash -c`, variable indirection, and compound `a && cmd` can evade or (rarely)
  over-match. This obfuscation gap is ACCEPTED and DOCUMENTED (the #352 KNOWN GAPS
  class) — a hook is a reflex backstop, not a sandbox.

**Registered hooks (opt-in, default-off):**
- `git-guard.sh` (`git_guard`, #352) — PreToolUse/Bash; denies reflexive destructive
  git on a dirty tree.
- `active-pointer-guard.sh` (`active_pointer_guard`, #454) — PreToolUse/Bash +
  Write|Edit; DEFENSE-IN-DEPTH over the #282 script-layer gate. Fires ONLY when the
  session carries a `DEVAGENT_ACTIVE_PROJECT` env pin; denies out-of-band writes to
  `_active.toml` (Write/Edit on the pointer path, or a raw-bash write verb targeting
  it), while letting the deliberate writer `devagent use` (use.sh) through. The
  two-UNPINNED-sessions interleave is out of scope here — the script layer (#282)
  owns it; unpinned sessions never see this guard.
- `commit-guard.sh` (`commit_guard`, #455) — PreToolUse/Bash; denies a `git commit`
  lacking a DCO sign-off (`-s`/`--signoff`), INCLUDING `git commit --amend` without
  `-s`. Fires ONLY when a devAgent issue is active for the resolved project AND the
  command's cwd is inside that project's `source_dir` (DCO is this operator's
  per-project policy, not universal). A signed `git commit -s` outside commit.sh is
  ALLOWED (ship.sh's #148 recovery path); `-S` gpg-sign is NOT a DCO sign-off.
- `session-rehydrate.sh` (`session_rehydrate`, #456) — **SessionStart** (matchers
  `startup|resume|clear`; `compact` EXCLUDED — compaction already carries a summary).
  A NON-guard hook: prints where.sh's one-screen "active issue + last/next step" as
  session context when a project resolves (env pin → pointer → single-configured
  fallback). The NO-OP path is load-bearing — SessionStart fires for every session in
  every repo, so no resolvable project / a where.sh error prints NOTHING and exits 0.
- `preship-dirty-tree.sh` (`preship_dirty_tree`, #457) — **PostToolUse**/Bash,
  `command`-type (deterministic — NOT a Stop hook, which fires every turn; NOT a
  `prompt`-type LLM hook). When ship.sh is the PROGRAM of a Bash-TOOL call
  (`bash …/ship.sh`, `sh …ship.sh`, or a direct `…/ship.sh`) it surfaces UNTRACKED
  files (`git status --porcelain` `^??`) in the issue worktree via exit 2 (the
  PostToolUse feedback channel — the ship already ran, this never blocks it).
  **Coverage (was a limit until #452):** `/devagent:ship` used to bang-EXECUTE
  ship.sh (`!\`bash …ship.sh\``) — command-expansion, NOT a Bash tool call — so
  PostToolUse could not observe the operator-typed slash command. Since #452
  converted ship to `skills/ship/SKILL.md`, its body carries no `!` line: the
  model runs `bash …/ship.sh` through the Bash TOOL, which this hook DOES observe.
  Coverage therefore now spans both the operator-typed slash command and the
  agent-driven / manual `bash …/ship.sh` path. (Unchanged: the `--auto` chain
  never reads the skill body at all — `next.sh` execs `scripts/ship.sh` in-process
  whenever it is executable, so that path is not a Bash tool call either.)
  Marginal-value boundary vs #148: ship.sh's #148 gate hard-blocks dirty TRACKED
  state but EXCLUDES untracked (`grep -cv '^??'`); this hook adds EXACTLY that
  excluded class and nothing else — #148 stays the authority for tracked state.
  Noise-scoped: matches ship.sh only at PROGRAM position (an argument
  `cat …/ship.sh` never fires), worktree-only, .gitignore-respecting (never
  `--ignored`), and fires at most once per (state × worktree) via a per-worktree
  `.git/devagent-preship-nag` marker keyed to HEAD-sha + the untracked set.

git-guard and preship-dirty-tree double as partial detection for the checker
agents' accepted Bash-escape residual (§7.4, #529) — opt-in detection of the
destructive-git and untracked-file shapes only, not prevention and not coverage
of tracked-file edits, consistent with the "reflex backstop, not a sandbox"
boundary above. That the hooks observe a dispatched subagent's Bash calls at
all is docs-verified, not measured (2.1.211 hooks doc: `agent_id` is "present
only when the hook fires inside a subagent call" — #529's redmr demanded this
provenance be on record; a live probe rides the #533/#530 smoke family).

**Latency / noise budget:** every registered PreToolUse Bash hook spawns one process
on EVERY Bash tool call (≤5s each); Write/Edit calls now also spawn the pointer guard.
Even a DISABLED hook is not free: the gate runs one `awk` over `config.toml` per call
(plus a second `awk` over `_active.toml` when the `DEVAGENT_ACTIVE_PROJECT` env pin is
unset) — only the no-`config.toml` case is subprocess-free. Keep the stack small
(today: git-guard + active-pointer-guard + commit-guard on Bash; #457 may add more)
and each hook's MATCH path allocation-light (short-circuit before any
per-command subprocess like `git status`).

## 9. Backend abstraction

Two separate backend dimensions per project:

- **Issue source** — where tickets live. Today: GitHub. Tomorrow:
  GitLab, JIRA, a custom in-house tracker.
- **Code source** — where branches push and MRs file. Often the same
  as issue source; diverges when issues live in JIRA but code lives
  in GitHub/GitLab.

### 9.1 Issue backend contract (`scripts/issue/<backend>.sh`)

```
fetch        <repo> <num>                                  → markdown to stdout
create       <repo> <title> <body-file> [--label X]…       → new <num> to stdout
transition   <repo> <num> <semantic-stage>                 → exit 0 on success
state        <repo> <num>                                  → backend state to stdout
comment-list <repo> <num>                                  → markdown to stdout
```

`<semantic-stage>` is a key from `[project.<name>.issue_workflow]`
(e.g., `in_progress`). The backend script maps to its native state
representation:

- GitHub: add/remove labels per `github_labels` config sub-block
- GitLab: same label model
- JIRA: native state transitions via REST API

### 9.2 Code backend contract (`scripts/code/<backend>.sh`)

```
push-branch  <remote> <branch>                              → exit 0
create-mr    <repo> <title> <body-file> <head> <base>       → MR URL to stdout
               [--draft]
mr-state     <mr-url>                                       → open|merged|closed|draft
mr-comments  <mr-url>                                       → markdown to stdout
merge-mr     <mr-url> [--method squash|merge|rebase]        → exit 0
```

### 9.3 Markdown shape from `fetch`

```markdown
# <repo>#<num> — <title>

- State: open
- Author: @foo
- Labels: bug, performance
- URL: https://github.com/...

---

<body text exactly as posted>

---

## Comments (N)

### @reviewer · 2026-05-12

<comment body>
```

`pull.sh` writes this verbatim to `<issue-dir>/issue.md`.

### 9.4 Reference implementations (v1)

- `issue/github.sh`, `code/github.sh` — wrap `gh`
- `issue/gitlab.sh`, `code/gitlab.sh` — prefer `glab`, fall back to `curl` against REST v4
- `issue/jira.sh` — `curl` against REST API
- `issue/custom.sh`, `code/custom.sh` — stub printing helpful "not implemented; see README"

## 10. Auth subsystem

```
scripts/auth/<backend>.sh create   <project>
                          store    <project> <token-file>
                          rotate   <project>
                          destroy  <project>
                          status   <project>
                          exec     <project> -- cmd ...
```

- `create` is interactive: opens browser to the PAT-creation page,
  pastes from clipboard, validates scopes, stores.
- `store` ingests a token from a file (non-interactive — for CI).
- `rotate` is atomic: create new, swap, destroy old.
- `destroy` is `shred -u` then `unlink`.
- `status` prints backend, scopes, expiry, last-used; never the token.
- `exec` sets the appropriate env var and execs. All issue/code
  backend scripts call themselves through `exec` so tokens never
  appear in `ps` or argv.

Storage at `~/.claude/devagent/secrets/<project>.<backend>.pat`, mode
600 in a dir mode 700. Future `--keyring` flag swaps to
libsecret/Keychain without changing caller contract.

## 11. Issue lifecycle / state transitions

Three semantic events trigger backend transitions:

| Event | Stage | Hook |
|---|---|---|
| Start of `draft` (step 1) | `on_draft_start` | `/devagent:draft` invokes `scripts/transition-draft-start.sh` once `issue.md` is confirmed and *before* invoking the writing-plans skill; gated by `permissions.transition_issue` (fail-closed skip-warn like `on_merge`, #219) and warns on failure rather than dying (#325) |
| End of `ship` (step 15) | `on_ship` | `ship.sh` after successful MR creation; **not** gated by `transition_issue` (consent-by-ship-action, #219), and a failing transition degrades to a warn — ship still completes |
| MR merged upstream (async) | `on_merge` | `/devagent:sync` |

The `commit` → `analyze` ordering (steps 10 → 11) exists because
`static_analysis_diff.py` requires a `git diff` against a baseline,
which requires a commit. With squash-on-merge, the noise of a
post-analyze amend commit is acceptable — both end up squashed.

If a transition fails (auth expired, JIRA disallows the transition
from current state), the **step proceeds anyway** but the failure is
logged with reason. Tracker-state failures do not block real work.

## 12. Templates / artifacts registry

Artifact resolution order is fixed and explicit:

1. `[project.<name>.paths].<artifact_key>` → file path (absolute or
   relative to `devdoc_dir`)
2. `<devdoc>/templates/<name>.md`
3. `~/src/devAgent/templates/<name>.md`

v1 artifact list:

| Key | Used by |
|---|---|
| `coding_standards` | step 8 (quality), step 13 (review) |
| `commit_template` | step 10 (commit) |
| `mr_template` | step 12 (draftmr) |
| `issue_template-<type>` | capture, reap, file |
| `epic_template` | capture (epic mode), scaffold |
| `redteam_issue_shared` / `_light` / `_standard` / `_full` | redissue (#443: tier-split; a monolithic `redteam_issue` override, resolved by the same §12 walk, shadows all tiers) |
| `redteam_mr` | redmr |
| `imPlan_template` | draft |
| `actualWork_template` | document |
| `lessonsLearned_template` | lessonslearned |
| `wbs_template` | wbs init |
| `statusreport_template` | statusreport |
| `checklist-standard` | checklist-init (default workflow template) |
| `checklist-perf` | checklist-init (perf-workflow template) |
| `checklist-docs-only` | checklist-init (docs-only template) |
| `checklist-research` | checklist-init (research template) |
| `revision_block` | revise (the per-revision checklist block, #76) |
| `intent_template` | draft (dispatched-planning `intent.md`, #284) |
| `potholes` | draft (pothole register read → `## Potholes considered`, #286), lessonslearned (`[pattern]`→register promote) |

Migration on first install: existing files at
`~/src/devAgent/{commitMessageTemplate,pr-redteam-prompt,PULL_REQUEST_TEMPLATE}.md`
and `~/.claude/{pr,issue}-redteam-prompt.md` are moved into
`~/src/devAgent/templates/` with canonical names. Original locations
left as symlinks for one release cycle to ease external references.

## 13. WBS data model

WBS source-of-truth is markdown with inline metadata, designed so
future renderers (Gantt, MS Project XML, OpenProject API) can parse
without changing the operator-facing format.

### 13.1 Source format (`<devdoc>/WBS.md`)

```markdown
# volk WBS

- [ ] Performance overhaul {est: 8w, milestone: M2, owner: @matt, cost: 0}
  - [x] Baseline measurement infrastructure {issue: Issue-Fork-12, est: 1w}
  - [~] Kernel fusion across hot path {issue: Issue-Fork-24, est: 4w, depends_on: Issue-Fork-12}
  - [ ] Static analyzer integration {issue: Issue-676, est: 1w}
- [ ] Dispatch path test coverage {est: 3w, milestone: M3}
```

Each leaf or node can carry an inline `{key: value, …}` metadata block.
Recognized keys (v1): `issue`, `est`, `cost`, `owner`, `milestone`,
`start`, `due`, `depends_on`. Unrecognized keys are preserved
verbatim for forward compatibility.

### 13.2 Commands

- `/devagent:wbs init` — scaffold from `wbs_template.md`
- `/devagent:wbs update` — invoked by step 17 and by `planwbs` from
  capture family; appends/updates entries based on active issues
- `/devagent:wbs show [--depth N] [--milestone X]` — markdown render

### 13.3 Future renderers (out of scope for v1)

- `/devagent:wbs gantt` — render to mermaid or PlantUML Gantt
- `/devagent:wbs export --format mspdi` — MS Project XML
- `/devagent:wbs export --format openproject` — POST to OpenProject API

These are deliberately deferred. The metadata schema is fixed in v1
so deferred renderers do not require schema migration.

## 14. Status reports

### 14.1 Pin

`~/.claude/devagent/state/<project>.statusreport.toml` holds the last
pin timestamp. `/devagent:statusreport` rolls it forward to now;
`--no-pin` runs read-only.

### 14.2 Data sources

- Per-issue `checklist.md` log entries with timestamps > pin
- Per-issue `STUCK` files (presence + mtime)
- `actualWork.md` deviation sections
- Source-repo `git log --since=<pin>`
- Devdoc-repo `git log --since=<pin>`
- `code/<backend>.sh mr-state` for shipped issues
- WBS for roll-up

### 14.3 Output

Written to `<devdoc>/StatusReports/YYYY-MM-DD.md`, committed if
`permissions.commit_devdoc=true`.

```markdown
# Status Report — volk — 2026-05-19 → 2026-05-26
Pin: 2026-05-19T14:30 → 2026-05-26T09:00 (6d 18h)

## Accomplished
- Issue-676 shipped → merged 2026-05-22 (PR #842)
- Issue-Fork-24 advanced steps 5→8

## Needs attention
### Stuck (1)
- Issue-Fork-12 — 11 days — "RFFT tap mismatch"
### Failed red-team (1)
- Issue-Fork-25 — 12 blocking findings on 2026-05-23
### Idle > 7d (2)
- Issue-203, Issue-Fork-13
### Poorly scoped (0)
### Dispatch-lint rejects (1)
- Issue-Fork-25 (2)

## WBS roll-up
<top-level milestones; expand only branches with active issues>

## Velocity & estimate
- Last 4 weeks: 2.3 issues/week shipped, median 4.1 days/issue
- Remaining WBS leaves: 18
- Estimated completion: 2026-08-14 ± 3 weeks
```

### 14.4 Detection heuristics

- **Stuck** — STUCK file present
- **Failed red-team** — most recent `redmr` log entry contains
  `blocking` with count > 0, and no subsequent passing `redmr` entry
- **Poorly scoped** — `scope` step logged ≥3 recommendations, or the
  log contains the word "ambiguity"
- **Idle** — `updated_at` > 7 days ago and step < 20
- **Dispatch-lint rejects** (#438) — count of `*.md` under the issue's
  `analysis/rejected/` archive (dispatched checker reports the linter rejected,
  #360). Issues with zero rejects are omitted from the list — no added noise.

### 14.5 Velocity & estimate

- Velocity = issues completed (step 20) per calendar week, computed
  over a configurable window (default 4 weeks)
- Estimate = (remaining WBS leaves) / velocity, rendered with `± X
  weeks` band based on observed variance
- Honest noise: v1 makes no attempt at precision and the report says
  so explicitly

## 15. Reap

`/devagent:reap [project]` scans for follow-up candidates:

- All `imPlan-potentialFutureEnhancements.md` files
- All `STUCK` files (unresolved blockers may warrant their own issue)
- All `actualWork.md` files for sections marked `### Follow-up` or
  containing the phrase "should be its own issue"
- All `lessonsLearned.md` entries tagged actionable

For each candidate, drafts a `Captures/<auto-slug>/draft.md` populated
from the matching `issue_template-*.md` with source citation
(`Found in Issue-676/imPlan-potentialFutureEnhancements.md line 42`).

Idempotent: content-hashes of reaped items live in
`~/.claude/devagent/state/<project>.reaped.toml`. A second run on the
same source produces nothing new.

After reap, captures flow through normal
`redissue` → `file` pipeline.

## 16. Revision flow

Post-MR feedback often requires re-walking the pipeline. Pattern:

1. `/devagent:comments` — fetch MR comments to
   `<issue-dir>/revisions/r<N>/comments.md`
2. `/devagent:revise` — increment revision counter, append a new
   `## Revision N` block to checklist with steps 1–14, 21 (preship),
   15, 16–20 re-listed in file order as `[ ]` (the `revision_block`
   template, #76 — NOT a bare 1–15), log the revision start. Then
   `/devagent:next` resumes from `draft` with the comments in context.
   The by-name preship/closeout gates are revision-scoped to match, so
   a hand-built block that omits them would bypass those gates.

Original Revision 1 entries remain in the checklist. Log is shared
across revisions for chronological readability.

## 17. Skill integration mapping

| Step / command | Skill |
|---|---|
| draft | `superpowers:writing-plans` (or dispatched planner, #284) |
| branch | `superpowers:using-git-worktrees` |
| implement | `superpowers:executing-plans` |
| quality | `simplify` |
| review | `superpowers:requesting-code-review` |
| scope, improve, prune, tighten, redmr, preship, lessonslearned, impact, capture, scaffold, redissue, reap, document, draftmr | devAgent-shipped custom skills under `skills/core-*` |

Custom skills live in `~/src/devAgent/skills/` and follow superpowers
skill conventions (frontmatter, single-purpose, checklists where
applicable).

## 18. Static analyzers and sanitizers

Step 11 (`/devagent:analyze`) dispatches to a per-project analyzer family
selected by `analyze = cmake | shellcheck | none` in
`[project.<name>]` (#55/#117). All paths are diff-scoped (changed lines
only) and require a baseline ref — hence the commit-before-analyze
ordering. A per-phase analyzer failure fails the step loudly rather than
being swallowed (#117); output is written under
`<issue-dir>/analysis/YYYY-MM-DD-<tool>.txt`.

- **`cmake`** (C/C++ projects, the default) — `analyze-static.sh` wraps the
  36 KB `~/src/devAgent/static_analysis_diff.py` (cppcheck, cpplint,
  clang-tidy, scan-build, include-what-you-use), then `analyze-sanitizers.sh`
  runs ASan/UBSan/TSan against the same diff scope (separate toolchain and
  build dir, slower). Both run sequentially; no checklist sub-step tracking.
- **`shellcheck`** (bash projects, e.g. devAgent itself) — diff-scoped
  `shellcheck` over the changed shell lines, with the same changed-line
  novelty gate as the C path (only findings new vs the baseline count).
- **`none`** — the step self-marks `[-]` with a logged reason (projects with
  no analyzable source, e.g. docs-only repos).

**`analyze_timeout` (#351).** A per-phase budget in seconds for the `cmake`
analyze legs (configure / build / ctest), default 1800. It bounds a hung build
or test that would otherwise wedge an `--auto` chain forever; a leg exceeding it
fails step 11 (#117). Set it in `[project.<name>]` (raise for a large/slow ctest
suite); `shellcheck`/`none` projects ignore it.

**Build-dir keying (#117).** The sanitizer and static build dirs are keyed
per project **and** issue — `build-<project>-<issue>[-<tag>]/` — so concurrent
`--auto` chains that share one source tree never collide on a build directory;
cleanup removes them.

## 19. Testing strategy

- Shell scripts under `scripts/`: `bats` test harness in `tests/`
- Python helpers (including `static_analysis_diff.py`): `pytest`
- Backend scripts mocked via fixture servers (no live API calls in CI)
- Per-step integration test: scaffold a fake issue dir, run the step,
  assert checklist updates and log entries
- Doctor command must pass against a reference `config.toml` fixture

## 20. Open questions for future versions

- **v2 candidates:**
  - `--keyring` mode for auth storage (libsecret/Keychain/wincred)
  - WBS Gantt / MS Project / OpenProject renderers
  - Auto-priority shifts: `/devagent:next` opting to suggest a
    different issue when current is `[?]` blocked
  - Issue dependency graph visualization

- **v3 candidates:**
  - Custom in-house tracker backend (replacing GitLab/JIRA in some
    projects)
  - Cross-project epic coordination
  - Cost rollups feeding budget tracking
  - Multi-operator support (handoff between humans, attribution)

- **Deliberately out of scope:**
  - Cloud-hosted CI orchestration
  - Real-time collaboration / shared sessions
  - Replacing git itself
  - Replacing the project tracker UI

## 21. Implementation phasing within v1

Even though all commands are v1, build order matters. Suggested
phasing for the implementation plan:

1. **Foundation:** `config.toml` loader, state files, secrets dir,
   `doctor`, `init`, checklist library, log library
2. **Pull family:** `pull`, `where`, `next`, `status`, `catchup`,
   `stuck`, `unstuck`, `park`, `resume`, `switch`
3. **Workflow (script steps):** `branch`, `commit`, `analyze`, `ship`,
   `mergetoall`, `cleanup`, `sync`
4. **Workflow (skill steps):** `draft`, `scope`, `improve`, `prune`,
   `tighten`, `implement`, `quality`, `document`, `draftmr`,
   `review`, `redmr`, `impact`, `lessonslearned`
5. **Capture family:** `capture`, `scaffold`, `redissue`, `file`,
   `reap`
6. **Revision family:** `comments`, `revise`
7. **WBS + status:** `wbs`, `statusreport`, `updatewbs`
8. **Auth subsystem:** `auth create|store|rotate|destroy|status|exec`
9. **Tooling:** `depends`, `grep`, `history`, `template`
10. **Backends:** ship with `github` complete; `gitlab` + `jira` +
    `custom` stubs with contract tests

This ordering ensures the context-preservation core is functional
before workflow commands need it.
