---
description: Draft an implementation plan for the active issue. Wraps superpowers:writing-plans.
allowed-tools: Bash, Read, Write, Edit, Skill
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
   to run `/devagent:pull` first.
3. **Check for pending review comments (Phase 6 revision flow).**
   Look up `pending_comments_file` in
   `~/.claude/devagent/state/<project>.toml`. If set and the file
   exists, read it and include its content as additional user-intent
   context alongside `$NOTE`, framed as "Reviewer feedback from the
   previous revision that the new plan must address:".
4. **Resolve the step-1 tier first** (Dispatch contract below): a
   non-empty tier — or an explicit operator instruction — means
   DISPATCH a planner per that contract instead of drafting inline.
   Otherwise invoke the `superpowers:writing-plans` skill. Pass `$NOTE` (plus
   the pending-comments block if any) as additional user-intent
   context describing what the operator wants emphasised in the plan.
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
   scripts/checklist-log.sh "$ISSUE_DIR" draft "imPlan.md written ($N steps); note: $NOTE"
   ```

   Where `$N` is the number of top-level tasks in the plan.

## Dispatch contract (#284 — thinking-class up-delegation)

Planning is the INVERSE of #151's checking dispatch: a checker wants
isolation (paths, no author context); a planner is better the more
operator INTENT it holds — packaged to disk, never "paste the
conversation".

1. **When to dispatch.** Resolve the tier:
   `tier="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/step-model.sh" <project> 1 || true)"`
   (canonical step number 1; the thinking class). A NON-EMPTY tier ⇒
   dispatch a fresh-context planner subagent with that model override.
   EMPTY ⇒ stay inline — note this deliberately differs from #151,
   where dispatch is unconditional and empty means dispatch-with-
   inherit; for planning, inline IS the fully-informed default and
   dispatch exists for up-delegation. An explicit operator instruction
   ("dispatch the draft" / "plan inline") overrides either way. If
   the resolved tier is unavailable at dispatch, retry once with no
   override and record the fallback form (rule 5).
   Per-issue `.devagent-step-models` markers do NOT apply — the #291
   layer is checking-class only (config.sh gate).
2. **Package intent to disk, then dispatch paths.** Before dispatching,
   write `<issue-dir>/intent.md` from the resolved `intent_template`
   (§12 registry key) — sections: `## Goals`, `## Constraints`,
   `## Rejected alternatives`, `## Answers` (append-only across
   rounds) — distilled from `$NOTE`, the conversation's constraints,
   and any scope answers. The dispatch prompt carries NO
   conversation transcript; its content is: the absolute paths of
   `issue.md` and `intent.md`, the project source repo directory,
   `$NOTE` verbatim, the output path `<issue-dir>/imPlan.md`, the
   contract duties the planner must honor (provenance header grammar,
   the question-return protocol, the house plan shape) — and, when
   `pending_comments_file` is set in state, that file's path as a
   REQUIRED input (the Phase-6 revision flow; a re-draft that omits
   it silently drops reviewer feedback).
3. **Question-return protocol (ask-don't-guess, dispatched).** A
   dispatched planner cannot ask the operator anything. If packaged
   intent leaves a load-bearing gap, the planner writes the plan with
   an `## Open questions (dispatch round N)` section INSTEAD of
   guessed content for the affected parts. A discovery that FALSIFIES
   an intent.md premise is an open question too — correct the record,
   but route the decision the correction opens back to the operator
   rather than resolving it unilaterally (sourced from the #284
   dogfood, where a planner corrected a false "guard already exists"
   premise unilaterally — the behavior this rule now forbids). The main session answers
   into intent.md's `## Answers` and re-dispatches. Bounded: at most
   two rounds; if questions remain, fall back to INLINE drafting
   (the operator is one message away there), reading intent.md — the
   accumulated Answers are the inline draft's input, not dead state.
4. **Round overwrite exemption.** Within a round sequence, the round-N
   plan supersedes round N-1 WITHOUT triggering the existing-imPlan
   halt below; that halt applies only to a NEW `/devagent:draft`
   invocation. The round number is DERIVED, not remembered: count the
   `## Open questions (dispatch round N)` headings already answered in
   intent.md's `## Answers` — that makes the bound enforceable across
   sessions.
5. **Provenance header.** A DISPATCHED imPlan.md carries the #151
   grammar as its first two lines, BEFORE the `# Issue-N:` title:
   `context: subagent` and `model: <tier>` (or
   `model: inherit (fallback from <tier>)` on the retry-once
   degradation; an operator-instructed dispatch with an EMPTY tier
   records `model: inherit`). Inline drafting writes NO header (no
   `context: inline` line — absence = inline, which keeps the
   historical plan corpus valid). The imPlan template does not define
   these lines; the planner prepends them.
6. **Finalization is the MAIN session's, once.** The marker files
   (workflow step 6), clearing `pending_comments_file` (step 7), the
   log entry (step 8), and the checklist mark happen ONLY after the
   FINAL accepted plan — questions resolved, or the bound exhausted
   and the inline fallback finished. A round plan still carrying
   UNRESOLVED `## Open questions` is never what `/devagent:scope`
   sees (an explicitly emptied/"None" section on the accepted plan is
   fine — it is the record that the protocol ran).
7. **Generalization note.** The other thinking-class steps (7/8/9/12)
   can adopt this contract later; draft is the payoff case and the
   only carrier today.

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
