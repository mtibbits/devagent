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
# phase_breaks: an --auto chain stops before the named steps so the next phase
# starts in a fresh session; "" disables. Unset, it breaks before implement and
# quality, and before updatewbs unless the active revision's mergemr row is [x],
# or [-] because ship was [-] (no PR); no mergemr row (older than #899) or an
# abandoned PR (mergemr [-] after a real ship) keeps that break. A value set
# here or in [project.<name>] itself (above its first subtable) is honoured as
# written, so writing the line below keeps the old break before updatewbs even
# after a merge.
# phase_breaks = "implement quality updatewbs"
# print the active issue and next step at session start (a bare line: no comment on it)
session_rehydrate = true
ci_gate = "report"   # the default. After ship, next prints one CI line; mergetoall
                     # requires green. "block" also holds a pending step (exit 0,
                     # nothing marked) and marks a red one [!]; "off" reads nothing.
                     # Read only as [defaults] ci_gate or [project.<name>] ci_gate:
                     # any other spelling or table is ignored, so the gate stays
                     # in report mode. Any other value stops next with an error.
                     # It does not apply to step 20 (mergemr), which always reads CI.
merge_method = "squash"     # step 20's merge: squash (default) | merge | rebase
merge_checks = "required"   # the default: step 20 merges only on green CI and stops
                            # [!] when the PR has no checks. A repo without CI sets
                            # merge_checks = "if-present". Both keys also work per
                            # project; a bad value stops step 20 on every run.

# Operator capacity (#743), optional: see "Capacity" below.
# devagent does not know the subscription's limits: every value here is an example.
# [capacity]
# operator_hours_per_week = 20          # example
# lane_hours_per_week = 40              # example
# max_lanes = 3                         # example
# tokens_per_week = 500000000           # example
# tokens_per_window = 60000000          # example
# windows_per_week = 10                 # example
# operator_hours_per_agent_hour = 0.25  # example (the one optional key)

[project.myproj]
source_dir       = "/home/you/src/myproj"      # the code checkout
devdoc_dir       = "/home/you/src/devDoc/myproj" # per-issue artifacts
default_baseline = "origin/main"               # branch step's base
fork_first       = false                       # branch/push via a fork
ship_as_draft    = false                       # open MRs as drafts
# default_issue_source = "origin"              # #1099: the tracker a flagless /devagent:pull reads,
                                               # "origin" or "fork"; unset = the only configured
                                               # source, else origin. --origin/--fork override it
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
merge_mr         = false       # true: step 20 merges the PR at the preship-verified
                               # head (#885). Read directly, never a prompt; false
                               # waits [?] until the PR is merged elsewhere
merge_to_all_prs = false       # step 19 local integration branch (merge_mr no longer gates it)
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
                               # dependency, then priority (P0-P4); false: off.
                               # Preview with /devagent:wbs order --dry-run
completed_last = false         # true: finished siblings follow the open ones

[project.myproj.merge_forward] # optional (#1125): accept a merge-forward that only
verify = "ci"                  # re-applies git's own merge of the base (plus keep-both
append_only = ["CHANGELOG.md"] # in these exact files) without a full preship:
                               # `preship-verified-head.sh forward <project>`
                               # re-records verified_head, and step 20 merges that
                               # head only on green CI. Absent or "preship": every
                               # merge-forward needs /devagent:preship. "The base" is
                               # default_baseline's ref: if it does not track the
                               # PR's base, leave verify unset. forward also refuses
                               # when a line of mr.md contains "merge gate" (any case):
                               # use that phrase for head-tied evidence. A bad value
                               # stops step 20 and forward naming the key; doctor
                               # reports it.

# [project.myproj.capacity]
# priority = 5                          # example
# max_lanes = 2                         # example
# paused = false                        # example
# deadline = 2026-12-31                 # example
# reserve_operator_hours_per_week = 4   # example
# reserve_tokens_per_week = 100000000   # example

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

## Capacity

