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

## Parking

Issues pause and resume without losing place:

- `/devagent:park` — park the active issue (marked `[P]`).
- `/devagent:resume` — reactivate a parked issue.
- `/devagent:switch` — park the current issue and resume a different one in
  one step.

Parked issues show `[P]` in `/devagent:status`, the multi-project dashboard
of active issues, stuck steps, and parked work.

[← devAgent onboarding](./index.md)
