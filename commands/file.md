---
description: File a capture draft as a tracker issue (origin or fork)
allowed-tools: Bash, Read
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
   scripts/capture/file.sh --slug <slug> --target <origin|fork>
   ```

   The script enforces the `permissions.push_mr` gate. If the gate
   is closed, the script prints the plan and exits non-zero; the
   operator re-invokes with `--yes` to confirm.

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

Same as `/devagent:capture`, plus the backend env vars consumed by
`file.sh`.

## Non-goals

- Does not transition issue state. That's `issue_workflow` hooks in
  the workflow family.
- Does not create the MR. That's `/devagent:ship`.
