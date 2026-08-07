---
name: next
description: Execute the next actionable step on the active issue
when_to_use: To advance the active issue's 24-step checklist; --auto chains steps.
argument-hint: "[project] [--auto] [--through <step>] [-- <note>]"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
---

# /devagent:next

Executes the next actionable step (spec §6.5). `--auto` chains to `cleanup`;
`--through <step>` chains through the named step (spec §7.1). Neither bypasses
permission gates nor continues past `[!]` or a non-zero step exit (spec §7.2).

## Chain recognition

`next.sh` runs script-backed steps in-process. For skill-backed steps it hands
back to the model:

    → Run /devagent:<name>
    CHAIN: /devagent:next --auto

The `CHAIN:` line is your instruction (model): invoke `/devagent:<name>` now
(its body marks the step done), then invoke the CHAIN: command verbatim;
next.sh advances and repeats. The chain breaks on: a step marked `[!]` or
`[?]`, a non-zero script-step exit, a declined permission gate, or the
through-target completing. review→redmr: review `[x]` proceeds; `[!]` halts
(/devagent:unstuck).

## Zero-diff (artifact-only) issues

When the issue branch has zero commits ahead of `baseline_sha`, steps 12
(commit), 18 (ship), and 19 (mergetoall) self-detect and mark `[-]`, exit 0 —
no flag exists (a clean tree WITH commits ahead is a `[x]` no-op; #116).
Step 17 (preship) marks `[-]` skill-side on zero-diff (`indeterminate` never
auto-skips). Step 10 (quality): the skill auto-marks step 10 `[-]` and advances
without operator confirmation (#116).

## Concurrent sessions

Pin per-session in the project directory's settings.local.json:
`"env": { "DEVAGENT_ACTIVE_PROJECT": "<project>", "DEVAGENT_ACTIVE_ISSUE":
"Issue-N" }` — a pinned session never reads or writes the shared pointer or
`active_issue`. Move the global pointer only via /devagent:use. Before any
manual script invocation, confirm the active issue:

    head -15 ~/.claude/devagent/state/<project>.toml

History and state-atomicity details: references/concurrency.md.

## Run the script

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/next.sh" <argument tail>

Forward the argument tail verbatim; pass the project first if known
(#572: a bare run refuses on a pointer/repo scope mismatch).
