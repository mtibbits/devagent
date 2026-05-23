---
name: devagent-redissue
description: Adversarially review a capture draft using templates/redteam_issue.md; write findings to redteam.md. Triggers when /devagent:redissue is invoked.
---

# devagent-redissue

## Inputs

- `draft_path` — absolute path to `Captures/<slug>/draft.md`.
- `redteam_prompt` — resolved contents of `templates/redteam_issue.md`.

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
