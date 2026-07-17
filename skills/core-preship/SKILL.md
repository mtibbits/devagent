---
name: core-preship
description: "Step 21: verify in fresh context that the committed branch meets the issue's acceptance criteria and contains every blocking finding before ship"
when_to_use: After /devagent:redmr and before /devagent:ship. Run as part of /devagent:preship.
user-invocable: false
context: fork
agent: devagent:preship-verifier
---

# devagent-preship

Step 21 of the devAgent 22-step workflow (file-ordered between redmr and ship;
the number is unique, not sequential — file order is execution authority).

**This skill is the fork prompt.** `context: fork` + `agent:` bind it to the
`devagent:preship-verifier` agent, so invoking it IS the fresh-context dispatch:
the harness runs this body inside that agent, with that agent's system prompt,
its pinned model, and its Write/Edit denial in force. The procedure — the five
verifications, the artifact format, the return contract — lives in the agent
definition (`agents/preship-verifier.md`), which is the single source. This body
only resolves the inputs and hands off. Fresh context is not conditional; the
model override is (see `commands/preship.md`).

## Resolve your inputs, then execute

You have no conversation history — that is the point. Resolve everything from
disk and state:

1. The invoking session names the PROJECT and ISSUE DIR. If it did not, resolve
   them: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/state.sh" get <project> active_issue`
   and `... get <project> issue_dir` (an env-pinned session exports
   `DEVAGENT_ACTIVE_PROJECT` / `DEVAGENT_ACTIVE_ISSUE`, which take precedence).
2. Read `<issue-dir>/issue.md` (the acceptance criteria under verification) and
   `<issue-dir>/mr.md` (the claims you cross-check).
3. Read the latest-dated `<issue-dir>/analysis/*-review.md` and `*-redmr.md`
   (the findings input).
4. Get the push content: `branch` and `baseline_sha` from state, then work the
   literal diff spec `<baseline_sha>..HEAD` in the project's `source_dir`.
5. Write nothing. Run your system prompt's five verifications and RETURN the
   complete `preship.md` body as your final message. The invoking session writes
   it to disk verbatim — authorship stays with you.

Stamp the mandatory header your system prompt specifies. Line 1 is always
`context: subagent` (a fork IS a subagent context; the report linter requires
that token — never `context: fork`). For line 2, stamp the `model:` value the
invoking session gives you; absent an instruction, stamp
`model: agent-default (preship-verifier)`.

## Templates referenced

- None directly (the artifact is free-form with the mandatory header;
  review/redmr artifacts are inputs, not templates).
