---
name: core-redmr
description: "Step 14: red-team adversarial review of the MR body and diff before shipping"
when_to_use: After /devagent:review and before /devagent:ship. Run as part of /devagent:redmr.
user-invocable: false
context: fork
agent: devagent:redteam-reviewer
---

# devagent-redmr

Step 14 of the devAgent 22-step workflow.

**This skill is the fork prompt.** `context: fork` + `agent:` bind it to the
`devagent:redteam-reviewer` agent, so invoking it IS the fresh-context dispatch:
the harness runs this body inside that agent, with that agent's system prompt,
its pinned model, and its Write/Edit denial in force. The procedure — the
adversarial stance, the severity taxonomy, the spec-touch question, the artifact
format, the return contract — lives in the agent definition
(`agents/redteam-reviewer.md`), which is the single source. This body only
resolves the inputs and hands off. Fresh context is not conditional; the model
override is (see `commands/redmr.md`).

## Resolve your inputs, then execute

You have no conversation history — that is what makes the attack real. Resolve
everything from disk and state:

1. The invoking session names the PROJECT and ISSUE DIR. If it did not, resolve
   them: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/state.sh" get <project> active_issue`
   and `... get <project> issue_dir` (an env-pinned session exports
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

Stamp the mandatory header your system prompt specifies. Line 1 is always
`context: subagent` (a fork IS a subagent context; the report linter requires
that token — never `context: fork`). For line 2, stamp the `model:` value the
invoking session gives you; absent an instruction, stamp
`model: agent-default (redteam-reviewer)`.

## Templates referenced

- the resolved `redteam_mr.md` (§12 registry: project paths → devdoc → plugin default) — the adversarial prompt itself.
