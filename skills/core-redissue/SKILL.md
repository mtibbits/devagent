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
   sections because they "seem fine". Format precedence (#134): the
   template defines the checks; THIS skill defines the output —
   severity taxonomy, summary counts, and verdict vocabulary, nothing
   else. If a resolved template (including a project override)
   specifies a different output format, this skill's output contract wins.
3. Group findings by severity:
   - **Blocking** — must be addressed before filing.
   - **Recommended** — should be addressed; not a hard stop.
   - **Nits** — wording, formatting, micro-improvements.
4. End with `Verdict: ship | revise | split`.
   - `ship` — zero blocking findings; recommended/nits acceptable
   - `revise` — one or more blocking findings, single issue still viable
   - `split` — capture is structurally multiple issues

## Output

Write to `<devdoc>/Captures/<slug>/redteam.md` in this shape —
ADDITIONALLY including the resolved template's check structure verbatim
(review-tier line, 16-dimension scorecard with per-dimension scores and
Clean/N-A caption, adversarial questions, and the Required Changes /
Suggested Improvements sections): those are adopted output, not
competing format.

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
