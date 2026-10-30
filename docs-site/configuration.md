<!-- derived-from: README.md docs/specs/2026-05-19-devagent-plugin-design.md templates/config.toml.skel -->
# Configuration

## config.toml anatomy

All projects live in one file: `~/.claude/devagent/config.toml`
(bootstrapped per project by `/devagent:init`). A representative entry —
note the permissions here loosen three of the shipped defaults; a fresh
init writes all five `false`:

```toml
[defaults]
checklist_template = "standard"
ship_as_draft = false
phase_breaks = "implement quality updatewbs"   # the default: an --auto chain stops
                                               # before these steps so the next phase
                                               # starts in a fresh session; "" disables
# print the active issue and next step at session start (a bare line: no comment on it)
session_rehydrate = true
ci_gate = "report"   # the default. After ship, next prints one CI line; mergetoall
                     # requires green. "block" also holds a pending step (exit 0,
                     # nothing marked) and marks a red one [!]; "off" reads nothing.
                     # Read only as [defaults] ci_gate or [project.<name>] ci_gate:
                     # any other spelling or table is ignored, so the gate stays
                     # in report mode. Any other value stops next with an error.

[project.myproj]
source_dir       = "/home/you/src/myproj"      # the code checkout
devdoc_dir       = "/home/you/src/devDoc/myproj" # per-issue artifacts
default_baseline = "origin/main"               # branch step's base
fork_first       = false                       # branch/push via a fork
ship_as_draft    = false                       # open MRs as drafts
analyze          = "none"                      # step-13 analyzer family; default when absent: cmake
                                               # legal: cmake | shellcheck | none; shellcheck needs
                                               # shellcheck on PATH, tested against
                                               # shellcheck 0.9.0 or newer (commands/analyze.md)
suite_jobs       = 1                           # bats test files run N at a time (#593)
                                               # needs GNU parallel on PATH; raise only after
                                               # auditing the suite at file granularity
                                               # (README "Parallel bats")
# evidence_platforms = ["os=Linux fs=ext4 modes=posix"]
                                               # optional (#654): platforms whose suite evidence
                                               # THIS config's preship accepts; any other fails
                                               # PLATFORM UNATTESTED. Absent: the platform is only
                                               # echoed on preship-evidence's PASS line.
                                               # modes=posix: the chmod probe found no no-op (it
                                               # fails open), not proof that modes work.
                                               # Declared or not, mr.md's Evidence block must
                                               # carry the artifact's platform: line, or drop it:
                                               # an unfilled template line fails preship.
                                               # (tests/suite-platform.bats runs the example
                                               # line as written.)
branch_prefix_map = { bug = "fix", feature = "feat", docs = "docs", perf = "perf", chore = "chore" }

[project.myproj.permissions]   # pre-grants: true = proceed unprompted,
                               # false = stop and ask (autonomous paths
                               # skip instead of asking; transition_issue
                               # skips even an interactive ship's on_ship).
                               # All ship false.
push_mr          = true        # step 18 pushes + opens the MR unprompted
merge_mr         = false       # legacy alias of merge_to_all_prs; no step merges the MR
merge_to_all_prs = false       # step 19 local integration branch
commit_devdoc    = true        # step 24 commits the devdoc unprompted
transition_issue = true        # every tracker transition (draft, ship, sync) writes only when true

[project.myproj.issue_source]  # where tickets live
backend = "github"             # github | gitlab | jira | custom
repo    = "you/myproj"
dir_prefix = "Issue-"          # issue-directory prefix; pull dies without it.
                               # wbs update also maps leaves to this tracker by it

[project.myproj.code_source]   # where branches push and MRs file
backend  = "github"
upstream = "you/myproj"
fork     = "you/myproj"

[project.myproj.issue_workflow] # semantic stage -> tracker state: a label on
on_draft_start = "In Progress"  # GitHub/GitLab, a status on JIRA. It must
on_ship        = "In Review"    # already exist; devagent never creates one.
on_merge       = "Done"         # Optional per-stage label override:
                                # [project.myproj.github_labels] (or
                                # gitlab_labels) keyed on_draft_start/on_ship/on_merge
# not_planned_resolutions = ["Won't Do"]  # jira: wbs update reads these done
                                          # resolutions as [-] (#703)

[project.myproj.wbs]           # optional (#706, #803)
auto_import_below_pct = 20     # wbs init --from-tracker imports
                               # everything while the closed share is below this
                               # (integer 0-100); at or above it /devagent:wbs
                               # asks how far back to go
order_on_update = true         # wbs update sorts each parent's children by
                               # dependency, then priority (P1-P4); false: off.
                               # Preview with /devagent:wbs order --dry-run
completed_last = false         # true: finished siblings follow the open ones

[project.myproj.step_models]   # optional per-step-class model tiers
checking = "opus"

[project.myproj.suite_env]     # optional; exported into run-suite.sh's bats and
                               # pytest child processes (step-14 evidence, #603).
                               # For a suite that needs environment which is not
                               # derivable from the tree — e.g. a data root kept
                               # outside git. Declaring it here rather than
                               # relying on the invoking shell keeps the evidence
                               # artifact a function of the TREE, not of the
                               # operator's session. Values are tilde-expanded;
                               # an empty value or a non-identifier key dies
                               # loud. The artifact records the NAMES only
                               # (`suite_env: FOO BAR`), never the values, so a
                               # declared secret is not quoted into an MR body.
MYPROJ_DATA_ROOT = "~/src/myprojData"
```

