---
description: Draft a pre-issue or epic capture under <devdoc>/Captures/<slug>/
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read, Write, Edit, Skill
argument-hint: "[issue|epic] <text>"
---

# /devagent:capture

Args: `[issue|epic] <free-form text>`

## Behavior

1. Parse args:
   - If first token is exactly `issue`, force-type = issue; remainder = text.
   - If first token is exactly `epic`, force-type = epic; remainder = text.
   - Otherwise, force-type is unset and the model decides.

2. Invoke the **core-capture** skill with the text and (if set) the
   forced type. The skill returns:
   - `type`: `issue` or `epic`
   - `subtype` (if issue): one of `bug feature docs perf chore`
   - `title`: a short title suitable for a slug
   - Optionally: a recommendation block such as
     `"this is 7 epics"` with proposed child titles. When the skill
     recommends a multi-epic split, do NOT call capture.sh seven times
     silently. Print the recommendation, ask the operator which epics
     to author, then author the chosen ones.

3. Call the script for each chosen artifact:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/capture/capture.sh" \
     --type "<type>" \
     --subtype "<subtype>"  \
     --title "<title>"
   ```

   For epics, omit `--subtype`. The script prints the slug; record it.

4. Report each created `Captures/<slug>/draft.md` path to the operator
   and suggest the next step (`/devagent:redissue <slug>` or, for
   epics, `/devagent:scaffold <slug>`).

## Non-goals

This command does NOT file the issue to any tracker. Filing is the
job of `/devagent:file` and requires the `permissions.push_mr` gate.

## Env contract

The capture/reap scripts hard-require these env vars and exit 2 if any
is unset. There is no automatic loader yet, so for now the operator
exports them in their shell; each derives from an existing source:

| Var                   | Source                                                              |
|-----------------------|--------------------------------------------------------------------|
| `DEVAGENT_PLUGIN_DIR` | `CLAUDE_PLUGIN_ROOT` — the harness-set plugin root (the same value the command wrappers already use to invoke `scripts/...`). |
| `DEVAGENT_PROJECT`    | `active_project` in `~/.claude/devagent/state/_active.toml`.        |
| `DEVAGENT_DEVDOC_DIR` | `[project.<name>].devdoc_dir` in `~/.claude/devagent/config.toml`. |

Example:

```bash
export DEVAGENT_PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT}"
export DEVAGENT_PROJECT="$(sed -n 's/^active_project = "\(.*\)"/\1/p' \
  ~/.claude/devagent/state/_active.toml)"
export DEVAGENT_DEVDOC_DIR="$(sed -n "/^\[project.${DEVAGENT_PROJECT}\]/,/^\[/s/^devdoc_dir *= *\"\(.*\)\"/\1/p" \
  ~/.claude/devagent/config.toml)"
```
