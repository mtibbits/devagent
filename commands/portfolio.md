---
description: Write one portfolio JSON document over every configured project's WBS
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[--out PATH]"
---

# /devagent:portfolio

**Usage:** `/devagent:portfolio [--out PATH]`

Writes one document that describes every configured project's `WBS.md`
(#726). The document conforms to the portfolio schema v1.0; its contract is
[`docs/portfolio-schema.md`](../docs/portfolio-schema.md), and spec §13.4
introduces it. The command is read-only. It writes the one document and
nothing else: no `WBS.md`, no state, and no devdoc file.

## Inputs

- **Projects.** Every `[project.<name>]` table in `config.toml`, in file
  order, through `config_list_projects`. No directory glob is used.
- **Each project's devdoc.** The project's own `devdoc_dir`. A project with no
  `devdoc_dir`, an empty one, or one that does not exist or is not a directory
  is reported with the status `no_devdoc_dir` and the run goes on; so does a
  project with no `WBS.md` (`no_wbs`), or with an unreadable devdoc dir or
  `WBS.md` (`unreadable`).
- **Each issue dir.** For an issue id on a node, `<devdoc>/<issue>/checklist.md`
  gives `checklist`, `next_step` and `next_step_number` (the rule `next.sh`
  uses), and `<devdoc>/<issue>/STUCK` gives `stuck`.

## Output

By default the document is written to
`~/.claude/devagent/portfolio/portfolio.json` (under `devagent_home`). It is
written atomically and, where the platform supports it, is readable by its
owner only (mode 0600); any directory the command creates is 0700. `--out PATH` chooses another file.

**Privacy.** The document names every configured project, private ones
included. Keep it outside every devdoc: `cleanup` stages and pushes everything
under a project's `devdoc_dir`. The command refuses an `--out` under any
configured `devdoc_dir`, `source_dir` or `worktree_root` (both sides are
canonicalised first). The default worktree root, used when `worktree_root` is
unset, is not checked yet; keep `--out` out of it too.

Before writing, the command checks its own document. It runs the structural
checker (`portfolio-check.py`) and the producer's cross-field invariants
I1–I16 (`invariant_violations` in `scripts/lib/portfolio.py`). If either
fails, nothing is written.

## Parse report

`parse_report` lists every problem met while reading, one entry per problem
with its project, `WBS.md` line and kind: issue-less leaves, unresolved
`depends_on` references (local and cross-project), duplicate issues,
unparseable estimates, unknown or unreadable metadata, lines shaped like nodes
that are not nodes, and parser warnings. The kinds are listed in the schema
doc's "Report kinds (#726)" table.

## Estimates (interim classifier)

Until #737 ships its classifier, `est` is classified here. Units must match
exactly, and the hour factors are **provisional** working-time hours:
`h` = 1, `d` = 8, `w` = 40. A placeholder such as `?w` is `placeholder`; a
number with another unit, such as `48pr`, is `non-time`; a range, a bare
number or free text is `unparseable` and is reported. #737's helper replaces
this classifier and its factors when it lands.

## Exit status

<!-- editor: test_command_doc_exit_map requires one row per EXIT_* constant in
     scripts/lib/portfolio.py, in order. -->

| Exit | Meaning |
|---|---|
| `0` | Written. A project with no WBS or an unreadable WBS is a status in the document, not a failure. |
| `1` | `config.toml` is missing or invalid. |
| `2` | A usage error, a refused `--out`, or an unwritable `--out`. |
| `3` | The self-check failed; nothing was written. |

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/portfolio.sh" $ARGUMENTS
```
