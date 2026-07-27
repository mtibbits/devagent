---
description: Set the glyph on a specific checklist step.
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
argument-hint: "<issue-dir> <step-num|step-name> <glyph> [expected-name]"
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-mark.sh" [--by-name] <issue-dir> <step-num|step-name> <glyph> [expected-name]`
where glyph is one of ' ', x, -, !, ~, ?, P. Forward all arguments verbatim.

Prefer `--by-name <step-name>` — numbers are positions and differ between a
pre-#558 checklist and a current one. When marking by NUMBER anyway, pass the
step's name as the optional 4th argument: it arms `checklist_mark`'s wrong-row
guard, so a number that resolves to a different step's row fails loud instead
of silently flipping it (#558 r3 m3/r4 m1).
