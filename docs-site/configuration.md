<!-- derived-from: README.md docs/specs/2026-05-19-devagent-plugin-design.md -->
# Configuration

## config.toml anatomy

All projects live in one file: `~/.claude/devagent/config.toml`
(bootstrapped per project by `/devagent:init`). A representative entry:

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
analyze          = "none"                      # step-11 analyzer family
branch_prefix_map = { bug = "fix", feature = "feat", docs = "docs", perf = "perf", chore = "chore" }

[project.myproj.permissions]   # gates the workflow must ask before crossing
push_mr          = true        # step 15 may push + open the MR
merge_mr         = false       # merging the MR itself
merge_to_all_prs = false       # step 16 local integration branch
commit_devdoc    = true        # step 20 may commit the devdoc
transition_issue = true        # tracker state transitions may fire

[project.myproj.issue_source]  # where tickets live
backend = "github"             # github | gitlab | jira | custom
repo    = "you/myproj"

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
```

## The five-verb backend contract

Backends are plain scripts; four ship out of the box (`github`, `gitlab`,
`jira`, and a `custom` stub). Every **issue backend** implements five verbs:

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

The markdown shape produced by `fetch` and `comment-list` is fixed across
backends, so everything downstream is backend-agnostic. To add your own
tracker, copy `scripts/issue/custom.sh`, implement each verb, point
`backend = "<yourname>"` at it, and verify with
`bats tests/backend-<yourname>.bats`.

## Templates (the §12 registry)

Every artifact the workflow writes (plans, MR bodies, red-team prompts,
checklists, the pothole register …) resolves through a fixed three-layer
order:

1. A per-project `paths` override in `config.toml` (exact file path).
2. Your devdoc's `templates/` directory — per-project customization.
3. The plugin's own `templates/` directory (under the plugin cache dir) —
   the shipped defaults.

Example keys: `imPlan_template` (step 1), `mr_template` (step 12),
`potholes` (steps 1/19), `checklist-standard` (issue scaffolding). Inspect
what resolves where with `/devagent:template list` and
`/devagent:template show <key>`.

[← devAgent onboarding](./index.md)
