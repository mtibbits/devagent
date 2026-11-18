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
- **Dependencies that cross projects.** A task can depend on an issue in
  another of your projects.
  [Release 3.1.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.1.0)

### Ship on evidence

- **Evidence attested across environments.** A test run made in one
  environment and checked from another counts only with an attestation of the
  exact tree it ran on.
  [Release 3.0.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.0.0)
- **Evidence stamps in the merge request body.** The test counts and file
  counts in a merge request are written from the recorded run, not typed by
  hand.
  [Release 3.0.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.0.0)
- **Claims and evidence checked before the verifier runs.** The last check
  before shipping now refuses early when the evidence or the merge request's
  claims do not hold.
  [Release 3.2.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.2.0)
- **Merging the pull request as its own step.** When you allow it, devagent
  merges the pull request itself once it is ready, and otherwise waits for you.
  [Release 3.0.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.0.0)

### Trust

- **A trust policy baseline for shared queues.** A machine-wide policy says
  which repositories and which people devagent will take work from, and
  devagent refuses anything else.
  [Release 3.0.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.0.0)

### Start small

- **Issues kept as files on disk.** Issues can be plain files in a folder, with
  no account and no network.
  [Release 3.1.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.1.0)
- **A starter checklist.** A shorter checklist for small changes and for
  people new to devagent.
  [Release 3.1.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.1.0)
- **A local code backend, no forge needed.** devagent can take a change through
  ship with no forge and no push: it records the merge request locally and
  notices when you merge the branch yourself.
  [Release 3.2.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.2.0)

### Cost and rules

- **Token cost per issue and step.** A report shows what each issue, and each
  step of it, cost in tokens.
  [Release 3.0.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.0.0)
- **A fresh session at each phase break.** A long automatic run stops between
  phases, so each phase starts with a fresh, smaller context.
  [Release 3.0.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.0.0)
- **devagent's own written requirements.** devagent's requirements are written
  down in the repository, so work can be traced to them.
  [Release 3.1.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.1.0)
- **Model-tier proposals when an issue is captured.** When a captured issue
  argues for a different model than the project's default, devagent writes
  that proposal down with the draft.
  [Release 3.2.0](https://github.com/mtibbits/devagent/releases/tag/devagent--v3.2.0)

## What's next

These are directions, not promises.

- **Safer shared queues.** Coming: checks on what an issue's text can make
  devagent write, push or merge, and a way to set a suspect issue aside.
- **Fewer stops on long runs.** Coming: standing answers for the questions that
  keep recurring, so an unattended run can hold, tell you, and carry on.
- **Forecasts you can score.** Coming: estimates compared with what the work
  really cost, and completion forecasts for a project.
- **Parallel lanes.** Coming: two issues of one project in flight at once.
- **PowerShell projects.** Coming: first-class analysis for PowerShell code.
- **Issues that carry their own plan.** Coming: dependencies, parents,
  estimates and model tiers kept on the issue itself and read from there.

Roadmap last checked against the open epics on 2026-11-17.
