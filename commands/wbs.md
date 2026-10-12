---
description: WBS authoring and rendering (init | update | show)
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "<init|update|show> [project] [args]"
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/wbs.sh" $ARGUMENTS` with the user's arguments.

Subcommands:
- `init [--force]` — scaffold `<devdoc>/WBS.md` from the resolved `wbs_template.md` (§12 registry: project paths → devdoc → plugin default); `--force` overwrites an existing `WBS.md`
- `update` — set each issue leaf's glyph from its `Issue-N/checklist.md` and add the active issue under `Unassigned`; only a changed glyph character is rewritten, and every other line (prose, headings, comments, fenced blocks, meta formatting, line endings, a missing final newline) is written back byte-for-byte
- `show [--depth N] [--milestone X]` — with no filter, print `<devdoc>/WBS.md` as written; with `--depth`/`--milestone`, print the title and the matching nodes only

Positional `[project]` and `[issue-dir]` follow the standard devAgent
invocation grammar (§6.1). This command consumes **no note**: tokens left
after the subcommand and its flags are warned about and ignored
(`wbs-update.sh` / `wbs-show.sh`), not captured as `$NOTE`.
