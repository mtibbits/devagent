---
description: Build the per-issue actuals document (tokens, time, sessions and dated milestones per issue) that the portfolio reads
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[--archive DIR] [--project P] [--out PATH | --stdout] [--if-stale]"
---

# /devagent:actuals

**Usage:** `/devagent:actuals [--archive DIR] [--project P] [--out PATH | --stdout] [--if-stale]`

Builds one JSON document (#735) that joins, per `(project, issue)`, what
`cost-report.sh` charges (tokens, agent and operator time, the sessions they
came from) with the dated events `milestones.sh` reports. By default it writes
`<devagent_home>/actuals.json` (`~/.claude/devagent/actuals.json`), which
`/devagent:portfolio` copies into each issue's `actuals` slot, each project's
`actuals` field and the document's top-level `actuals`
(`docs/portfolio-schema.md`, "Actuals"). Estimates (#736) and forecasts (#742)
read the same file, so nothing parses report text.

## Run the script

Run it with the longest Bash tool timeout (600000 ms): it reads every
transcript and runs one `milestones.sh <project> --all --json` per project.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/actuals.sh" $ARGUMENTS
```

The written form prints one line, `actuals: wrote <path> (<i> issues, <p>
projects, <m> missing sources)`; relay it. With `--stdout`, redirect stdout
to a new temporary file (`>"$(mktemp)"`, or a file in your scratch directory)
and do not page the document into the conversation: it lists every issue's
sessions and milestones. Name the file and offer to read one issue's row.
Relay any `actuals: WARNING:` line (a project's milestones run failed; its
rows are missing and the document says so). Exits `1` and `2`: print stderr
and stop.

## Options

- **`--archive DIR`** reads only that `scripts/archive-transcripts.sh` archive
  (`<DIR>/<host>/<cwd-slug>/<session>.jsonl.gz`), every host in it, and no
  live transcript. Without it: every live transcript dir under
  `${CLAUDE_CONFIG_DIR:-~/.claude}/projects`, plus `[archive].transcripts_dir`
  when it is configured and accepted. One API call is counted once however
  many copies are read; this host's own archive partition is skipped for a
  cwd dir whose files are all still live.
- **`--project P`** keeps P's issue rows and overhead and drops the
  unassigned rows. It needs `--out` or `--stdout`: the default file stays the
  all-projects document the portfolio reads (the portfolio treats a
  one-project document as unusable).
- **`--out PATH`** writes there instead. Refused, exit 2 and nothing written:
  a path under any configured project's `devdoc_dir`, `source_dir` or
  worktree root (cleanup commits and pushes devdoc dirs), and a path inside a
  git work tree.
- **`--stdout`** prints the document instead of writing it.
- **`--if-stale`** is cleanup's call: it does nothing (exit 0, no output, no
  milestones call) while `<devagent_home>/actuals.json` is a usable document
  younger than `[archive].actuals_max_age_hours` (default 24), and rebuilds it
  otherwise: missing, unreadable, not an actuals document, a one-project
  document, or dated in the future. It takes no `--out`, `--stdout` or
  `--project`.

Flags take `--flag value` or `--flag=value`. An empty value, an unknown flag
or a positional argument is a usage error.

## The document

Keys are sorted at every level and rows are sorted (issues by project and
issue, projects by project, unassigned by cwd, sources by source, project and
detail); sessions and milestones keep their producers' order. Two runs over
unchanged inputs differ only in `generated_at`. UTF-8, LF, 2-space indent.

```json
{
  "actuals_version": "1.0",
  "generated_at": "2026-11-23T06:20:00Z",
  "inputs": {"archive": "/home/me/private/claude-transcripts", "hosts": ["laptop", "local"], "project": null},
  "issues": [
    {"project": "alpha", "issue": "Issue-4", "actuals": {
      "milestones": [{"at": "2026-11-01T14:02:11Z", "event": "opened", "source": "https://github.com/acme/alpha/issues/4"}],
      "sessions": [{"cwd_slug": "-work-alpha", "host": "laptop", "session": "0b7c2f1e-…"}],
      "time": {"agent_busy_s": 5400.0, "agent_wall_s": 4980.5, "fallback_events": 0,
               "operator_events": 12, "operator_s": 610.0, "returns_after_absence": 2},
      "tokens": {"main": 1700000.0, "subagents": 329120.0, "total": 2029120.0,
                 "raw": [{"cache_read": 15800000, "cache_write_1h": 120000, "cache_write_5m": 0,
                          "input": 3120, "model": "claude-opus-5-5", "output": 41200}]}}}
  ],
  "projects": [{"project": "alpha", "actuals": {"overhead": {
    "rules": {"cwd": 14, "hint": 3}, "sessions": ["…"], "tokens": {"…": "…"}}}}],
  "unassigned": [{"cwd": "/home/me", "sessions": ["…"], "tokens": {"…": "…"}}],
  "sources": [{"source": "archive", "project": null, "status": "ok", "detail": "/home/me/private/claude-transcripts"}],
  "time_rule": {"attention_cap_s": 900.0, "idle_gap_s": 300.0, "tool_gap_s": 3600.0}
}
```

- **`tokens`** are cost-report's input-token equivalents (input 1, cache read
  0.1, cache write 1.25 for 5m or 2 for 1h, output 5): `total` = `main` +
  `subagents` is the headline. **`raw`** holds the unweighted counts per
  `message.model`, main and subagent calls together; weighted, they sum to
  `total` to rounding. A call with no model is `(unknown)`; a model whose
  counts are all zero has no entry.
- **`time`** is cost-report's `--time` figures in seconds, under `time_rule`.
- **`sessions`** name where each figure came from: the archive host (`local`
  for a live dir), the transcript dir and the session id.
- **`milestones`** are milestones.sh's rows, `at`, `event` and `source` only,
  in its order.

Empty forms. An issue with milestones but no transcript calls has
`"sessions": [], "time": null, "tokens": null`. An issue with calls but no
milestones has `"milestones": []`. **`"milestones": null` means the project's
milestones run failed outright** (it exited non-zero or printed no whole JSON
Lines): not known, which is not the same as no events. A run that completed
with one of its own sources missing (a tracker outage: a header `missing`
entry) still gives arrays of the events it did read, checklist rows only for
example; the `sources` rows say which source was missing. A project with no
overhead has `"overhead": null`. With no transcript and no milestones at all,
the document still writes, with empty lists and `missing` source rows.

**Keys.** Rows are keyed `(project, issue)` as written. Calls cost-report
charges to `(no project)/(no issue)` are not an issue row: they appear once,
as a project's `overhead` (placed by a session hint or the working directory)
or as an `unassigned` row per working directory. A pair whose project is
`(no project)`, or a project that is not configured, stays under that name;
the portfolio has no slot for it and ignores the row. Two known gaps: a fork
issue's milestones are keyed `Issue-Fork-N` while cost-report charges its
calls to the `Issue-N` its dispatch header names, so the two land in separate
rows (fork-issue keying in cost-report is out of scope); and Jira-style keys
(`ABC-123`) are kept as each producer writes them, with no cross-producer
reconciliation.

## Sources

`sources` has one row per source consulted, `ok` or `missing`, with a detail:

| `source` | Rows |
|---|---|
| `archive` | The archive read (`ok`, its dir) or why none was (`missing`: no `[archive].transcripts_dir`, a refused `[archive]` table, an unreadable dir). |
| `live` | The live transcript root, without `--archive` only. |
| `transcript` | One `missing` row per transcript file skipped or truncated, and per unreadable archive host dir; the rest is still read. |
| `milestones` | One per project: `ok`, or `missing` as `exit <N>: <last stderr line>` (or `output is not whole JSON Lines`). Each stderr line of a successful run adds an `ok` row with that line. |
| `tracker`, `fork tracker`, `mr`, `fork mr` | milestones.sh's own `missing` header entries, detail verbatim, per project. |

A missing source is a row, never a failure.

## Exit status

| Exit | Meaning |
|---|---|
| `0` | Written, printed, or skipped as fresh (`--if-stale`). |
| `1` | The config is missing or invalid, or `--project` names an unknown project. |
| `2` | A usage error, `--archive` not a directory, a refused or unwritable output, or a refused `[archive].actuals_max_age_hours`. Nothing is written. |
| `4` | `--if-stale` only: written, but a source the replaced file had is now missing (a tracker outage, say). One `actuals: WARNING:` line names them; cleanup reports it at the next close. |

## Privacy

The document lists project names, session ids, transcript dir names and
working directories. It is written owner-only (file `0600`, new dirs `0700`),
atomically, and never under a project's dirs or inside a git work tree. Do
not commit it or paste it into an issue; quote figures instead.

## Cost and the cleanup rebuild

A build reads every transcript once (one cost-report pass, time and overhead
included) and runs one `milestones.sh --all --json` per project, up to 6 at
once, each making one tracker `issue-list` call per configured source and its
MR lookups. Measured at #735 on one host with 14 projects: the transcript pass
took about 10 s over 895 MB in 24 dirs, and a whole build about 64 s, bounded
by the largest project's own milestones run (devagent, about 10,000 rows).

Cleanup (step 24) checks the file's age inside its `[archive]` gate, after
the archive run, and when it is stale starts `actuals.sh --if-stale` in the
background without waiting (`commands/cleanup.md`, "Actuals rebuild"); a host
without an `[archive]` table builds actuals on demand only.
`[archive].actuals_max_age_hours` (`0 < x <= 168`, default 24) sets the age;
168 is the portfolio's 7-day stale line. **A plugin older than #735 refuses an
`[archive]` table that sets this key** (it stops archiving, with a warning):
set it only after every install that reads the config is upgraded.

## Versions

`actuals_version` is the file's own MAJOR.MINOR, under the version rules of
`docs/portfolio-schema.md`. The portfolio reads minors up to its own (`1.0`);
a newer minor, or another major, makes the file unusable until the plugin is
upgraded. A new `actuals_version` minor ships with a portfolio schema minor.
