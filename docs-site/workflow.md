<!-- derived-from: README.md docs/specs/2026-05-19-devagent-plugin-design.md templates/checklist-standard.md docs-site/phases.txt -->
# How it works

devAgent plans before it builds, has fresh eyes check the plan and the finished
change, and keeps a written record of each step. The record lives in plain
files, so any session can pick up an issue where the last one stopped.

## Five phases

A standard issue moves through these steps, in five phases:

- **Plan** — `pull` · `research` · `draft` · `spike` · `scope` · `improve` · `prune` · `tighten`. Write down what to build, and have the plan checked before any code exists.
- **Build** — `branch` · `implement` · `quality` · `document` · `commit` · `analyze`. Make the change on its own branch, tidy it, and record what was built.
- **Verify** — `draftmr` · `review` · `redmr` · `preship`. Describe the change, then let fresh readers try to break it.
- **Ship** — `ship` · `mergetoall` · `mergemr`. Open the merge request, and merge it at the verified head.
- **Learn** — `updatewbs` · `impact` · `lessonslearned` · `cleanup`. Update the plan of work, measure what changed, and keep the lessons.

Three steps are optional and off unless you turn them on: research, spike and
mergetoall. Run the steps one at a time with `/devagent:next`, or chain them
with `/devagent:next --auto`.

## The steps

Rows in execution order.

| #  | Command | Phase | Purpose | Why |
|----|---------|-------|---------|-----|
| 0  | `pull` | Plan | Fetch the issue and scaffold its workflow directory | Every issue starts from the tracker's own words, saved on disk, so every later check compares against what was asked. |
| 1  | `research` | Plan | _(optional, off by default)_ Measure code/docs/upstream before drafting; record cited findings and open unknowns | Measuring the code before planning keeps the plan from resting on guesses. |
| 2  | `draft` | Plan | Draft the implementation plan | A written plan is cheaper to fix than code, and it gives every later check something to check against. |
| 3  | `spike` | Plan | _(optional, off by default)_ Run the plan's load-bearing bets in a throwaway worktree; record verdicts | A quick throwaway test of the plan's riskiest guess shows whether the plan stands before anything is built on it. |
| 4  | `scope` | Plan | Structured scope evaluation appended to the plan | Asking whether the plan does too much or too little catches scope creep before any work is done. |
| 5  | `improve` | Plan | Fresh-context check for latent bugs, side effects, and ambiguities | A fresh reader with none of the author's assumptions looks for bugs in the plan, where they are cheapest to fix. |
| 6  | `prune` | Plan | Move non-load-bearing items to the future-enhancements file | Moving the nice-to-haves out of the plan keeps the change small enough to review well. |
| 7  | `tighten` | Plan | Final pre-implementation review: lock ordering, paths, and test plan | Locking the order, the files and the tests means the build follows a fixed plan, not a moving one. |
| 8  | `branch` | Build | Create the issue branch from the configured baseline | Its own branch keeps each issue's change apart from everything else. |
| 9  | `implement` | Build | Execute the plan task-by-task | The plan is carried out one task at a time, each with its own test plan run before the next, so each piece is checked as it lands. |
| 10 | `quality` | Build | Review and tighten code quality on the branch | A second pass over working code catches the mess that passing tests let through. |
| 11 | `document` | Build | Record what was actually built versus planned | Writing down what was built, and where it differs from the plan, keeps the record honest. |
| 12 | `commit` | Build | Commit with DCO sign-off using the commit template | A signed-off commit in a fixed format ties the change to its issue and its author. |
| 13 | `analyze` | Build | Run the project's analyzer family against the changed lines | Static checks on the changed lines catch mistakes that people and tests miss. |
| 14 | `draftmr` | Verify | Draft the merge-request body | The merge request says what changed and why, so reviewers do not have to rebuild the story. |
| 15 | `review` | Verify | Run code review on the branch | A code review reads the whole change against the plan before anyone else has to. |
| 16 | `redmr` | Verify | Red-team adversarial review of the MR before shipping | A hostile reader tries to break the change before a real reviewer or user does. |
| 17 | `preship` | Verify | Fresh-context verification that the committed branch satisfies the acceptance criteria, after a main-session preflight checks the suite evidence and the MR body's claims | A fresh reader checks the committed branch against the issue's goals, so nothing ships on the author's word alone. |
| 18 | `ship` | Ship | Push the branch, open the MR and commit the issue's devDoc folder | The merge request opens only once the fresh preship check has finished or been deliberately skipped, so reviewers see finished work. |
| 19 | `mergetoall` | Ship | _(optional, off by default; on when the project configures `all_prs_branch`)_ Squash-merge the branch into the local all-PRs branch; requires green CI on the MR | Merging every open change into one local branch shows early whether they work together. |
| 20 | `mergemr` | Ship | Merge the PR at the verified head (preship's, or forward's on green CI) when `merge_mr = true`; otherwise wait `[?]` until it is merged | When devAgent merges, it merges only at the verified head: the checked version, or a merge-forward of it that keeps the diff and passes CI. |
| 21 | `updatewbs` | Learn | Update the work-breakdown structure | Updating the plan of work keeps the list of what is left true after each merge. |
| 22 | `impact` | Learn | Measure and record the real-world impact of the merged change | Measuring what the merged change really did shows whether it solved the problem. |
| 23 | `lessonslearned` | Learn | Extract reusable lessons from the completed issue | Writing down what went wrong feeds the next plan, so the same mistake is not made twice. |
| 24 | `cleanup` | Learn | Restore the tree, commit the devdoc and sync it with origin, clear the active issue | Restoring the tree and saving the record gives the next issue a clean start. |

