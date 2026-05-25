---
name: core-redissue
description: Adversarially review a capture draft using ${CLAUDE_PLUGIN_ROOT}/templates/redteam_issue.md; write findings to redteam.md. Triggers when /devagent:redissue is invoked.
---

# devagent-redissue

## Inputs

- `draft_path` — absolute path to `Captures/<slug>/draft.md`.
- `redteam_prompt` — resolved contents of `${CLAUDE_PLUGIN_ROOT}/templates/redteam_issue.md`.

## Procedure

1. Read the draft.
2. Apply each check in the red-team prompt verbatim. Do not skip
   sections because they "seem fine".
3. Group findings by severity:
   - **Blocking** — must be addressed before filing.
   - **Recommended** — should be addressed; not a hard stop.
   - **Nits** — wording, formatting, micro-improvements.
4. End with `Verdict: ship | revise | split`.
   - `ship` — zero blocking findings; recommended/nits acceptable
   - `revise` — one or more blocking findings, single issue still viable
   - `split` — capture is structurally multiple issues

## Output

Write to `<devdoc>/Captures/<slug>/redteam.md` in this shape:

```markdown
# Red-team — <slug>

Run: <YYYY-MM-DD HH:MM>

### Blocking (N)
- <finding>

### Recommended (N)
- <finding>

### Nits (N)
- <finding>

Verdict: ship | revise | split
```

## Anti-patterns

- Do not edit `draft.md`. The operator owns the draft.
- Do not invent acceptance criteria not present in the draft just to
  give yourself something to find.
- Do not write `Verdict: ship` if any Blocking finding exists.

## Verification

Verified via fixture-grep against SKILL.md contract structure.

## Completion handoff

After marking the step `[x]` (or `[-]` if skipped) and logging:

**STOP.** Do not invoke any other `/devagent:*` command on your own.
End your final message with this exact question (substituting the
correct next-step slash command from the checklist):

> Would you like to continue on to /devagent:<next-step-name>?

The next-step name is the first line in the issue's checklist.md
that starts with `- [ ]` -- read that, take the verb after the
step number, and substitute it into the question.

The only exception: if you were invoked under a `/devagent:next
--auto` or `--through` chain (recognizable because the preceding
turn's tool output contained a `CHAIN: /devagent:next ...` line),
then do NOT ask the question -- instead invoke that exact CHAIN:
command verbatim to continue the chain.

If the operator typed a one-off `/devagent:<name>` directly (no
preceding CHAIN: line), DO ask the question and wait for the
operator's answer. Do not advance even if your internal TODO list
still has steps after this one -- the operator's last explicit
instruction is the authoritative scope.
