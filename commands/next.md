---
description: Execute the next actionable step on the active issue
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
argument-hint: "[project] [--auto] [--through <step>] [-- <note>]"
---

# /devagent:next

**Usage:** `/devagent:next [project] [--auto] [--through <step>] [-- <note>]`

Executes the next actionable step (spec §6.5). `--auto` chains to
`cleanup`; `--through <step>` chains up to and including the named
step (spec §7.1).

`--auto` cannot bypass permission gates and cannot continue past `[!]`
or a non-zero step exit (spec §7.2).

## Chain semantics across script and skill steps

`next.sh` chains *script-backed* steps in-process (pull, branch,
commit, analyze, ship, mergetoall, cleanup). For *skill-backed*
steps (draft, scope, improve, etc.), the script can't execute the
skill itself, so it hands back to the model with:

```
→ Run /devagent:<name>
CHAIN: /devagent:next --auto
```

The `CHAIN:` line is your instruction (model) to invoke the named
slash command immediately after the preceding step completes. Standard
flow under `--auto`:

1. You see `CHAIN: /devagent:next --auto`
2. You invoke `/devagent:<name>` (the skill body marks the step done)
3. You then invoke `/devagent:next --auto`
4. next.sh advances to the next checklist step and repeats

The chain breaks on any of: step marked `[!]` (stuck), `[?]`
(blocked-external), a non-zero exit from a script step, a permission
gate that the operator declines, or the through-target step
completing.

"Recommended revisions" (review → redmr → ship): as long as the
review skill marks itself `[x]` (issues recorded but not blocking),
the chain proceeds into redmr automatically. If review marks itself
`[!]`, the chain halts and you'll need `/devagent:unstuck` before
resuming.

## Zero-diff (artifact-only) issues

When the issue branch has zero commits ahead of `baseline_sha`,
three script-backed steps auto-skip instead of erroring:

- **Step 10 (commit):** marks `[-]`, exits 0. (A clean tree *with* commits
  ahead of baseline is instead a `[x]` no-op success — see `/devagent:commit`,
  #116.)
- **Step 21 (preship):** skill-level `[-]` on a zero-diff branch (see
  `/devagent:preship`; `indeterminate` never auto-skips).
- **Step 15 (ship):** marks `[-]`, exits 0.
- **Step 16 (mergetoall):** marks `[-]`, exits 0.

Step 8 (quality) also auto-skips: on a true zero-diff (artifact-only)
issue the quality skill auto-marks step 8 `[-]`, logs, and advances
without operator confirmation (see `/devagent:quality`, #116) — no
manual mark needed.

For the script-backed steps (10/15/16) the auto-skip fires at the
script level — `next.sh` invokes the script normally and the script
detects the zero-diff condition internally; step 8 (quality), being
skill-backed, auto-skips in the skill body as described just above.
No `--artifact-only` flag exists for either path.

## Concurrent sessions

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

The supported per-session pin is a Claude Code `settings.local.json`
env entry in the project directory:

```json
{ "env": { "DEVAGENT_ACTIVE_PROJECT": "<project>" } }
```

The harness injects the variable into every shell, so resolution through
the standard chain (arg → env → pointer) is pinned for that session
without consulting or touching the shared pointer. (Tooling that edits
`_active.toml` directly — e.g. capture.md's recipe — bypasses the pin.)

Per-PROJECT state is still one file (`state/<project>.toml`): two sessions
on different issues of the *same* project can clobber the shared
`active_issue` scalar — last writer wins; `state_set` emits an advisory
stderr warning, not a lock. As of #96 all multi-key transitions are single
atomic transactions (`state_set_many`) — state can no longer TEAR (A's issue
with B's dir) and the clobber-warn reads in-lock. As of #240/#303 each issue's
`STATE_ISSUE_KEYS` live under `[context.<issue>]` (`scripts/lib/state.sh:165–174`),
so the top-level scalars are only a compatibility mirror for the shared active
issue and same-project sessions can no longer launder one issue's keys into
another. The sole residual is the last-writer-wins PICK of the `active_issue`
scalar itself — avoided entirely by a per-session issue pin.

The per-session ISSUE pin is the sibling of the project pin above:
`"env": { "DEVAGENT_ACTIVE_ISSUE": "Issue-N" }` in the directory's
`settings.local.json`. It is resolved by `active.sh:147–152` (the env resolver;
chain arg → env → shared state) and honored by `pull.sh`, `next.sh`, `where.sh`,
`park.sh`, `commit.sh`, `cleanup.sh`, `switch.sh`, `step-model.sh`, and
`resume.sh` (pinned-mismatch die). A pinned session resolves its own issue and
never reads or writes the shared `active_issue` slot.

Before any manual script invocation, confirm the active issue:

```bash
cat ~/.claude/devagent/state/<project>.toml | head -15
```

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/next.sh" $ARGUMENTS
```

Where `$ARGUMENTS` is the verbatim CLI tail forwarded by the harness.