Every issue's `checklist.md` tracks step state with this key:

```
State key: [ ] pending  [x] done  [-] skipped  [!] stuck  [~] in-progress  [?] blocked-external  [P] parked
```

## When it stops

A chain of steps can stop in a few ways, and each asks something different of
you.

**Waiting `[?]`.** Something outside devAgent has to happen first. The row is
marked `[?]`; the glyph key calls this state `blocked-external`, and the two
names mean the same thing. The common case is the merge step, which waits for
the pull request to be merged. `/devagent:next` re-checks that row each time
you run it. While the pull request is still open, it prints a line that starts
with `WAITING` and stops. Nothing polls in the background, so run
`/devagent:next` again later. For any other `[?]` row, `/devagent:next` stops
and suggests parking the issue with `/devagent:park <project>` until the
outside work is done.

**Stuck `[!]`.** When a step fails, the chain stops. Usually that is all: the
row stays as it was, so fix the cause and run `/devagent:next` again to retry
the step. Some steps, and you with `/devagent:stuck <project> "<reason>"`, mark
the row `[!]` and write the reason to a `STUCK` file in the issue's folder.
Then `/devagent:next` refuses to go on until you read it, fix the cause and run
`/devagent:unstuck <project>`.

**Phase breaks and `--through`.** A chain started with `/devagent:next --auto`
stops at each phase break and prints `PHASE BREAK` with a resume command. Run
`/clear`, then the printed command. The next stretch of work starts in a fresh
session instead of re-reading the whole issue's history on every call. By
default the breaks fall before `implement`, `quality` and `updatewbs`. They
fall where a fresh session helps most, not on the five phases' borders; only the
last happens to sit on one. Once the pull request has merged (the active
revision's mergemr row is `[x]`), the default `updatewbs` break is skipped, so
the chain runs on through the Learn steps to cleanup in the same session. To
stop a chain early on purpose, give it an end:
`/devagent:next --through <step>` runs up to and including that step, then
stops. It still stops at any phase break on the way.
`/devagent:next --auto --no-breaks` runs a chain without them.

## The revision loop

When reviewers comment on the merge request, run `/devagent:comments` to fetch
their comments, then `/devagent:revise` to open a new revision pass. The pass
re-runs the workflow from the `draft` step. `revise` does not fetch comments
itself: if they are missing, it stops and points you to `comments`. At any
point, `/devagent:where <project>` and `/devagent:catchup <project>` show where
an issue stands: the current step, the work so far, and what comes next.

## Details

**Numbering.** Steps are numbered 0–24 in execution order — 25 numbered step
commands in all, and the checklist reads top-to-bottom. Some are optional and
off by default: `1 research` and `3 spike` opt in per issue via the
`## Workflow flags` block, and `19 mergetoall` opts in per project by
configuring `all_prs_branch`. A normal issue runs the 22 mandatory steps and
its checklist shows the optional rows pre-marked `[-]` (skipped). Reduced
checklist tiers show a monotonic subset with larger gaps.

**Phase breaks.** The phase breaks described under When it stops come from
config `phase_breaks`; see the
[configuration reference](../docs/configuration.md).
Only the built-in default skips its `updatewbs` break, and only when the active
revision's mergemr row is `[x]`, or `[-]` because ship was `[-]` (no PR). A
checklist with no mergemr row, an abandoned PR (mergemr `[-]` after a real
ship), or a `phase_breaks` value you set keeps the break.

**Merging.** Step 20, `/devagent:mergemr`, merges the PR only when the project
sets `permissions.merge_mr = true`, and only at the head the last passing
preship verified (`verified_head`), or, after a merge-forward git made itself,
the head `preship-verified-head.sh forward` re-recorded, on green CI only;
otherwise it marks its row `[?]` until the PR is merged elsewhere.
`/devagent:next` re-checks a `[?]` mergemr row on every run; while the PR is
still open it prints
`WAITING at step 20 (mergemr): the PR is not merged yet; …`
and stops with exit 0. Nothing polls: run `/devagent:next` again later.
mergetoall (19) holds on pending CI before mergemr runs, so an `--auto` chain
reaches mergemr only with mergetoall `[-]` or CI green. Cleanup waits for the
mergemr row; `/devagent:park <project>` or marking the row `[-]` are the
escapes for a PR that stays open (see `commands/mergemr.md`).

**Other stops.** A chain can also stop while CI is still running on the merge
request, and at a permission gate you decline, such as `ship` asking before it
pushes; the [design spec](../docs/specs/2026-05-19-devagent-plugin-design.md)
(section 7, Chaining) has the full rules.

[← devAgent onboarding](./index.html)
