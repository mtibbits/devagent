---
description: Review and tighten code quality on the active issue's branch. Wraps simplify skill + project coding standards.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:quality

Step 8 of the 21-step devAgent workflow. Runs two passes on the
changed code:

1. The `simplify` skill (reuse, quality, efficiency review).
2. A coding-standards conformance pass against the project's
   `coding_standards.md`, resolved per the spec §12 artifact registry
   (project paths → `<devdoc>/templates/` → plugin
   `${CLAUDE_PLUGIN_ROOT}/templates/coding_standards.md`).

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Resolve the coding-standards artifact path:
   - `${config.project.<name>.paths.coding_standards}` if set
   - else `<devdoc_dir>/templates/coding_standards.md` if exists
   - else `<plugin_root>/templates/coding_standards.md`
3. Verify the working tree is on the issue's branch and there are
   changed files since the baseline SHA (from state file).
4. Invoke the `simplify` skill on the changed diff.
5. Read the resolved `coding_standards.md` and check each rule
   against the changed files.
6. Apply fixes (or surface them for operator decision per simplify's
   own halt-and-ask rules).
7. On completion:

```bash
scripts/checklist-log.sh "$ISSUE_DIR" quality \
  "Quality pass: K simplify findings applied, S standards findings applied; note: $NOTE"
```

## Halt and ask if

- Working tree has uncommitted changes that aren't from the implement
  step (operator may have stray edits — confirm before reformatting).
- Coding-standards file cannot be resolved from any of the three
  registry layers.
- Simplify proposes a refactor that would touch files outside the
  current diff (surfaces a scope-creep risk).

## Skipping policy

Never auto-skip. If the diff is tiny (< 5 LOC) and no standards apply,
surface "minimal diff; mark step `[-]` skipped?" for operator
confirmation.

## Completion handoff

After marking the step `[x]` (or `[-]` if skipped) and logging:

**STOP.** Do not invoke any other `/devagent:*` command on your own.
End your final message with this exact question (substituting the
correct next-step slash command from the checklist):

> Would you like to continue on to /devagent:<next-step-name>?

The next-step name is the first line in the issue's checklist.md
that starts with `- [ ]` -- read that, take the verb after the
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
