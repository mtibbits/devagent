# Resolver-scope triage (#572)

The 18 scripts that resolve the active project — the 17 call sites of
`active_resolve_project` plus `next.sh`, which calls
`active_resolve_project_src` directly — classified PROTECTED (a wrong scope
writes, verifies, or transitions against the wrong project; the site calls
`active_guard_scope`) or EXEMPT (read-only and self-identifying; no guard).
Line anchors are at the pre-change baseline `86efe8c`.

Derivation (the sweep test `tests/resolver-scope-triage.bats` re-runs this and
diffs it against the rows below):

```bash
grep -rln 'active_resolve_project' scripts/ \
  | grep -v '^scripts/lib/active.sh$' | grep -v '^scripts/wbs.sh$'   # 18 files
```

Excluded non-members: `scripts/lib/active.sh` (defines the resolver) and
`scripts/wbs.sh` (comment-only match at `:5`; a pure dispatcher that `exec`s
`wbs-init.sh` / `wbs-update.sh` / `wbs-show.sh`, all listed).

| script | class | reason | `config_is_project` |
|---|---|---|---|
| `born-red.sh` | PROTECTED | creates worktrees at another project's `baseline_sha` and writes the gate artifact `commit.sh` reads — a wrong scope greens or FLAGs the wrong issue | validates (`:40`) |
| `checklist-init.sh` | PROTECTED | resolved project selects the per-project checklist template (§12 registry, `:38-39`); a wrong scope writes another project's template into the named issue dir | no-validation |
| `comments.sh` | PROTECTED | writes `<issue-dir>/revisions/r<N>/comments.md` and appends a `## Log` line in the resolved project | no-validation |
| `depends.sh` | PROTECTED | `depends_add` records into another project's dependency graph; the read-only `list` form shares the same resolution site | no-validation |
| `grep.sh` | EXEMPT | read-only search; every output line is prefixed with the issue-dir path, so a wrong scope is self-identifying and leaves no record | no-validation |
| `history.sh` | EXEMPT | read-only chronological print with the same self-identifying path prefix | no-validation |
| `next.sh` | PROTECTED | dispatches and execs write-capable step scripts against the resolved project and refreshes the global pointer; largest blast radius of the set | validates (`:53`) |
| `preship-evidence.sh` | PROTECTED | emits a PASS/FAIL verdict about another project's MR — the print-only PROTECTED site (#572's second observed misfire) | validates (`:36`) |
| `record-scope.sh` | PROTECTED | writes `.devagent-scope` into another project's issue dir, driving `commit_autostage` | validates (`:29`) |
| `rederive.sh` | PROTECTED | writes `analysis/<date>-rederive.txt` into another project's issue dir | validates (`:27`) |
| `revise.sh` | PROTECTED | appends a revision block to another project's `checklist.md` and mutates its state | no-validation |
| `run-suite.sh` | PROTECTED | `cd`s into another project's resolved tree (`worktree_path` else `source_dir`, #571), runs its suite and writes the canonical evidence artifact | validates (`:38`) |
| `statusreport.sh` | PROTECTED | writes `StatusReports/<date>.md`, then `git add` + `git commit -s` in another project's devdoc repo and pins its state | validates (`:46`) |
| `template.sh` | EXEMPT | read-only resolver/printer; the `# === template <key> (layer=<L>) ===` banner names the resolved file, so a wrong scope is self-identifying — and it is the workflow's hottest script, called with `--project` at five sites | no-validation |
| `transition-draft-start.sh` | PROTECTED | the only OFF-MACHINE effect: fires a real `on_draft_start` tracker transition for `transition_issue = true` projects | no-validation |
| `wbs-init.sh` | PROTECTED | scaffolds `<devdoc>/WBS.md` in another project | validates (`:36`) |
| `wbs-show.sh` | EXEMPT | read-only render of another project's WBS; no write, no verdict | validates (`:39`) |
| `wbs-update.sh` | PROTECTED | rewrites another project's committed `WBS.md` (#572's first observed misfire) | validates (`:53`) |

Counts: **14 PROTECTED, 4 EXEMPT; 10 validate, 8 no-validation.** The eight
non-validating sites are `checklist-init`, `comments`, `depends`, `grep`,
`history`, `revise`, `template`, `transition-draft-start`. Four of those eight
are PROTECTED (`checklist-init`, `comments`, `revise`,
`transition-draft-start`) — follow-up candidates for adding validation, out of
scope for #572 (AC1 records the status only).

## Blind spot (register: Issue-558)

This table classifies **sites**, not forms: `depends.sh` and `next.sh` each
carry both a read-only and a write-capable form behind one resolution site, so
the table protects the site at its worst form. A future read-only subcommand
added to a PROTECTED script inherits the guard; that is the safe direction.
The guard itself cannot decide a scope when `$PWD` is under no configured
`source_dir` — that branch allows with a warning naming the resolved project
and its resolution source (see `active_guard_scope` in `scripts/lib/active.sh`).
Its fast path also cannot see NESTED configured source_dirs: cwd inside an
inner project satisfies the resolved outer project's ancestor walk and is
allowed. No configured projects nest today; the fast path's header says to
drop it if they ever do. A git WORKTREE of a project (`branch.sh`'s
`<source_dir>-wt` convention) is likewise outside every configured
`source_dir`, so invocations from inside one land on the warned UNDECIDABLE
branch — a known workflow-internal shape. The SCOPE question stays undecidable
there (#572's domain, unchanged); the TREE question now has an answer:
`active_guard_tree` (#571, `scripts/lib/active.sh`) refuses an evidence run
invoked from a linked worktree — or an equal-`origin` clone — of the tree it
would measure, via exactly the `git rev-parse --git-common-dir` derivation the
earlier follow-up candidate here named.
