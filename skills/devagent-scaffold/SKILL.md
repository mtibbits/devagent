---
name: devagent-scaffold
description: Bin an epic capture into child issue draft entries (subtype + title + summary). Triggers when /devagent:scaffold is invoked.
---

# devagent-scaffold

You are decomposing an epic into the smallest set of child issues that
can each be implemented, reviewed, and shipped independently.

## Inputs

- `epic_draft` — the markdown body of `Captures/<slug>/draft.md`.

## Decomposition rules

1. **Each child must be shippable alone.** No child depends on a
   sibling for correctness. If A truly depends on B, write the
   dependency explicitly in A's summary and order them so B is
   numbered lower than A.

2. **Each child has one subtype.** Don't bundle "fix X and also add Y"
   into one child.

3. **5–9 children is the sweet spot.** Fewer means the epic was an
   issue. More means it was several epics; recommend re-running
   `/devagent:capture` on the outliers.

4. **Order matters.** Number children so the natural execution order
   is N=01, 02, 03... Foundational/blocking work first, polish last.

## Output format (REQUIRED)

Emit exactly:

```
CHILDREN:
- subtype: <bug|feature|docs|perf|chore>
  title:   <imperative title>
  summary: <one paragraph>
- subtype: ...
  title:   ...
  summary: ...
```

(YAML-ish; the slash command parses by indent.)

## Anti-patterns

- Do not author the full issue body. The slash command fills the
  template; you only choose subtype + title + summary.
- Do not silently produce 20+ children. Cap at 9; if more, return:
  `OVERFLOW: this epic is N epics, suggest re-capturing as: ...`

## Verification

Verified via fixture-grep against SKILL.md contract structure.