## The backend verb contract

Backends are plain scripts; four issue backends ship out of the box
(`github`, `gitlab`, `jira`, and a `custom` stub), and code backends for
GitHub and GitLab plus a `custom` stub (JIRA hosts issues only). Every
**issue backend** implements five verbs and may implement three more,
`state-list`, `issue-list` and `state-exists`:

| Verb | Args | Output / exit |
|------|------|---------------|
| `fetch` | `<repo> <num>` | markdown to stdout |
| `create` | `<repo> <title> <body-file> [--label X]…` | new num to stdout |
| `transition` | `<repo> <num> <semantic-stage> [--project <name>]` | exit 0 landed, already there or no mapping; non-zero did not land |
| `state` | `<repo> <num>` | backend state |
| `comment-list` | `<repo> <num>` | markdown to stdout |
| `state-list` | `<repo>` | one `<id>` TAB `<class>` line per issue (optional) |
| `issue-list` | `<repo>` | one JSON record per issue (optional) |
| `state-exists` | `<repo> <state-name>` | exit 0 present, 4 absent (optional) |

`transition` writes the tracker state the stage maps to: the
`issue_workflow` value, unless a `github_labels` / `gitlab_labels` table
overrides that stage. The callers append `--project <name>` (a custom
backend may ignore it), and every transition is behind
`permissions.transition_issue`. A built-in backend reads the issue first,
writes the target and removes the other mapped stage labels the issue
carries; a mapped label or status missing from the tracker is never
created, and the backend exits non-zero naming it while the step carries
on. On GitLab the label is checked — the project's or an ancestor group's
— before any write. (The group-label path is unverified against a live
GitLab instance.)

The per-stage environment overrides `DEVAGENT_GITHUB_LABEL_<STAGE>`,
`DEVAGENT_GITLAB_LABELS_<STAGE>` and `DEVAGENT_JIRA_STAGE_<STAGE>` take
precedence over config, and they are process-global: a stale one redirects
every project's write. `/devagent:doctor` warns while one is set, and, for
a project with `transition_issue = true`, checks each mapped state with
`state-exists` — a warning, never a failure, skipped when the tracker is
unreachable.

`state-list` is what `wbs update` reads to set leaf glyphs from the
tracker. The class is `done`, `not_planned`, `in_progress`, `open` or
`other`; the in-progress signal is the label `issue_workflow.on_draft_start`
maps to, after any `github_labels` / `gitlab_labels` or environment
override. There is no default label. A
backend without it exits 78 (or 2, unknown verb), and `wbs update` then
uses local checklists. `issue-list` is what `wbs init --from-tracker`
reads to build a new `WBS.md` from the tracker history, and what
`wbs init --merge` reads to add the issues an existing one lacks; without
it those commands stop. See spec §9.1.

Every **code backend** implements five verbs and may implement two more,
`issue-mrs` and `mr-checks`:

