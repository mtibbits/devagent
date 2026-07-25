<!-- derived-from: README.md docs/specs/2026-05-19-devagent-plugin-design.md templates/checklist-standard.md -->
# Workflow reference

## Numbering

The workflow has **22 mandatory steps numbered 0–21**; two optional flagged
steps (`22 research` and `23 spike`, both off by default) extend the
numbering to 0–23 — 24 numbered step commands in all. Numbers are permanent
IDs, not positions: the checklist's file order sets execution order, so
`21 preship` runs between 14 and 15, `22 research` between 0 and 1, and
`23 spike` between 1 and 2.

Run steps one at a time with `/devagent:next` (which advances to the next
unmarked step), chain them with `/devagent:next --auto`, or invoke any step
command directly.

## Step table

Rows in execution order.

| #  | Command | Phase | Purpose |
|----|---------|-------|---------|
| 0  | `pull` | Plan | Fetch the issue and scaffold its workflow directory |
| 22 | `research` | Plan | _(optional, off by default)_ Measure code/docs/upstream before drafting; record cited findings and open unknowns |
| 1  | `draft` | Plan | Draft the implementation plan |
| 23 | `spike` | Plan | _(optional, off by default)_ Run the plan's load-bearing bets in a throwaway worktree; record verdicts |
| 2  | `scope` | Plan | Structured scope evaluation appended to the plan |
| 3  | `improve` | Plan | Fresh-context check for latent bugs, side effects, and ambiguities |
| 4  | `prune` | Plan | Move non-load-bearing items to the future-enhancements file |
| 5  | `tighten` | Plan | Final pre-implementation review: lock ordering, paths, and test plan |
| 6  | `branch` | Implement | Create the issue branch from the configured baseline |
| 7  | `implement` | Implement | Execute the plan task-by-task |
| 8  | `quality` | Implement | Review and tighten code quality on the branch |
| 9  | `document` | Implement | Record what was actually built versus planned |
| 10 | `commit` | Implement | Commit with DCO sign-off using the commit template |
| 11 | `analyze` | Implement | Run the project's analyzer family against the changed lines |
| 12 | `draftmr` | Ship | Draft the merge-request body |
| 13 | `review` | Ship | Run code review on the branch |
| 14 | `redmr` | Ship | Red-team adversarial review of the MR before shipping |
| 21 | `preship` | Ship | Fresh-context verification that the committed branch satisfies the acceptance criteria |
| 15 | `ship` | Ship | Push the branch and open the MR |
| 16 | `mergetoall` | Integrate & close | Squash-merge the branch into the local all-PRs branch |
| 17 | `updatewbs` | Integrate & close | Update the work-breakdown structure |
| 18 | `impact` | Integrate & close | Measure and record the real-world impact of the merged change |
| 19 | `lessonslearned` | Integrate & close | Extract reusable lessons from the completed issue |
| 20 | `cleanup` | Integrate & close | Restore the tree, commit the devdoc, clear the active issue |

## Checklist glyphs

Every issue's `checklist.md` tracks step state with this key:

```
State key: [ ] pending  [x] done  [-] skipped  [!] stuck  [~] in-progress  [?] blocked-external  [P] parked
```

## The revision loop

- `/devagent:revise` opens a new revision pass: it pulls reviewer feedback
  via `/devagent:comments` and re-runs the workflow from the draft step —
  the revision's first pending step.
- `/devagent:stuck` marks the current step stuck with a reason;
  `/devagent:unstuck` clears it and resumes.
- `/devagent:where` and `/devagent:catchup` rehydrate an issue's state at
  any point — the current step, the artifacts so far, and what comes next.

[← devAgent onboarding](./index.md)
