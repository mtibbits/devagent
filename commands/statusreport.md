---
description: Generate per-project status report, advance pin, optionally commit to devdoc
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[--no-pin] [--window-weeks N]"
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/statusreport.sh" $ARGUMENTS` with the user's arguments.
With `commit_devdoc = true` it commits under the devDoc repository lock (#749),
which can wait its full bound (spec §3.3): give the Bash call the longest tool
timeout (600000 ms).

Flags:
- `--no-pin` — do not advance the pin (read-only report)
- `--window-weeks N` — velocity window override (default 4)

Positional arguments follow the standard devAgent invocation grammar
(§6.1). The report is written to
`<devdoc>/StatusReports/YYYY-MM-DD.md` and committed to the devdoc
repo iff `permissions.commit_devdoc=true`. The commit carries the report file
only, under the devDoc repository lock (#749, spec §3.3). The pin advances
only after the report is committed or needed no commit; a failed commit (lock
held past its bound, a mid-merge repository, a failing `git add`/`git commit`)
exits non-zero with the report file written but uncommitted and the pin
unchanged — fix the named cause and re-run.
