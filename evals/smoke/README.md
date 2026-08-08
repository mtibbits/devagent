# Harness-conformance smoke rungs (#530)

These rungs are the LIVE gate for the agent binding/isolation class — the gate
spec §7 names ("the live smoke test on the installed version is the gate") but
that until now existed only as prose plus #458's one-time evidence artifact.

**Why bats cannot be this gate.** Every test in the agents area
(`tests/agents.bats`) greps devAgent's own markdown for strings devAgent wrote;
none exercises enforcement. If the Claude Code harness ever stops honouring
`context: fork` / `agent:` / `disallowedTools`, every one of those tests stays
GREEN while isolation silently degrades to a general-purpose subagent with full
Write. Only a live run on the installed version can observe the binding.

## ⚠️ NOT CI-gating

Model runs are non-deterministic — a red rung must NEVER fail a build. The only
CI-durable artifact is [`tests/evals-structure.bats`](../../tests/evals-structure.bats),
which guards the STRUCTURE of these rungs (every rung has a target, procedure,
measured, expected, baseline, trigger; the rung count floor holds; the
broken-binding fixture exists) and never invokes a model. This mirrors the
steering evals' split (`evals/README.md`), but the rungs here measure the
HARNESS, not a skill body.

## Run trigger

Run **every Claude Code upgrade AND every plugin reinstall/update.** A harness
regression has no skill-body-edit to hang a trigger on (unlike the steering
evals, whose customer is a skill-body edit), so it is keyed to the harness or
plugin VERSION changing. Reinstall the plugin first — the cache is SHA-versioned
and a stale cache false-passes — and run each rung in a FRESH headless session
(`claude -p --plugin-dir <worktree>`); plugin components load at session start.

## The rungs (single source: `smoke.json` → `rungs`)

| id | measures |
|----|----------|
| `binding-honoured` | the fork quotes the first sentence that exists ONLY in `agents/preship-verifier.md` (direct attestation the plugin-scoped agent bound) |
| `disallowed-tools-enforced` | Write/Edit **TOOLS** absent from the fork's schema at schema-resolution — evidenced by the **structural tool-call refusal / resolved-schema report** (path-absence alone is only corroboration; it cannot tell denial from the model choosing not to write). Measured as tool-denial, NOT "cannot write" (Bash retained; no sandbox overclaim, spec §7.4). Path-absence-only ⇒ INCONCLUSIVE, not PASS |
| `model-routing-observable` | per-subagent model IDs from `subagents/*.jsonl` — unpinned fork inherits the session model; an explicit `model:` param is honoured |
| `plugin-root-grant-automatch` | the quoted two-token `${CLAUDE_PLUGIN_ROOT}` grant auto-approves a real command's script call — Bash tool_result read mechanically from stream-json, never the prose (#548; a denied run can narrate success) |

`smoke.json`'s `meta.criteria` is authoritative (3 runs / ≥2 pass /
below-baseline = regression, per #460); this prose restates it.

## Recording a baseline

For each of the 3 runs, mark the `expected` observation PASS/FAIL, then write the
result into that rung's `baseline` block in `smoke.json` (`date`, `model`,
`pass_rate`, `runs`). A run that returns no tool use / does no work is a MISFIRE
(#315) — re-dispatch, don't score it. A below-baseline pass-rate after a version
change is a HARNESS regression, not a re-baseline candidate.

## Proving the rungs discriminate — the broken-binding fixture

`fixtures/broken-binding/` is a deliberately-degraded `preship-verifier.md`
(`disallowedTools` stripped, first sentence mangled). Point a scratch plugin's
`agents/` at it, reinstall, and the two enforcement rungs FAIL against it while
they PASS against the shipped agent — see `fixtures/broken-binding/README.md`.
That contrast is what proves a green rung means something (a green bats suite
does not). Demonstrated once at bring-up; re-run only if the fixture procedure
itself is doubted.
