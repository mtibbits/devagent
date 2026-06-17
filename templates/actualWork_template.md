# Actual Work — {{ISSUE_ID}}

> Written by `/devagent:document` after `/devagent:implement`. Be terse:
> when implementation followed `imPlan.md` exactly, say so in one line.
> Document deviations only.

**Branch:** `{{BRANCH}}` based on `{{BASELINE_REF}}` (`{{BASELINE_SHA}}`)

## Summary

(One line: "Implementation followed the plan exactly. No deviations." OR
list the deviations.)

## Deviations from plan

(Skip this section if none.)

- **Plan said:** …
  **Actually did:** …
  **Why:** …

## Verification

- Build: …
- Tests: …
- Smoke: …

### Follow-up

(Future work discovered while implementing — one `- ` bullet each.
`/devagent:reap` harvests every bullet under this exact `### Follow-up` heading,
so delete this guidance line and add real bullets, or leave the section empty if
there are none. Keep this section LAST: reap harvests until the next `### `
heading or end of file, so a bulleted section placed after it would be
mis-harvested.)
