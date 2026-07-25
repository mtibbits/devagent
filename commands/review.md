---
description: Run code review on the active issue's branch.
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read, Write, Edit, Skill
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:review

Step 13 of the 22-step devAgent workflow. Invokes the upstream
`superpowers:requesting-code-review` skill against the issue's
branch diff. Produces a review report that the operator addresses
before the red-team step (14).

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify mr.md exists (proves draftmr ran) and branch is set.
3. Resolve coding_standards artifact per spec §12 and pass its path
   to the wrapped skill as context.
4. Invoke `superpowers:requesting-code-review` with the diff scope
   = `baseline_sha..HEAD` on the issue's branch. This wrapper already
   dispatches a fresh-context subagent; per #151, resolve the model
   override first —
   `tier="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/step-model.sh" <project> 13 || true)"`
   — and pass it on the dispatch (omit when empty ⇒ inherit the session
   model; if the tier is unavailable, retry once with no override and
   record the degradation in the artifact header). A per-issue
   `.devagent-step-models` marker (#291) may supply the tier — a stderr
   `per-issue` provenance line means record the `(per-issue)` header
   form. A nonzero exit WITH an error on stderr (stderr WITHOUT a
   `per-issue` provenance line) is a bad marker: STOP and fix or remove
   it — do NOT dispatch on inherit.

   **Fallback (superpowers absent):** if that Skill invocation errors
   (`Unknown skill: superpowers:requesting-code-review`, #541), run the
   review exactly as this wrapper already specifies — dispatch the
   fresh-context review subagent over `baseline_sha..HEAD` with the
   coding-standards context and the same verdict/artifact contract —
   without the upstream skill's framing. Print the nudge line verbatim
   and continue:
   `recommended: claude plugin install superpowers@claude-plugins-official`
5. Save the review output to `<issue-dir>/analysis/YYYY-MM-DD-review.md`
   (**canonical location**; `<issue-dir>/review.md` at the root is accepted
   legacy — some recent issues wrote it there. #360: prefer `analysis/` going
   forward; statusreport surfaces a `context: inline` report from either place),
   headed by the #151 artifact lines: `context: subagent` (or
   `context: inline` when no subagent mechanism exists) and
   `model: <tier>|inherit|inherit (fallback from <tier>)|<tier> (per-issue)|inherit (per-issue)`.
5a. **Report validation — retry-then-stuck (#360).** When the review ran
   DISPATCHED, validate the artifact before adopting it:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-lint.sh" "<review artifact>"
   subagent --class review`. On FAIL (a garbled / no-tool-use report — the
   #117/#122/#76/#315 misfire class): archive the reject to
   `<issue-dir>/analysis/rejected/<date>-review-attempt<N>.md`, re-dispatch ONCE
   with an explicit "your previous response did no work — actually do the work
   with tools" nudge, and on a second FAIL mark the step `[!]` with the reason.
   Never adopt a garbled report as a review (the #315 lesson). Inline runs skip
   the lint.
6. **Commit applied fixes (#148).** If addressing review findings
   modified (or added) any tracked file in the project source repo —
   the issue branch — `git add` the files and `git commit -s` them
   BEFORE marking the step. A new signed-off commit, not an amend:
   the review-fix delta stays auditable. All source-repo work is
   committed as of step 10; from this step on,
   uncommitted fixes are a defect — ship.sh (15) refuses to push when
   tracked files are modified. Devdoc artifacts (analysis/, mr.md) are
   NOT committed here; they are governed by `commit_devdoc` at cleanup.
7. Log:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" review \
     "Review: F findings (B blocking, N nits); see analysis/YYYY-MM-DD-review.md; note: $NOTE"
   ```

## Halt and ask if

- mr.md does not exist (draftmr step skipped).
- The wrapped skill returns blocking findings — do not silently
  advance. Surface the findings and let the operator decide whether
  to address, mark `[!]` stuck, or override.

## Skipping policy

Never auto-skip; review is a quality gate.

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
