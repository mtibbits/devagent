---
description: File a capture draft as a tracker issue (origin or fork)
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read
argument-hint: "<capture-slug> [origin|fork]"
---

# /devagent:file

Args: `<capture-slug> [origin|fork]` (default: `origin`)

## Behavior

1. Validate that `<devdoc>/Captures/<slug>/draft.md` exists.
2. If `<devdoc>/Captures/<slug>/redteam.md` does NOT exist, warn the
   operator and require confirmation. (Filing without a red-team is
   allowed but should be a conscious choice.)
3. Call:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/capture/file.sh" --slug <slug> --target <origin|fork>
   ```

   The script reads the env var `DEVAGENT_PERMISSION_PUSH_MR` (which
   mirrors config `[project.<name>.permissions].push_mr` once exported),
   defaulting to `false`. When the gate is `false`, the script prints
   the plan and exits non-zero; the operator re-invokes with `--yes`
   to confirm.

4. On success, print the returned URL and remind the operator that
   `Captures/<slug>/filed.toml` now records the issue number.

## Targets

- `origin` — the upstream tracker repo (from
  `[project.<name>.issue_source].repo`)
- `fork` — the personal/fork tracker repo (from
  `[project.<name>.issue_source_fork].repo`)

Forks vs origins matter when working on a project where some issues
are filed to your fork (private, scratch, exploratory) and others to
the upstream organization.

## Env contract

Same as `/devagent:capture` (see its derivation table), plus the
backend env vars `file.sh` consumes:

- `DEVAGENT_PERMISSION_PUSH_MR` — the push gate (default `false`);
  mirrors config `[project.<name>.permissions].push_mr`.
- the tracker backend/repo vars from `[project.<name>.issue_source]`
  (and `issue_source_fork` for `--target fork`).

## Non-goals

- Does not transition issue state. That's `issue_workflow` hooks in
  the workflow family.
- Does not create the MR. That's `/devagent:ship`.
