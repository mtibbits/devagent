# {{title}}

## Scope
<housekeeping, tooling, CI, infra; not user-visible>

## Rationale
<why now>

## Acceptance criteria
- [ ] <verifiable change>
- [ ] No user-visible behavior change

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
                            (#561; steers the THINKING class â€” steps 2 draft,
                             9 implement, 10 quality, 11 document, 14 draftmr.
                             ENFORCED for draft only; ADVISORY for the rest,
                             which run inline and cannot swap their own model)
       - checking-model: <token>
                            (#561; steers the CHECKING class â€” steps 5 improve,
                             15 review, 16 redmr, 17 preship. Fully enforced.)
                             Legal tokens for both: sonnet opus haiku fable
                             inherit. Validated fail-closed before any write.
                             Written into `.devagent-step-models` at first
                             scaffold only; afterwards hand-edit that file.
                             `tier: <model>-checking` is also accepted as a
                             legacy model annotation (warns, means
                             `checking-model: <model>`), and recognized
                             `tier:*` forge LABELS steer too â€” see spec Â§7.4.
     Duplicate keys are first-match-wins, so combine a template tier with a
     model annotation as `tier:` + `checking-model:`, one line each.
     Unknown keys warn-and-ignore (forward compatibility).
     (No live example here on purpose: an invisible commented block that
     parses as config was a #537 red-team finding.) -->

## Source
{{source}}
