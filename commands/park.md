---
description: Park the active issue (or a named issue), marking it [P]
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "<project> [issue-id] [--reason <text>]"
---

# /devagent:park

**Usage:** `/devagent:park <project> [issue-id] [--reason "<text>"]`

Parks the active issue (or `issue-id` if given), marking its current step
`[P]` and recording it in the `[parked]` table. Clears `active_issue` from
state when the parked issue was the active one.

`--reason "waiting on legal"` appends the reason to the park's checklist log
entry; quote it, since a third bare word is a usage error (exit 2). The log
entry also records the row that was marked and its earlier mark, as
`park: issue parked (row 5 improve was [~]): waiting on legal`. An issue held
on an operator question (a `Kind: question` STUCK) keeps its `[?]` row: no
row is marked `[P]`.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/park.sh" $ARGUMENTS
```
