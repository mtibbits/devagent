---
description: "Step 19: squash-merge the issue branch into the local all_prs_branch (e.g. dev/all-prs). Local only — does not close the PR."
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[project] [issue-dir]"
---

# /devagent:mergetoall

Invokes `scripts/mergetoall.sh` with the parsed arguments per spec §6.1.

**Optional step, off by default:** checklists scaffold row 19 pre-skipped
`[-]`; configuring the per-project `all_prs_branch` flips it back to pending
at scaffold time. The script keeps its own unconfigured/zero-diff auto-skip
as a runtime backstop — that covers config REMOVED mid-issue only. Adding
`all_prs_branch` mid-issue does not re-open an already-scaffolded `[-]` row
(next.sh never dispatches a skipped row); opt that issue in manually:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-mark.sh" --by-name <issue-dir> mergetoall " "
```

The manual opt-in is per-revision: `/devagent:revise` (and `--retier`)
re-applies the config-derived glyph in the new revision block, matching
research/spike semantics — re-mark after revising if still wanted.

**What it does (local only):**
1. `git checkout <all_prs_branch>` (e.g. `dev/all-prs`)
2. `git merge --squash <issue-branch>`
3. `git commit` with the branch tip's subject

**What it does NOT do:**
- No `gh pr close` or `gh pr merge` — the PR (if any) is untouched.
- No `git push` of `<all_prs_branch>` UNLESS the per-project
  `all_prs_auto_push = true` flag is set, in which case it does
  `git push <all_prs_remote> <all_prs_branch>` after the local
  merge. Push failure is non-fatal (warning, local commit retained).
  `all_prs_remote` defaults to `source_remote` (which defaults to
  `origin`).

Honors `permissions.merge_to_all_prs` only; `permissions.merge_mr` no
longer gates this step (#885: it approves `/devagent:mergemr`). With `--auto`, the
chaining layer suppresses the inter-step prompt but does **not**
suppress permission gates (spec §7.2).

## Requires green CI (#782)

When the issue has a recorded MR (`mr_url`, set by ship), the script reads
the MR's CI once (bounded at 20 s) after its auto-skips and before it
fetches or prompts, prints one `CI …:` line, and acts on it:

- **Green** (`CI PASSED`), or a backend with no `mr-checks` (`CI NOT
  CHECKED`): merges as before. A configured backend whose script is missing
  reads `CI UNKNOWN` and holds.
- **Pending or unknown** (`CI PENDING`, `CI UNKNOWN`): exits 1 with
  `mergetoall: not merging until CI is green; nothing was marked`. Row 19
  stays `[ ]`; run `/devagent:next` again once CI has finished. Do not
  poll for it.
- **No checks** (`CI NONE`): holds the same way for 120 s after devagent
  first sees a new head commit (checks may not have registered yet), then
  merges.
- **Red** (`CI FAILED`): marks row 19 `[!]` and writes `STUCK` with the
  `CI FAILED:` line. The remedy depends on the failure:
  - a test failure: push a fix to the issue branch;
  - a check shown with `[ACTION_REQUIRED]`, `[STARTUP_FAILURE]`,
    `[CANCELLED]` or `[TIMED_OUT]`: approve or re-run the workflow on the
    forge.

  Either way, then run `/devagent:unstuck` and `/devagent:next`.
- **Local branch is not the MR head** (a commit not pushed yet, or a
  branch behind a push made elsewhere): exits 1 with `mergetoall: local
  <branch> (<sha7>) is not the MR head CI checked (<sha7>)`, nothing
  marked. Push or pull the branch, let CI run on it, and re-run. The
  squash takes the local branch, so this keeps unchecked code out of
  `all_prs_branch`.

`DA_YES=1` does not bypass this: the CI check runs before the permission
gate. The only way past a red or pending CI is the reviewed de-scope
`ci_gate = "off"` (per project, or under `[defaults]`), which skips the
read entirely.

## If the permission gate prompts

If `merge_to_all_prs = false` (or unset) and you (the model) are
running this without an interactive tty, the gate will halt. Do NOT
flip `merge_to_all_prs = true` in `~/.claude/devagent/config.toml`
on your own — that's a self-elevation the auto-classifier blocks and
that bakes an indefinite policy change into a one-time decision.

Instead:
1. Surface the halt to the operator with a brief summary of what the
   gate is gating (local squash-merge into the all_prs_branch — no
   remote effect).
2. If the operator approves, re-run with `DA_YES=1` prefix for a
   one-time bypass:
   `DA_YES=1 bash "${CLAUDE_PLUGIN_ROOT}/scripts/mergetoall.sh" ...`
3. If the operator says "yes, and always" — only THEN ask them to
   set `merge_to_all_prs = true` permanently (they can edit
   `config.toml` themselves or grant you explicit permission to do
   the edit).

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/mergetoall.sh" $ARGUMENTS`
