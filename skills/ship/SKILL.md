---
name: ship
description: "Step 15: push branch and open MR, fire on_ship issue transition."
when_to_use: Workflow step 15, after preship passes — push the issue branch and open its MR.
argument-hint: "[project] [issue-dir] [--strict-deps]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
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

Concretely, `fork_only = true` lets you build a backlog of changes on
your `code_source.fork` (recording per-issue context, checklist
progress, fork PRs) without notifying the upstream tracker until you
choose to flip the flag and re-engage. The upstream PR is then opened
manually (e.g. `gh pr create --repo <upstream-owner>/<repo> ...`)
because the workflow can't infer when readiness has been reached.

## Draft PRs

`ship_as_draft` in `config.toml` controls whether PRs open as drafts
(global default → project override). For per-issue draft state, create
a marker file:

```bash
touch <issue-dir>/.devagent-draft
```

When present, `ship.sh` forces `--draft` on the PR regardless of
project config. Remove the marker to resume normal (non-draft) behavior
on the next ship invocation.

## Run the script

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/ship.sh" <argument tail>

Run this now, forwarding the invocation's argument tail verbatim.
