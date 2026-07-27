---
name: core-preship
description: "Step 17: verify in fresh context that the committed branch meets the issue's acceptance criteria and contains every blocking finding before ship"
when_to_use: After /devagent:redmr and before /devagent:ship. Run as part of /devagent:preship.
user-invocable: false
context: fork
agent: devagent:preship-verifier
---

# devagent-preship

Step 17 of the devAgent 24-step workflow (file-ordered between redmr and ship;
the number is unique, not sequential — file order is execution authority).

<!-- #458: this body is the FORK PROMPT. `context: fork` + `agent:` have already
     taken effect by the time it is in context — the harness supplies the agent's
     system prompt, pinned model, and Write/Edit denial. The procedure (checklist,
     artifact format, return contract) lives in `agents/preship-verifier.md`, the single
     source; the main-session duties (tier resolution, the verbatim artifact
     write, dispatch-lint, the failure protocol) live in the command wrapper.
     Keep this body to what is genuinely fork-specific, or it is paid for in
     context on every run. Rationale: docs/specs/2026-05-19-devagent-plugin-design.md §7.5. -->

The procedure lives in `agents/preship-verifier.md` — your system prompt. This body
only resolves the inputs and hands off.

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

Stamp the header your system prompt specifies. The wrapper normally tells you
what to stamp (its rc-2 path — the #291 inherit escape — rides this skill and
says `inherit (per-issue)`); invoked directly with no instruction, stamp
`model: inherit` — this fork runs at the session model, since the agent
definition deliberately carries no pin.

## Templates referenced

- None directly (the artifact is free-form with the mandatory header;
  review/redmr artifacts are inputs, not templates).
