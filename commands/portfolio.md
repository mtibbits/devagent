---
description: Write one portfolio JSON document over every configured project's WBS, or list ready leaves (--ready)
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[--out PATH | --ready]"
---

# /devagent:portfolio

**Usage:** `/devagent:portfolio [--out PATH | --ready]`

Writes one document that describes every configured project's `WBS.md`
(#726). The document conforms to the portfolio schema v1.4; its contract is
[`docs/portfolio-schema.md`](../docs/portfolio-schema.md), and spec §13.4
introduces it. The command is read-only. It writes the one document and
nothing else: no `WBS.md`, no state, and no devdoc file. With `--ready` it
writes nothing and prints every project's ready leaves instead (#727; see
"Ready leaves" below).

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
  uses), and `<devdoc>/<issue>/STUCK` gives `stuck` (with `stuck.kind`, the
  header's `Kind:`, since 1.4).
- **Devagent state** (#963). `<devagent_home>/state/<project>.toml` is read,
  never written, for its `[parked]` keys: an issue that is a key there has
  `parked: true`. A project with no state file has no parked issues. A state
  file that cannot be loaded, or whose `parked` is not a table, gives every
  issue of that project `parked: null`, one `state_unreadable` entry (which
  does not name the path), and no ready leaf that carries an issue.
- **Actuals** (#735). `<devagent_home>/actuals.json`, built by
  `/devagent:actuals` (and by cleanup when it is stale), is read, never run:
  each issue's row fills its `actuals` slot, each project's row its `actuals`
  field, and the file's `actuals_version`, `generated_at` and `unassigned` the
  document's top-level `actuals`. A row whose issue is on no node is ignored.
  When the file is missing, unreadable, not a usable actuals document, or
  generated more than 7 days before the document, every one of them is null
  and each project gets one `actuals_unavailable` entry saying why; the run
  still writes and exits 0.

## Output

By default the document is written to
`~/.claude/devagent/portfolio/portfolio.json` (under `devagent_home`). It is
written atomically and, where the platform supports it, is readable by its
owner only (mode 0600); any directory the command creates is 0700. `--out PATH` chooses another file.

**Privacy.** The document names every configured project, private ones
included, and since schema 1.3 (#735) its actuals slots carry transcript
session ids, host names, cwd slugs and, in the top-level `actuals.unassigned`
rows, the working directories of work no project claimed. Keep it outside every
devdoc and every repository: every devdoc commit reaches origin at the next
cleanup (#1148). The command refuses an `--out` inside any git work tree (by
git's own answer for the nearest existing directory; it fails closed when git
cannot answer), and under any configured `devdoc_dir`, `source_dir` or
`worktree_root` (both sides are canonicalised first). When `worktree_root` is unset or empty, the rail treats
`<source_dir>-wt` as the worktree root (the rule trust applies) and refuses
`--out` under it the same way.

Before writing, the command checks its own document. It runs the structural
checker (`portfolio-check.py`) and the producer's cross-field invariants
I1–I17 (`invariant_violations` in `scripts/lib/portfolio.py`). If either
fails, nothing is written. Under `--ready` the same check runs before anything
is printed, and if it fails, nothing is printed.

## Parse report

`parse_report` lists every problem met while reading, one entry per problem
with its project, `WBS.md` line and kind: issue-less leaves, unresolved
`depends_on` references (local and cross-project), dependencies on skipped
rows (`dep_skipped`), dependency cycles (`dep_cycle`), parents marked done
with pending leaves under them (`parent_done_leaf_pending`), duplicate issues,
unparseable estimates, unknown or unreadable metadata, lines shaped like nodes
that are not nodes, parser warnings, and an actuals file that could not be
used (`actuals_unavailable`, one per project), and a devagent state file that
could not be read (`state_unreadable`, one per project). The kinds are listed in the
schema doc's "Report kinds" table.

## Ready leaves (`--ready`)

`--ready` lists the leaves you could start now, across every project, instead
of writing the document. It builds the same document in memory, without
actuals, and fills its
readiness fields by the rule below; the document itself carries them too.

<!-- editor: tests/test_portfolio.py::test_command_doc_defines_ready requires
     the block between these markers to hold rules 1. to 5., the report kinds
     and fields it names, the line-format paragraph and the order paragraph.
     The readiness engine (compute_readiness in scripts/lib/portfolio.py)
     implements exactly this text. -->
<!-- ready-rule:start -->
A leaf is **ready** when all of these hold:

1. Its state is pending (`[ ]`), and, when it has an issue, that issue's
   entry has no `stuck` and a `parked` of false. In progress, stuck, parked,
   blocked externally, done and skipped leaves are not ready, and neither is a
   leaf with an issue that has a `STUCK` file, is parked in devagent's state,
   or belongs to a project whose devagent state could not be read
   (`state_unreadable`).
2. Its effective dependencies are its own `depends_on` plus the
   `depends_on` of every ancestor row.
3. Every effective dependency resolves, within the same project — or, for a
   `<project>:<issue>` entry, within the named project — to a node whose
   `issue:` equals the reference.
4. Every node it resolves to is done (`[x]`). If an id appears on two rows,
   both must be done.
5. No ancestor row is parked, stuck, blocked externally or skipped. A
   pending leaf under a parent marked done is still ready, and the parse
   report notes the inconsistent parent.

Special cases:

- **An unresolved reference blocks.** The leaf is not ready, and the parse
  report names the reference (`dep_unresolved`): an outline number such as
  `4.1`, an issue no node carries, or a `<project>:<issue>` entry whose
  project is not configured, was not read, or carries no such issue. A bare
  `Issue-N` resolves only within its own project, never across projects;
  `<own project>:Issue-N` means the same as `Issue-N`.
- **A skipped target blocks.** A dependency on a skipped (`[-]`) row is not
  satisfied: the leaf is not ready, and the parse report says so
  (`dep_skipped`), so you decide whether the dependent work still makes sense.
- **A parent-row target is judged by its glyph as written.** The leaf carries
  `ready_via_parent_row: true` in the document. Such a row's state is hand-set
  today (`wbs update` never sets a parent's glyph); once #788 lands, a
  `status_src: rollup` parent's state is derived instead, and the field's
  meaning does not change.
- **A cycle blocks.** Leaves caught in a dependency cycle are not ready, and
  the parse report names the cycle once, at its first member (`dep_cycle`).
  Cycles are found over effective dependencies, so a parent that depends on
  its own child counts. A cycle among done rows blocks nothing but is still
  reported.
- **A done parent does not block.** A pending leaf under a parent marked done
  is ready; the parent is reported once, with the pending leaves under it
  (`parent_done_leaf_pending`).

In the document, `ready` is a boolean on every leaf and null on every parent,
and `depends_on[].resolved` is `true` exactly when the entry is not reported
as `dep_unresolved`.

The view prints one line per ready leaf with four fields, `project`, `issue`,
`est` and `text`, separated by a TAB and ended by LF, in UTF-8. `issue` is
empty for a leaf with no issue; `est` is the estimate as written (a list is
joined with `, `), empty when there is none, never `0`. A TAB, CR or LF inside
a field prints as one space.

Lines come in config order of the projects, then by each leaf's
`source_line`, so two runs over the same input print the same lines.
<!-- ready-rule:end -->

Fields may be empty, so two TABs can be adjacent. The output is therefore
**not** safe for `IFS=$'\t' read`, which collapses them; read it with `cut -f`
or `awk -F'\t'`. A sample line, then a leaf with no issue (`<TAB>` stands for
the TAB character):

    alpha<TAB>Issue-12<TAB>1h, 2h<TAB>Ready the schema
    alpha<TAB><TAB>?w<TAB>Spike the importer

When no leaf is ready, the view prints nothing and exits 0. Each project the
command could not read gets one line on stderr, `portfolio: <project>: not
read (<status>); its leaves are not listed`, so "nothing is ready" and "could
not read" differ. A project whose `WBS.md` was read but whose devagent state
could not be (#963) gets `portfolio: <project>: devagent state could not be
read; leaves with an issue are not listed`; its leaves without an issue are
still listed. `--ready` writes nothing (no document, no devdoc file) and
refuses `--out` (exit 2). To read the parse report, run without `--ready`.

## Estimates

`est` is classified by the WBS key contract's `classify_estimate`
(`scripts/lib/wbs-parser.py`; spec §13.1), which this command calls rather
than parsing the value itself. Units match exactly, in agent hours: `h` = 1,
`d` = 8, `w` = 40. A range such as `2-4d` is `time` with a low and a high bound
(16 and 32 hours). A placeholder such as `?w` is `placeholder`; a number with
another unit, such as `48pr`, is `non-time`; a bare number, a reversed range
(`4-2d`) or free text is `unparseable` and is reported as `est_unparseable`.
`tok`, the token estimate, is carried in the node's `meta`, not as a typed
field (#941); an unparseable `tok` is reported as `tok_unparseable`.

## Exit status

<!-- editor: test_command_doc_exit_map requires one row per EXIT_* constant in
     scripts/lib/portfolio.py, in order. -->

| Exit | Meaning |
|---|---|
| `0` | Written, or printed under `--ready`. A project with no WBS or an unreadable WBS is a status in the document, not a failure. |
| `1` | `config.toml` is missing or invalid. |
| `2` | A usage error (`--ready` with `--out` included), a refused `--out`, or an unwritable `--out`. |
| `3` | The self-check failed; nothing was written or printed. |

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/portfolio.sh" $ARGUMENTS
```
