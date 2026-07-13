---
description: Run the issue red-team prompt against a capture draft; write redteam.md
allowed-tools: Read, Write, Edit, Skill
argument-hint: "<capture-slug>"
---

# /devagent:redissue

Args: `<capture-slug>`

## Behavior

1. Locate `<devdoc>/Captures/<slug>/draft.md`. Abort if missing.
2. Resolve the red-team prompt (#443 — tier-split, loaded per the triage gate):
   - **Monolith override first.** Resolve `redteam_issue` via the artifact order
     (project paths → devdoc templates → plugin templates). The plugin ships NO
     monolith, so this resolves ONLY when a project/devdoc override exists; if it
     does, that single file is the WHOLE prompt and **shadows all tiers**
     (backward compat) — pass it as-is and skip the tier composition.
   - **Else compose from tiers.** Resolve + read `redteam_issue_shared` (it carries
     the triage gate, severity scale, adversarial questions, and output contract).
     Decide the review tier from its triage gate, then read the CUMULATIVE tier
     parts: Light → `redteam_issue_light`; Standard → `+redteam_issue_standard`;
     Full → `+redteam_issue_full`. Each dimension lives in exactly one part; a
     Light run never loads the Standard/Full dimension bodies (the token saving).
3. Invoke the **core-redissue** skill with `draft_path` and the resolved prompt
   (the whole monolith override, or shared + the selected cumulative tier parts).
4. The skill writes findings to `<devdoc>/Captures/<slug>/redteam.md`
   structured with `### Blocking`, `### Recommended`, `### Nits`,
   and a one-line `Verdict: ship | revise | split` footer.
5. Report the path and verdict. Do NOT modify `draft.md` itself —
   the operator decides whether to revise based on the findings.

## Env contract

Same as `/devagent:capture`.
