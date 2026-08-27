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
7. **Stage patterns for the register (#286, #586, #611).** For each entry whose
   tag set includes `pattern` (any form — `pattern`, `[pattern, norm]`,
   etc.) AND that generalises beyond this issue, stage a one-line
   distillation, ROUTED to a register layer — `--layer` is mandatory, there
   is no default, and the routing is YOUR judgment (the script enforces only
   the citation form and the shared-layer leak rails):
   - `--layer project` — the lesson is about THIS project's code or domain
     (domain nouns are fine; the project register is private). Cite `(Issue-N)`.
   - `--layer workflow` — the lesson would fire on ANOTHER project's issue
     (workflow, tooling, review discipline). Cite `(<project> Issue-N)` with
     the config spelling of the project; keep the line project-neutral — the
     body must not name the project or a `paths.potholes_domain_nouns` term.

   **Do NOT edit any register file yourself** — an uncommitted edit in a
   shared tree is stashed or reverted by the next session's gate (the #586
   defect). Stage each line instead, one command per line. The register is
   read as a UNION of seed + workflow + project (`template.sh --project <p>
   show potholes` prints it; `grep '^## '` for the legal headings — a heading
   may appear once per layer; treat every copy as ONE section, identity is
   the heading text):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/promote-potholes.sh" "$PROJECT" "$ISSUE_DIR" --add --layer project|workflow "<section heading>" "- <one-line distillation> (<citation>)."
   ```

   The script refuses a missing/unknown layer, a wrong citation form for the
   layer, an unknown section, a multi-line value, and (workflow layer) a body
   naming the project or a domain noun; `--layer workflow` with no
   `[paths] potholes_workflow` configured is refused HERE, loudly — configure
   the key first, and only then consider re-routing to `project` (a shared
   lesson forked into a private register is what the design exists to avoid).
   It writes `<issue-dir>/potholes-promotion.md` (durable in devdoc) and is
   idempotent. `/devagent:cleanup` (step 23) drains it: each layer file
   (bootstrapped if absent) gets its own path-scoped commit in the devdoc
   repo, and the file flips to `status: applied <sha>[,<sha>]`. A DEFER (rc 3
   — `commit_devdoc` not true, dirty/untracked target, mid-merge, containment,
   held lock) keeps the file pending and says why; `--add` warns at staging
   time about the ones it can already see. cleanup also REFUSES a log line
   that claims a promotion no layer carries, so the Logging line below must
   say `staged`, never `promoted`. Rules for the line itself:
   dedupe by citation — skip if a layer already cites this issue for the same rule;
   pick the closest existing heading. Not every `pattern` entry belongs —
   stage the ones that will fire on FUTURE issues, not the one-off.
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
