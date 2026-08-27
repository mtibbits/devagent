---
name: capture
description: Draft a pre-issue or epic capture under <devdoc>/Captures/<slug>/
when_to_use: To capture a new idea as an issue or epic draft before filing.
argument-hint: "[issue|epic] <text>"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *), Read, Write, Edit, Skill
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
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/capture/capture.sh" --type "<type>" --subtype "<subtype>" --title "<title>"
   ```

   For epics, omit `--subtype`. The script prints the slug; record it.

4. Report each created `Captures/<slug>/draft.md` path to the operator
   and suggest the next step (`/devagent:redissue <slug>` or, for
   epics, `/devagent:scaffold <slug>`).

## Non-goals

This skill does NOT file the issue to any tracker. Filing is the
job of `/devagent:file` and requires the `permissions.push_mr` gate.

## Env contract

The capture/reap scripts read three env vars. There is no automatic loader
yet, so for now the operator exports them in their shell.

| Var | Role | Source |
|-----|------|--------|
| `DEVAGENT_PLUGIN_DIR` | locates scripts + templates; required. | `CLAUDE_PLUGIN_ROOT` — the harness-set plugin root. |
| `DEVAGENT_DEVDOC_DIR` | **governs WHERE the draft is written** (`<devdoc>/Captures/<slug>/`); required. | `[project.<name>].devdoc_dir` in `~/.claude/devagent/config.toml`, for the project you are capturing FOR. |
| `DEVAGENT_PROJECT` | names the project you are capturing FOR. `capture.sh`: optional — fills `{{project}}` and picks up a `[project.<name>.paths]` template override. `reap.sh`: **required** (exit 2), and it keys the ledger `<state>/$DEVAGENT_PROJECT.reaped.toml`. | You type it. |

**Do not derive `DEVAGENT_PROJECT` from `~/.claude/devagent/state/_active.toml`.**
That global pointer names whichever project was last made active, not the one
you are capturing for; deriving from it silently files the draft — and reap's
ledger — under the wrong project.

Example — name the project first, then paste:

```bash
export DEVAGENT_PROJECT="${DEVAGENT_PROJECT:?name the project you are capturing FOR, e.g. devagent}"
export DEVAGENT_PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:?harness-set; export it by hand in a plain shell}"
DEVAGENT_DEVDOC_DIR="$(python3 "${DEVAGENT_PLUGIN_DIR}/scripts/lib/_toml.py" get \
  ~/.claude/devagent/config.toml "project.${DEVAGENT_PROJECT}.devdoc_dir")" \
  || echo "no devdoc_dir for '${DEVAGENT_PROJECT}' in config.toml" >&2
export DEVAGENT_DEVDOC_DIR
```

That lookup takes a literal TOML key path, not a `sed` regex: a name with
regex metacharacters cannot spill into another project's block, and an
unknown name yields an empty value plus a loud message.
