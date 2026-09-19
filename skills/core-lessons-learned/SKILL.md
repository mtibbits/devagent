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
   carry a tag in one of the two CANONICAL shapes `scripts/lessons-lint.sh`
   recognizes:

   ```markdown
   ### <one-line claim>
   - Evidence: <one line citing log entry, deviation, or finding>
   - Consequence: <one line: what to do differently next time>
   - Tags: [actionable | reference | norm | pattern]
   ```

   or the flat inline form `- [<tag>] <one-line claim>`. Prefer the
   `### `+`- Tags:` form for register-grade lessons — `/devagent:reap` lifts
   the heading as the follow-up title. The legacy bold-lead form
   `- **[tag] <claim>.**` is TOLERATED (#588) — the lint reads its tag so
   Fable-era files do not false-flag — but it is not a recommended shape.
   **Anti-pattern:** a bare bold bullet
   `- **<claim>**` with NO `- Tags:` line and NO `### ` heading is invisible
   to the tagging pipeline; since #525 `lessons-lint` FAILS such wholly
   flat-bullet, zero-tag files naming the file (the batch-11 gap — Issue-440–443,
   453–457, 459–460 shipped this way and silently escaped both reap and the lint).

   **The lint is enforced at step 23 (#594).** `/devagent:cleanup` lints this
   issue's `lessonsLearned.md` BEFORE any side effect and refuses a red file; a
   file that is present is linted whatever the step's glyph says, and with
   `lessonslearned` `[x]` a missing file is itself a refusal. Marking the step
   `[-]` with no file written is the only skip, and it leaves the issue out of
   the reap pipeline. Self-check before marking this step done:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/lessons-lint.sh" "$ISSUE_DIR/lessonsLearned.md"
   ```

   Two shapes the lint reads since #594, neither one recommended: a bracket that
   LEADS a heading (`### [tag] <claim>`) tags that entry — TOLERATED, because
   `/devagent:reap` does NOT read a heading's bracket, so **when the honest tag
   is `actionable`, also add a `- Tags: [actionable]` bullet beneath the
   heading** or reap never sees it; and a `- [[wikilink]]` bullet (or a
   `### [[wikilink]]` heading) is a link, never a tag — it tags nothing, so the
   entry above it still needs its own tag line.

6. **Classify every entry — mandatory.** Each entry MUST carry ≥1 tag
   from the closed set `actionable | reference | norm | pattern` (no
   other tag is legal — `scripts/lessons-lint.sh` rejects ad-hoc tags).
   For each entry, explicitly decide `actionable` vs not: an entry that
   names an unfiled follow-up — cues like "should file", "found but not
   fixed", "candidate follow-up", "its own issue" — is `actionable`
   (`/devagent:reap` harvests these). Tag `reference` for a fact to
   remember, `norm` for an operator-working-style change, `pattern` for
   something that generalises beyond this issue.
7. **Register ops for `pattern` entries (#286, #586, #611, #612).** The register
   is read as a UNION — `template.sh --project <p> show potholes` prints seed +
   workflow + project (the READ union: `## Retired (mechanised)` sections are
   omitted; `grep '^## '` for the legal headings — a heading may appear once
   per layer; treat every copy as ONE section, identity is the heading text).
   Run 7a and 7b BEFORE staging any add. Both are YOUR judgment with a grep
   assist — the register's triggers are prose and the diff is code; no
   mechanical detector is claimed. **Do NOT edit any register file yourself**
   — an **uncommitted** edit in a shared tree is stashed or reverted by the
   next session's gate (the #586 defect). Stage every result through
   `promote-potholes.sh`; cleanup (step 23) drains it.

   7a. **Retire-on-fix.** Did this issue mechanise, in full or in part,
   something the register already warns about? Grep the union for the diff's
   key nouns (`template.sh --project "$PROJECT" show potholes | grep -i
   '<noun>'`) and judge each hit. FULL → retire the line in the ONE devdoc
   layer that holds it:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/promote-potholes.sh" "$PROJECT" "$ISSUE_DIR" --retire --layer <project|workflow> "- <the exact line>" "<mechanism — single line, no ')' and no 'Issue-'>"
   ```

   The line moves to `## Retired (mechanised)` at the end of its layer file as
   `- [<section>] <text> — mechanised by <mechanism> (<its tokens>; <this issue's token>).`
   — it keeps its text (the citation proof `--check` needs) and leaves the READ
   union. A line that lives only in the plugin SEED is refused ("seed line —
   … edited only by a seed-curation PR", #613) — the seed is a curated
   excerpt, never an op target. The union read shows a deduped lesson in the
   SEED's spelling and hides its body-identical devdoc twin — a register that
   was distributed from this seed (#613) carries one per seed line, differing
   only by citation form; an install with no private layers has none: when
   the refusal names a twin ("lives in the <layer> layer … as: <line>"),
   target THAT line; when it says no layer carries the lesson, record it as
   an `[actionable]` lesson instead. PARTIAL → amend (7b's command) to name the mechanism and what it
   does NOT cover.

   7b. **Consolidate-before-add.** For each candidate line, grep the UNION
   (all layers, not just the target) for the same pothole FAMILY — same
   section AND same failure shape, not a shared noun. When a member lives in a
   devdoc layer, stage a merged REPLACEMENT of exactly ONE devdoc-resident
   member (an `--amend` replaces one line) that keeps every member's specific
   trigger recognisable and carries every member's token plus this issue's;
   the other members' lines stay — retire each under 7a if the merge makes it
   redundant:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/promote-potholes.sh" "$PROJECT" "$ISSUE_DIR" --amend --layer <project|workflow> "- <the exact old line>" "- <merged line> (<old tokens>; <this issue's token>)."
   ```

   A line already staged for a 7a retire is not an amend candidate — one op
   per line: pick another devdoc-resident member, or `--drop` the retire and
   amend instead. When the only match is in the SEED (never replaced by an
   op), stage an
   `--add` whose body names the seed family it extends. Never stage an `--add`
   of L beside an `--amend` → L, nor two `--amend` ops → the same L: `--apply`
   refuses both (old AND new present).

   7c. **Stage the remaining adds**, routed to a layer — `--layer` is mandatory,
   no default, the routing is YOUR judgment (the script enforces only the
   citation form and the shared-layer leak rails):
   - `--layer project` — the lesson is about THIS project's code or domain
     (domain nouns are fine; the project register is private). Cite `(Issue-N)`.
   - `--layer workflow` — the lesson would fire on ANOTHER project's issue
     (workflow, tooling, review discipline). Cite `(<project> Issue-N)` with
     the config spelling of the project; keep the line project-neutral — the
     body must not name the project or a `paths.potholes_domain_nouns` term.

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/promote-potholes.sh" "$PROJECT" "$ISSUE_DIR" --add --layer <project|workflow> "<section heading>" "- <one-line distillation> (<citation>)."
   ```

   Every op's result line obeys ONE citation grammar `(<tok>[; <tok>]*).`, each
   token in the layer's form, this issue's token present. Dedupe by citation —
   skip if a layer already cites this issue for the same rule; pick the closest
   existing heading. `--add` WARNS (never refuses) when the target section of
   the target layer file already holds the cap's worth of bullets
   (`POTHOLES_SECTION_CAP` in `scripts/lib/potholes.sh`; the warning prints the
   count and the cap) — consolidate (7b) first. The script refuses a
   missing/unknown layer, a wrong token form, an unknown or Retired section, a
   multi-line value, a heading or Retired-region target, a multi-hit target, a
   second op on a line another staged op already names (one op per line — the
   refusal prints the `--drop <n>` that clears the first), a no-op amend, any
   op onto an already-drained (`applied`) staging file, and (workflow) a body
   naming the project or a domain noun; `--layer
   workflow` with no `[paths] potholes_workflow` configured is refused HERE,
   loudly — configure the key first, and only then consider re-routing to
   `project` (a shared lesson forked into a private register is what the
   design exists to avoid). It writes `<issue-dir>/potholes-promotion.md`
   (durable in devdoc; keyed `op:` blocks, one op per block and one op per
   line; a byte-identical re-run is a no-op).
   `/devagent:cleanup` (step 23) drains it: every op is validated against a
   temp copy of every target file, then each layer file (bootstrapped if
   absent) is written and gets its own path-scoped commit in the devdoc repo,
   and the file flips to `status: applied <sha>[,<sha>]`. A DEFER (rc 3 —
   `commit_devdoc` not true, dirty/untracked target, mid-merge, containment,
   held lock, or any failed op validation with the op quoted) keeps the file
   pending and says why; `--add` warns at staging time about the ones it can
   already see. A STALE op (its target consumed by another closeout) names its
   two closes: `--drop <op>` or `status: applied by-hand <sha>` after landing
   a line by hand. cleanup also REFUSES a log line that claims a promotion no
   layer carries, so the Logging line below must say `staged`, never
   `promoted`. Not every `pattern` entry belongs — stage the ones that will
   fire on FUTURE issues, not the one-off.
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
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" lessonslearned "lessonsLearned.md written: L entries (A actionable, R reference, N norm, P pattern); register: S staged; retired: T, amended: M; note: $NOTE"
```

`S` is the number of op blocks in `<issue-dir>/potholes-promotion.md`
(`grep -c '^## '` — one op per block, so blocks == ops; `promote-potholes.sh
<project> --list-pending` prints the same count), `T`/`M` the retire/amend
blocks among them, so S ≥ T + M in ONE unit — never the pattern-tag count.
When nothing was staged write `register: none staged` (no `retired:`/`amended:`
fields) — `0` and `none` are non-claims; `--check` reads `S` literally and a
staged retire/amend backs the claim exactly like an add.

## Templates referenced

- the resolved `lessonsLearned_template.md` (§12 registry: project paths → devdoc → plugin default) (canonical entry format and
  tag taxonomy).
