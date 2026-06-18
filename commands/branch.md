---
description: "Step 6: create issue branch from default_baseline (or a per-issue baseline override)."
allowed-tools: Bash
argument-hint: "[project] [issue-dir] [free-form note words ...]"
---

# /devagent:branch

Invokes `scripts/branch.sh` with the parsed arguments per spec §6.1.

## Per-issue baseline override (#162)

By default the branch is cut from the project's `default_baseline`
(e.g. `origin/main`). An issue whose changes touch files that exist only on a
non-default branch — e.g. a fork-only harness living on an integration branch
like `dev/all-prs` — cannot be branched from the default base (the target files
aren't there). For those, drop a **`.devagent-baseline`** marker file in the
issue directory (alongside the `.devagent-type` / `.devagent-title` markers):

```bash
printf '%s' "dev/all-prs" > "<issue-dir>/.devagent-baseline"
```

`branch.sh` then cuts the branch from that ref and records it as `baseline_sha`,
which is exactly the signal the stacked-child ship logic (#34) uses to base the
PR on the override branch rather than `default_baseline` — so ship + mergetoall
follow automatically, no further configuration.

Rules:
- The marker accepts a local branch (`dev/all-prs`) or a `remote/branch` ref
  (`fork/dev-all-prs`); the contents are treated strictly as a git ref
  (ref-charset only — no shell metacharacters).
- An override that does not resolve is a **hard error**: `branch.sh` exits
  non-zero and creates no branch. It never silently falls back to
  `default_baseline` or `HEAD` (that silent fallback, on the *default* path, is
  the separate concern tracked by #72).
- No marker ⇒ unchanged behavior (cut from `default_baseline`).

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
