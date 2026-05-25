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

## Completion handoff

After marking the step `[x]` (or `[-]` if skipped) and logging:

**STOP.** Do not invoke any other `/devagent:*` command on your own.
End your final message with this exact question (substituting the
correct next-step slash command from the checklist):

> Would you like to continue on to /devagent:<next-step-name>?

The next-step name is the first line in the issue's checklist.md
that starts with `- [ ]` -- read that, take the verb after the
step number, and substitute it into the question.

The only exception: if you were invoked under a `/devagent:next
--auto` or `--through` chain (recognizable because the preceding
turn's tool output contained a `CHAIN: /devagent:next ...` line),
then do NOT ask the question -- instead invoke that exact CHAIN:
command verbatim to continue the chain.

If the operator typed a one-off `/devagent:<name>` directly (no
preceding CHAIN: line), DO ask the question and wait for the
operator's answer. Do not advance even if your internal TODO list
still has steps after this one -- the operator's last explicit
instruction is the authoritative scope.
