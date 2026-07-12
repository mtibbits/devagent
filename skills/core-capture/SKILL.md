---
name: core-capture
description: Decide whether a captured idea is one issue, one epic, or several epics; pick a subtype; emit a structured handoff for capture.sh. Triggers when /devagent:capture is invoked.
user-invocable: false
---

# devagent-capture

You are turning a free-form capture into structured input for
`scripts/capture/capture.sh`.

## Inputs

- `text` — the free-form capture from the operator.
- `forced_type` — one of `issue`, `epic`, or unset.

## Decision procedure

1. **If `forced_type` is set, use it.** Do not second-guess.
2. **Otherwise, classify:**
   - **issue** if the capture describes a single bounded change
     (one bug, one feature, one doc fix, one perf target, one chore)
     that one person can finish in days.
   - **epic** if the capture describes a multi-week effort with
     several independent deliverables.
   - **multi-epic** if the capture describes work that spans
     multiple independent epics (e.g., "rewrite build system AND
     add wheels pipeline AND modernize docs").

3. **If issue, pick a subtype:**
   - `bug`: existing behavior is wrong
   - `feature`: new behavior
   - `docs`: documentation only
   - `perf`: faster/smaller/leaner; no behavior change
   - `chore`: tooling, CI, infra; not user-visible

4. **Pick a title.** Imperative mood, ≤60 characters after slugification.
   - Bug: `fix parser NaN at length-1 input`
   - Feature: `add CSV export to the profiler`
   - Epic: `Performance overhaul`

## Output format (REQUIRED)

You MUST emit exactly this block, then stop:

```
TYPE: <issue|epic|multi-epic>
SUBTYPE: <bug|feature|docs|perf|chore|->     # `-` when type is epic / multi-epic
TITLE: <title>
RECOMMENDATION: <one short paragraph; empty if straightforward>
CHILDREN:
- <child title 1>
- <child title 2>
(omit CHILDREN block if not multi-epic)
```

The slash command parses this block and calls `capture.sh` per row.

## Anti-patterns

- Do not author the issue body. `capture.sh` fills the template.
- Do not invent a project name. Use whatever `DEVAGENT_PROJECT` is.
- Do not file the issue. Filing is `/devagent:file`.
- Do not silently expand a single capture into many. If you see
  multi-epic, surface the recommendation and let the operator decide.

## Draft lifecycle — archive on land

`Captures/<slug>/` is a *live* backlog: its top level should signal only
candidates that still need work. Once a draft's content has LANDED — the
issue was filed and its PR merged, or the idea was absorbed into another
change — retire the draft so the directory keeps signalling accurately:

- Move the draft directory into `Captures/archive/` (never delete it — the
  record is the point).
- Append a one-line disposition to `Captures/archive/LEDGER.md`:
  `<slug> — landed as <PR/issue/mechanism> (<date>)`.
- A draft whose content did NOT land stays at the top level; if it is stale
  but unresolved, ledger it `OPEN — re-file candidate` rather than archiving.
- A capture filed under the wrong project belongs in that project's
  `Captures/` — relocate it (ledger the move target).

This keeps `grep --captures` and human/audit browsing reading a clean live
corpus instead of a mix of pending and already-shipped ideas.

## Verification

This skill is verified by `tests/skill_core_capture.bats`, which
checks the SKILL.md file for the required output-format block. Live
model execution is not part of CI.
