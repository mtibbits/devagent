---
name: core-improve
description: "Step 5: surface latent bugs, side effects, and ambiguities in an implementation plan before pruning"
when_to_use: After /devagent:scope has appended scope evaluation and before /devagent:prune. Run as part of /devagent:improve.
user-invocable: false
context: fork
agent: devagent:plan-improver
---

# devagent-improve

Step 5 of the devAgent 24-step workflow.

<!-- #527 (pattern-completing #458): this body is the FORK PROMPT.
     `context: fork` + `agent:` have already taken effect by the time it is in
     context — the harness supplies the agent's system prompt, pinned effort,
     and Write/Edit denial. The procedure (checklist, artifact format, return
     contract) lives in `agents/plan-improver.md`, the single source; the
     main-session duties (tier resolution, the verbatim artifact write,
     dispatch-lint, the failure protocol, triage + the `## Improvements`
     append) live in the command wrapper. Keep this body to what is genuinely
     fork-specific, or it is paid for in context on every run. Rationale:
     docs/specs/2026-05-19-devagent-plugin-design.md §7.5. -->

The procedure lives in `agents/plan-improver.md` — your system prompt. This
body only resolves the inputs and hands off.

## Resolve your inputs, then execute

You have no conversation history — that is what makes the check real. Resolve
everything from disk and state:

1. The invoking session names the PROJECT and ISSUE DIR. If it did not, resolve
   them: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/state.sh" get <project> active_issue`
   and `... get <project> issue_dir` (an env-pinned session exports
   `DEVAGENT_ACTIVE_PROJECT` / `DEVAGENT_ACTIVE_ISSUE`, which take precedence).
2. Read `<issue-dir>/imPlan.md` (the plan under check, including its Scope
   evaluation and its `## Load-bearing unknowns` section) and `<issue-dir>/spike.md`
   when it exists, and `<issue-dir>/checklist.md` (the spike row's glyph is the spike
   tripwire's GATE — #536; all are packaged by the dispatch contract's `<INPUTS>`),
   and `<issue-dir>/issue.md` (the goal the plan must serve).
3. **Resolve the pothole register** — the tripwire's input (#286):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/template.sh" --project <project> show potholes
   ```

   That walks the §12 registry (project paths → devdoc override → plugin
   default `templates/potholes.md`) and prints the resolved source path plus
   its content. Halt-and-report in your artifact if it cannot be resolved;
   never check with less and stay silent about it.
4. **Spike tripwire (#536) — only on a `spike: required` issue** (checklist row 23 is
   not `[-]`; unflagged issues that merely declare unknowns do NOT fire this):
   - a declared `## Load-bearing unknowns` entry with NO matching verdict in
     `spike.md` is a finding (the bet was declared and never tested); and
   - a plan task whose `U<N> (Task <M>)` back-reference points at an unknown recorded
     FALSIFIED or INCONCLUSIVE, with no stated plan delta disposing of it, is a finding
     (the plan still rides a bet measurement broke).
   The `U<N> (Task <M>)` back-reference is what makes "task depends on unknown"
   mechanically evaluable — without it this item would be unevaluable, i.e. dead.
5. Verify the plan's claims against the project source repo at HEAD — read the
   files the plan says it will touch; check them cold.
6. Write nothing. Produce the three finding categories + the pothole tripwire
   per your system prompt and RETURN the complete artifact body as your final
   message. The invoking session writes it to
   `<issue-dir>/analysis/YYYY-MM-DD-improve.md` verbatim, triages
   (`[merge]`/`[defer]`/`[dismiss]` is the main session's judgment), appends
   the tagged `## Improvements` section to `imPlan.md`, and enforces the
   halt rules — it never rewrites your findings in place.

Stamp the header your system prompt specifies. The wrapper normally tells you
what to stamp (its rc-2 path — the #291 inherit escape — rides this skill and
says `inherit (per-issue)`); invoked directly with no instruction, stamp
`model: inherit` — this fork runs at the session model, since the agent
definition deliberately carries no pin.

## Templates referenced

- the resolved `potholes` register (§12 registry: project paths → devdoc → plugin default) — the tripwire's input.
- the resolved `imPlan_template.md` (§12 registry) (canonical section ordering; the wrapper appends the `## Improvements` section, which the template does not define).
