---
name: core-reap
description: Classify harvested follow-up candidates (subtype + keep/discard) before they become drafts. Triggers when /devagent:reap surfaces ambiguous candidates.
---

# devagent-reap

## When invoked

`/devagent:reap` runs the mechanical scan first. You are invoked only
when the operator wants a judgment pass on ambiguous candidates before
drafts are written.

## Inputs

A list of candidates from `reap.sh --dry-run`, each row
`<hash>\t<subtype>\t<source>\t<title>`:

- `hash`    — the 12-char body hash; the **stable candidate key** (`source` is
  NOT unique — several `### Follow-up` bullets share one source)
- `source`  — e.g., `Issue-101/STUCK` (for your judgment only)
- `body`/`title` — the harvested text

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

Emit a YAML-ish block keyed by `hash`, parsed by the slash command (which
translates it into the `reap.sh --decisions` TSV). Key by `hash`, not `source`:

```
DECISIONS:
- hash: 9e1033f0a1b2       # the candidate's dry-run hash
  action: keep            # keep | discard
  subtype: chore          # only when overriding the heuristic
  title:   <better title> # only when overriding the heuristic
- hash: 4da061d3c4e5
  action: discard
  reason: already covered by Issue-200   # informational; not persisted
```

A candidate with no entry defaults to **keep** (drafted with the heuristic
subtype/title). `discard` is not drafted and is recorded so it is not
re-surfaced — but it is re-triageable, not a permanent burn.

## Anti-patterns

- Do not author the issue body. The script fills the template.
- Do not edit the source file (e.g., the original
  imPlan-potentialFutureEnhancements.md). Reaping is read-only on
  sources.
- Do not discard a STUCK candidate just because it's painful to read.
  STUCK files often surface the highest-value missing issues.

## Verification

Verified via fixture-grep against SKILL.md contract structure.
