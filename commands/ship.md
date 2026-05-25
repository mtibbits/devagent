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

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/ship.sh" $ARGUMENTS`
