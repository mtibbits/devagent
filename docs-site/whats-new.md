<!-- derived-from: CHANGELOG.md -->
# What's new

devagent is under active development. This page lists what it has gained
since its first release, 1.0.0, and where it is heading next. The full record
is the [changelog](../CHANGELOG.md).

## Shipped since 1.0

Each item links the first published release that has it.

### Plan from your tracker

- **Work breakdown built from the tracker.** devagent can build a project's
  work breakdown from the issues and epics already on its tracker.
  [Release 3.0.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.0.0)
- **Portfolio view across projects.** One command writes a single document
  covering every project you have configured, and can list the work that is
  ready to start.
  [Release 3.0.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.0.0)
- **Dependencies that cross projects.** A task in one project's work breakdown
  can name an issue in another of your projects, and the portfolio's ready
  list waits for it.
  [Release 3.0.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.0.0)
- **Keeping an issue out of the work breakdown.** One command records that an
  issue stays out of a project's work breakdown, so rebuilding it from the
  tracker no longer brings the issue back.
  [Release 3.4.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.4.0)

### Ship on evidence

- **Evidence attested across environments.** A test run made in one
  environment and checked from another counts only with an attestation of the
  exact tree it ran on.
  [Release 3.0.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.0.0)
- **Evidence stamps in the merge request body.** The test totals in a merge
  request are copied from the recorded test run, and its changed-file count
  from the branch, not typed by hand.
  [Release 3.0.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.0.0)
- **Claims and evidence checked before the verifier runs.** Before the final
  check, devagent stops early when the test evidence fails, and corrects merge
  request counts that do not match the branch.
  [Release 3.2.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.2.0)
- **Merging the pull request as its own step.** When you allow it, devagent
  merges a GitHub pull request itself once its checks pass; otherwise, and on
  other forges, it waits for you to merge.
  [Release 3.0.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.0.0)

### Trust

- **A trust policy baseline for shared queues.** A policy file kept outside
  devagent's reach names the repositories it covers and the accounts devagent
  may work them as. In those repositories devagent refuses to run as any other
  account, and it fails closed on a defective policy.
  [Release 3.0.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.0.0)

### Start small

- **Issues kept as files on disk.** Issues can be plain files in a folder, with
  no account and no network.
  [Release 3.1.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.1.0)
- **A starter checklist.** A shorter checklist, chosen per issue, for a
  newcomer's first issues: it keeps the plan, review and final check and drops
  the longer planning steps.
  [Release 3.1.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.1.0)
- **A local code backend, no forge needed.** devagent can take a change through
  ship with no forge and no push: it records the merge request locally and
  notices when you merge the branch yourself.
  [Release 3.2.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.2.0)

### Several machines

- **Shared records kept in step across machines.** When an issue closes,
  devagent merges and pushes the records your machines share, so they stay in
  step, and the status view counts any records not yet pushed.
  [Release 3.4.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.4.0)

### Cost and rules

- **Token cost per issue and step.** A report shows what each issue, and each
  step of it, cost in tokens.
  [Release 3.0.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.0.0)
- **Breaks for a fresh session on long runs.** A long automatic run pauses at a
  few set points, so you can clear the session and carry on with a smaller
  context.
  [Release 3.0.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.0.0)
- **Close-out without a break once the pull request is merged.** After the
  merge, an automatic run carries straight on through the closing steps
  instead of pausing for a fresh session.
  [Release 3.3.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.3.0)
- **devagent's own written requirements.** devagent's requirements are written
  down in the repository, so work can be traced to them.
  [Release 3.1.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.1.0)
- **Model-tier proposals when an issue is captured.** When a captured issue
  argues for a different model than the project's default, devagent writes
  that proposal down with the draft.
  [Release 3.2.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.2.0)

## What's next

These are directions, not promises.

- **Safer shared queues.** Coming: screening of an issue's text before it can
  steer devagent, and limits on what it can make devagent write or push.
- **Fewer stops on long runs.** Coming: standing answers for the questions that
  keep recurring, so an unattended run can hold, tell you, and carry on.
- **Forecasts you can score.** Coming: estimates compared with what the work
  really cost, and completion forecasts for a project.
- **Parallel lanes.** Coming: one command to give a second issue of the same
  project its own worktree and session, with every step working in that tree.
- **PowerShell projects.** Coming: first-class analysis for PowerShell code.
- **Issues that carry their own plan.** Coming: on trackers you opt in, the
  issue becomes the one place its dependencies, parent, estimate and model
  tiers are kept, and the work breakdown copies them from there.
- **Work across your machines.** Coming: one command to start a background
  session on an issue on any of your machines, and one table of every
  session, flagging the ones that are waiting on you.
- **One issue, several small merge requests.** Coming: the plan splits a large
  issue into slices that each land as their own reviewable merge request,
  while the design and close-out happen once.

Roadmap last checked against the open epics on 2026-11-19.
