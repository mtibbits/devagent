---
description: Grep across all per-issue artifact files in a project's devdoc.
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
argument-hint: "[--project P] [-i] [-l] [--captures] <pattern>"
---

# /devagent:grep

Searches across all issue directories for a project, hitting only the
canonical artifact files: `issue.md`, `imPlan.md`,
`imPlan-potentialFutureEnhancements.md`, `actualWork.md`, `mr.md`,
`checklist.md`.

## Usage

```
/devagent:grep [--project P] [-i] [-l] [--captures] <pattern>
```

- `-i` — case-insensitive (pass-through to grep)
- `-l` — print filenames only (pass-through to grep)
- `--captures` — also search `<devdoc>/Captures/` (off by default)

## Output

```
<issue-dir>:<file>:<line-num>: <matching-line>
```

## Invocation

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/grep.sh" $ARGUMENTS
```
