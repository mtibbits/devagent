---
description: Generate per-project status report, advance pin, optionally commit to devdoc
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[--no-pin] [--window-weeks N]"
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/statusreport.sh" $ARGUMENTS` with the user's arguments.

Flags:
- `--no-pin` — do not advance the pin (read-only report)
- `--window-weeks N` — velocity window override (default 4)

Positional arguments follow the standard devAgent invocation grammar
(§6.1). The report is written to
`<devdoc>/StatusReports/YYYY-MM-DD.md` and committed to the devdoc
repo iff `permissions.commit_devdoc=true`.
