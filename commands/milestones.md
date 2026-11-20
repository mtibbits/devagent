---
description: Print each issue's dated milestones (opened, MRs, steps, parks, closed) and spans from the tracker, linked MRs and checklists (read-only)
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[project] [--issue <issue-id> | --all] [--json]"
---

# /devagent:milestones

**Usage:** `/devagent:milestones [project] [--issue <issue-id> | --all] [--json]`

Prints one row per dated event of each issue in scope (#734), read from three
places: the tracker's `issue-list`, the code host's `issue-mrs` and the
issue's local `checklist.md` log. It then prints each issue's spans. The
command is read-only: it writes no `WBS.md`, devdoc file, state or tracker.
Spec §13.5 is the contract.

## Run the script

Run it with the longest Bash tool timeout (600000 ms): the default scope can
make many tracker and forge calls (devagent's default scope was about 15
GitHub GraphQL batches at #734's draft), and a pre-empted run prints nothing.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/milestones.sh" $ARGUMENTS
```

Print stdout verbatim. Exit `0`: the report printed; any
`milestones: WARNING:` line on stderr names a source that failed, whose rows
are missing (relay it). Exit `2`: a usage error, or `--issue` names no
configured source and no checklist dir; print stderr and stop. Exits `6`–`11`:
a trust refusal; print stderr verbatim and stop. Exit `1`: an unknown project,
an unset or missing `devdoc_dir`, or a library failure; print stderr.

## Scope

- **Default:** every issue with a `<devdoc>/<issue>/checklist.md`, plus every
  issue the tracker reports open.
- **`--all`:** every tracker issue (open and closed), plus every checklist
  issue.
- **`--issue <issue-id>`:** one issue. The id is one token of letters,
  digits, `_`, `.` and `-`, led by a letter or digit, and must name a
  configured issue source (by its `dir_prefix`) or a devdoc dir.

A checklist dir and a tracker issue that name the same issue are one issue
(on Jira with the key prefix `PROJ`, `Issue-PROJ-12` and `PROJ-12` are
`Issue-12`). A dir that names no
configured source keeps its name and has checklist rows only.

## Events

| Event | From | `at` | Detail column |
|---|---|---|---|
| `opened` | tracker `created` | date | `-` |
| `closed` | tracker `closed` | date | the close class (`done`, `not_planned`, …) |
| `mr_opened` | `issue-mrs` per linked MR | UTC timestamp | `<ref> base=<base branch>` |
| `mr_merged` | `issue-mrs`, when merged | UTC timestamp | `<ref> base=<base branch>` |
| `step_done` | checklist log, the first line of a step in a revision | log time | `<step> r<N> tz=<tz>` |
| `step_note` | checklist log, a later line of that step in the same revision | log time | `<step> r<N> tz=<tz>` |
| `parked`, `resumed` | checklist log `park:` / `resume:` lines | log time | `r<N> tz=<tz>` |
| `revision_started` | checklist log `revise: revision N started` or a retier `(revision N)` line | log time | `r<N> tz=<tz>` |
| `log` | any other dated log line | log time (a date for a date-only line) | `<name> r<N> tz=<tz>` |

An MR row's source is the MR's URL. A tracker row's source is the issue URL.
A checklist row's source is `<issue-dir>/checklist.md:<line>`.

**`tz: assumed`.** Checklist log lines carry no zone. Each one is given the
offset of its checklist's `Created:` line, so its time can be off in two
ways: a line written on another machine, in another zone, and a line written
after a daylight-saving change on the same machine, which is off by one hour.
A checklist whose `Created:` line has no offset gives `tz: unknown`, read as
UTC. A log line whose date or time is not a real one (a hand-typed
`2026-02-30` or `24:00`) is skipped with one stderr line,
`milestones: WARNING: <issue-dir>/checklist.md:<line>: unreadable time '<…>'; line skipped`.

## Output

Text (the default): the header, a `missing:` line per source that could not
be read, one TAB-separated row per event (`<issue>`, `<at>`, `<event>`, the
detail column, `<source>`), then the spans. An excerpt of
`/devagent:milestones devagent --issue Issue-700` (rows elided between the
lines shown):

```
milestones: devagent scope: issue
Issue-700	2026-10-07	opened	-	https://github.com/mtibbits/devagent/issues/700
Issue-700	2026-10-11T18:14-04:00	step_done	pull r1 tz=assumed	Issue-700/checklist.md:37
Issue-700	2026-10-12	closed	done	https://github.com/mtibbits/devagent/issues/700
Issue-700	2026-10-12T08:11-04:00	step_done	analyze r1 tz=assumed	Issue-700/checklist.md:48
Issue-700	2026-10-12T08:11-04:00	step_note	analyze r1 tz=assumed	Issue-700/checklist.md:49
Issue-700	2026-10-12T13:35:28Z	mr_opened	mtibbits/devagent#723 base=master	https://github.com/mtibbits/devagent/pull/723
Issue-700	2026-10-12T14:07:15Z	mr_merged	mtibbits/devagent#723 base=master	https://github.com/mtibbits/devagent/pull/723
Issue-700	2026-10-15T20:59-04:00	log	reap r1 tz=assumed	Issue-700/checklist.md:59
spans:
Issue-700	opened->merged 5	opened->closed 5	first-step->closed 1	parked 0.0d
```

Rows sort by UTC instant: a date-only `opened`/`closed` row counts as
00:00 UTC, so `closed` lists before that day's steps.

The spans line holds whole UTC calendar days from `opened` to the first
`mr_merged`, from `opened` to `closed` and from the first `step_done` to
`closed` (`-` when either end is absent), and the time spent parked (each
`parked` to the next `resumed`, in days with one decimal; `+open` when the
issue is still parked). With no rows at all, the text form is the header, any
`missing:` lines and `(no rows)`:

```
milestones: devagent scope: default
missing: tracker: github mtibbits/devagent issue-list failed (exit 1: HTTP 502)
(no rows)
```

`--json` prints JSON Lines (UTF-8, LF), with no spans: a header line
`{"kind":"header","project":…,"scope":…,"missing":[{"source":…,"detail":…}]}`,
then one `{"kind":"row","project","issue","event","at","source",…}` line per
row, with the event's own keys (`reason`; `mr`, `base`; `step`, `revision`,
`tz`; `name`). With no rows, it prints the header line only.

## Missing sources

A source that could not be read is named in a `missing:` line, never fatal:
`tracker` and `fork tracker` (the issue sources), `mr` and `fork mr` (the
code host, per issue source). A failed call also prints one stderr line,
`milestones: WARNING: <source>: <detail>; other sources still reported`.
MRs are read only when the issue source's backend is GitHub or GitLab and is
the project's `code_source.backend`; a Jira project gets
`missing: mr: tracker backend jira is not the code backend …; MRs not read`.

## Cost

One `issue-list` call per configured issue source, then one `issue-mrs` call
per source with ids in scope: on GitHub, one GraphQL call per 50 ids plus
one per further page of a truncated timeline; on GitLab, one call per id.
