---
description: Run red-team adversarial review of the MR before shipping.
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read, Write, Edit, Skill, Agent
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:redmr

Step 14 of the 22-step devAgent workflow. The red-team runs in the
`devagent:redteam-reviewer` agent, which cannot write files and carries the
adversarial stance, severity taxonomy, and output contract as its system
prompt; it attacks the MR body and diff using the resolved `redteam_mr.md`
(§12 registry: project paths → devdoc → plugin default). This command resolves
the tier, dispatches, writes the returned report to
`<issue-dir>/analysis/YYYY-MM-DD-redmr.md`, and enforces the blocking gate.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify `mr.md` exists.
3. **Dispatch** per the contract below. The checker authors the report and
   returns it; it cannot write files.
4. **Write the returned body VERBATIM** to
   `<issue-dir>/analysis/YYYY-MM-DD-redmr.md` (create `analysis/` if missing).
   Never rewrite the checker's findings in place — triage them, act on them,
   but leave the record as authored.
5. Validate the report (below), then log the finding counts in the
   parser-compatible format from spec §14.4:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" redmr \
     "Red-team: B blocking, M major, m minor, I info (template: $TEMPLATE_PATH); note: $NOTE"
   ```

   The `N blocking` token is machine-parsed by statusreport (`failed_redteam`,
   regex `\d+\s+blocking`) — never reword it; the old template vocabulary
   ("N block") is invisible to that parser.
6. **Refuse silent advance.** If B > 0, do not advance: report the failure and
   tell the operator to address findings before re-running, or mark `[!]`
   stuck via `/devagent:stuck`. Under dispatch the checker only reports
   counts — this gate is yours to enforce.
7. **Commit applied fixes (#148).** If addressing findings modified (or added)
   any tracked file in the project source repo — the issue branch — `git add`
   + `git commit -s` them before marking step 14. A new signed-off commit, not
   an amend (the fix delta stays auditable; amending after a prior ship would
   force-push). ship.sh (15) refuses to push when tracked files are modified.
   Committing here also re-anchors the report to `baseline..HEAD`, so the
   report and the pushed branch cannot diverge (the #101/#102 failure). Devdoc
   artifacts (analysis/, mr.md) are NOT committed here; they are governed by
   `commit_devdoc` at cleanup.

## Dispatch contract

Fresh context is what makes the attack real; the model override is conditional.

1. **Resolve the model tier** (optional):
   `tier="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/step-model.sh" <project> 14 || true)"`.
   Pass the CANONICAL step number (14) even on a renumbered checklist — the
   class map is keyed to canonical numbers (config.sh). A per-issue
   `.devagent-step-models` marker (#291) may supply the tier — a stderr
   `per-issue` provenance line means stamp `model: <tier> (per-issue)`. A
   nonzero exit WITH an error on stderr (stderr WITHOUT a `per-issue`
   provenance line) is a bad marker: STOP and fix or remove it — do NOT
   dispatch on inherit.
2. **Bifurcated dispatch** (#458). Both paths run the same agent, so its
   system prompt, its Write/Edit denial, and fresh context hold either way:
   - **Tier resolved** ⇒ dispatch the Agent tool with
     `subagent_type: devagent:redteam-reviewer` and an explicit `model: <tier>`
     parameter, which overrides the agent's pinned default (per-invocation
     model beats definition frontmatter). Tell it to stamp `model: <tier>`
     (or `<tier> (per-issue)`).
   - **Tier empty** ⇒ invoke the `core-redmr` skill. Its `context: fork` +
     `agent:` frontmatter runs it inside the same agent at that agent's pinned
     default; the report stamps `model: agent-default (redteam-reviewer)`.
     Empty means "no override", NOT "inherit the session model" — for steps
     14/21 the agent's pinned model is the tier of last resort.
3. **Package inputs as paths, not conversation.** The dispatch prompt contains
   only: the project name, the absolute paths of `mr.md`, `imPlan.md`,
   `actualWork.md`, the repo directory plus the literal diff spec
   `<baseline_sha>..HEAD`, the output artifact path, and the `model:` value to
   stamp. The checker resolves the red-team template itself via
   `template.sh --project <project> show redteam_mr`. Do NOT paste the MR
   summary, your recollection of the change, or prior findings into the prompt
   — the checker must derive everything from disk, which is exactly how it
   catches a report/branch divergence.
4. **Mandatory artifact header.** First lines: `context: subagent` (always —
   a fork IS a subagent context; `context: inline` only on the degraded path
   below), then `model:` as one of `<tier>`, `<tier> (per-issue)`,
   `inherit (fallback from <tier>)`, or `agent-default (redteam-reviewer)`.
5. **Degraded-harness fallback.** When no subagent mechanism exists (headless
   run, cron, degraded harness), run the red-team inline against the agent
   definition's contract and the resolved template; the artifact MUST record
   `context: inline` so the reduced independence stays visible in the record.
   If dispatch fails because the tier is unavailable, retry once with NO
   override and record `model: inherit (fallback from <tier>)`.
6. **Report validation — retry-then-stuck (#360).** When this ran DISPATCHED,
   validate before adopting:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-lint.sh" "<artifact>" subagent --class redmr`.
   On FAIL (a garbled / no-tool-use report — the #117/#122/#76/#315 misfire
   class): archive the reject to
   `<issue-dir>/analysis/rejected/<date>-redmr-attempt<N>.md`, re-dispatch ONCE
   with an explicit "your previous response did no work — actually do the work
   with tools" nudge, and if it FAILs again mark the step `[!]` with the lint
   reason. Never adopt a garbled report as a verdict (the #315 lesson). Inline
   runs skip the lint (the operator sees the artifact directly).

## Halt and ask if

- `mr.md` missing.
- The red-team template cannot be resolved (the checker reports this).
- BLOCKING findings — do NOT advance to ship.
- The checker returns findings it could not classify — surface them un-tagged
  and triage with the operator rather than inventing a severity.

## Skipping policy

Never auto-skip; red-team is an unconditional gate on shipping upstream per
spec §6.3 principle and the operator's principal value prop. If the operator
insists on skipping (private fork-only experimentation, etc.), surface "this
means shipping un-red-teamed; confirm?" and require acknowledgement.

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
