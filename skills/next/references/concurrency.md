# Concurrent sessions — history and mechanics

Moved from the former next command doc (#439/#452); the operative summary
lives in `../SKILL.md`. This file carries the archaeology: pointer-writer history,
state-atomicity guarantees, and the honored-script list.

## The global project pointer

The global project pointer (`~/.claude/devagent/state/_active.toml`) is
written ONLY by pointer/fallback-resolved `next.sh` invocations (#282) —
an arg- or env-pinned session never touches it, and `pull.sh` never writes
it (its project is always an explicit positional). Consequence: on a
multi-project install the pointer's VALUE effectively freezes — running
`next.sh <other-project>` no longer moves it. To move it deliberately, run
`/devagent:use <project>` (`scripts/use.sh`) — the one legitimate arg-driven
pointer writer (#349): it validates the project, writes the pointer via the
atomic `active_set_project` (#328), and prints the resolved state. The
per-session env pin and a direct `_active.toml` edit remain as the
per-session / fallback alternatives.

## The per-session project pin

The supported per-session pin is a Claude Code `settings.local.json`
env entry in the project directory:

```json
{ "env": { "DEVAGENT_ACTIVE_PROJECT": "<project>" } }
```

The harness injects the variable into every shell, so resolution through
the standard chain (arg → env → pointer) is pinned for that session
without consulting or touching the shared pointer. (Tooling that edits
`_active.toml` directly — e.g. capture's recipe — bypasses the pin.)

## Per-project state atomicity

Per-PROJECT state is still one file (`state/<project>.toml`): two sessions
on different issues of the *same* project can clobber the shared
`active_issue` scalar — last writer wins; `state_set` emits an advisory
stderr warning, not a lock. As of #96 all multi-key transitions are single
atomic transactions (`state_set_many`) — state can no longer TEAR (A's issue
with B's dir) and the clobber-warn reads in-lock. As of #240/#303 each issue's
`STATE_ISSUE_KEYS` live under `[context.<issue>]` — the authoritative home
read/written by `state_issue_get` / `state_issue_set_many` and snapshotted by
`state_context_save` in `scripts/lib/state.sh` — so the top-level scalars are
only a compatibility mirror for the shared active issue and same-project
sessions can no longer launder one issue's keys into another. The sole
residual is the last-writer-wins PICK of the `active_issue` scalar itself —
avoided entirely by a per-session issue pin.

## The per-session issue pin

The per-session ISSUE pin is the sibling of the project pin above:
`"env": { "DEVAGENT_ACTIVE_ISSUE": "Issue-N" }` in the directory's
`settings.local.json`. It is resolved by `active_resolve_issue_src` in
`scripts/lib/active.sh` (the env resolver; chain arg → env → shared state)
and honored by `pull.sh`, `next.sh`, `where.sh`, `park.sh`, `commit.sh`,
`cleanup.sh`, `switch.sh`, `step-model.sh`, and `resume.sh`
(pinned-mismatch die). A pinned session resolves its own issue and
never reads or writes the shared `active_issue` slot.
