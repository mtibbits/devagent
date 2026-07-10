---
description: "Step 16: squash-merge the issue branch into the local all_prs_branch (e.g. dev/all-prs). Local only — does not close the PR."
allowed-tools: Bash
argument-hint: "[project] [issue-dir]"
---

# /devagent:mergetoall

Invokes `scripts/mergetoall.sh` with the parsed arguments per spec §6.1.

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

Honors `permissions.merge_to_all_prs` (falls back to the legacy
`permissions.merge_mr` name for backward compat). With `--auto`, the
chaining layer suppresses the inter-step prompt but does **not**
suppress permission gates (spec §7.2).

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
