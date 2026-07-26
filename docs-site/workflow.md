<!-- derived-from: README.md docs/specs/2026-05-19-devagent-plugin-design.md templates/checklist-standard.md -->
# Workflow reference

## Numbering

Steps are numbered 0–23 in execution order — 24 numbered step commands in
all, and the checklist reads top-to-bottom. Two of them (`1 research`,
`3 spike`) are optional and off by default, so a normal issue runs the 22
mandatory steps and its checklist shows two gaps. Reduced checklist tiers
show a monotonic subset with larger gaps.

Run steps one at a time with `/devagent:next` (which advances to the next
unmarked step), chain them with `/devagent:next --auto`, or invoke any step
command directly.

## Step table

Rows in execution order.

| #  | Command | Phase | Purpose |
|----|---------|-------|---------|
| 0  | `pull` | Plan | Fetch the issue and scaffold its workflow directory |
| 1  | `research` | Plan | _(optional, off by default)_ Measure code/docs/upstream before drafting; record cited findings and open unknowns |
| 2  | `draft` | Plan | Draft the implementation plan |
| 3  | `spike` | Plan | _(optional, off by default)_ Run the plan's load-bearing bets in a throwaway worktree; record verdicts |
| 4  | `scope` | Plan | Structured scope evaluation appended to the plan |
| 5  | `improve` | Plan | Fresh-context check for latent bugs, side effects, and ambiguities |
| 6  | `prune` | Plan | Move non-load-bearing items to the future-enhancements file |
| 7  | `tighten` | Plan | Final pre-implementation review: lock ordering, paths, and test plan |
| 8  | `branch` | Implement | Create the issue branch from the configured baseline |
| 9  | `implement` | Implement | Execute the plan task-by-task |
| 10 | `quality` | Implement | Review and tighten code quality on the branch |
| 11 | `document` | Implement | Record what was actually built versus planned |
| 12 | `commit` | Implement | Commit with DCO sign-off using the commit template |
| 13 | `analyze` | Implement | Run the project's analyzer family against the changed lines |
| 14 | `draftmr` | Ship | Draft the merge-request body |
| 15 | `review` | Ship | Run code review on the branch |
| 16 | `redmr` | Ship | Red-team adversarial review of the MR before shipping |
| 17 | `preship` | Ship | Fresh-context verification that the committed branch satisfies the acceptance criteria |
| 18 | `ship` | Ship | Push the branch and open the MR |
| 19 | `mergetoall` | Integrate & close | Squash-merge the branch into the local all-PRs branch |
| 20 | `updatewbs` | Integrate & close | Update the work-breakdown structure |
| 21 | `impact` | Integrate & close | Measure and record the real-world impact of the merged change |
| 22 | `lessonslearned` | Integrate & close | Extract reusable lessons from the completed issue |
| 23 | `cleanup` | Integrate & close | Restore the tree, commit the devdoc, clear the active issue |

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
