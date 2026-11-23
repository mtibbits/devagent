---
name: core-scaffold
description: Bin an epic capture into child issue draft entries (subtype + title + summary). Triggers when /devagent:scaffold is invoked.
user-invocable: false
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

## Required CI checks (#1097)

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/required-checks.sh" "$DEVAGENT_PROJECT"`.
Exit 0 with no output: the section does not apply. **A non-zero exit: stop and
report its stderr; never read it as "does not apply"** (devagent Issue-713).
Otherwise, for a child whose behaviour differs under Git Bash (drive-letter
paths, MSYS path rewriting, a native Windows python3, CRLF line endings, no POSIX
file modes), its `summary` asks for this criterion, `<check name>` taken from the
printed list:
`` `tests/<file>.bats` carries the `gitbash` tag, `<test name>` has no Git Bash skip, and `<check name>` is green at the merged head ``.

## Anti-patterns

- Do not author the full issue body. The slash command fills the
  template; you only choose subtype + title + summary.
- Do not silently produce 20+ children. Cap at 9; if more, return:
  `OVERFLOW: this epic is N epics, suggest re-capturing as: ...`

## Verification

Verified via fixture-grep against SKILL.md contract structure.
