---
description: Step 15: push branch and open MR, fire on_ship issue transition.
allowed-tools: Bash
argument-hint: "[project] [issue-dir] [--strict-deps] [free-form note words ...]"
---

# /devagent:ship

Invokes `scripts/ship.sh` with the parsed arguments per spec §6.1.

The script honors all permission gates from `[project.<name>.permissions]`.
With `--auto`, the chaining layer suppresses the inter-step prompt but does
**not** suppress permission gates (spec §7.2).

Before opening the MR, `ship.sh` calls Phase 9's `depends_ship_preflight`.
By default it warns when the active issue has unmerged dependencies.
Pass `--strict-deps` to escalate the warning to a hard block (exit 2,
no MR opened).

## Fork targeting

Three project-level settings under `[project.<name>]` control where
the MR lands:

| Setting              | Behavior                                                  |
|----------------------|-----------------------------------------------------------|
| (defaults)           | MR opens directly against `code_source.upstream`.         |
| `fork_first = true`  | MR opens against `code_source.fork` first; upstream PR is intended as a later step. The `on_ship` issue transition still fires on the upstream tracker. |
| `fork_only = true`   | MR opens against `code_source.fork`. The upstream tracker is NOT transitioned. Use when you're iterating on the fork and not yet ready to engage upstream. Implies `fork_first = true`; requires `code_source.fork` to be set. |

For the volk case specifically, `fork_only = true` lets you build a
backlog of changes on `mtibbits/volk` (recording per-issue context,
checklist progress, fork PRs) without notifying `gnuradio/volk` until
you choose to flip the flag and re-engage. The upstream PR is then
opened manually (e.g. `gh pr create --repo gnuradio/volk ...`)
because the workflow can't infer when readiness has been reached.

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/ship.sh" $ARGUMENTS`
