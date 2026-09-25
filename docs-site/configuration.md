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

[project.myproj]
source_dir       = "/home/you/src/myproj"      # the code checkout
devdoc_dir       = "/home/you/src/devDoc/myproj" # per-issue artifacts
default_baseline = "origin/main"               # branch step's base
fork_first       = false                       # branch/push via a fork
ship_as_draft    = false                       # open MRs as drafts
analyze          = "none"                      # step-13 analyzer family; default when absent: cmake
suite_jobs       = 1                           # bats test files run N at a time (#593)
                                               # needs GNU parallel on PATH; raise only after
                                               # auditing the suite at file granularity
                                               # (README "Parallel bats")
branch_prefix_map = { bug = "fix", feature = "feat", docs = "docs", perf = "perf", chore = "chore" }

[project.myproj.permissions]   # pre-grants: true = proceed unprompted,
                               # false = stop and ask (autonomous paths
                               # skip instead of asking). All ship false.
push_mr          = true        # step 18 pushes + opens the MR unprompted
merge_mr         = false       # legacy alias of merge_to_all_prs; no step merges the MR
merge_to_all_prs = false       # step 19 local integration branch
commit_devdoc    = true        # step 23 commits the devdoc unprompted
transition_issue = true        # tracker state transitions fire unprompted

[project.myproj.issue_source]  # where tickets live
backend = "github"             # github | gitlab | jira | custom
repo    = "you/myproj"
dir_prefix = "Issue-"          # issue-directory prefix; pull dies without it

[project.myproj.code_source]   # where branches push and MRs file
backend  = "github"
upstream = "you/myproj"
fork     = "you/myproj"

[project.myproj.issue_workflow] # semantic stage -> tracker state
on_draft_start = "In Progress"
on_ship        = "In Review"
on_merge       = "Done"

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

## The five-verb backend contract

Backends are plain scripts; four issue backends ship out of the box
(`github`, `gitlab`, `jira`, and a `custom` stub), and code backends for
GitHub and GitLab plus a `custom` stub (JIRA hosts issues only). Every
**issue backend** implements five verbs:

| Verb | Args | Output / exit |
|------|------|---------------|
| `fetch` | `<repo> <num>` | markdown to stdout |
| `create` | `<repo> <title> <body-file> [--label X]…` | new num to stdout |
| `transition` | `<repo> <num> <semantic-stage>` | exit 0 |
| `state` | `<repo> <num>` | backend state |
| `comment-list` | `<repo> <num>` | markdown to stdout |

Every **code backend** implements five verbs:

| Verb | Args | Output / exit |
|------|------|---------------|
| `push-branch` | `<remote> <branch>` | exit 0 |
| `create-mr` | `<repo> <title> <body-file> <head> <base> [--draft]` | MR URL to stdout |
| `mr-state` | `<mr-url>` | `open\|merged\|closed\|draft` |
| `mr-comments` | `<mr-url>` | markdown to stdout |
| `merge-mr` | `<mr-url> [--method squash\|merge\|rebase]` | exit 0 |

Exit-code conventions across all backends:

| Code | Meaning |
|------|---------|
| 0 | success |
| 1 | generic failure |
| 2 | usage error (bad/missing args, unknown verb) |
| 3 | auth failure (HTTP 401/403) |
| 4 | not found (HTTP 404) |
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
`potholes` (steps 2/22/23), `checklist-standard` (issue scaffolding).

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
private layers you accumulate hold the rest, and step 22 writes only to those.

Inspect
what resolves where with `/devagent:template list` and
`/devagent:template show <key>`.

[← devAgent onboarding](./index.md)
