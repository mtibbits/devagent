---
description: Record or list issue dependencies (Issue-A depends on Issue-B).
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[--project P] <A> on <B> | list"
---

# /devagent:depends

Record or display dependencies between issues.

## Forms

- `/devagent:depends <A> on <B>` — record that Issue A depends on Issue B.
- `/devagent:depends list` — print the dependency graph for the active project.
- `/devagent:depends --project P list` — print the graph for a named project (`--project` is the ONLY way to name a non-active project; a bare first token is parsed as Issue A).

## Behavior

- Refuses to create a cycle (direct or transitive).
- Idempotent: re-recording the same edge is a no-op.
- Refuses self-dependency.
- `ship.sh` calls a pre-flight hook (`depends_ship_preflight`) that warns
  when an issue is shipped with unmerged dependencies. Pass `--strict-deps`
  to `/devagent:ship` to escalate the warning to a hard block.

## Invocation

Run the entry script with the parsed arguments:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/depends.sh" $ARGUMENTS
```
