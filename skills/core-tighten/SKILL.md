---
name: core-tighten
description: Use when running step 5 of the devAgent workflow to perform the final pre-implementation review of a pruned plan, locking down task ordering, file paths, and test plan
when-to-use: After /devagent:prune has produced a minimal plan and before /devagent:branch. Run as part of /devagent:tighten.
---

# devagent-tighten

Step 5 of the devAgent 21-step workflow. The last review pass on
`<issue-dir>/imPlan.md` before any code is written. Locks down the
plan so the implementing engineer (often a fresh subagent in a fresh
session) needs zero context-discovery to start.

## Overview

After prune, the plan is minimal. Tighten makes it executable:
- Tasks are in dependency order, smallest first.
- Each task names the file path(s) it touches with absolute paths.
- Each task has a one-line test plan (or explicit "no test, because…").
- The plan has a "Definition of done" matching the Scope evaluation's
  success criteria.

## Inputs

- `$ISSUE_DIR`, `$NOTE`.
- Reads: full `<issue-dir>/imPlan.md`, scope evaluation, any
  `<issue-dir>/issue.md` clarifications.
- Writes: modifies `<issue-dir>/imPlan.md` in place; may append a
  `## Definition of done` section.

## Checklist

1. **Task ordering.** Are tasks listed in dependency order? Smallest
   first? Reorder if not. Number tasks 1..N after reordering.
2. **Task dependencies.** Mark explicit cross-references with
   `(depends on task N)` notation. If a cycle appears, halt.
3. **File paths.** Every task names the absolute file path(s) it
   modifies or creates. "Update the kernel" → "Update
   `/abs/path/to/foo_kernel.c:142-160`".
4. **Test plan.** Every task has a one-line test plan or an explicit
   "no test, because…" justification. Halt if any task lacks both.
5. **Definition of done.** Append `## Definition of done` mapping
   each Scope > Success criterion to the task(s) that fulfill it.
6. **Re-read silently.** A fresh subagent should be able to start
   task 1 with zero clarifying questions. If you would ask one,
   tighten the plan until you wouldn't.

## Halt and ask if

- A dependency cycle exists between tasks.
- A task cannot have a test plan AND lacks a "no test, because…"
  justification.
- Success criteria from the Scope section are not fulfilled by any
  task.
- The plan needs more than one round of restructuring — surface that
  the plan should arguably go back to `/devagent:draft` rather than
  be patched here.

## Skipping policy

Never auto-skip. If the plan is already tight (ordering, paths, tests
all present), surface "plan is already tight; mark step `[-]`
skipped?" for operator confirmation.

## Logging

```bash
scripts/checklist-log.sh "$ISSUE_DIR" tighten \
  "Tightened; N tasks, M depend-edges, Definition of done has S criteria; note: $NOTE"
```

## Templates referenced

- `${CLAUDE_PLUGIN_ROOT}/templates/imPlan_template.md` (canonical structure including
  Definition of done section).

## Completion handoff

After marking the step `[x]` (or `[-]` if skipped) and logging:

**STOP.** Do not invoke any other `/devagent:*` command on your own.
Return control to the operator with a one-line summary of what was
written and which step is next on the checklist.

The only exception: if you were invoked under a `/devagent:next
--auto` or `--through` chain (recognizable because the preceding
turn's tool output contained a `CHAIN: /devagent:next ...` line),
then after stopping, invoke that exact CHAIN: command verbatim to
continue the chain.

If the operator typed a one-off `/devagent:<name>` directly (no
preceding CHAIN: line), DO NOT chain. Pause and wait for explicit
instruction even if your internal TODO list still has steps after
this one — the operator's last explicit instruction is the
authoritative scope.
