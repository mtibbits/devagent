---
name: core-capture
description: Decide whether a captured idea is one issue, one epic, or several epics; pick a subtype; emit a structured handoff for capture.sh. Triggers when /devagent:capture is invoked.
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
   - Bug: `fix conv kernel NaN at simd-1 length`
   - Feature: `add CSV export to volk_profile`
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

## Verification

This skill is verified by `tests/skill_devagent_capture.bats`, which
checks the SKILL.md file for the required output-format block. Live
model execution is not part of CI.
