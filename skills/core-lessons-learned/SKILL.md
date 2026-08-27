---
name: core-lessons-learned
description: "Step 22: extract reusable lessons from a completed issue"
when_to_use: After /devagent:impact and before /devagent:cleanup. Run as part of /devagent:lessonslearned.
user-invocable: false
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
---

# devagent-lessons-learned

Step 22 of the devAgent 24-step workflow. Writes
`<issue-dir>/lessonsLearned.md` capturing what to do differently next
time. Entries tagged `actionable` are harvested by `/devagent:reap`
into new captures.

## Overview

A lesson is not a postmortem. The format is one-line claim + one-line
evidence + one-line consequence. The bias is toward short, specific,
re-readable entries — lessonsLearned is read at the start of similar
issues, not at the end of the current one.

## Inputs

- `$ISSUE_DIR`, `$NOTE`.
- Reads:
  - `<issue-dir>/checklist.md` (the Log section — chronology of
    decisions).
  - `<issue-dir>/actualWork.md` (the Deviations section).
  - `<issue-dir>/analysis/*-redmr.md` (what red-team caught).
  - `<issue-dir>/impact.md` (what actually mattered).
  - Resolved `lessonsLearned_template.md` (§12 registry: project paths → devdoc → plugin default).
- Writes: `<issue-dir>/lessonsLearned.md`.

## Checklist

1. **Resolve template.** Walk §12 registry to find
   `lessonsLearned_template.md`. Halt if unresolvable.
2. **Read the Log chronologically.** Identify decision points where
   the operator second-guessed or reversed course. Each is a candidate
   lesson.
3. **Read Deviations.** Each deviation is a candidate lesson — what
   in the plan was wrong, what was learned mid-implementation?
4. **Read red-team findings.** Each BLOCKING finding the operator
   addressed is a candidate lesson about future plans.
5. **Write entries in a tagged, lint-recognized shape.** Every entry MUST
   carry a tag in one of the TWO shapes `scripts/lessons-lint.sh` recognizes:

   ```markdown
   ### <one-line claim>
   - Evidence: <one line citing log entry, deviation, or finding>
   - Consequence: <one line: what to do differently next time>
   - Tags: [actionable | reference | norm | pattern]
   ```

   or the flat inline form `- [<tag>] <one-line claim>`. Prefer the
   `### `+`- Tags:` form for register-grade lessons — `/devagent:reap` lifts
   the heading as the follow-up title. **Anti-pattern:** a bare bold bullet
   `- **<claim>**` with NO `- Tags:` line and NO `### ` heading is invisible
   to the tagging pipeline; since #525 `lessons-lint` FAILS such wholly
   flat-bullet, zero-tag files naming the file (the batch-11 gap — Issue-440–443,
   453–457, 459–460 shipped this way and silently escaped both reap and the lint).

6. **Classify every entry — mandatory.** Each entry MUST carry ≥1 tag
   from the closed set `actionable | reference | norm | pattern` (no
   other tag is legal — `scripts/lessons-lint.sh` rejects ad-hoc tags).
   For each entry, explicitly decide `actionable` vs not: an entry that
   names an unfiled follow-up — cues like "should file", "found but not
   fixed", "candidate follow-up", "its own issue" — is `actionable`
   (`/devagent:reap` harvests these). Tag `reference` for a fact to
   remember, `norm` for an operator-working-style change, `pattern` for
   something that generalises beyond this issue.
7. **Stage patterns for the register (#286, #586).** For each entry whose
   tag set includes `pattern` (any form — `pattern`, `[pattern, norm]`,
   etc.) AND that generalises beyond this issue, stage a one-line
   distillation of it, with its `(Issue-N)` source citation, for the
   resolved `potholes` register (§12 walk: project paths → devdoc →
   plugin default; `template.sh --project <p> show potholes` prints its
   path). **Do NOT edit the register file yourself** — it lives in the
   shared source tree, where an uncommitted edit is stashed or reverted by
   the next session's gate (the #586 defect). Stage each line instead, one
   command per line:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/promote-potholes.sh" "$PROJECT" "$ISSUE_DIR" --add "<section heading>" "- <one-line distillation> (Issue-N)."
   ```

   The script refuses an unknown section heading, a wrong/missing
   citation, a multi-line value, and a line naming the project; it writes
   `<issue-dir>/potholes-promotion.md` (durable in devdoc) and is
   idempotent. `/devagent:cleanup` (step 23) applies and commits the
   staged lines on the base branch and flips the file to
   `status: applied <sha>` (a register outside this project's repos — the
   plugin default, for every project but devagent — DEFERS at cleanup and is
   landed by hand from the register's own repo; `--add` warns when that is
   the case); cleanup also REFUSES a log line that claims a
   promotion the register does not carry, so the Logging line below must
   say `staged`, never `promoted`.
   Rules for the line itself: dedupe by citation — skip if the register
   already carries a line citing this issue for the same rule; keep the
   one-liner PROJECT-NEUTRAL (strip domain nouns — the register is a
   shipped plugin template scanned by `generic-templates.bats`, so a
   project-specific token would redden that canary in an unrelated
   issue); pick the closest existing trigger-domain heading
   (`grep '^## ' <register>`). Not every `pattern` entry belongs — stage
   the ones that will fire on FUTURE issues of other kinds, not the
   one-off.
8. **Brevity check.** If an entry is more than 4 lines total, split
   it or trim. Long lessons are unread lessons.

## Halt and ask if

- Fewer than 2 candidate lessons surface AND the issue had > 5 log
  entries — likely the skill is missing something; surface the
  thinness for operator review rather than writing a mostly-empty
  file.
- Operator's $NOTE asserts a lesson that contradicts the evidence in
  log/deviations — surface the conflict.

## Skipping policy

Never auto-skip. If the issue was truly mechanical (e.g., a typo fix
with zero deviations and zero red-team findings), surface "nothing
to learn; mark step `[-]` skipped?" for operator confirmation.

## Logging

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" lessonslearned "lessonsLearned.md written: L entries (A actionable, R reference, N norm, P pattern); register: S staged pending cleanup; note: $NOTE"
```

`S` is the number of lines actually staged (`grep -c '^- '
<issue-dir>/potholes-promotion.md`), not the pattern-tag count; when none
were staged write `register: none staged` instead.

## Templates referenced

- the resolved `lessonsLearned_template.md` (§12 registry: project paths → devdoc → plugin default) (canonical entry format and
  tag taxonomy).
