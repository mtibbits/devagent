# {{title}}

## Summary
<one paragraph: what's broken, observable symptom>

## Reproduction
1. <step>
2. <step>
3. <step>

Expected: <what should happen>
Actual:   <what happens>

## Environment
- Project: {{project}}
- Branch/commit: <ref>
- Toolchain: <compiler, version, flags>

## Root-cause hypothesis (optional)
<what you suspect, why>

## Acceptance criteria
- [ ] <observable test that proves the fix>
- [ ] Regression test added

<!-- Optional per-issue `## Workflow flags` (spec §6.3). To use, add an
     UNCOMMENTED block before this section: a "## Workflow flags" heading line
     followed by one `key: value` line per flag. Recognized keys:
       - tier: <name>       (legal names: spec §6.3 tier table)
       - research: required (flags the optional pre-draft research step, #535;
                             flips checklist row 22 where the template carries it
                             — standard/perf; warn+no-op elsewhere)
     Unknown keys warn-and-ignore (forward compatibility).
     (No live example here on purpose: an invisible commented block that
     parses as config was a #537 red-team finding.) -->

## Source
{{source}}
