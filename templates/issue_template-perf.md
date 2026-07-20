# {{title}}

## Hot path
<which function/loop/hot path; how to find it>

## Baseline measurement
- Tool: <your profiler / perf stat / criterion / ...>
- Workload: <inputs, sizes, repetitions>
- Result: <number ± noise>

## Hypothesis
<what change should help, why>

## Target
<numeric improvement goal; how it will be measured>

## Acceptance criteria
- [ ] Benchmark script checked in (or referenced)
- [ ] Plot from an evidence-plot script attached (if the project has one)
- [ ] No regression on adjacent functions/callers

<!-- Optional per-issue workflow tier (legal names: spec §6.3 tier table).
     To use one, add an UNCOMMENTED block before this section: a
     "## Workflow flags" heading line followed by a "tier: <name>" line.
     (No live example here on purpose: an invisible commented block that
     parses as config was a #537 red-team finding.) -->

## Source
{{source}}
