---
description: Step 6: create issue branch from default_baseline.
allowed-tools: Bash
argument-hint: "[project] [issue-dir] [free-form note words ...]"
---

# /devagent:branch

Invokes `scripts/branch.sh` with the parsed arguments per spec §6.1.

The script honors all permission gates from `[project.<name>.permissions]`.
With `--auto`, the chaining layer suppresses the inter-step prompt but does
**not** suppress permission gates (spec §7.2).

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/branch.sh" $ARGUMENTS`

## Do NOT commit yet

The branch step only creates the working branch (`scripts/branch.sh`).
It does NOT commit. Implementation comes in step 7, then quality (8),
document (9), analyze (11), and finally commit (10). The commit step
intentionally follows analyze so the commit captures verified work.

If your subsequent implement/quality work feels at risk in the working
tree, use `git stash` rather than `git commit`. Premature commits
force `git commit --amend` after analyze finds issues, which is
fine locally but clutters reasoning and breaks if you'd already pushed.
