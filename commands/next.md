---
description: Execute the next actionable step on the active issue
allowed-tools: Bash
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
- **Step 15 (ship):** marks `[-]`, exits 0.
- **Step 16 (mergetoall):** marks `[-]`, exits 0.

Step 8 (quality) is skill-driven and must be manually marked `[-]`
by the operator for artifact-only issues. A follow-up is tracked
for skill-level zero-diff handling.

The auto-skip fires at the script level — `next.sh` invokes the
script normally and the script detects the zero-diff condition
internally. No `--artifact-only` flag is needed.

## Concurrent sessions

The global project pointer (`~/.claude/devagent/state/_active.toml`) is
written ONLY by pointer/fallback-resolved `next.sh` invocations (#282) —
an arg- or env-pinned session never touches it, and `pull.sh` never writes
it (its project is always an explicit positional). Consequence: on a
multi-project install the pointer's VALUE effectively freezes — running
`next.sh <other-project>` no longer moves it; switch projects via the env
pin or by editing `_active.toml` directly. (Nuance: a pointer naming a
project absent from config dies at resolution with 2+ projects rather
than being rewritten.)

The supported per-session read-half is a Claude Code `settings.local.json`
env pin in the project directory:

```json
{ "env": { "DEVAGENT_ACTIVE_PROJECT": "<project>" } }
```

The harness injects the variable into every shell, so all resolution in
that session is pinned without consulting or touching the shared pointer.

Per-PROJECT state is still one file (`state/<project>.toml`): two sessions
on different issues of the *same* project can clobber `active_issue` —
last writer wins; `state_set` emits an advisory stderr warning, not a
lock. That race is #240's remit.

Before any manual script invocation, confirm the active issue:

```bash
cat ~/.claude/devagent/state/<project>.toml | head -15
```

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/next.sh" $ARGUMENTS
```

Where `$ARGUMENTS` is the verbatim CLI tail forwarded by the harness.
