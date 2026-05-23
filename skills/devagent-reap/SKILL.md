---
name: devagent-reap
description: Classify harvested follow-up candidates (subtype + keep/discard) before they become drafts. Triggers when /devagent:reap surfaces ambiguous candidates.
---

# devagent-reap

## When invoked

`/devagent:reap` runs the mechanical scan first. You are invoked only
when the operator wants a judgment pass on ambiguous candidates before
drafts are written.

## Inputs

A list of candidates, each:

- `source` — e.g., `Issue-101/STUCK`
- `body`   — the harvested text

## For each candidate

1. **Classify subtype** if obviously wrong from the heuristic:
   - The script defaults `STUCK` → `chore` and `imPlan-*` → `feature`.
     Override when the content clearly indicates `bug`, `docs`, or
     `perf`.
2. **Keep or discard:**
   - **Keep** if this would be a sensible standalone issue.
   - **Discard** if the item is a one-line working note with no
     external value, or if it's already covered by an active issue.
3. **Suggest a better title** if the heuristic title (everything up
   to the first period) is awkward.

## Output

Emit a YAML-ish block parsed by the slash command:

```
DECISIONS:
- source: Issue-101/STUCK
  action: keep            # keep | discard
  subtype: chore          # only required when overriding
  title:   <better title> # only required when overriding
- source: Issue-100/imPlan-potentialFutureEnhancements.md line 2
  action: discard
  reason: already covered by Issue-200
```

## Anti-patterns

- Do not author the issue body. The script fills the template.
- Do not edit the source file (e.g., the original
  imPlan-potentialFutureEnhancements.md). Reaping is read-only on
  sources.
- Do not discard a STUCK candidate just because it's painful to read.
  STUCK files often surface the highest-value missing issues.

## Verification

Verified via fixture-grep against SKILL.md contract structure.