| Verb | Args | Output / exit |
|------|------|---------------|
| `push-branch` | `<remote> <branch>` | exit 0 |
| `create-mr` | `<repo> <title> <body-file> <head> <base> [--draft]` | MR URL to stdout |
| `mr-state` | `<mr-url>` | `open\|merged\|closed\|draft` |
| `mr-comments` | `<mr-url>` | markdown to stdout |
| `merge-mr` | `<mr-url> [--method squash\|merge\|rebase]` | exit 0 |
| `issue-mrs` | `<repo> <id>...` | `issue` and `mr` lines per issue (optional) |
| `mr-checks` | `<mr-url>` | `state`, `head` and one line per CI check (optional) |

`issue-mrs` is what `wbs update` reads to show linked-MR state on open
issue leaves (`[~]` with `mr: open`, `draft` or `merged`). An MR links an
issue when its title or description carries a closing-keyword reference
(`Closes #N`, `Fixes owner/repo#N`), whatever its target branch; a
`Related: #N` mention does not. GitHub costs one GraphQL call per 50 open
leaves, GitLab one call per open leaf. A backend without it exits 78 (or
2, unknown verb), and `wbs update` then shows no MR state. See spec §9.2.

`mr-checks` is what `/devagent:next` reads after ship to print one `CI …:`
line (`CI PASSED`, `CI PENDING`, `CI FAILED`, `CI NONE`, `CI UNKNOWN`),
and what `mergetoall` reads to refuse a red or pending branch. It is one
bounded call (20 s) per `next` invocation from ship until cleanup; nothing
waits for CI. GitHub implements it; a backend without it prints `CI NOT
CHECKED` and gates nothing. See spec §7.2 and §9.2.

Exit-code conventions across all backends:

| Code | Meaning |
|------|---------|
| 0 | success |
| 1 | generic failure |
| 2 | usage error (bad/missing args, unknown verb) |
| 3 | auth failure (HTTP 401/403) |
| 4 | not found (HTTP 404) |
| 5 | malformed, truncated or non-ending response (a 2xx page that is not the expected JSON, a list cut at a backend's limit, or a paging walk that does not end) |
| 78 | not implemented (reserved for stubs) |

The markdown shapes produced by `fetch`, `comment-list` and `mr-comments` are
fixed across backends, so everything downstream is backend-agnostic.
`mr-comments` entries may add an optional ` · review: <STATE>` or
` · <path>:<line>` suffix; the github backend includes review summaries and
inline code comments this way. To add your own
tracker or forge, copy `scripts/issue/custom.sh` (and `scripts/code/custom.sh`
for the forge half), implement each verb, point `backend = "<yourname>"` at
it, and verify with a `tests/backend-<yourname>.bats` you write yourself —
copy `tests/backend-contract.bats` as the starting point.

## Templates (the §12 registry)

Every artifact the workflow writes (plans, MR bodies, red-team prompts,
checklists, the pothole register …) resolves through a fixed three-layer
order:

1. A per-project `paths` override in `config.toml` (a file path; relative
   paths resolve against `devdoc_dir`). Beware: an override path that does
   not exist falls through to the next layer with a warning on stderr.
2. Your devdoc's `templates/` directory — per-project customization.
3. The plugin's own `templates/` directory (under the plugin cache dir) —
   the shipped defaults.

Example keys: `imPlan_template` (step 2), `mr_template` (step 14),
`potholes` (steps 2/23/24), `checklist-standard` (issue scaffolding).

The pothole register is layered (#611): `show potholes` prints the union of the
plugin seed, the shared workflow register and the project's own register. The
workflow register is named by a global `[paths] potholes_workflow = "<absolute
path>"` (a per-project `[project.<name>.paths]` value overrides it); it is the
one key that reads the global table, and it has no plugin fallback, so
`template list` shows it as its own row. Optional
`[project.<name>.paths] potholes_domain_nouns = [...]` lists words the shared
layer refuses at staging time.

The plugin's own `templates/potholes.md` is a curated public excerpt (#613): at
most 100 entries, 25 per section, citing devagent issues only. Its line-1
marker names a commit in the plugin author's private devDoc — the migration
ledger that records where every pre-#613 entry went — and is not resolvable
from a public install; the entries that left the seed are in the plugin's own
git history at `2438f4d`. On a fresh install the excerpt IS the register; the
private layers you accumulate hold the rest, and step 23 writes only to those.

Inspect
what resolves where with `/devagent:template list` and
`/devagent:template show <key>`.

[← devAgent onboarding](./index.md)
