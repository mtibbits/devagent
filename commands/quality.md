---
description: Review and tighten code quality on the active issue's branch.
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read, Write, Edit, Skill
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:quality

Step 8 of the 22-step devAgent workflow. Runs two passes on the
changed code:

1. The `simplify` skill (reuse, quality, efficiency review).
2. A coding-standards conformance pass against the project's
   `coding_standards.md`, resolved per the spec §12 artifact registry
   (project paths → `<devdoc>/templates/` → plugin default for `coding_standards.md`).

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Resolve the coding-standards artifact path:
   - `${config.project.<name>.paths.coding_standards}` if set
   - else `<devdoc_dir>/templates/coding_standards.md` if exists
   - else `<plugin_root>/templates/coding_standards.md`
3. **Zero-diff gate.** Verify the working tree is on the issue's branch,
   then check for any change since the baseline SHA. Resolve
   `baseline_sha` from `~/.claude/devagent/state/<project>.toml` and
   `source_dir` from config, then:

   ```bash
   git -C "$source_dir" rev-list HEAD "^$baseline_sha" 2>/dev/null
   git -C "$source_dir" status --porcelain
   ```

   If both are empty — no commits ahead of baseline and no
   working-tree changes (an artifact-only issue) — there is nothing to
   review. Auto-mark step 8 `[-]`, log, and skip the rest of this
   workflow WITHOUT asking the operator. This mirrors the script-level
   zero-diff guards in commit/ship/mergetoall (#3):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-mark.sh" "$ISSUE_DIR" 8 -
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" quality "auto-skipped: zero diff (artifact-only issue)"
   ```

   Otherwise, continue to the simplify pass.
4. Invoke the `simplify` skill on the changed diff.
5. Read the resolved `coding_standards.md` and check each rule
   against the changed files.
6. Apply fixes (or surface them for operator decision per simplify's
   own halt-and-ask rules).
7. On completion:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" quality \
  "Quality pass: K simplify findings applied, S standards findings applied; note: $NOTE"
```

## Halt and ask if

- Working tree has uncommitted changes at entry (implement commits
  per-task, so these are stray operator edits — confirm before
  reformatting).
- Coding-standards file cannot be resolved from any of the three
  registry layers.
- Simplify proposes a refactor that would touch files outside the
  current diff (surfaces a scope-creep risk).

## Skipping policy

Auto-skip ONLY on a true zero diff (artifact-only issue — see Workflow
step 3): mark `[-]`, log, and advance without operator confirmation,
matching the script-level guards from #3.

For a tiny-but-nonzero diff (< 5 LOC) where no standards apply, do NOT
auto-skip — surface "minimal diff; mark step `[-]` skipped?" for
operator confirmation.

## Commit your fixes

If this step changed any tracked file, `git add` and `git commit -s`
the fixes as their own commit — not an amend — so the quality delta
stays auditable next to implement's task commits. The commit step
(10) then verifies everything is on the branch, and analyze (11)
runs against the committed work. Do not leave quality fixes sitting
uncommitted in the working tree.

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
