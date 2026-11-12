# Epic: Run issues from files on disk

## Outcome
A person can run devagent's whole workflow on a real issue with no GitHub account, no forge (a code-hosting service such as GitHub or GitLab) and no tracker. The issues are plain files in a folder, and the code is merged by local git.

- **The folder is the tracker.** A project sets `backend = "disk"` under `[project.<name>.issue_source]`. Each issue is one file, `<devdoc>/issues/<N>.md`.
- **The file starts as plain text and grows.**
  - The smallest valid issue is a title line followed by prose.
  - devagent adds only what it needs: a few `key: value` lines under the title (`state:`, `status:`, `parent:`, `labels:`, later `github:`), and an optional `## Prompt` and `## Comments` section.
  - It is Markdown, never JSON, so a person can read and edit it.
- **The checklist does not change.** `pull` writes `<devdoc>/Issue-<N>/issue.md` (devdoc is the project's notes folder) in the same shape as for a fetched GitHub issue, and the 25-step checklist is unchanged. Some step scripts and libraries gain a local path, each in the child that owns it, for example: ship, mergemr, the branch step's baseline, the CI line, the stage transitions, init, doctor, `/devagent:file` and the WBS (work breakdown structure) import. The `Issue-` folder prefix stays, because the pothole register (devagent's list of known workflow hazards, which cites issues as `Issue-N`) requires it.
- **Shipping without a forge.** A matching code backend, `local`, keeps all code work on the machine:
  - "ship" records the branch in a local merge request (MR) record, and the MR body stays in the issue folder;
  - "mergemr" squash-merges (folds the branch into one commit) into the default branch locally when `merge_mr` is true, and otherwise waits `[?]` as it does today;
  - steps about CI and pushing say "not applicable".
- **Waiting.** `[?]` is the checklist's "waiting" mark; `[!]` is "stuck".
- **One backend at a time.** A project uses one issue backend at a time, never a mix. A later converter publishes a disk project to GitHub, or imports a GitHub project to disk. Each run switches the project's backend; nothing is kept in sync.

**Why this is not a project-management tool.** devagent's requirements say it is not one (CON-1). The folder is a stand-in tracker for a first rung (the first step of a learning ladder, before a newcomer needs a forge): no boards, no assignment, no search, no notifications. A project that needs those graduates to a real tracker with the converter.

Here is a minimal issue file, then the same file after the issue merged. The person added `parent: 3` by hand to group it under issue 3; devagent wrote the rest:

```text
Add a dark-mode toggle to the settings page

The settings page should have a switch that flips the site between light and dark.
Done when the choice survives a page reload.
```

```text
# Add a dark-mode toggle to the settings page
state: closed
status: Done
parent: 3

## Prompt
The settings page should have a switch that flips the site between light and dark.
Done when the choice survives a page reload.

## Comments
- 2026-11-10 on_draft_start: status In Progress
- 2026-11-10 on_ship: status In Review
- 2026-11-11 on_merge: status Done, closed
```

## Why now
devagent's first rung needs all of these before a newcomer sees one issue done:
- a GitHub account;
- a repository;
- labels;
- `gh auth login`.

That is a large up-front cost.

Every built-in backend today talks to a remote service (GitHub, GitLab, Jira). The backend contract in `scripts/issue/custom.sh` and `scripts/code/custom.sh` is narrow enough that a file-backed tracker and a git-only code backend fit behind it.

Three sibling epics build on it:
- **Starter mode (#988)** writes a starter profile that uses the disk issue backend and the local code backend. It needs the first six children; its end-to-end case (#993) extends this epic's end-to-end test.
- **Windows via Git Bash (#983)** adds a Windows CI job (#987) that runs one disk issue end to end. It needs the first six children.
- **devagent website 2.0 (#994)** has a "Your first issue" page that is only true once this epic's first six children and starter mode ship.

## Departures from the approved design
- **The code backend is named `local`.** The design left the name open between `disk` and `local`. The backend is about where the code merges, not where the issues live.
- **The disk backend also answers `state-class`.** The merge step's dependency check reads it.
- **Numbers are never reused.** The design says `create` takes the highest existing N plus 1. The disk backend also remembers the highest number it ever issued, so deleting the top file never hands its number (and its old `Issue-<N>/` folder) to a new issue.
- **Import keeps GitHub numbers.** The design does not say which numbers imported issues get. They keep their GitHub numbers, so existing `Issue-<N>/` folders and WBS lines still match.
- **`push_mr` does not gate local writes.** devagent's requirements make `push_mr` gate ship and file (CON-6, CON-9), because those write outward. `/devagent:file` skips it for the disk issue backend, and ship skips it for the local code backend, because nothing leaves the machine. A disk tracker with a GitHub code backend still asks at ship. CON-6 and CON-9 are updated in the children that make the change.
- **Trust policies fail closed.** A trust policy's scope is matched against a tracker repo, and a disk folder never matches one. So today a policy would silently not cover a disk project. The disk issue backend child makes this explicit: with a trust policy on the host, every entry point of a disk project refuses, publish and import included. The local code backend child makes every entry point of a local project that a policy covers refuse. A folder that several people write to should graduate to GitHub first.
- **Publishing refuses parked issues.** The design allowed a parked issue at publish time. A parked disk issue resumed afterwards would send its transitions to the GitHub issue with the same number, which is a different issue.
- **Publishing moves finished history.** The design kept finished disk issues under their `Issue-<N>/` folders and said no migration is owed. After the switch, `pull` of a new GitHub issue N would land in a finished disk issue's folder. So publish renames those folders to a name outside the `Issue-` pattern, and rewrites the WBS lines, dependency records and state entries that name disk issues. This is a one-time move at graduation, not a format migration: the file format never changes, and publish only adds `github:` lines and closes finished files through the normal writer.
  - Known residual: text citations of a disk `Issue-<N>` in the pothole register or in lessons files are left as written. After publishing they read as GitHub issue N, so they are provenance only.

## Estimated children (rough)
1. **Read and write the disk issue file format.** One parser and one writer shared by every caller, plus a format reference page. No dependencies.
2. **Add the disk issue backend.** `scripts/issue/disk.sh` with the required verbs, the list verbs and `state-class`. The read-only trust verbs answer "unsupported". It also teaches `wbs init --from-tracker` and `/devagent:file` the disk issue reference. Depends on 1.
3. **Add the local code backend and ship without a forge.** `scripts/code/local.sh`. `ship` records the branch with no push and no `push_mr` prompt, and the CI line says "not applicable". Independent of 1 and 2.
4. **Squash-merge locally at mergemr.** The merge step's local path when `merge_mr` is true. Depends on 3.
5. **Set up and check disk projects in init and doctor.** Depends on 2 and 3.
6. **Test a disk project end to end.** A new test driver runs one disk issue, completing the model steps with fixtures (scripted stand-ins), from `init` to `cleanup` in a scratch repo, with every network command stubbed. Depends on 2 to 5.
7. **Document issues on disk.** The README section for newcomers, a commented config example and the site's configuration page. Depends on 1 to 6. Each behaviour child updates its own spec section and `docs/requirements.md` entries in its own PR, as CON-25 requires.
8. **Publish a disk project to GitHub** (later). The graduation. It requires the code to move to GitHub first, because a local merge never closes a GitHub issue. Depends on 1, 2 and 7.
9. **Import a GitHub project to disk** (later). It reuses publish's mid-workflow check and config editor. Depends on 1, 2, 7 and 8.

## Acceptance criteria
- [ ] All nine children are filed and tracked under this epic. The epic closes when all nine are merged. The sibling epics depend on children 1 to 6 only, not on the epic closing.
- [ ] **Demo (child 6's test, run in CI).**
  - **Setup.**
    - A scratch source repo with one commit on `main` and no remotes.
    - A scratch devdoc folder that is its own git repo, separate from the source repo.
    - `init` with the disk issue backend and the local code backend.
    - `transition_issue`, `merge_mr` and `commit_devdoc` are `true`; `push_mr` is `false`.
  - **Stubs.** `gh` and git's network commands (`push`, `fetch`, `pull`, `ls-remote`, `clone`) are replaced by stubs that leave a marker and fail the test if called.
  - **Run.** One disk issue is created and pulled. A new test driver then runs `next --auto` repeatedly and completes each model step from a fixture. No such driver exists today (#826); child 6 builds it, and #752's two-lane test may share it.
  - **End state.**
    - `main` has exactly one new squash commit.
    - The issue file reads `state: closed` with the mapped done status.
    - The devdoc repo has cleanup's commit.
    - No stub marker exists.
- [ ] **Epics from files.** A folder of three parent files and fifteen child files with `parent:` lines produces, through `wbs init --from-tracker`, a WBS of three epics with five leaves each.
- [ ] **Contract.** `tests/backend-contract.bats` runs the disk issue backend's and the local code backend's own contract suites. Its "every issue backend" checks count five backends.

## Out of scope
- **Starter mode** itself (#988): the `starter` checklist tier, the "new to devagent?" question in `init`, its permission profile and the newcomer end-to-end case (#993).
- **The website page** that teaches this ("Your first issue"). That belongs to the website 2.0 epic (#994).
- **The Windows CI job** (#987, in the Windows via Git Bash epic #983).
- **Trust policy support** for disk projects. The disk backend's trust verbs (`events`, `comment-records`, `whoami`) report "unsupported" (exit 78), and a host with a trust policy refuses disk projects outright (see Departures).
- **Mixing backends** in one project, or keeping the folder and GitHub in sync.
- A JSON or database store for issues.
- **Reserved names.** A custom backend someone already wrote as `scripts/issue/disk.sh` or `scripts/code/local.sh` is replaced by the built-in one. The `CHANGELOG.md` line saying so ships in the same PR as each backend (children 2 and 3), so no release can replace one without notice.

## Source
Design approved 2026-11-09 in the maintainer's design notes (section 6, "Issues on disk"). Every decision this epic depends on is restated above.
