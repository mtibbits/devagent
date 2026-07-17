---
description: "Step 21: fresh-context verification that the committed branch satisfies the ACs and contains all findings, before ship."
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read, Write, Edit, Skill, Agent
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:preship

Step 21 of the devAgent 22-step workflow (file-ordered between redmr (14)
and ship (15); the number is unique — file order is execution authority).
The verification runs in the `devagent:preship-verifier` agent, which cannot
write files and carries the five verifications as its system prompt; this
command resolves the tier, dispatches, writes the returned artifact to
`<issue-dir>/preship.md`, and enforces the failure protocol.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify `mr.md` exists (draftmr ran) and the redmr artifact exists —
   UNLESS the issue's checklist does not contain step 14 (docs-only): a
   prerequisite whose producing step is absent is **N/A**, and the review
   report alone is the findings input. Do not halt on the absent step;
   DO halt when the step is present but its artifact is missing.
3. **Dispatch** per the contract below. The checker authors the artifact and
   returns it; it cannot write files.
4. **Write the returned body to `<issue-dir>/preship.md` VERBATIM.** Do not
   edit, summarize, or "fix" it — authorship stays with the checker, and a
   main session that rewrites a verdict it dislikes is the failure this step
   exists to prevent.
5. Validate, then enforce the failure protocol (both below).

## Dispatch contract

Fresh context is not conditional; the model override is. The implementing
session reviews what it remembers intending; preship reviews what is on disk.

1. **Resolve the model tier and read the EXIT CODE** (#458). Pass the
   CANONICAL step number (21) even on a renumbered checklist — the class map is
   keyed to canonical numbers (config.sh). The three no-tier states are not
   interchangeable here, so discriminate on the code, never on stderr prose:

   ```bash
   tier="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/step-model.sh" <project> 21)"; rc=$?
   ```

   | rc | meaning | dispatch with | stamp |
   |----|---------|---------------|-------|
   | 0 | a tier resolved | `model: <tier>` | `<tier>`, or `<tier> (per-issue)` when stderr carries a `per-issue` line |
   | 2 | the reserved `inherit` marker (#291) — the operator's explicit escape from a project pin | `model: inherit` | `inherit (per-issue)` |
   | 3 | nothing configured | no override — the agent's pinned default | `agent-default (preship-verifier)` |
   | 1 | error: a bad/unreadable marker | — | **STOP**; fix or remove the marker |

   rc 2 must never collapse into rc 3: that would silently defeat the only way
   to opt out of a pinned tier.

2. **Bifurcated dispatch** (#458). Both paths run the same agent, so its system
   prompt, its Write/Edit denial, and fresh context hold either way:
   - **rc 0 or 2** ⇒ dispatch the Agent tool with
     `subagent_type: devagent:preship-verifier` and an explicit `model:` parameter per the
     table (a per-invocation model beats the agent's pinned default).
   - **rc 3** ⇒ invoke the `core-preship` skill. Its `context: fork` + `agent:`
     frontmatter runs it inside the same agent at that agent's pinned default.
     rc 3 means "no override configured", NOT "inherit the session model" — for
     steps 14/21 the agent's pinned model is the tier of last resort.

3. **Package inputs as paths, not conversation.** The dispatch prompt contains
   only: the project name, the absolute paths of `issue.md`, `mr.md`, the
   latest-dated review/redmr artifacts, the repo directory plus the literal
   diff spec `<baseline_sha>..HEAD`, and the `model:` value to stamp. Do NOT
   paste your recollection of the change or prior findings into the prompt —
   deriving everything from disk is exactly how a stranded fix gets caught.
4. **Mandatory artifact header.** First lines: `context: subagent` (always —
   a fork IS a subagent context; `context: inline` only on the degraded path
   below), then `model:` as one of `<tier>`, `<tier> (per-issue)`,
   `inherit (fallback from <tier>)`, or `agent-default (preship-verifier)`.
5. **Degraded-harness fallback.** When no subagent mechanism exists (headless
   run, cron, degraded harness), run the verifications inline against the
   agent definition's checklist; the artifact MUST record `context: inline` so
   the reduced independence stays visible in the record. If dispatch fails
   because the tier is unavailable, retry once with NO override and record
   `model: inherit (fallback from <tier>)`.
6. **Report validation — retry-then-stuck (#360).** When this ran DISPATCHED,
   validate before adopting:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-lint.sh" "<preship.md>" subagent --class preship`.
   On FAIL (a garbled / no-tool-use report — the #117/#122/#76/#315 misfire
   class): archive the reject to
   `<issue-dir>/analysis/rejected/<date>-preship-attempt<N>.md`, re-dispatch
   ONCE with an explicit "your previous response did no work — actually do the
   work with tools" nudge, and if it FAILs again mark the step `[!]` with the
   lint reason. Never adopt a garbled report as a verdict (the #315 lesson).
   Inline runs skip the lint (the operator sees the artifact directly).

## Failure protocol

- ANY FAIL ⇒ run
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-stuck.sh" "$ISSUE_DIR" "preship: <one-line failure list>"`
  and STOP. NB: checklist-stuck.sh takes NO step-number argument — it marks the
  CURRENT step, which is preship when steps 0-14 are terminal (guaranteed under
  next.sh dispatch; on manual out-of-order invocation, verify the checklist's
  current step is 21 first). The `[!]` plus STUCK file is the halt next.sh
  honors (exit 1 + STUCK display); recovery is `/devagent:unstuck` after
  addressing the failures, then re-run preship.
- All PASS ⇒ mark step 21 `[x]` per the Completion handoff below.

## Zero-diff (artifact-only) issues

Detected via `zero_diff_classify` (lib/zerodiff.sh) on `baseline..HEAD`:
`empty` means nothing ships (mark `[-]`, log, advance); `indeterminate`
(missing/stale baseline) NEVER auto-skips — fail loud and let the operator fix
the state (the #116/#242 discipline).

## Halt and ask if

- `mr.md` missing (run draftmr first).
- Step 14 present in the checklist but no `analysis/*-redmr.md` (and the
  docs-only inverse: step 13 present but no review artifact).
- State lacks `baseline_sha`/`branch` (preship cannot identify the push
  content) — fix state, do not guess.

## Skipping policy

Zero-diff auto-skip only (`empty` ⇒ `[-]`; `indeterminate` never auto-skips).
Never skip otherwise — this step is the last gate before content leaves the
machine.

## Logging

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" preship \
  "Preship: A/B ACs pass, F findings located, push-preview MATCH|MISMATCH; note: $NOTE"
```

## Completion handoff

First, **mark this step done** — `next.sh` keys off the checklist mark
(not the log), so without it an `--auto`/`--through` chain re-dispatches
this same step forever:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-mark.sh" "$ISSUE_DIR" <N> x
```

`<N>` is this step's number on the issue's checklist; use `-` instead of
`x` if the step was skipped. Then run the Logging command above (if this
skill/command defines one).

**STOP.** Do not invoke any other `/devagent:*` command on your own.
End your final message with this exact question (substituting the
correct next-step slash command from the checklist):

> Would you like to continue on to /devagent:<next-step-name>?

The next-step name is the first step in the issue's checklist.md not
marked `[x]` or `[-]` -- read that line, take the verb after the
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
