# Epic: {{title}}

## Outcome
<what is true when this epic is done>

## Why now
<the motivating context; what changes if we skip it>

## Estimated children (rough)
- <child 1 — one-line summary>
- <child 2 — one-line summary>
- <child 3 — one-line summary>

(After authoring, run `/devagent:scaffold <slug>` to bin children into
`children/NN-<name>.md` draft files.)

## Acceptance criteria
- [ ] All children filed and tracked
- [ ] Epic-level integration test or demo

## Out of scope
<adjacent work this epic does not own>

<!-- Optional per-issue `## Workflow flags` (spec §6.3). To use, add an
     UNCOMMENTED block before this section: a "## Workflow flags" heading line
     followed by one `key: value` line per flag. Recognized keys:
       - tier: <name>       (legal names: spec §6.3 tier table)
       - research: required (flags the optional pre-draft research step, #535;
                             flips the checklist's `research` row where the
                             template carries it — standard/perf; warn+no-op
                             elsewhere)
       - spike: required    (flags the optional post-draft spike step, #536; flips
                             the checklist's `spike` row the same way — the plan's
                             `## Load-bearing unknowns` are what it executes)
     Unknown keys warn-and-ignore (forward compatibility).
     (No live example here on purpose: an invisible commented block that
     parses as config was a #537 red-team finding.) -->

## Source
{{source}}
