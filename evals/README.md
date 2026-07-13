# Skill-steering evals (#460)

These evals measure whether the **judgment-heavy** skills — `core-scope`,
`core-redmr`, `core-preship` — actually *steer* the model to the required
judgment. The bats suite proves every script *triggers*; nothing proved the
skills *steer*. Triggering ≠ steering: a skill can fire and still fail to
influence behavior, and a prompt/body regression is invisible to bats. These
evals baseline the steering so a skill-body edit can be diffed against it.

> **The token epic (#440–#443) is this eval set's first customer.** Those issues
> edit these three skills' bodies. Run the affected skill's cases before and
> after each such edit; a below-baseline pass-rate is a steering regression.

## ⚠️ NOT CI-gating

Model runs are **non-deterministic**. A red eval must **never** fail a build.
The only CI-durable artifact is [`tests/evals-structure.bats`](../tests/evals-structure.bats),
which validates the eval *structure* (every case has a fixture + rubric +
baseline; each skill has ≥ 2 cases) and **never invokes a model**. The
model-run leg is manual/local, operator-run.

## The criteria (single source: `evals.json` → `meta.criteria`)

- **runs_per_case = 3** — each case is run 3× in **fresh sessions** (no shared
  context, so the skill body is what steers, not conversation memory).
- **pass_rule** — a case PASSES a baseline if **≥ 2 of 3** runs satisfy its
  rubric (the recorded `verdict` **and** every `must_name` point).
- **regression_rule** — after a skill-body edit, re-run that skill's cases; a
  **regression** is any case whose new pass-rate drops **below** its recorded
  baseline `pass_rate`. Re-baseline deliberately (and note it) only when the
  edit *intends* to change steering.

`evals.json`'s `meta.criteria` is authoritative; this section restates it. If
they ever disagree, `evals.json` wins — keep this prose in sync with it.

## Running a case

```bash
bash evals/run-eval.sh --list            # list case ids
bash evals/run-eval.sh <case-id>         # print the fresh-session prompt + rubric
```

`run-eval.sh` **never runs a model.** It assembles the exact fresh-session prompt
(skill body path + fixture input paths; for diff-based cases it redirects the
skill's `git diff baseline..HEAD` input to the fixture's `diff.patch`; for
`core-preship` it scopes scoring to verifications 1–3, the steering core). Copy
the printed prompt into a fresh session, run it 3×, and hand-score each run
against the printed rubric.

## Recording a baseline

For each of the 3 runs, mark PASS/FAIL against the rubric, then write the result
into that case's `baseline` block in `evals.json`:

```json
"baseline": {
  "date": "2026-07-13",
  "model": "claude-opus-4-8",
  "pass_rate": "3/3",
  "runs": ["pass", "pass", "pass"]
}
```

`runs` is the ordered per-run verdicts (so a `2/3` records *which* run missed);
`pass_rate` is the fraction. A run that returns no tool use / does no work is a
**misfire** (Issue-315) — re-dispatch it, don't score it as a fail or a pass.

## The cases

Two per skill, one **must-catch** (a real defect the skill should flag) and one
**must-not-false-positive** (a clean input the skill should pass), so a regression
is detectable in *both* directions — an over-eager edit that flags everything
regresses the clean cases; a weakened edit that misses defects regresses the
must-catch cases.

| id | skill | expects |
|----|-------|---------|
| `scope-oversized` | core-scope | propose a split (plan > 300 LOC / 1 day) |
| `scope-well-scoped` | core-scope | accept scope, no split |
| `redmr-spec-lag` | core-redmr | `[MAJOR]` spec-lag: config key added, no spec change |
| `redmr-clean` | core-redmr | 0 blocking, no invented finding |
| `preship-stranded-fix` | core-preship | overall FAIL: claimed fix absent from the diff |
| `preship-clean` | core-preship | all verifications PASS |

### Scoring note (core-scope Q7)

The two `core-scope` fixtures deliberately ship no `analysis/<date>-rederive.txt`,
so the skill's Q7 (premise-freshness, #361) will mark the step `[!]` "no rederive
artifact". That behavior is **consistent across both cases** and **orthogonal to
the size/scope-boundary judgment** each rubric measures, so it is **not scored** —
`scope-oversized` is scored on the size-over-threshold + split verdict,
`scope-well-scoped` on the under-threshold + no-split verdict. The recorded
2026-07-13 baselines (3/3 each) saw this Q7 `[!]` and still passed their rubrics.
