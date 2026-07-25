---
description: Draft an implementation plan for the active issue.
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read, Write, Edit, Skill
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:draft

Drafts `<issue-dir>/imPlan.md` for the active issue — inline via the
upstream `superpowers:writing-plans` skill, or via a dispatched planner
when a step-1 tier is configured (Dispatch contract, #284). Step 1 of the 22-step
devAgent workflow (spec §6.3).

## Argument parsing (spec §6.1)

This command receives positional arguments left-to-right:

1. If the first token matches a `project.<name>` from
   `~/.claude/devagent/config.toml`, consume it as the project.
2. If the next token matches `^Issue(-Fork)?-\d+$`, consume it as the
   issue directory.
3. Join remaining tokens with single spaces into `$NOTE` — free-form
   user intent.

`--` halts positional consumption; everything after `--` is `$NOTE`.

Defaults when omitted: project = state's `active_project` (or the only
configured project if exactly one); issue = state's `active_issue` for
that project.

## Workflow

1. Resolve `project`, `issue-dir`, and `$NOTE` per the rules above.
2. Read `<issue-dir>/issue.md`. If absent, halt and tell the operator
   to run `/devagent:pull` first. Once the issue is confirmed, drafting
   has begun, so **fire `on_draft_start`** (§11) — the tracker learns
   work started:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/transition-draft-start.sh" "$project" || true
   ```

   Best-effort and gated: the helper fires the backend `transition`
   for `on_draft_start` only when `permissions.transition_issue = true`
   (fail-closed skip-warn otherwise, mirroring sync's `on_merge`, #219),
   and a transition failure warns rather than dies. The `|| true` is
   belt-and-suspenders — the helper never exits non-zero — so drafting
   proceeds regardless of tracker state.

   **Pre-plan inputs — re-derive the issue's named inputs at HEAD (#361).**
   Then run the rederive prober and let its artifact inform the plan:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/rederive.sh" "$project"
   ```

   It writes `<issue-dir>/analysis/<date>-rederive.txt`: per named file
   exists-at-HEAD ✓/✗, cited-line drift, and commits that landed touching
   those files since the tracker filing date. ADVISORY — but **every ✗ is a
   falsified premise**: the plan's `## Preconditions` MUST dispose of each one
   (correct the record + route the decision back per the #284 question-return
   path, or state an explicit plan delta). A "0 named inputs found" line means
   derive inputs by hand. (This `## Pre-plan inputs` block is the shared home
   for premise-freshness checks; #286's pothole register appends here.)

   **Declare the plan's bets — `## Load-bearing unknowns` (#536).** Fill the plan's
   `## Load-bearing unknowns` section: one entry per assumption the plan's SHAPE depends on,
   each naming (a) the assumption, (b) WHY it is load-bearing — what breaks if it is false —
   and (c) the CHEAPEST probe that would falsify it. Use the `U<N> (Task <M>)` back-reference
   so a later step can tell which task rides which bet. `(none)` is legal and common; declaring
   is cheap either way. On a `spike: required` issue these entries are what step 23 executes.

   **Research findings — read `research.md` if present (#535).** If the optional
   research step (22) ran, `<issue-dir>/research.md` exists. Read it: the plan's
   `## Preconditions` and design choices CITE its `## Findings` rather than
   re-deriving them, and each `## Open unknowns` entry MUST be disposed of — designed
   around, or carried forward explicitly (never silently dropped).

   **Pothole register — consider known potholes before drafting (#286).**
   Resolve `potholes` via the §12 walk (project paths → `<devdoc>/templates/`
   → plugin default) and read it:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/template.sh" --project "$project" show potholes
   ```

   The register is a curated list of `[pattern]` lessons keyed by DOMAIN
   TRIGGER, each citing its source `(Issue-N)`. Judge which triggers MATCH
   this issue's change, then emit a `## Potholes considered` section in the
   plan (the `imPlan_template` carries the skeleton) listing: (a) each MATCHING
   trigger with the mitigation the plan adopts, and (b) triggers reviewed and
   deemed N/A. ADVISORY to the plan — enforcement is the improve-step tripwire
   (core-improve): a trigger that matches but is absent from, or wrongly N/A in,
   `## Potholes considered` is a finding. Cost: one file read + a short section.
3. **Check for pending review comments (Phase 6 revision flow).**
   Look up `pending_comments_file` in
   `~/.claude/devagent/state/<project>.toml`. If set and the file
   exists, read it and include its content as additional user-intent
   context alongside `$NOTE`, framed as "Reviewer feedback from the
   previous revision that the new plan must address:".
4. **Resolve the step-1 tier first** (see the conditionally-loaded
   Dispatch contract stub below — READ the referenced contract file
   when either load condition holds): a non-empty tier — or an explicit
   operator instruction — means DISPATCH a planner per that contract
   instead of drafting inline.
   Otherwise invoke the `superpowers:writing-plans` skill. Pass `$NOTE` (plus
   the pending-comments block if any) as additional user-intent
   context describing what the operator wants emphasised in the plan.

   **Fallback (superpowers absent):** if that Skill invocation errors
   (`Unknown skill: superpowers:writing-plans` — the measured absence
   symptom, #541), draft the plan yourself directly against
   `templates/imPlan_template.md`'s section contract: every template
   section present, tasks bite-sized with exact files, code blocks, and
   runnable test commands, tests-before-implementation ordering. Then
   print the nudge line verbatim and continue — never stall on the
   missing plugin:
   recommended: claude plugin install superpowers@claude-plugins-official
5. The skill writes the plan to `<issue-dir>/imPlan.md` (NOT to
   `docs/plans/`, despite the wrapped skill's default).
   Override its save path explicitly when invoking it.
6. **Write issue-classification marker files.** After saving `imPlan.md`,
   write two files into `<issue-dir>` that `branch.sh` (step 6) and
   `commit.sh` (step 10) consume:

   a. Read `~/.claude/devagent/config.toml` with the Read tool and
      extract the `branch_prefix_map` keys from the active project's
      section — e.g. `bug`, `feature`, `docs`, `perf`, `chore`.
      These are the only legal values.
   b. Based on the issue body and the plan just written, select the
      single best-matching type key. If genuinely ambiguous, prefer
      `feature` for new capabilities, `bug` for defect fixes, `perf`
      for performance work, `chore` for maintenance.
   c. Extract a short descriptive title (3–6 words) from the issue —
      typically the H1 with boilerplate stripped.
   d. Write the files:

      ```bash
      printf '%s' "<type>" > "<issue-dir>/.devagent-type"
      printf '%s' "<title>" > "<issue-dir>/.devagent-title"
      ```

   If `.devagent-type` or `.devagent-title` already exist (e.g. on a
   revision re-draft), overwrite them — the classification from the
   current draft supersedes any prior value.

   These files are consumed by `scripts/branch.sh` to compute the
   branch name (`<prefix>/<num>-<slugified-title>`) and by
   `scripts/commit.sh` for the commit-message prefix. The type
   **must** be a key present in `branch_prefix_map` or `branch.sh`
   will die at runtime.
7. Clear `pending_comments_file` from state after the plan is
   written, so subsequent steps in the same revision don't re-surface
   the comments. (The original `revisions/r<N>/comments.md` file is
   left in place — it's the durable record.)
8. On completion, append a log entry:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" draft "imPlan.md written ($N steps); note: $NOTE"
   ```

   Where `$N` is the number of top-level tasks in the plan.

## Dispatch contract (#284) — loaded conditionally

The full #284 dispatch contract (when-to-dispatch, intent packaging to disk, the
ask-don't-guess question-return protocol, the provenance-header grammar, and the
finalization rules) lives in `${CLAUDE_PLUGIN_ROOT}/docs/draft-dispatch-contract.md`.
It is **loaded only when dispatch can fire** — before drafting, READ that file and
follow it verbatim if EITHER condition holds:

1. the resolved step-1 tier is non-empty
   (`tier="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/step-model.sh" <project> 1 || true)"`), OR
2. the operator explicitly instructs dispatch ("dispatch the draft") — this fires
   even on an EMPTY tier (the `model: inherit` provenance case), so the trigger is
   BOTH conditions, not tier-alone.

Otherwise (empty tier AND no operator dispatch instruction) drafting is INLINE via
`superpowers:writing-plans` — skip the contract entirely (it is conditionally-dead
on dispatch-disabled projects; #441 moved it out of the common load path).

## Halt and ask if

- `<issue-dir>/issue.md` does not exist (operator must run pull first).
- `<issue-dir>/imPlan.md` already exists and is non-empty — ask whether
  to overwrite, start a new revision, or abort. (Exception: an
  in-progress dispatch round sequence — Dispatch contract rule 4.)
- Active project cannot be inferred and `config.toml` has multiple
  projects.

## Skipping policy

Never auto-skip. If a precondition is unmet, surface
"step doesn't apply because X, mark skipped?" and require operator
confirmation per spec §6.3 principle.

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
