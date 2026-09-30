---
name: next
description: Execute the next actionable step on the active issue
when_to_use: To advance the active issue's 24-step checklist; --auto chains steps.
argument-hint: "[project] [--auto] [--through <step>] [--no-breaks] [-- <note>]"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
---

# /devagent:next

Executes the next actionable step (spec §6.5). `--auto` chains to `cleanup`;
`--through <step>` chains through the named step (spec §7.1). Neither bypasses
permission gates nor continues past `[!]` or a non-zero step exit (spec §7.2).

## Chain recognition

Script-backed steps run in-process. Skill-backed steps hand back to the model:

    → Run /devagent:<name> <project>
    CHAIN: /devagent:next <project> --auto --chained

The project token is load-bearing (#578): without it the command re-resolves
global state at fire time.

The `CHAIN:` line is your instruction (model): invoke the `→ Run` command now
(its body marks the step done), then invoke the CHAIN: command verbatim;
next.sh advances and repeats. The chain breaks on: a step marked `[!]` or
`[?]`, a non-zero script-step exit, a declined permission gate, or the
through-target completing. review→redmr: review `[x]` proceeds; `[!]` halts
(/devagent:unstuck).

A `PHASE BREAK` line also ends it: the next phase (at implement, quality,
updatewbs; config `phase_breaks`) belongs in a fresh session. Relay the
Resume line and stop. `--no-breaks` opts out.

## Zero-diff (artifact-only) issues

With zero commits ahead of `baseline_sha`, steps 12 (commit), 18 (ship) and
19 (mergetoall) self-mark `[-]` and exit 0, no flag needed (a clean tree WITH
commits ahead is a `[x]` no-op; #116). Step 17 (preship) marks `[-]`
skill-side (`indeterminate` never auto-skips). Step 10 (quality): the skill
auto-marks step 10 `[-]` and advances without operator confirmation (#116).

## Concurrent sessions

Pin a session with `DEVAGENT_ACTIVE_PROJECT`/`DEVAGENT_ACTIVE_ISSUE` in the
project's settings.local.json `env`; move the global pointer only via
/devagent:use. Details: references/concurrency.md.

## Run the script

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/next.sh" <argument tail>

Forward the argument tail verbatim; pass the project first if known
(#572: a bare run refuses on a pointer/repo scope mismatch).
