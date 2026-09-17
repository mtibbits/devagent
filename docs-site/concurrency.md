<!-- derived-from: README.md skills/next/references/concurrency.md -->
# Multi-project & concurrency

## One machine, many projects

devAgent tracks which project is active in a shared pointer file,
`~/.claude/devagent/state/_active.toml`. To switch the active project
deliberately, run `/devagent:use <project>` — the one arg-driven writer of
the shared pointer; hand-editing `_active.toml` is the fallback. Each
project's own state (active issue, branch, per-issue context) lives in its
own `~/.claude/devagent/state/<project>.toml`.

## Per-session pins

Running two Claude Code sessions at once? Pin each session in that working
directory's `.claude/settings.local.json` so it never touches the shared
pointer:

```json
{ "env": { "DEVAGENT_ACTIVE_PROJECT": "myproj",
           "DEVAGENT_ACTIVE_ISSUE": "Issue-42" } }
```

A pinned session never reads or writes the shared pointer or the project's
shared `active_issue` scalar:

- **Different projects** are safe to run concurrently as of
  [#282](https://github.com/mtibbits/devagent/issues/282) — the shared
  pointer is only written when actually consulted.
- **Same-project sessions** are isolated per issue as of
  [#240](https://github.com/mtibbits/devagent/issues/240)/[#303](https://github.com/mtibbits/devagent/issues/303):
  each issue's state lives under its own `[context.<issue>]` table, so keys
  cannot launder between issues. The `DEVAGENT_ACTIVE_ISSUE` pin closes the
  last residual (the last-writer-wins pick of the shared `active_issue`
  scalar).

## The wrong-scope guard

A script invoked without a project acts on whatever the shared pointer names —
which may not be the project you are working in. Since
[#572](https://github.com/mtibbits/devagent/issues/572), write-, verify- and
transition-capable scripts refuse a bare invocation when your working
directory demonstrably belongs to a *different* configured project than the
one that resolved: the error names both projects, both active issues, and
where the resolution came from. Passing the project explicitly (positionally
or via `--project`) always satisfies the *scope* guard; running from a
directory outside any configured project proceeds with a warning naming what
was resolved. The per-call escape hatch is `DEVAGENT_SCOPE_GUARD_OVERRIDE=1`
(an empty or `0` value does not disable it). The full PROTECTED/EXEMPT triage
lives in `docs/resolver-scope-triage.md`. Separately, since
[#571](https://github.com/mtibbits/devagent/issues/571) the two *evidence*
scripts (`run-suite.sh`, `preship-evidence.sh`) also check WHICH CHECKOUT of
the correctly-resolved project they would measure: invoking them from a
linked worktree or an equal-`origin` clone of the tree about to be measured
refuses with `TREE MISMATCH` **even when the project was passed explicitly**
— re-run from the measured tree, record your checkout as the issue's
`worktree_path`, or use the per-call `DEVAGENT_TREE_GUARD_OVERRIDE=1`.

## Parking

Issues pause and resume without losing place:

- `/devagent:park` — park the active issue (marked `[P]`).
- `/devagent:resume` — reactivate a parked issue.
- `/devagent:switch` — park the current issue and resume a different one in
  one step.

Parked issues are listed on a `Parked:` line in `/devagent:status` (the `[P]`
glyph lives in the issue's checklist), the multi-project dashboard
of active issues, stuck steps, and parked work.

[← devAgent onboarding](./index.md)
