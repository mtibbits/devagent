---
description: Harvest follow-up candidates into Captures/<slug>/draft.md (idempotent)
allowed-tools: Bash, Read, Skill
---

# /devagent:reap

Args: `[project]` (optional; defaults to active project)

## Behavior

1. Run `scripts/capture/reap.sh --dry-run` to enumerate candidates. Each row is
   `<hash>\t<subtype>\t<source>\t<title>` — the `<hash>` is the stable
   per-candidate key.
2. If candidates exist, ask the operator whether to triage. If yes, trigger the
   **core-reap** skill (passing the dry-run rows) to classify ambiguous ones
   (e.g., is `STUCK` content really an issue or just operator pain?). The skill
   returns a `DECISIONS:` block keyed by `<hash>`.
3. Apply the result:
   - **With decisions** — translate the skill's `DECISIONS:` block into a TSV
     decisions file (one `"<hash>\t<action>\t<subtype>\t<title>"` row per
     candidate; `subtype`/`title` empty unless overriding; tabs literal), then run
     `scripts/capture/reap.sh --decisions <file>`. Kept candidates are drafted
     (with overrides); discarded ones are not drafted and are recorded in the
     `[discarded]` table (skipped next run, but re-triageable by deleting the line).
   - **No triage pass** — run `scripts/capture/reap.sh` (no flags); every
     candidate is kept and drafted (back-compat).
4. Print the list of newly created `Captures/<slug>/` paths and
   suggest `/devagent:redissue <slug>` for each.

## Idempotence

The script records content hashes in
`~/.claude/devagent/state/<project>.reaped.toml`. Re-running this
command harvests only candidates added since the last run.

## Env contract

Same as `/devagent:capture`, plus:

- `DEVAGENT_STATE_DIR` (default `~/.claude/devagent/state`)
