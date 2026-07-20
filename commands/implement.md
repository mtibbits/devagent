---
description: Execute the active issue's plan task-by-task.
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read, Write, Edit, Skill
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:implement

Step 7 of the 22-step devAgent workflow. Invokes the upstream
`superpowers:executing-plans` skill against `<issue-dir>/imPlan.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify branch step has completed (state file's `branch` field is
   set and the working tree is on that branch). If not, halt — UNLESS the
   issue's `checklist.md` contains no branch row (step 6), as in the
   oneshot checklist.
   A prerequisite whose producing step is absent from the issue's checklist is N/A, not a halt
   (branch produces the branch): with no branch step, implement acts as an
   operational one-shot on the current tree and must produce no repo diff.
3. Verify `imPlan.md` has a `## Definition of done` section (proves
   tighten ran). If absent, halt — UNLESS the checklist contains no draft
   row (step 1): the producing step is absent, so the check is N/A
   (draft produces imPlan.md); the issue body's `## Proposed behavior`
   and acceptance criteria are then the work statement.
4. Invoke `superpowers:executing-plans` with `$ISSUE_DIR/imPlan.md`
   as the plan path — UNLESS the checklist contains no draft row (step 1):
   there is no imPlan.md, so skip the executing-plans dispatch and
   execute directly against the issue body (its `## Proposed behavior`
   and acceptance criteria are the work statement, per step 3's
   carve-out). Pass `$NOTE` as additional context the executor
   should consider (e.g., "skip task 4 — already merged upstream").
5. Implementation happens task-by-task per the wrapped skill's
   conventions. Each task gets its own commit per executing-plans
   defaults.
6. On full completion, append a single summary log entry:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" implement \
  "Plan implemented: N tasks done, F files changed, all tests pass; note: $NOTE"
```

## Halt and ask if

- Working tree is not on the issue's branch **and** the checklist
  contains the branch step (6).
- `imPlan.md` lacks Definition of done **and** the checklist contains
  the draft step (1).
- A task fails halfway through — surface the failure and let the
  operator decide whether to mark the step `[!]` stuck (via
  `/devagent:stuck`) or retry.

## Skipping policy

Never auto-skip individual tasks; the wrapped skill's task-level
prompting handles that. At the step level, never auto-skip implement
itself — without code change the rest of the pipeline is meaningless.

## Commit discipline

Per-task commits (Workflow step 5 above) are the norm. Two rules make
commit (10) and ship (15) safe:

- `git add` NEW files in the same task commit that creates them; an
  untracked file that never gets added ships an incomplete PR (#25's
  failure class).
- Leave nothing uncommitted at the end of this step. The commit step
  (10) verifies everything is on the branch — it succeeds as a no-op
  when per-task commits already captured all work, and fails loudly
  on a dirty tree. Analyze (11) then runs against the committed work;
  post-analyze fixes are new signed-off commits (squash-on-merge
  absorbs the noise — spec §11).

## Completion handoff

First, **record the in-scope manifest** — only when the active project sets
`commit_autostage=true`, run record-scope so step 10's #251 autostage can stage
exactly this issue's edited files with no hand-written `.devagent-scope`. It is a
no-op for projects without `commit_autostage=true`, and it preserves an
operator-authored `.devagent-scope` (it only regenerates manifests it created):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/record-scope.sh"
```

Next, **run the born-red check** — only when the active project sets
`born_red=true`, run born-red so each NEW test is proven to fail at
`baseline_sha` before it can be committed (#362). It runs the new-test set in an
ephemeral worktree at baseline (never mutating your tree) and writes
`<issue-dir>/analysis/<date>-born-red.txt`. A **nonzero exit means FLAGGED** — a
new test was green at baseline (never-red / vacuous); fix it to fail without the
change, or allowlist it with a reason in `<issue-dir>/.devagent-born-red-allow`,
before marking this step. No-op for projects without `born_red=true` (and for
non-bats/pytest work). commit.sh (step 10) also hard-blocks on a FLAGGED artifact.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/born-red.sh"
```

Then **mark this step done** — `next.sh` keys off the checklist mark
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
