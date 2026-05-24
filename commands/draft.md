---
description: Draft an implementation plan for the active issue. Wraps superpowers:writing-plans.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:draft

Drafts `<issue-dir>/imPlan.md` for the active issue by invoking the
upstream `superpowers:writing-plans` skill. Step 1 of the 21-step
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
4. Invoke the `superpowers:writing-plans` skill. Pass `$NOTE` (plus
   the pending-comments block if any) as additional user-intent
   context describing what the operator wants emphasised in the plan.
5. The skill writes the plan to `<issue-dir>/imPlan.md` (NOT to
   `docs/plans/`, despite the wrapped skill's default).
   Override its save path explicitly when invoking it.
6. Clear `pending_comments_file` from state after the plan is
   written, so subsequent steps in the same revision don't re-surface
   the comments. (The original `revisions/r<N>/comments.md` file is
   left in place — it's the durable record.)
7. On completion, append a log entry:

   ```bash
   scripts/checklist-log.sh "$ISSUE_DIR" draft "imPlan.md written ($N steps); note: $NOTE"
   ```

   Where `$N` is the number of top-level tasks in the plan.

## Halt and ask if

- `<issue-dir>/issue.md` does not exist (operator must run pull first).
- `<issue-dir>/imPlan.md` already exists and is non-empty — ask whether
  to overwrite, start a new revision, or abort.
- Active project cannot be inferred and `config.toml` has multiple
  projects.

## Skipping policy

Never auto-skip. If a precondition is unmet, surface
"step doesn't apply because X, mark skipped?" and require operator
confirmation per spec §6.3 principle.
