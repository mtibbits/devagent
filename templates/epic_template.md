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
       - implementation-model: <token>
                            (#561; steers the THINKING class — steps 2 draft,
                             9 implement, 10 quality, 11 document, 14 draftmr.
                             ENFORCED for draft only; ADVISORY for the rest,
                             which run inline and cannot swap their own model)
       - checking-model: <token>
                            (#561; steers the CHECKING class — steps 5 improve,
                             15 review, 16 redmr, 17 preship. Fully enforced.)
                             Legal tokens for both: sonnet opus haiku fable
                             inherit. Validated fail-closed before any write.
                             Written into `.devagent-step-models` at first
                             scaffold only; afterwards hand-edit that file.
                             `tier: <model>-checking` is also accepted as a
                             legacy model annotation (warns, means
                             `checking-model: <model>`), and recognized
                             `tier:*` forge LABELS steer too — see spec §7.4.
     Duplicate keys are first-match-wins, so combine a template tier with a
     model annotation as `tier:` + `checking-model:`, one line each.
     Unknown keys warn-and-ignore (forward compatibility).
     (No live example here on purpose: an invisible commented block that
     parses as config was a #537 red-team finding.) -->

## Source
{{source}}
