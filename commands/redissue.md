---
description: Run the issue red-team prompt against a capture draft; write redteam.md
allowed-tools: Read, Write, Edit, Skill
argument-hint: "<capture-slug>"
---

# /devagent:redissue

Args: `<capture-slug>`

## Behavior

1. Locate `<devdoc>/Captures/<slug>/draft.md`. Abort if missing.
2. Resolve `redteam_issue` template via the artifact resolution
   order (project paths → devdoc templates → plugin templates).
3. Invoke the **core-redissue** skill with `draft_path` and the
   contents of the red-team prompt.
4. The skill writes findings to `<devdoc>/Captures/<slug>/redteam.md`
   structured with `### Blocking`, `### Recommended`, `### Nits`,
   and a one-line `Verdict: ship | revise | split` footer.
5. Report the path and verdict. Do NOT modify `draft.md` itself —
   the operator decides whether to revise based on the findings.

## Env contract

Same as `/devagent:capture`.
