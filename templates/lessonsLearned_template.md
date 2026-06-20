# Lessons Learned — {{ISSUE_ID}}

> Written by `/devagent:lessonslearned` after `/devagent:impact`.
> One entry per lesson. Each entry is one-line claim + one-line
> evidence + one-line consequence + tag set. Long entries are unread
> entries — split or trim anything over four lines.
>
> **Tag taxonomy** (used by `/devagent:reap`):
> - `actionable` — implies a follow-up issue should exist
> - `reference` — fact to remember; no action
> - `norm` — changes operator working style
> - `pattern` — generalises beyond this issue
>
> These four are the ONLY legal tags. Any other tag (e.g. `[process]`,
> `[testing]`) is rejected by `scripts/lessons-lint.sh`. Every entry must
> carry at least one.

## Entries

### <one-line claim>
- Evidence: <one line citing log entry, deviation, or red-team finding>
- Consequence: <one line: what to do differently next time>
- Tags: [actionable]

### <one-line claim>
- Evidence: <citation>
- Consequence: <one line>
- Tags: [reference]

### <one-line claim>
- Evidence: <citation>
- Consequence: <one line>
- Tags: [norm, pattern]

<!--
Examples (delete before saving):

### draft-step missed sign-error in foo_kernel
- Evidence: log 2026-05-19 10:00 "improve: 1 bug surfaced, fixed in task 2"
- Consequence: include a brief manual trace through edge cases when drafting.
- Tags: [norm, pattern]

### bar.c callers had matching off-by-one
- Evidence: actualWork Follow-up section
- Consequence: file a focused issue to audit callers; do not bundle.
- Tags: [actionable]
-->