Operator capacity (#743) is what the operator can give devagent each week. It
is declared in a shared top-level `[capacity]` table and, per project, an
optional `[project.<name>.capacity]` table (the commented tables in the anatomy
above). devagent only declares and validates it here: dividing it among
projects, scheduling and the forecast are planned (#744). With no `[capacity]`
table, forecasting is off.

devagent does not know the subscription's limits: every value in the examples is an example, not a measurement.
Every number is declared: the token numbers are the operator's own, and relating the subscription's limits (which may count raw tokens) to this budget is the operator's call.

Tokens are weighted input-token equivalents, the unit of the actuals ledger
(#729); the document names it as `token_unit` = `weighted_input_token_equivalents`.
Operator hours are operator time as #733 measures it.

### Keys

In `[capacity]`, every key except `operator_hours_per_agent_hour` is required.

| Key | Type | Range | Meaning |
|---|---|---|---|
| `operator_hours_per_week` | number | `0 < x <= 168` | Hours of the operator's attention a week |
| `lane_hours_per_week` | number | `0 < x <= 168` | Hours one lane may run a week |
| `max_lanes` | integer | `1 <= x <= 9007199254740991` | The shared lane pool: lanes running at once, all projects together |
| `tokens_per_week` | integer | `0 < x <= 9007199254740991` | The weekly token budget |
| `tokens_per_window` | integer | `0 < x <= 9007199254740991` | The token budget of one rolling window |
| `windows_per_week` | number | `0 < x <= 33.6` | Windows used a week (at most 168 hours of back-to-back five-hour windows) |
| `operator_hours_per_agent_hour` | number | `0 <= x <= 9007199254740991` | Optional. Fallback operator hours per agent hour for a project with no history (the operator-attention sibling of #744 consumes it) |

In `[project.<name>.capacity]`, every key is optional:

| Key | Type | Default | Range | Meaning |
|---|---|---|---|---|
| `priority` | integer | `5` | `1 <= x <= 9007199254740991` | Order when shared capacity is short; a lower number is a higher priority |
| `max_lanes` | integer | none | `1 <= x <= 9007199254740991` | This project's lane cap; it may not exceed `capacity.max_lanes` |
| `paused` | boolean | `false` | | A paused project takes no capacity: its reservations leave the pool sums (planned, #744: its forecast outcome is "paused") |
| `deadline` | date | none | | A TOML local date (`2026-12-31`) or a quoted `"YYYY-MM-DD"` string (planned, #744: the date the forecast reports a probability against) |
| `reserve_operator_hours_per_week` | number | none | `0 <= x <= 9007199254740991` | Operator hours set aside for this project |
| `reserve_tokens_per_week` | integer | none | `0 <= x <= 9007199254740991` | Tokens set aside for this project |

The priority rule (planned, #744; this change only validates the value):
lanes go to the lowest priority number first, and
ties go to the project holding fewer lanes, then by name.
Tokens and operator hours beyond the reservations are shared by weight 1/priority.
The default priority is 5.

Types. `integer` is a TOML integer: `3.0` and `true` are wrong types. `number`
is a TOML integer or float, never a boolean. `date` is a TOML local date or a
string; a date-time, a time or any other type is `wrong type: expected date`,
and a string is a calendar date only when it is exactly `YYYY-MM-DD` in ASCII
digits and names a real day. Every numeric key has a finite upper bound; where
the domain gives none it is 2^53 − 1 = 9007199254740991 (JavaScript's
`Number.MAX_SAFE_INTEGER`). A non-finite number (`nan`, `inf`, `-inf`) is out
of range. `capacity` or `project.<name>.capacity` present but not a table is
`wrong type: expected table`.

### The reader

`scripts/capacity.sh` takes no arguments (`-h` or `--help` prints
`usage: capacity.sh`). It checks the config the way doctor does, takes the
projects from `config_list_projects`, and runs `scripts/lib/capacity.py`, which
owns every rule, the document and the text.

| Exit | Meaning | stdout |
|---|---|---|
| 0 | resolved | the capacity JSON |
| 2 | any argument | empty |
| 3 | invalid values; one line per violation on stderr | empty |
| 4 | config missing, unreadable or not valid TOML | empty |

Exit 1 is never chosen: it is what a crash looks like. On exit 4 stderr is one of:

```
capacity: config not readable: <path>
capacity: config is not valid TOML: <path>
capacity: cannot list projects: <path>
```

Every line on stderr starts `capacity: `: violations first, then warnings. They
are on stderr so a caller's `doc="$(capacity.sh)"` cannot swallow them.

The JSON (UTF-8, LF) has six top-level fields in both forms:

- `capacity_schema`: `"1.0"`.
- `declared`: whether `[capacity]` is present.
- `token_unit`: `weighted_input_token_equivalents`.
- `shared`: the seven shared keys, each `{"value": <v>, "source": "config" | "default"}`; `null` when not declared.
- `effective_tokens_per_week`: `{"value": <n>, "binding": <b>}`, where `value` is `min(tokens_per_week, tokens_per_window * windows_per_week)`, unrounded, and `binding` is `tokens_per_week` or `tokens_per_window_x_windows_per_week` (a tie is `tokens_per_week`); `null` when not declared.
- `projects`: every project in config order, each with `name` and the six project keys in the same `{"value", "source"}` form. Defaults: `priority` 5, `paused` false, the rest `null`. `deadline.value` is `YYYY-MM-DD` for both spellings.

Declared, for the example tables above (one project, layout abridged):

```json
{
  "capacity_schema": "1.0",
  "declared": true,
  "token_unit": "weighted_input_token_equivalents",
  "shared": {
    "operator_hours_per_week": {"value": 20, "source": "config"},
    "lane_hours_per_week": {"value": 40, "source": "config"},
    "max_lanes": {"value": 3, "source": "config"},
    "tokens_per_week": {"value": 500000000, "source": "config"},
    "tokens_per_window": {"value": 60000000, "source": "config"},
    "windows_per_week": {"value": 10, "source": "config"},
    "operator_hours_per_agent_hour": {"value": 0.25, "source": "config"}
  },
  "effective_tokens_per_week": {"value": 500000000, "binding": "tokens_per_week"},
  "projects": [
    {
      "name": "myproj",
      "priority": {"value": 5, "source": "config"},
      "max_lanes": {"value": 2, "source": "config"},
      "paused": {"value": false, "source": "config"},
      "deadline": {"value": "2026-12-31", "source": "config"},
      "reserve_operator_hours_per_week": {"value": 4, "source": "config"},
      "reserve_tokens_per_week": {"value": 100000000, "source": "config"}
    }
  ]
}
```

Not declared (no `[capacity]` table):

```json
{
  "capacity_schema": "1.0",
  "declared": false,
  "token_unit": "weighted_input_token_equivalents",
  "shared": null,
  "effective_tokens_per_week": null,
  "projects": [
    {
      "name": "myproj",
      "priority": {"value": 5, "source": "default"},
      "max_lanes": {"value": null, "source": "default"},
      "paused": {"value": false, "source": "default"},
      "deadline": {"value": null, "source": "default"},
      "reserve_operator_hours_per_week": {"value": null, "source": "default"},
      "reserve_tokens_per_week": {"value": null, "source": "default"}
    }
  ]
}
```

`capacity_schema` follows the version rules of
[portfolio-schema.md](portfolio-schema.md#version-rules) as written. A new
optional field bumps the minor. A renamed or removed field, a type change, a
new enum value (`binding`, `source`), a changed bound, or an added or changed
rule string bumps the major.

### Violations

Each violation is one stderr line, `capacity: <where>: <rule>`, and the exit is 3.
#957 reproduces these rule strings in devagent's JavaScript engine, so they are a
contract: change one only with a major bump.

| Violation | `<where>` | `<rule>` |
|---|---|---|
| a required key is absent | the key's path | `missing required key` |
| a value has the wrong type | the key's path | `wrong type: expected <type>` (`number`, `integer`, `boolean`, `date` or `table`) |
| a number is outside its range | the key's path | `out of range: <range>` (the five ranges above) |
| a `deadline` string is not a real calendar date | the key's path | `not a calendar date` |
| a project's `max_lanes` is above `capacity.max_lanes` (paused or not) | the key's path | `exceeds capacity.max_lanes` |
| reserved operator hours over unpaused projects exceed the shared value | `pool` | `reserve_operator_hours_per_week sum exceeds capacity.operator_hours_per_week` |
| reserved tokens over unpaused projects exceed the effective budget | `pool` | `reserve_tokens_per_week sum exceeds the effective weekly token budget` |
| a project capacity table with no `[capacity]` table | `project.<name>.capacity` | `[capacity] table missing` |

Every `<rule>` string, in full:

```
missing required key
wrong type: expected number
wrong type: expected integer
wrong type: expected boolean
wrong type: expected date
wrong type: expected table
out of range: 0 < x <= 168
out of range: 1 <= x <= 9007199254740991
out of range: 0 < x <= 9007199254740991
out of range: 0 < x <= 33.6
out of range: 0 <= x <= 9007199254740991
not a calendar date
exceeds capacity.max_lanes
reserve_operator_hours_per_week sum exceeds capacity.operator_hours_per_week
reserve_tokens_per_week sum exceeds the effective weekly token budget
[capacity] table missing
```

`<where>` is the dotted path. A part that matches `[A-Za-z0-9_-]+` in full is
written bare; any other part is written as a JSON string, so
`project."my proj".capacity.priority` and `capacity."max_lane\n"` (a key holding
a newline stays on one line).

Order: `capacity` (not a table), else the seven shared keys in the table order
above; then each project in config order: its capacity (not a table), else
`[capacity] table missing` when the shared table is absent, then its six keys in
the table order above; then `pool`, the hours rule before the token rule.

Suppression: one line per key, the first of missing, wrong type, then out of
range, not a calendar date or exceeds. `exceeds capacity.max_lanes` is checked
only when both lane caps are valid. A `pool` rule runs only when every value it
reads is valid: the hours rule reads `capacity.operator_hours_per_week`, every
project's `paused` and each unpaused project's
`reserve_operator_hours_per_week`; the token rule reads the three token keys,
every project's `paused` and each unpaused project's `reserve_tokens_per_week`.
An absent optional value is valid. With `[capacity]` absent or not a table there
is no `exceeds` line and no `pool` line; the key-local rules still run. A
project whose capacity is not a table counts as unpaused with no reservations.

Sums: each unpaused project's reservation is added with `+`, left to right in
config order, from the integer 0 (never `sum()`, `math.fsum` or decimal). The
hours sum is refused only when it exceeds `capacity.operator_hours_per_week + 1e-9`:
the fixed tolerance absorbs binary rounding, so an exactly-full declaration
(4.4 + 11.8 + 3.8 against 20) passes in any order. The token sum is an exact
integer and is refused when strictly above the effective budget.

### Warnings

Warnings follow the violations, on exit 0 and on exit 3, and never change the exit:

```
capacity: warning: <path of the key>: unknown key (ignored)
capacity: warning: project.<name>: only key is capacity (misspelled project name?)
```

Unknown keys in `[capacity]` come first, in file order; then, per project, the
capacity-only line, then its unknown keys.

### Doctor

A bare `/devagent:doctor` (every project) runs the reader after the per-project
checks and prints a `[capacity]` header, then:

- exit 0: `OK   capacity: not declared (forecasting off)`, or the summary line
  `OK   capacity: <H> operator h/week, pool of <L> lanes, <T> weighted tokens/week (<binding>)`;
- exit 3: one `FAIL` row per violation line;
- each warning: a `WARN capacity: <rest>` row, which adds no error;
- anything else: `FAIL capacity: reader failed (exit <N>)` with the reader's
  last stderr line, so a fault never reads as "not declared". An exit 0 with no
  capacity JSON is `reader failed (exit 0: no capacity document)`, and an exit 3
  with no violation line is `reader failed (exit 3: no violation lines)`.

`doctor <project>` does not run it.

## The backend verb contract

Backends are plain scripts; four issue backends ship out of the box
(`github`, `gitlab`, `jira`, and a `custom` stub), and code backends for
GitHub and GitLab plus a `custom` stub (JIRA hosts issues only). Every
**issue backend** implements `fetch`, `create`, `transition`, `state` and
`comment-list`, and may implement `state-list`, `issue-list`,
`state-exists`, `state-class`, `events`, `comment-records` and `whoami`:

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
| `state-class` | `<repo> <num>` | one `<class>` TAB `<reason>` line (optional) |
| `events` | `<repo> <num>`, or `--kinds <repo>` | one six-field record per change, or one `<kind>` TAB `<coverage>` line per kind (optional) |
| `comment-records` | `<repo> <num>` | one six-field record per comment (optional) |
| `whoami` | `<repo>` | the credential's account id on the repo's host (optional) |

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
uses local checklists. `state-class` is the same class for one issue, plus
its state reason (e.g. `completed` or `not planned`; `-` for none); the merge step reads it
to decide whether a dependency is done. `issue-list` is what `wbs init --from-tracker`
reads to build a new `WBS.md` from the tracker history, and what
`wbs init --merge` reads to add the issues an existing one lacks; without
it those commands stop. `events`, `comment-records` and `whoami` are
read-only records of who changed an issue and when, its comments with
stable ids, and the configured credential's own account; GitHub implements
them, GitLab and JIRA answer exit 2 until #900, and nothing reads them yet.
See spec §9.1 and §9.3.1.

Every **code backend** implements `push-branch`, `create-mr`, `mr-state`,
`mr-comments` and `merge-mr`, and may implement `issue-mrs`, `mr-checks`
and `mr-view`:

| Verb | Args | Output / exit |
|------|------|---------------|
| `push-branch` | `<remote> <branch>` | exit 0 |
| `create-mr` | `<repo> <title> <body-file> <head> <base> [--draft]` | MR URL to stdout |
| `mr-state` | `<mr-url>` | `open\|merged\|closed\|draft` |
| `mr-comments` | `<mr-url>` | markdown to stdout |
| `merge-mr` | `<mr-url> [--method squash\|merge\|rebase] [--match-head-commit <sha>] [--subject <s>] [--body <b>]`, or `<mr-url> --disable-auto` | exit 0 |
| `issue-mrs` | `<repo> <id>...` | `issue` and `mr` lines per issue (optional) |
| `mr-checks` | `<mr-url>` | `state`, `head` and one line per CI check (optional) |
| `mr-view` | `<mr-url>` | the `mr-checks` lines plus draft, base, mergeability, auto-merge, queue, title, closing issues, trailers and commit counts (optional) |

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

`mr-view` is what step 20 (`/devagent:mergemr`) reads to decide whether to
merge, and `merge-mr --match-head-commit` is how it merges only the head
preship verified (or that `preship-verified-head.sh forward` re-recorded,
#1125). GitHub implements both; on any other forge the step reads `mr-state`
and waits for a merge done by hand.

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

A global `[archive]` table (#731) turns on the durable transcript archive:
`transcripts_dir` (absolute, required), `host_id` (the machine's partition,
default the hostname with `-wsl` under WSL) and `exclude` (cwd-slug globs).
`scripts/archive-transcripts.sh` copies `~/.claude/projects` into
`<transcripts_dir>/<host_id>/` append-only, cleanup runs it when
`transcripts_dir` is set, and `cost-report.sh --archive <transcripts_dir>`
reads it. The archive holds everything a session read, so a `transcripts_dir`
inside a git work tree or inside `~/.claude/projects` is refused; keep it on
private storage.

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
