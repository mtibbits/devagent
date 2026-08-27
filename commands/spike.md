---
description: "Step 3: run a plan's load-bearing bets in a throwaway worktree; record VERIFIED/FALSIFIED/INCONCLUSIVE verdicts with evidence."
allowed-tools: Read, Grep, Glob, Write, Edit, Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[project] [Issue-N]"
---

# /devagent:spike

Step 3 of the devAgent workflow — the OPTIONAL post-draft spike step (flow-order between
`2 draft` and `4 scope`). It runs only when the issue was flagged `spike: required` in its
`## Workflow flags` block (pull.sh flips the `spike` row at scaffold), or when the operator
flips that row manually (the escape hatch).

**Why post-draft.** The plan is the hypothesis; the spike is the experiment. Pre-draft
prototyping was rejected: a plan written after a prototype rationalizes whatever the prototype
happened to do, and every later checking step then reviews a plan whose author is committed to
it. Declaring the bet in writing FIRST keeps falsification sharp.

## Argument parsing

Per `commands/draft.md` (spec §6.1): optional `project`, optional `Issue[-Fork]-N`, rest
ignored. Defaults to the active project/issue.

## Precondition — the spike row must be active

Read the `spike` row's glyph (`checklist_step_state_by_name <checklist> spike`). Proceed
only if `[ ]` or `[~]`. If `[-]` (the unflagged default), HALT: "spike is not flagged for
this issue — flip the spike row first (`/devagent:checklist-mark --by-name <issue-dir>
spike ' '`) or skip." Never silently flip `[-]`→`[x]`.

## Discipline — spike code is EVIDENCE, never product

Nothing built here is merged, cherry-picked, or copied into the issue branch. The worktree and
its temp branch are DESTROYED on completion and on failure. `Write`/`Edit` are granted to author
`<issue-dir>/spike.md` and to edit files INSIDE the spike worktree — never the real source tree.

**This last rule is CONVENTIONAL, not enforced.** `Write`/`Edit` reach the whole tree; the
constraint is this contract, and review/redmr are the backstop. What IS mechanically enforced is
the worktree's destruction: `teardown` verifies the worktree and branch are gone and FAILS loudly
(leaving `spike_worktree_path` set) rather than reporting a success it did not achieve.

## Workflow

1. Resolve `project` / `issue-dir`. Read the plan's `## Load-bearing unknowns`. If it is
   `(none)`, record "no declared unknowns" in spike.md and mark the step done — that is a
   legitimate outcome, not a finding.
2. Create the throwaway worktree (at the RESOLVED baseline — never the issue branch, never HEAD):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/spike.sh" create <project> <Issue-N>
   ```

   It prints the worktree path and records `spike_worktree_path` in issue state.
3. For EACH declared unknown `U<N>`, implement the MINIMAL slice that would falsify it — inside
   the spike worktree only. Measure; do not argue.
4. Write `<issue-dir>/spike.md`, one entry per unknown:

   ```markdown
   ## U1 (Task 3) — <the assumption, restated>
   **Verdict:** VERIFIED | FALSIFIED | INCONCLUSIVE
   **Evidence:** <command + its output, a diff excerpt, or a measurement>
   ```

   Every verdict MUST carry evidence. INCONCLUSIVE is an honest verdict — record what blocked it.
5. ALWAYS tear down, including when the spike failed:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/spike.sh" teardown <project> <Issue-N>
   ```

   Teardown is idempotent and clears `spike_worktree_path`.
6. **If a core bet is FALSIFIED**, do not patch around it here: route back to draft via the
   existing revision machinery (`/devagent:revise`), which opens a `## Revision N` block. There is
   no bespoke spike loop. (The spike row is excluded from revision blocks — re-spike via the manual
   escape hatch, as with the research row.)

## Logging

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" spike "spike.md written (V verified, F falsified, I inconclusive)"
```

## Completion handoff

First, **mark this step done** — `next.sh` keys off the checklist mark
(not the log), so without it an `--auto`/`--through` chain re-dispatches
this same step forever:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-mark.sh" --by-name "$ISSUE_DIR" spike x
```

This step marks itself BY NAME, not by number — the row's number differs between
a pre-#558 checklist and a current one, and the name does not. Use `-` instead of
`x` if the step was skipped. Then run the Logging command above.

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
