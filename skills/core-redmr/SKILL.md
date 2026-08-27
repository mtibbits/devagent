---
name: core-redmr
description: "Step 16: red-team adversarial review of the MR body and diff before shipping"
when_to_use: After /devagent:review and before /devagent:ship. Run as part of /devagent:redmr.
user-invocable: false
context: fork
agent: devagent:redteam-reviewer
---

# devagent-redmr

Step 16 of the devAgent 24-step workflow.

<!-- #458: this body is the FORK PROMPT. `context: fork` + `agent:` have already
     taken effect by the time it is in context — the harness supplies the agent's
     system prompt, pinned model, and Write/Edit denial. The procedure (checklist,
     artifact format, return contract) lives in `agents/redteam-reviewer.md`, the single
     source; the main-session duties (tier resolution, the verbatim artifact
     write, dispatch-lint, the failure protocol) live in the command wrapper.
     Keep this body to what is genuinely fork-specific, or it is paid for in
     context on every run. Rationale: docs/specs/2026-05-19-devagent-plugin-design.md §7.5. -->

The procedure lives in `agents/redteam-reviewer.md` — your system prompt. This body
only resolves the inputs and hands off.

## Resolve your inputs, then execute

You have no conversation history — that is what makes the attack real. Resolve
everything from disk and state:

1. The invoking session names the PROJECT and ISSUE DIR. If it did not, resolve
   them: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/where.sh" "${DEVAGENT_ACTIVE_PROJECT:-<project>}"`
   (prints `Active issue: Issue-N`; the issue dir is `<devdoc>/<dir_prefix>Issue-N`,
   both keys from `[project.<name>]` in `~/.claude/devagent/config.toml`; an env-pinned session exports
   `DEVAGENT_ACTIVE_PROJECT` / `DEVAGENT_ACTIVE_ISSUE`, which take precedence).
2. Read `<issue-dir>/mr.md` (the MR body under attack) and, for context,
   `<issue-dir>/imPlan.md` and `<issue-dir>/actualWork.md`.
3. **Resolve the red-team template** — it is the authority for WHAT to attack:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/template.sh" --project <project> show redteam_mr
   ```

   That walks the §12 registry (project paths → devdoc override → plugin
   default `templates/redteam_mr.md`) and prints the resolved source path plus
   its content. Read it and run every check it specifies. Halt-and-report if it
   cannot be resolved; never attack with less and stay silent about it.
4. Get the code under attack: `branch` and `baseline_sha` from state, then work
   the literal diff spec `<baseline_sha>..HEAD` in the project's `source_dir`.
   Attack the diff itself, never a description of it.
5. Write nothing. Produce the severity-classified findings per your system
   prompt and RETURN the complete artifact body as your final message. The
   invoking session writes it to
   `<issue-dir>/analysis/YYYY-MM-DD-redmr.md` verbatim, triages, applies fixes,
   and enforces the blocking gate — it never rewrites your findings in place.

Stamp the header your system prompt specifies. The wrapper normally tells you
what to stamp (its rc-2 path — the #291 inherit escape — rides this skill and
says `inherit (per-issue)`); invoked directly with no instruction, stamp
`model: inherit` — this fork runs at the session model, since the agent
definition deliberately carries no pin.

## Templates referenced

- the resolved `redteam_mr.md` (§12 registry: project paths → devdoc → plugin default) — the adversarial prompt itself.
