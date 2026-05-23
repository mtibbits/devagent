---
description: Harvest follow-up candidates into Captures/<slug>/draft.md (idempotent)
allowed-tools: Bash, Read, Skill
---

# /devagent:reap

Args: `[project]` (optional; defaults to active project)

## Behavior

1. Run `scripts/capture/reap.sh --dry-run` to enumerate candidates.
2. If candidates exist, ask the operator: review the list, optionally
   trigger the **devagent-reap** skill to classify ambiguous ones
   (e.g., is `STUCK` content really an issue or just operator pain?).
3. Run `scripts/capture/reap.sh` (no `--dry-run`) to write drafts.
4. Print the list of newly created `Captures/<slug>/` paths and
   suggest `/devagent:redissue <slug>` for each.

## Idempotence

The script records content hashes in
`~/.claude/devagent/state/<project>.reaped.toml`. Re-running this
command harvests only candidates added since the last run.

## Env contract

Same as `/devagent:capture`, plus:

- `DEVAGENT_STATE_DIR` (default `~/.claude/devagent/state`)
