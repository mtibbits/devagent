# devagent requirements

devagent's own requirements, in the format of Gantry's
[requirements-format.md](https://github.com/mtibbits/gantry/blob/main/docs/requirements-format.md),
in namespace `devagent`. A bare ID here means `devagent:<ID>`.

Source of truth: this file was derived once from devagent's README and docs
site, the design spec, the v1 build plans, the contract docs, the command,
skill and agent docs, CONTRIBUTING, SECURITY and the CHANGELOG, the open
epics, and the maintainer's private planning notes. From now on it changes
with the code, in the same pull request as the change it describes. It is not
re-derived from those sources, and the sources are not updated from it.

IDs are never renumbered or reused. A withdrawn requirement is deleted, and
its withdrawal is recorded in a prose line in its section.

`tests/test_own_requirements.py` reads this file. Keep every requirement a
top-level `- ID: text` item, add no HTML comment, and write no ID-shaped list
item anywhere else, not even inside a fenced block.

The file holds every layer but business requirements, and no ID in another
namespace. Business requirements live in the operator's private portfolio
file. Links to other projects' requirements are left to Gantry's
cross-project trace ([mtibbits/gantry#21](https://github.com/mtibbits/gantry/issues/21)).

Workflow steps are named here by name, never by their position in the
checklist: positions change when steps are added. A requirement that is not
yet delivered says so: it sits under a "Planned" heading, starts with
"(Planned.)", or is marked "(planned)".

## Terms

- **operator:** the person running devagent on their projects.
- **project:** a repository devagent works on, named by a
  `[project.<name>]` table in devagent's config.
- **issue dir:** the per-issue directory in a project's devdoc tree that
  holds the issue's checklist, plan, analysis records and notes.
- **checklist:** the issue dir's `checklist.md`, one row per workflow step,
  each with a state glyph.
- **capture:** a draft issue or epic in a project's `Captures/` directory,
  red-teamed and filed later.
- **WBS:** a project's `WBS.md`, its work breakdown as a tree of epics and
  issues.
- **portfolio JSON:** devagent's versioned JSON of every configured
  project's plan, gathered from their `WBS.md` files.
- **trust policy:** the host-level `policy.toml` that says which issue
  authors and sources devagent may act on without the operator.
- **permission gate:** a config switch that must be on before devagent takes
  an outward-facing action, such as pushing, opening or merging a pull
  request, or posting to a tracker.
- **autonomous caller:** a program, not a person, that runs devagent's
  workflow without an operator watching, for example a worker draining a
  shared queue.
- **installation:** one private copy of Gantry
  ([mtibbits/gantry](https://github.com/mtibbits/gantry)), the planning tool
  that reads devagent's `WBS.md` files and requirements files.
- **site:** one project in a Gantry installation, named by its devagent
  `[project.<name>]` table.
- **requirements file:** a project's Markdown file of requirements with
  stable IDs, in Gantry's format.
- **qualified ID:** an ID with its namespace, `<namespace>:<code>-<n>`, for
  example `devagent:FR-12`.
- **leaf:** a `WBS.md` line with no children, usually one tracker issue;
  **open leaf:** one that is neither done (`[x]`) nor not planned (`[-]`).
- **trace:** the links from leaves up to the requirements they serve,
  written as a `satisfies:` meta key on the leaf; **in the trace:** a site
  whose `requirements` path is set in the installation config.

## Business rules

None yet.

## Use cases

Each use case gives a starting state, what the operator (or an autonomous
caller) does, and an end state that can be seen on disk, in git or in the
tracker.

- UC-1: File an idea as an issue. The operator has an idea for a configured
  project and no tracker issue for it. They capture it, red-team the draft and
  file it. The capture directory holds the draft, its red-team report and a
  filed record naming the new tracker issue, which exists on the tracker.
  {needs: [FR-77, FR-79, FR-80, FR-63, EI-1, EI-8]}
- UC-2: File an epic with its children in one pass. The operator has
  discussed a topic big enough for an epic. They run the one-pass capture,
  red-team, revise and file command on it. The tracker holds the epic and one
  issue per child, each child names the epic, and the capture directory holds
  every red-team round and a manifest of each capture's outcome; or the run
  stops before filing and says why.
  {needs: [FR-77, FR-78, FR-79, FR-80, FR-81, FR-86, CON-9]}
- UC-3: Take an issue from the tracker to a merged change, step by step. A
  tracker issue exists and no issue is active in its project. The operator
  pulls it and runs each workflow step in turn, answering the question at the
  end of each. The issue's branch is merged, the tracker issue has moved
  through its configured stages, the issue dir holds the plan, the MR body and
  every check's report, the checklist shows every step done or skipped, and
  the project has no active issue.
  {needs: [FR-1, FR-4, FR-6, FR-17, FR-20, FR-25, FR-28, FR-31, FR-33, FR-35, FR-38, FR-40, FR-44, FR-46, FR-51, EI-1, EI-2, EI-3, EI-7]}
- UC-4: Run an issue unattended from pull to cleanup. The operator has pulled
  an issue and wants no questions between steps. They run the next step with
  `--auto`. The chain runs every step it can without asking, and ends at
  cleanup with the issue closed out; at a configured phase break, printing
  the command that resumes it in a fresh session; or at a step that is
  stuck, waiting or gated, with the reason on screen and in the checklist.
  {needs: [FR-5, FR-42, FR-44, FR-93, FR-86, QA-2, QA-3]}
- UC-5: Recover a stuck step. A step failed and the checklist marks it stuck,
  with a STUCK file giving the reason. The operator reads the reason, fixes
  the cause and clears the stuck mark. The STUCK file is gone, the step is
  pending or in progress again, and the next run continues from it.
  {needs: [FR-7, FR-55, FR-4]}
- UC-6: Park an issue, work on another, and resume the first in a fresh
  session. An issue is active and part way through its checklist. The
  operator parks it (or switches to another issue), works elsewhere, and
  later, in a new session, resumes it. The parked issue's checklist row reads
  parked while it waits, and on resume the issue is active again at the step
  it stopped at, with its saved context restored and nothing lost.
  {needs: [FR-52, FR-53, FR-54, FR-55, FR-57, QA-1]}
- UC-7: Answer review feedback with a revision pass. A shipped MR has
  reviewer comments. The operator fetches the comments and starts a revision
  pass. The issue dir holds the comments under the new revision, the
  checklist has a new revision block whose steps run again from draft, earlier
  blocks and the log are kept, and the MR gets the new commits.
  {needs: [FR-59, FR-60, FR-61, FR-38, FR-40]}
- UC-8: Keep the work breakdown and status report current. A project has a
  `WBS.md` and work has moved on the tracker. The operator updates the work
  breakdown and writes a status report. Every leaf's glyph matches its
  tracker issue, children are in dependency order, the lines the update does
  not own are byte-for-byte unchanged, and a dated status report covers the
  time since the last one.
  {needs: [FR-65, FR-66, FR-67, FR-70, FR-107, QA-17, EI-9, EI-17]}
- UC-9: Publish the portfolio across projects. Several projects are
  configured, each with a `WBS.md`. The operator writes the portfolio
  document, or lists the ready leaves. One JSON document, owner-only and
  outside every devdoc and source tree, describes every project's plan and
  everything that could not be read; or the ready list prints one line per
  ready leaf and writes nothing.
  {needs: [FR-71, FR-72, FR-73, FR-74, EI-10, QA-24, QA-27]}
- UC-10: Harvest follow-ups from finished work. Finished issues left
  deferred plan items, follow-ups and actionable lessons. The operator runs
  the harvest and keeps or discards each candidate. Each kept candidate is a
  new capture citing the file and line it came from, the discards are
  recorded, and a second run drafts nothing new.
  {needs: [FR-75, FR-76, FR-22, FR-27, FR-49, EI-8]}
- UC-11: Set up and check an installation. devagent is installed and a
  project is not yet configured. The operator adds the project, stores its
  tracker and forge credentials and runs the health check. The config has
  the project's table, the credentials sit in owner-only files, and the
  health check reports every check passed, or names each one that failed.
  {needs: [FR-83, FR-84, FR-85, EI-5, EI-13, QA-22]}
- UC-12: Work a shared queue with nobody present. An autonomous caller polls
  a tracker queue that other people write to, on a host with a trust policy
  and permission gates. It pulls the next ready ticket and chains the
  workflow. Work runs only on tickets the policy admits; each outward action
  happens only when its gate is open; and every stop leaves a checklist state
  and an exit code that tell the caller whether to retry, skip the ticket or
  call a person.
  {needs: [FR-86, FR-87, FR-88, FR-89, FR-90, FR-91, FR-93, FR-96, FR-98, FR-74, EI-11, EI-20, CON-13, CON-14]}
- UC-13: Run sessions on two projects at once. The operator has two
  projects with active issues. They pin one session to each project and work
  both at the same time. Each session reads and writes only its own project's
  state and issue, a command that names no project and runs from the other
  project's tree is refused and names both projects, and neither session
  moves the other's pointer.
  {needs: [FR-58, FR-94, QA-8, QA-9, EI-19]}

## System requirements

- SR-1: devagent takes each issue through a fixed sequence of named workflow
  steps, from pull to cleanup, and tracks every step in the issue's
  checklist.
- SR-2: devagent keeps all workflow state on disk, so a later session, a
  scheduled job or another program can read it and carry on where the last
  one stopped.
- SR-3: devagent scripts the mechanical work (fetching, branching,
  committing, pushing, analysis) and uses the model only where a step needs
  judgment.
- SR-4: devagent leaves each issue's progress as an auditable trail in one
  per-issue directory.
- SR-5: devagent serves several projects from one installation, with at
  most one active issue per project, and (planned) always acts on the
  project the operator or the chain meant.
- SR-6: devagent works against more than one issue tracker and code forge
  through one backend contract, and chooses a project's tracker and forge
  separately.
- SR-7: devagent turns an idea into a filed tracker issue, or an epic with
  child issues, through a capture, red-team and file pipeline.
- SR-8: devagent answers review feedback with a new revision pass of the
  same issue and keeps the earlier passes.
- SR-9: devagent keeps each project's work breakdown and status report
  current from the tracker, the code forge and the checklists, as a
  by-product of the workflow.
- SR-10: devagent describes every configured project's plan in one
  versioned, machine-readable document that other tools read.
- SR-11: devagent harvests follow-up work recorded in finished issues back
  into captures.
- SR-12: devagent sets up projects, stores their credentials and checks the
  installation's health from one global config.
- SR-13: devagent lets an autonomous caller work a shared issue queue with
  every outward action behind a permission gate and, when the host has one,
  a trust policy, and (planned) no ticket text it has not screened steers
  the workflow.
- SR-14: devagent keeps configuration apart from artifact templates, and
  resolves each template from layered overrides so a new project needs none
  of its own.
- SR-15: devagent runs its checking steps (improve, review, redmr and
  preship) in a fresh context that reads the issue's artifacts from disk, not
  the author's conversation.
- SR-16: devagent learns from finished issues: it records tagged lessons and
  a layered pothole register that later plans and checks read.
- SR-17: devagent backs some workflow rules with opt-in Claude Code hooks.
- SR-18: devagent's evidence can be taken at face value: a suite artifact
  records the tree, head, branch and environment it measured in the issue's
  own directory, and (planned) every other evidence artifact does too.
- SR-19: devagent measures what each issue actually cost in tokens and
  time, and (planned) calibrates estimates against those actuals and
  forecasts completion from them.
- SR-20: (Planned.) devagent runs two or more issues of one project at once, each in
  its own worktree and session, and no issue measures or commits another's
  work.
- SR-21: (Planned.) devagent asks the operator only questions whose answer is not
  already settled, and asks them without blocking the rest of the work.
- SR-22: devagent gives a project in each supported language machine-checked
  lint and test-suite evidence.
- SR-23: devagent can be installed and learned from its public
  documentation.

## Functional requirements

### The workflow checklist

- FR-1: devagent's pull fetches a tracker issue and its comments from the
  origin or the fork into the issue dir's `issue.md`, scaffolds the issue dir
  and its checklist, and makes the issue the project's active issue. A
  re-pull keeps the existing checklist. {refines: SR-1}
- FR-2: devagent picks the steps an issue runs from a named tier: the issue
  body's workflow flags, else the project's default, else the standard tier.
  It reads workflow flags only from the issue body's `## Workflow flags`
  block, validates every value before use, and refuses an unknown tier,
  naming the legal ones. {refines: SR-1}
- FR-3: devagent records each step's state in the checklist as pending,
  done, skipped, stuck, in progress, waiting on something external, or
  parked. The checklist keeps one block per revision and one shared log,
  and a log entry is one timestamped line that is never rewritten.
  {refines: SR-4}
- FR-4: devagent's next runs the first step of the active revision block
  that is not done or skipped, halts at a stuck step, and offers to park the
  issue at a waiting one. {refines: SR-1}
- FR-5: With `--auto` devagent chains steps through cleanup, and with
  `--through <step>` through the named step. A chain stops at a stuck or
  waiting step, at a step that exits non-zero, at a declined permission gate,
  and before each configured phase-break step, where it prints the command
  that resumes it in a fresh session. {refines: SR-1}
- FR-6: Outside a chain, a completed step marks its own row by name and asks
  the operator before the next step runs. {refines: SR-1}
- FR-7: devagent marks a step stuck with a reason in the issue's STUCK file
  and chains no further. Clearing it returns the row to in progress or
  pending, and removes the STUCK file only after the row has changed.
  {refines: SR-1}
- FR-8: A step whose prerequisite comes from a step absent from the issue's
  tier treats that prerequisite as not applicable instead of halting.
  {refines: SR-1}
- FR-9: An issue with no commits ahead of its baseline skips the commit,
  ship and mergetoall steps by itself; a baseline devagent cannot decide
  never causes a skip. {refines: SR-1}
- FR-10: devagent never skips a step that has work on its own: a skip needs
  the operator's confirmation and stays visible in the checklist.
  {refines: SR-1}
- FR-11: A project may supply its own checklist template; its steps run in
  file order, and the gating steps are found by name. {refines: SR-14}
- FR-12: devagent records that one issue depends on another, refuses a
  self-dependency or a cycle, and lists a project's dependency graph. Ship
  warns about unmerged dependencies, and refuses on request.
  {refines: SR-1}
- FR-13: Each command resolves its project, issue dir and free-form note
  from its arguments, defaulting to the active project and issue, and a
  chain passes the note to every step unchanged. {refines: SR-5}
- FR-14: devagent reads and sets checklist marks within the active revision
  block only, so an earlier revision's marks never satisfy a later
  revision's gate. {refines: SR-1}

### Planning an issue

- FR-15: The research step, when the issue flags it, records the questions,
  cited findings and open unknowns before drafting, and builds nothing.
  {refines: SR-1}
- FR-16: Before drafting, devagent re-derives the issue's named inputs at
  HEAD: whether the checkout is behind its base, which named files exist, and
  what changed since the issue was filed. {refines: SR-1}
- FR-17: The draft step writes the implementation plan `imPlan.md`, with
  preconditions that dispose of every stale input, declared load-bearing
  unknowns, the matching potholes and any pending reviewer feedback, and
  records the issue's type and short title for the branch and commit.
  {refines: SR-1}
- FR-18: When a thinking-class model tier is configured, devagent hands the
  operator's intent to a dispatched planner through `intent.md`, answers its
  open questions for a bounded number of rounds, and otherwise drafts inline.
  {refines: SR-1}
- FR-19: The spike step, when the issue flags it, runs each load-bearing
  unknown in a throwaway worktree, records a verified, falsified or
  inconclusive verdict with evidence, and always removes the worktree. A
  falsified core bet sends the issue back to drafting. {refines: SR-1}
- FR-20: The scope step appends a scope evaluation to the plan (in and out
  of scope, size, ambiguities, preconditions, success criteria) and proposes
  a split when the size or the ambiguity count is too large.
  {refines: SR-1}
- FR-21: The improve step checks the plan in a fresh context for latent
  bugs, side effects, ambiguities and missed potholes, saves the report as
  written, and appends each finding to the plan tagged merge, defer or
  dismiss. {refines: SR-15}
- FR-22: The prune step moves deferred and off-scope items from the plan to
  a future-enhancements file with their source, and refuses to prune the plan
  to no tasks. {refines: SR-1}
- FR-23: The tighten step puts the plan's tasks in dependency order with
  exact file paths and a test plan each, adds a Definition of done that maps
  every success criterion to a task, and halts on a task cycle.
  {refines: SR-1}

### Building the change

- FR-24: The branch step cuts the issue branch from the project's baseline,
  or from a per-issue baseline override, with a prefix from the issue's
  type, and fails without a branch when an override does not resolve.
  {refines: SR-3}
- FR-25: The implement step executes the plan task by task, with one
  signed-off commit per task, and leaves no uncommitted work.
  {refines: SR-1}
- FR-26: The quality step runs a simplification pass and a coding-standards
  pass over the changed code and commits any fixes as their own commit.
  {refines: SR-1}
- FR-27: The document step records the work actually done against the plan,
  task by task, tersely when nothing deviated, with follow-ups last.
  {refines: SR-4}
- FR-28: The commit step builds the message from the resolved commit
  template and always signs the commit off. It succeeds without a new commit
  when per-task commits hold all the work, fails on a dirty tree with nothing
  staged, and strips `Co-Authored-By:` lines for a project that turns
  co-author lines off. {refines: SR-3}
- FR-29: With scoped auto-staging on, the commit step stages only the files
  the issue declares, and never guesses. {refines: SR-3}
- FR-30: With the born-red check on, each new test must fail at the
  baseline, and the commit step refuses when the born-red record is missing,
  flags a test that passed at the baseline, or covers a different set of
  tests. {refines: SR-18}
- FR-31: The analyze step runs the project's analyzer family over the
  changed lines against the baseline and over new untracked source files
  whole, writes the output under the issue's analysis directory, and reports
  new findings without failing on them. {refines: SR-3}
- FR-32: The analyze step fails, and stays unmarked, when an analyzer or a
  sanitizer leg fails, is truncated or overruns its time budget; it never
  records such a run as zero findings. It names each tool's version in its
  output, and skips itself with a logged reason for a project whose analyzer
  family is none. {refines: SR-18}

### Checking and shipping

- FR-33: The draftmr step writes the MR body from the MR template, and a
  script stamps its evidence block (suite, files, platform) from a fresh
  test-suite record; it refuses to stamp evidence that does not describe
  HEAD. {refines: SR-18}
- FR-34: The review step runs a code review of the branch diff in a fresh
  context and saves the report under a header naming its context and model.
  {refines: SR-15}
- FR-35: The redmr step red-teams the MR body and diff in a fresh context,
  saves the report as written, and does not advance while a blocking finding
  is open. {refines: SR-15}
- FR-36: Fixes made for review or red-team findings are new signed-off
  commits, and the evidence block is stamped again after any such commit.
  {refines: SR-18}
- FR-37: devagent runs the improve, redmr and preship checks as bound agents
  that cannot write files and return their report for devagent to save. It
  heads each checking step's report with its provenance (subagent or inline,
  and the model), rejects a garbled report, re-dispatches once, and then
  marks the step stuck.
  {refines: SR-15}
- FR-38: The preship step pins the branch head and checks in a fresh
  context that the committed branch meets every acceptance criterion,
  contains every blocking finding's fix, and carries a spec change for each
  spec-relevant surface it touches. A pass records the verified head; a
  failure marks the step stuck. {refines: SR-15}
- FR-39: Preship fails evidence from a platform the operator did not
  declare, a suite that could not be run, and an evidence block whose lines
  differ from the ones rebuilt from the newest record. {refines: SR-18}
- FR-40: The ship step refuses while preship is unfinished or tracked files
  are modified; otherwise it pushes the branch and opens the MR against the
  upstream or the fork, as a draft when the project or the issue asks.
  {refines: SR-1}
- FR-41: devagent resolves each step's model from the per-issue marker, then
  a per-step override, then the step class's tier, then the default tier,
  then the bound step's own default, else the session's model. A bad marker
  or two labels that steer one class to different models stop the step.
  {refines: SR-3}

### Integrating and closing

- FR-42: After ship, each run of next prints one line with the MR's CI
  result and never waits for CI. A failed, timed-out or unreadable CI read is
  never shown as green or as no checks, and the project's CI gate either
  reports, blocks every later step on CI that is not green, or is off.
  {refines: SR-1}
- FR-43: The mergetoall step squash-merges the issue branch into the
  project's local all-PRs branch. When an MR is recorded and the project's
  CI gate is not off, it proceeds only on green CI, or on no checks after a
  grace period, and only when the local branch is the head CI checked; red
  CI marks it stuck with the failing line.
  It does not close the PR. {refines: SR-1}
- FR-44: The mergemr step merges the PR only when the project's merge gate
  is exactly `true` and only at the head preship verified. Otherwise it marks
  its row waiting until the PR is merged elsewhere, decides from one read,
  never polls, and waits while a recorded dependency is unmerged.
  {refines: SR-1}
- FR-45: A squash merge carries the PR's closing references and its
  commits' sign-off and co-author lines. {refines: SR-1}
- FR-46: devagent moves the tracker issue to its configured stage when
  drafting starts, after ship opens the MR, and when the MR merges, once per
  revision. A failed transition warns and the step carries on, and devagent
  never creates a tracker label or status. {refines: SR-9}
- FR-47: The sync command finds shipped issues merged outside the session,
  fires the merge transition (logged only when it landed, so a failed one is
  retried), reopens the closeout steps waiting on the merge and prints a
  closeout nudge, and runs no closeout step itself. {refines: SR-2}
- FR-48: The impact step refuses an unmerged issue, and records
  quantifiable claims backed by cited evidence, qualitative notes, and the
  issue's own workflow cost and time read from session transcripts.
  {refines: SR-19}
- FR-49: The lessonslearned step tags every lesson from a closed set
  (actionable, reference, norm, pattern), and stages pothole-register
  additions, retirements and amendments in the issue dir without editing a
  register file. {refines: SR-16}
- FR-50: The cleanup step refuses while any closeout step in the checklist
  is not done or skipped (naming every one), while the lessons file does not
  lint clean, or while the log claims a register promotion no register layer
  carries. On a oneshot-tier issue it refuses while the tree carries
  unpublished change or cannot be measured. {refines: SR-1}
- FR-51: The cleanup step restores the source tree, applies staged register
  changes with one path-scoped commit per register file, commits the devdoc
  when permitted (or defers with a stated reason), archives session
  transcripts when an archive is configured, and clears the active issue; an
  archive failure does not stop it. Its devdoc commit carries only the paths
  the cleanup owns, reports the rest, and is serialised with every other
  session's devdoc writes; a close whose lock or commit fails leaves the step
  in progress with the issue's state kept, ready to re-run. {refines: SR-1}

### Parking, switching and resuming

- FR-52: devagent's park marks an issue's current row parked, saves the
  issue's context keyed by issue, lists it among the parked issues, and
  clears the active issue when it was active. {refines: SR-2}
- FR-53: devagent's resume returns a parked issue's row to in progress,
  restores its saved context and makes it the active issue; switch validates
  the target, then parks the current issue and resumes the target.
  {refines: SR-2}
- FR-54: An issue that a pull or a resume displaces is parked with its
  context saved. Pulling a displaced issue again restores its context;
  pulling an issue the operator parked starts it fresh. {refines: SR-2}
- FR-55: devagent's where reports the active issue, its current and next
  step, any STUCK reason and the parked issues, and runs nothing; catchup
  shows one issue on one screen from its issue text, plan, actual-work
  record, recent comments and recent log entries. {refines: SR-2}
- FR-56: devagent's status shows active, stuck and parked issues for one
  project or all; history prints the checklist logs merged in time order;
  grep searches a project's per-issue artifacts, naming each hit's issue
  dir. {refines: SR-4}
- FR-57: With the opt-in rehydrate hook on, a session start prints the
  active issue and its last and next step, and prints nothing when no
  project resolves. {refines: SR-17}
- FR-58: devagent's use sets the shared active-project pointer, rejects an
  unknown project, and warns when the session is pinned to another project.
  {refines: SR-5}

### Revision passes

- FR-59: devagent's comments fetches every page of an MR's comments, review
  summaries and inline comments included, into the revision's
  `comments.md`, refuses when no MR is recorded, and writes no partial file
  when a forge call fails. {refines: SR-8}
- FR-60: devagent's revise appends a new revision block that lists the
  re-run steps as pending and restarts at draft, keeps every earlier block
  and the shared log, refuses until the revision's comments are fetched, and
  clears preship's verified head so a merge needs a fresh preship.
  {refines: SR-8}
- FR-61: A re-draft reads the pending reviewer comments as feedback the new
  plan must address, then clears the pending pointer and keeps the comments.
  {refines: SR-8}
- FR-62: devagent moves an issue to another tier as a new revision block,
  appending the new tier's rows and deleting nothing. {refines: SR-8}

### Templates and the pothole register

- FR-63: devagent resolves each artifact template from the project's
  configured path, then the devdoc's `templates/`, then the plugin's shipped
  default; a configured path that is missing falls through with a warning.
  {refines: SR-14}
- FR-64: devagent's template command lists every artifact template with the
  layer it resolves from and shows one under a banner naming its source; the
  pothole register shows as the union of its plugin, workflow and project
  layers, each entry marked by layer. {refines: SR-14}

### Work breakdown and status reports

- FR-65: devagent scaffolds a project's `WBS.md` from its template, or builds
  it from the tracker's epics, children and closed work, asking how far back
  to go and writing nothing until answered when the history is large. A merge
  run adds only the tracker issues missing from an existing file, as new
  lines, honours exclusion lines, and changes no existing line.
  {refines: SR-9}
- FR-66: devagent's work-breakdown update sets each issue leaf's glyph from
  the tracker's issue state and the linked MRs, using the issue's checklist
  only to fill gaps, records which source it used, and adds the active issue
  unless a leaf names it or an exclusion line lists it. A failed lookup
  changes nothing in its phase, warns once and exits zero. It writes under
  the devDoc repository lock, after every lookup, replaces the file
  atomically, and exits non-zero when the lock is held past its bound or the
  write fails. {refines: SR-9}
- FR-67: devagent sorts each parent's children by dependency, then
  inherited priority, then fan-out, moving whole blocks and never top-level
  nodes; it writes only a pure permutation, otherwise leaves the order and
  says why, and previews the change as a diff on request. {refines: SR-9}
- FR-68: devagent's work-breakdown show prints the file, filtered by depth
  or milestone on request, and reports each parse warning once on stderr.
  {refines: SR-9}
- FR-69: devagent keeps the `satisfies`, `objective` and `h` keys of a
  `WBS.md` node as written, validates and publishes them, and makes no
  workflow decision from them. {refines: SR-9}
- FR-139: devagent keeps a `WBS.md` node's `thinking` and `checking` keys
  as written, warns when a value is not one model token, and makes no
  workflow decision from them. {refines: SR-9}
- FR-70: devagent's status report covers the time since the last pin in a
  dated file under the devdoc's `StatusReports/`, lists work done, stuck,
  idle and poorly scoped issues, failed red-teams, dispatch-lint rejects, a
  work-breakdown roll-up and velocity with an estimate labelled as noisy,
  commits the report file alone only when the devdoc commit is permitted,
  and moves the pin, unless told not to, only after the report is committed
  or needed no commit; a failed commit exits non-zero and leaves the pin.
  {refines: SR-9}

### The portfolio

- FR-71: devagent's portfolio writes one versioned JSON document over every
  configured project's `WBS.md`, in config order, keyed by project and issue,
  with each issue's checklist state, next step and stuck reason; a missing or
  unreadable work breakdown gets a status instead of failing the run.
  {refines: SR-10}
- FR-72: The portfolio document's parse report lists everything devagent
  could not interpret or had to guess, each with its project, `WBS.md` line
  and kind. {refines: SR-10}
- FR-73: devagent writes the portfolio document only after it passes the
  schema check and devagent's own cross-field checks, writes it owner-only,
  and refuses an output path inside a configured devdoc, source or worktree
  root. {refines: SR-10}
- FR-74: devagent lists every ready leaf across projects, one tab-separated
  line each, writes nothing, and names each project it could not read on
  stderr. A leaf is ready only when it is pending, every dependency of the
  leaf and of its ancestors resolves to a done row, and no ancestor is
  parked, stuck, waiting or skipped.
  {refines: SR-10}
- FR-140: devagent's portfolio publishes each leaf's planned thinking and
  checking model, from the leaf, else the project's `step_models` class
  then default, and reports each value that is not a model token.
  {refines: SR-10}

### Harvesting follow-ups

- FR-75: devagent's reap scans finished issues' future-enhancements files,
  STUCK files, actual-work follow-ups and actionable lessons for candidates
  keyed by content hash, lets the operator keep or discard each one, drafts
  each kept one as a capture citing its source file and line, records each
  discard with its reason, and logs the harvest in the source issue's
  checklist. {refines: SR-11}
- FR-76: A repeated harvest drafts only candidates found since the last
  run, and never re-drafts a candidate already decided. {refines: SR-11}

### Capture, red-team and file

- FR-77: devagent's capture classifies an idea as an issue with a subtype
  (bug, feature, docs, perf or chore) or as an epic, and writes the capture's
  draft from the matching template without filing it; when the idea looks
  like several epics, it shows its recommendation and authors only the ones
  the operator picks. {refines: SR-7}
- FR-78: devagent's scaffold bins an epic capture into ordered child drafts,
  each of one subtype and shippable alone, and refuses to overwrite existing
  children unless forced. {refines: SR-7}
- FR-79: devagent's redissue red-teams a capture draft at a triaged depth and
  writes a report with blocking, recommended and nit findings and a ship,
  revise or split verdict, leaving the draft unchanged. {refines: SR-7}
- FR-80: devagent's file creates the tracker issue on the origin or the fork,
  records its number and URL in the capture, asks first when the draft has no
  red-team record, stops before any tracker write while the filing gate is
  closed, and never files one capture twice. {refines: SR-7}
- FR-81: devagent's one-pass capture command runs capture, scaffold,
  red-team, bounded revision and filing for one topic without asking in
  between. It halts before filing when a finding challenges the capture's
  premise or blocking findings survive the last revision, never confirms past
  a closed gate, and ends with a manifest of each capture's outcome.
  {refines: SR-7}
- FR-82: A capture whose content has landed moves to the captures archive
  with a ledger line, and is never deleted. {refines: SR-7}

### Installation, credentials and health

- FR-83: devagent's init adds a project to the config from an interview,
  refuses a project that already exists, and without a terminal takes each
  answer from an environment variable, naming any that is missing.
  {refines: SR-12}
- FR-84: devagent's auth stores a project's tracker and forge credentials in
  owner-only files, rotates one (store the new one, swap it in, then destroy
  the old one), destroys one, and reports one without ever printing the
  token. {refines: SR-12}
- FR-85: devagent's doctor checks the config, the required fields, the
  source and devdoc directories, the modes of the state and secrets files,
  template resolution, and each backend's credential and reachability, for
  one project or all; it changes no state, and warns about a missing
  companion plugin. {refines: SR-12}

### Gates, trust and unattended callers

- FR-86: A permission gate that is not `true` makes the script that would
  act ask first when a terminal can answer, and refuse with a non-zero exit
  when none can, unless the operator set `DA_YES=1` for that run. The
  `merge_mr` and `transition_issue` gates never ask, filing never asks and
  proceeds past a closed gate only with `--yes`, and a closed
  `commit_devdoc` gate skips the devdoc commit. devagent never changes a
  permission in its config itself.
  {refines: SR-13}
- FR-87: With no trust policy on the host, devagent behaves exactly as
  without the feature and makes no extra call. {refines: SR-13}
- FR-88: devagent reads a trust policy only from its fixed system and user
  locations, a system policy winning, and puts a project in the policy's
  scope when the key of one of its issue sources equals a listed scope.
  {refines: SR-13}
- FR-89: At every entry point of an in-scope project, before any backend
  call, network call or devdoc write, devagent checks the tracker account it
  runs as; it refuses an account that is not a listed worker, or one that is
  also a trusted approver when the policy does not allow a single identity,
  and asks for a retry when the check could not run. {refines: SR-13}
- FR-90: Under a trust policy, pull refuses before fetching, with an exit
  code that tells a polling caller whether to skip the ticket, stop polling
  or retry later. {refines: SR-13}
- FR-91: Every skill-backed step first checks the issue's quarantine and
  trust status, and on a refusal stops with no checklist write and no log
  line. {refines: SR-13}
- FR-92: With a trust policy on the host, doctor reports the policy's
  location and a digest that does not change with key order, whitespace or
  explicit defaults, the worker account per scope, and the hardenings met and
  missing. {refines: SR-13}
- FR-93: devagent gives an external caller the same contract as `--auto`: a
  stuck row with a STUCK file needs a person, a waiting step exits zero and
  prints its reason, and an unchanged row without a STUCK file means retry
  later. devagent never polls for CI or for a merge. {refines: SR-13}
- FR-94: A command that writes, verifies or moves tracker state, and was not
  given its project explicitly, refuses when its resolved project differs
  from the project of the working directory, naming both, and warns once,
  naming its choice, when the working directory decides nothing. {refines: SR-5}
- FR-95: devagent's suite runner takes its issue only from its argument or
  the session pin, and refuses a detached head, a branch that lacks its
  remote's tip, and a checkout that is not the issue's recorded tree. Its
  record names the head, tree, branch, upstream state and platform it
  measured. {refines: SR-18}
- FR-96: An unattended sync over every project executes and deletes nothing,
  and leaves pending closeout as checklist state. {refines: SR-13}
- FR-97: devagent's opt-in hooks deny a reflexive destructive git command on
  a dirty tree, deny a commit without a sign-off in the active project's
  source tree, deny a write to the active-project pointer from a pinned
  session except through use, and report untracked files left after ship.
  {refines: SR-17}

### Screening tickets from a shared queue

Partly delivered. A requirement here that is not built yet starts with
"(Planned.)", and a part not built yet is marked "(planned)".

- FR-98: (Planned.) At pull, devagent acts on no ticket text, workflow flag or label
  until the ticket has passed a deterministic floor, a provenance check from
  tracker history, and a screen by an isolated model session that holds no
  tools; missing history counts as unknown and quarantines. {refines: SR-13}
- FR-99: (Planned.) The deterministic floor quarantines a ticket that is over the size
  limit, holds invisible or bidirectional control characters, or carries a
  steering key or label outside the policy's allowlist; the model screen can
  add a quarantine but never remove one. {refines: SR-13}
- FR-100: devagent marks a quarantined ticket with a tracker label; pull
  refuses it on every machine, every entry point refuses it with one fixed
  message, and devagent re-reads quarantine state at every step and before
  every outward write. {refines: SR-13}
- FR-101: devagent counts a release only from a trusted approver who is not
  a worker identity, and (planned) counts an approval or a widening of bounds
  the same way, or from a countersignature made with a security key that
  needs a human touch. {refines: SR-13}
- FR-102: (Planned.) devagent builds the statement of work only from the title, the body
  and trusted comments, and no session that holds tools reads an untrusted
  comment. {refines: SR-13}
- FR-103: (Planned.) devagent checks its own outward writes (pushes, MRs, claims,
  comments, devdoc pushes, local merges) against the ticket's bounds for
  paths, destination, secrets and size before they leave the machine.
  {refines: SR-13}
- FR-104: (Planned.) devagent claims an issue on the tracker at pull and verifies the
  claim, so two workers never both proceed on one ticket. {refines: SR-13}
- FR-105: With trust on, every entry point refuses when a hardening the
  policy requires is missing, and (planned) devagent records each issue's
  trust evaluation (validated, approved or quarantined, with the text hash
  and the policy digest) in its checklist. {refines: SR-13}

### Work breakdown from the shared tracker

- FR-106: When the tracker closes an issue, devagent marks its leaf done, or
  skipped when it was closed as not planned. {refines: SR-9}
- FR-107: devagent keeps a leaf's glyph when it has no signal, and keeps the
  parked, stuck and waiting glyphs the operator set by hand. {refines: SR-9}
- FR-108: devagent counts a leaf with no usable time estimate as unestimated,
  never as zero. {refines: SR-10}

### Actuals, estimates and forecasts

Partly delivered. A requirement here that is not built yet starts with
"(Planned.)", and a part not built yet is marked "(planned)".

- FR-109: devagent attributes token cost to a project and issue, and to each
  workflow step, across worktrees, and places cost that belongs to no issue
  by a stated rule with an explicit unassigned remainder. {refines: SR-19}
- FR-110: devagent archives session transcripts into a durable, append-only
  store partitioned by host, so its actuals outlive the transcripts' own
  retention. {refines: SR-19}
- FR-111: devagent reports agent time and operator time per issue, apart from
  calendar time, and (planned) records each issue's milestones from
  checklists, the tracker and MRs. {refines: SR-19}
- FR-112: (Planned.) devagent publishes per-issue actuals as a source the portfolio
  document reads. {refines: SR-19}
- FR-113: devagent's work-breakdown key contract classifies every estimate
  value as absent, placeholder, time, non-time or unparseable, and (planned)
  defines an agent-time estimate, a token estimate and a range form.
  {refines: SR-19}
- FR-114: (Planned.) devagent records a structured estimate at the scope step, confirms
  it at the tighten step, copies it onto the issue's leaf, and compares it
  with the actuals at the impact step. {refines: SR-19}
- FR-115: (Planned.) devagent publishes each project's calibration pairs (actual over
  estimate, for agent time and tokens) with their sample count, and reports
  open leaves without a usable estimate. {refines: SR-19}
- FR-116: (Planned.) devagent proposes a derived estimate for an unestimated leaf from
  closed work and writes it only after the operator approves; it records
  provenance per estimate key and never rewrites an estimate the operator
  wrote. {refines: SR-19}
- FR-117: (Planned.) devagent reads the operator's declared capacity (operator hours, a
  token budget, a shared lane pool, and each project's priority, lane cap,
  paused flag, deadline and reservations), and doctor fails on an invalid
  declaration, naming the key. {refines: SR-19}
- FR-118: (Planned.) devagent forecasts each project's completion by simulation over
  dependencies and declared capacity, reports a median and a conservative
  date or the reason it cannot, and names the resource that binds the
  forecast, operator attention included. {refines: SR-19}
- FR-119: (Planned.) devagent records each forecast with its inputs, scores it later
  against outcomes, and ships its forecast engine in a form a browser page can
  re-run with an edited capacity. {refines: SR-19}

### Planned: parallel lanes

- FR-120: devagent opens a lane for an issue in one command (worktree,
  recorded worktree path, lane record and session pin together) and closes it
  in one command; it refuses a lane for a tier with no branch step, and
  refuses to close an unfinished issue unless told to abandon it.
  {refines: SR-20}
- FR-121: Every step a lane runs measures, commits and records against the
  lane's tree, never the project's main checkout. {refines: SR-20}
- FR-122: devagent's status shows each project's open lanes with the issue,
  worktree, branch, step and last activity. {refines: SR-20}

### Planned: standing answers and holds

- FR-123: At a recurring halt that has a settled operator answer, devagent
  applies the answer and logs it in the checklist instead of asking.
  {refines: SR-21}
- FR-124: devagent fixes blocking findings from the review and MR red-team
  steps on the branch in rounds, and caps every fix-and-recheck loop at three
  rounds before it asks. {refines: SR-21}
- FR-125: In a session a launcher started, devagent holds an issue on a
  pending question: it writes a self-contained question to the STUCK file,
  marks the step waiting, parks the issue and appends one line to a
  machine-local notifications file. In an interactive session it asks the
  same question there. Only recording the operator's answer releases a hold,
  and the ready list leaves held issues out. {refines: SR-21}
- FR-126: The scope step splits an issue whose production code, or production
  code plus tests, exceeds the configured size thresholds, files the pieces
  through the capture pipeline, and holds when no split works; an issue is
  also flagged as a split candidate by its token estimate and the operator
  attention it needs. {refines: SR-21}
- FR-127: devagent refreshes stale counts and golden files without asking
  only when an intended change explains the drift, and never refreshes an
  integrity pin by itself. {refines: SR-21}
- FR-128: devagent posts tracker comments and issue-body edits only after a
  leak gate (the permission gate, a private-name scan, a red-team record bound
  to the exact text, and the tracker's owner) that fails closed.
  {refines: SR-21}
- FR-129: devagent files follow-up issues through the capture pipeline
  without filing one twice, and keeps the harvest's ledger in step.
  {refines: SR-21}
- FR-130: When the active issue depends on an open issue, devagent parks it
  and switches to the first unblocked dependency, or, in an issue-pinned
  session, exits with a waiting code. {refines: SR-21}
- FR-131: devagent records a watchdog kill of a stalled chained step in the
  STUCK file and the notifications file, and stops only the processes it
  registered. {refines: SR-21}
- FR-132: devagent records an issue's scope ambiguity count as one
  structured number that the scope log, the status report and the portfolio
  read. {refines: SR-21}

### Evidence integrity and scope resolution

Partly delivered. A requirement here that is not built yet starts with
"(Planned.)".

- FR-133: devagent marks or refuses evidence made in an environment that
  cannot give authoritative results, and from a clone behind its remote
  branch; preship refuses, rather than warns, when it cannot verify the
  checkout a record measured. {refines: SR-18}
- FR-134: (Planned.) The analyzers, the born-red check and the scope record measure the
  issue's own worktree and stamp its head and branch. {refines: SR-18}
- FR-135: (Planned.) Every project-resolving entry point rejects a project name that is
  not configured before it writes any state, refuses a stale project value
  left in the session environment, and resolves the right project from a
  linked git worktree; capture, reap and file take their project and paths
  from the config. {refines: SR-5}

### Planned: more languages

- FR-136: The analyze step lints the changed PowerShell files in the issue's
  own checkout and reports a finding on a changed line as new.
  {refines: SR-22}
- FR-137: devagent accepts a project-declared test-suite command that emits
  TAP, records its counts in the evidence block's suite line, and preship
  checks them. {refines: SR-22}

### Public documentation

- FR-138: devagent's public site explains what devagent is, how to install
  it and how to run the workflow, and is published only when the repository
  switches publishing on. {refines: SR-23}

## Quality attributes

- QA-1: Context preservation: an operator can leave an issue for weeks, work
  on others, and resume it from its on-disk files alone with nothing lost.
- QA-2: Token economy: mechanical steps run as scripts with no model call.
- QA-3: Bounded context: each phase of an issue starts in a fresh session
  instead of replaying the issue's history, steps read plans by outline and
  bounded ranges, and checker replies and command bodies stay within size
  limits that tests guard.
- QA-4: Auditability: every step leaves an artifact or a log line in one
  fixed, parseable format, so an issue's history can be reviewed afterwards.
- QA-5: A checker's report is kept exactly as the checker wrote it; the main
  session triages it but never rewrites it.
- QA-6: Portability across backends: the same workflow runs against GitHub,
  GitLab and JIRA trackers and GitHub and GitLab forges, every backend gives
  the same Markdown shape for an issue and its comments and the same exit
  codes, and one shared contract suite checks them. Two parts are GitHub
  only so far: the merge step, and the account and change-event reads the
  trust policy needs.
- QA-7: Portability across hosts: devagent runs on Linux and WSL, and its
  scripts behave the same under any POSIX awk and normalise CRLF output and
  backslash paths before matching; native Git Bash runs the plugin but not
  its test suite.
- QA-8: Safe concurrency: every state write holds an exclusive lock across
  read, modify and write and lands by atomic rename in the same directory,
  so a reader sees the old state or the new, never a mix or a truncated
  file.
- QA-9: Session isolation: sessions pinned to different projects, or to
  different issues of one project, never read or write each other's
  per-issue state and never move the shared pointer. Sessions pinned to
  different projects also never commit or overwrite each other's source
  files; sessions on one project share its checkout until lanes (SR-20)
  separate them.
- QA-10: Analyzer build directories are keyed by project and issue, so
  concurrent chains on one source tree never share one.
- QA-11: Fail closed: an ambiguous setting, an undecidable state or a check
  that cannot run stops the step; it never passes, skips or authorizes
  completion.
- QA-12: Hooks fail open, because they are backstops: an error, a timeout
  or an uncertain match allows the call, only a confirmed match denies, and
  each hook finishes within five seconds.
- QA-13: Boundedness: every network read and merge call a chain makes has a
  time limit, and each analyzer phase has a budget, so no chain hangs.
- QA-14: Resilience: a tracker or lookup failure warns and never blocks real
  work, a sync over several projects continues past one project's failure,
  and a transient network or permission failure is never read as absent.
- QA-15: Honest evidence: an unreadable CI result, an unmeasured or
  truncated suite and a stale tree are never reported as green, and suite
  evidence depends on the tree, not on the operator's session.
- QA-16: All or nothing: a backend verb that fails prints nothing, so no
  caller sees partial data.
- QA-17: Byte fidelity: work-breakdown commands rewrite only what they own
  and keep every other byte, line endings and hand-written prose included.
- QA-18: Idempotence: running pull, comments, reap, depends, a tracker merge
  into the work breakdown, a work-breakdown update, a spike teardown or a
  register apply again on unchanged input changes nothing.
- QA-19: Zero-config neutrality: an absent optional table, such as model
  tiers or a trust policy, leaves behaviour identical to a build without the
  feature.
- QA-20: Forward compatibility: unknown workflow-flag keys and unknown
  work-breakdown meta keys are kept or ignored, never rejected.
- QA-21: A new project works with the plugin's shipped templates alone, and
  those templates carry no project-specific identity or vocabulary.
- QA-22: Secret hygiene: token files are owner-only in an owner-only
  directory, and a token never appears in a command line, a process listing,
  shell history, a log, an artifact or a commit.
- QA-23: devagent updates in place without an uninstall, and works without
  any other plugin installed, using built-in fallbacks and printing a
  one-line install hint.
- QA-24: The portfolio document is deterministic: the same inputs give the
  same document apart from its generation time, and a schema test fails when
  a field is renamed or removed without a major version.
- QA-25: devagent's tests never call a live tracker or forge.
- QA-26: Retry safety: a declined permission gate leaves the checklist and
  log unchanged, and a refused cleanup leaves the tree as it was, so the step
  can simply run again.
- QA-27: Privacy: devagent writes the portfolio document and the transcript
  archive outside every devdoc and source checkout, and publishes nothing
  private.
- QA-28: Missing data shows as missing, never as a default: an unreadable
  work breakdown, an unestimated leaf and a sample count of zero are all
  reported as such.
- QA-29: (Planned.) Every halt in a session a launcher started is asynchronous: nothing
  waits on a reply, and a stalled step is detected within a configurable
  window and leaves a STUCK file naming the reason.
- QA-30: A failed web request is reported with its method, URL, status and
  response, and an auth failure, a network failure and an absent resource are
  told apart.
- QA-31: (Planned.) Every actuals figure traces to its sources: cost and time to the
  session and host they came from, and milestones to a tracker or MR address
  or a checklist line.
- QA-32: devagent's spec keeps in step with its behaviour: the MR red-team
  and preship steps ask whether a change touches the spec.

## External interfaces

- EI-1: Issue-tracker backend contract (GitHub, GitLab, JIRA or a custom
  backend): devagent fetches an issue and its comments as fixed Markdown,
  creates issues, moves an issue to a mapped stage, and reads its state,
  comments, change events and the account its credential belongs to. It
  reads success, usage error, auth failure, not found, malformed response and
  not implemented as distinct exit codes.
- EI-2: Code-forge backend contract (GitHub, GitLab or a custom backend):
  devagent pushes a branch, opens an MR (as a draft on request), reads an
  MR's state, comments, CI checks and the MRs linked to issues, and merges an
  MR at a matched head.
- EI-3: git: devagent creates branches and worktrees, commits, diffs against
  a baseline, pushes and squash-merges in the project's source repository,
  and commits to the project's devdoc repository.
- EI-4: Claude Code plugin host: devagent exposes slash commands and skills,
  dispatches its bound checker agents and a planner as subagents and reads
  their reports back as text, registers opt-in hooks, declares enable-time
  config options, and grants itself no Bash call but its own scripts.
- EI-5: The global config `config.toml`: devagent reads defaults, global
  paths, the transcript archive and one table per project (source and devdoc
  locations, permission gates, issue and code sources, tracker stage
  mapping, label overrides, template paths, model tiers and work-breakdown
  options); init writes a new project table.
- EI-6: Per-project state under devagent's home: devagent reads and writes
  each project's active issue, per-issue context and parked issues, the
  status-report pin, the dependency graph, the harvest ledger and the shared
  active-project pointer.
- EI-7: The per-issue directory and its `checklist.md`: devagent writes the
  issue text, intent, plan, future enhancements, actual work, MR body,
  analysis output, revision comments, STUCK and quarantine markers and the
  model-steering marker, and reads and writes each step's glyph per revision
  block and the log.
- EI-8: `Captures/`: devagent writes each capture's draft, red-team report,
  child drafts and filed record in the devdoc's `Captures/<slug>/`, and moves
  landed captures to its archive.
- EI-9: `WBS.md`: devagent reads and writes each project's work breakdown, a
  Markdown checkbox tree with inline key-value metadata in braces and
  `wbs-` directives.
- EI-10: The portfolio JSON document: devagent writes one versioned document
  against a published schema, whose readers refuse another major version and
  ignore unknown fields of a newer minor one, and prints a ready-leaf view of
  one tab-separated UTF-8 line per leaf.
- EI-11: The trust policy `policy.toml`: devagent reads the trusted scopes,
  worker and trusted identities, gates and hardenings from a fixed system or
  user location outside anything it writes.
- EI-12: Static analyzers and sanitizers: devagent runs the project's
  analyzer family (C and C++ static tools with sanitizers, or shellcheck)
  over the changed lines and reads their findings and versions.
- EI-13: The secrets store under devagent's home: devagent stores and reads
  each project's tracker and forge tokens in owner-only files.
- EI-14: The optional companion skills plugin: devagent uses its planning,
  plan-execution, worktree and code-review skills when it is installed.
- EI-15: Project test suites: devagent runs a project's bats and pytest
  suites in a declared environment and writes a suite-count record that
  preship reads.
- EI-16: Artifact templates and the pothole register: devagent reads
  standards, prompts, issue, epic, plan, MR, work-breakdown, report and
  checklist templates, and the register's layers, from the project, the
  devdoc or the plugin, and stages register changes into the devdoc layers.
- EI-17: Status reports: devagent writes dated reports to the devdoc's
  `StatusReports/`.
- EI-18: Claude Code session transcripts: devagent reads them for cost and
  time, and copies them into the configured archive at cleanup.
- EI-19: Session pins: devagent reads a per-session active-project pin and
  active-issue pin that take precedence over the shared pointer.
- EI-20: Refusal exit codes: devagent's trust and quarantine refusals use
  stable exit codes that a polling caller keys on.
- EI-21: Issue-body workflow flags and labels: devagent reads the tier,
  research, spike and model-steering keys from an issue body's
  `## Workflow flags` block, and model steering from the issue's labels.
- EI-22: The launcher notifications file and unattended marker (planned):
  devagent reads the marker a launcher sets, and appends hold, notice and
  stuck lines for the launcher to read.
- EI-23: The ticket screen and signing keys (planned): devagent passes staged
  ticket text to an isolated model process and parses its verdict against a
  strict grammar, and verifies security-key signatures posted on the tracker.
- EI-24: Actuals, calibration and forecast documents (planned): devagent
  writes per-issue cost, time and milestones, per-project calibration pairs,
  and forecasts with their inputs, for the portfolio and other tools to read.
- EI-25: The operator's private name list (planned): devagent reads it by
  path only, to scan tracker posts for private names before they are sent.
- EI-26: The public documentation site: devagent's onboarding pages,
  published from the repository.

## Constraints

From the design spec's non-goals:

- CON-1: devagent is not a project-management tool; the work breakdown and
  status reports are by-products, not the product.
- CON-2: devagent is not a CI system: it runs analyzers, sanitizers and test
  suites, but does not run cloud builds.
- CON-3: devagent is not an MR review bot: red-team and code review are
  workflow steps, not background processes.
- CON-4: devagent wraps git for its workflow and does not abstract or
  replace git.
- CON-5: devagent is not session-aware: it is invoked from Claude Code
  sessions, but its state lives on disk for anything that can read the files.

From the design spec's permission gates and gates under trust:

- CON-6: Each permission gate is set per project: `true` proceeds, `false`
  asks before each remote-visible action, and an unset gate counts as
  `false`.
- CON-7: The script that performs a gated action enforces the gate, not the
  chaining layer.
- CON-8: Neither `--auto` nor the operator's note can suppress or override a
  gate; only an edit to the config changes one.
- CON-9: The gates are `push_mr` (ship and file), `merge_mr` (mergemr),
  `merge_to_all_prs` (mergetoall), `commit_devdoc` (the devdoc commits of
  cleanup and the status report) and `transition_issue` (every tracker
  transition). The spec also lists `cleanup_on_merge`, for a cleanup after
  sync, which no step performs.
- CON-10: `merge_mr` never prompts: devagent merges only when it is exactly
  `true`, so no answer at a terminal and no yes-flag can open it.
- CON-11: `transition_issue = false` never prompts: devagent skips the
  transition and warns.
- CON-12: `merge_mr` and `merge_to_all_prs` are separate gates, and neither
  stands in for the other.
- CON-13: Under a trust policy, for a project in its scope, the policy alone
  decides the `push_mr`, `commit_devdoc`, `merge_to_all_prs`, `merge_mr` and
  `file` gates.
- CON-14: A gate the trust policy closes denies at once; no prompt, terminal,
  environment variable, yes-flag or config value can open it.
- CON-15: Under trust, `transition_issue` stays in the config, and an
  in-scope project without it set to `true` is refused at its entry point.
- CON-16: With any trust policy on the host, filing uses only the backend and
  repository configured for the project that owns the devdoc, ignores
  environment overrides, and refuses a yes-flag.

From the design spec's trust policy:

- CON-17: The trust policy lives at fixed locations outside everything the
  agent can write; no environment variable names one, and a policy under
  devagent's home, the plugin root, a devdoc, a source tree or a worktree
  root is a defect.
- CON-18: Trust-policy validation fails closed on an unknown key, a wrong
  type, an empty worker or scope list, or an identity that is not an
  immutable account id; a scope is an exact repository key, never an owner
  prefix.
- CON-19: A host-level trust refusal is never retried or worked around; the
  host is fixed instead.

From CONTRIBUTING and the commit conventions (devagent's own repository):

- CON-20: Every commit is signed off under the Developer Certificate of
  Origin, and a PR with an unsigned commit is not merged.
- CON-21: A commit subject is `<type>: <title>`, with an imperative title
  under 72 characters, and issue references go in the body on their own
  lines, never in the subject.
- CON-22: Tests are born red: a behaviour change ships with a test that fails
  on the old code and passes on the new, or the PR says why it cannot.
- CON-23: Scripts and hooks stay shellcheck clean; a finding is silenced only
  by a targeted disable with a reason.
- CON-24: One change per PR.
- CON-25: Docs travel with the change: a change to what a command does
  updates its command body and the README's command table in the same PR,
  and a change to what a requirement states updates this file.
- CON-26: The only Bash grant in a command or skill body is the quoted
  plugin-scripts form, and that grant is never widened.

From SECURITY:

- CON-27: No issue body, tracker response, template, config value or
  working-tree file may make devagent run a command, write outside the
  intended tree, or read or expose a credential.
- CON-28: Text the model typed never reaches an unquoted shell.
- CON-29: No devagent step pushes, publishes, closes or changes the
  visibility of a repository unless the operator asked for it.
- CON-30: The secrets store keeps its owner-only directory and file modes,
  and no path lets a stored token reach a log, an artifact or a commit.
- CON-31: devagent runs only on the operator's machine, under the operator's
  user and the credentials that user already holds.
- CON-32: Only the latest release is supported: fixes land on the default
  branch and ship in the next release, with no backports.
- CON-33: A vulnerability is reported privately through the repository's
  security advisories, never in a public issue.
