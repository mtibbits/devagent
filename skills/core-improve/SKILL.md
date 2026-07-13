---
name: core-improve
description: "Step 3: surface latent bugs, side effects, and ambiguities in an implementation plan before pruning"
when_to_use: After /devagent:scope has appended scope evaluation and before /devagent:prune. Run as part of /devagent:improve.
user-invocable: false
---

# devagent-improve

Step 3 of the devAgent 22-step workflow. Reads `<issue-dir>/imPlan.md`
(including the Scope evaluation section) and appends an `## Improvements`
section that flags concrete plan defects in three categories — bugs,
side effects, ambiguities — plus a pothole-register tripwire (#286) whose
findings route into Bugs.

## Overview

Scope tells you what the plan covers. Improve tells you what the plan
gets *wrong* or fails to consider. The deliverable is a flat list of
concrete callouts the operator chooses to act on (merge into tasks),
defer (move to potentialFutureEnhancements), or dismiss (note why).

## Inputs

- `$ISSUE_DIR`, `$NOTE`, and the active PROJECT name — resolved by the
  command wrapper per spec §6.1; when the skill is invoked directly,
  default to state's `active_project`. If no project resolves, treat the
  tier as unconfigured (dispatch with no override).
- Reads: `<issue-dir>/imPlan.md`, `<issue-dir>/issue.md`.
- Writes: `<issue-dir>/analysis/YYYY-MM-DD-improve.md` (the checker's
  findings, subagent-authored under dispatch — see Dispatch contract) and
  appends the triaged `## Improvements` section to `<issue-dir>/imPlan.md`.

## Dispatch contract (#151)

Run this check in FRESH CONTEXT whenever the harness provides a subagent
mechanism (Claude Code's Agent/Task tool does). Fresh context — a checker
that reads the artifacts from disk instead of inheriting this
conversation — is what makes the check adversarial; the #101/#102
incident (a check approved work it had itself just edited) is the failure
class this prevents. The model override is conditional; fresh context is
not.

1. **Resolve the model tier** (optional):
   `tier="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/step-model.sh" <project> 3 || true)"`.
   Pass the CANONICAL step number (3) even if this issue's checklist
   renumbers steps — the class map is keyed to canonical numbers
   (config.sh). Empty ⇒ dispatch with NO model override (the subagent
   inherits the session model). A per-issue `.devagent-step-models`
   marker (#291) may supply the tier — a stderr `per-issue` provenance
   line means record `model: <tier> (per-issue)` (or
   `inherit (per-issue)`) in the artifact header. A nonzero exit WITH an
   error on stderr (stderr WITHOUT a `per-issue` provenance line) is a
   bad marker: STOP and fix or remove it — do NOT dispatch on inherit.
2. **Package inputs as paths, not conversation.** The dispatch prompt
   contains only: the absolute paths of `issue.md` and `imPlan.md`
   (including its Scope evaluation), the resolved pothole register
   (`potholes` via the §12 walk — `template.sh --project <p> show
   potholes` prints its source path; #286), the project source repo
   directory, the three finding categories (bugs / side effects /
   ambiguities), the pothole tripwire (Checklist item 4), and the output
   artifact path `<issue-dir>/analysis/YYYY-MM-DD-improve.md` (create
   `analysis/` if missing — pull scaffolds only the issue dir). The
   register path is load-bearing: a tripwire the dispatched checker never
   RECEIVES is dead (#286). Do NOT paste plan summaries or your own
   assessment into the prompt — that re-imports the author bias the
   dispatch exists to shed.
3. **Dispatch** one subagent with the resolved override (per step 1).
   If dispatch fails because the tier is unavailable (e.g. a model the
   current plan does not include), retry once with NO override and
   record the degradation in the artifact header (below).
4. **The subagent authors the artifact** and returns only a short
   summary (finding counts). The main session then triages per the
   Checklist below (tag assignment is the main session's judgment) and
   appends the tagged `## Improvements` section to imPlan.md citing the
   artifact. Never rewrite the subagent's
   findings file in place. The Halt-and-ask rules in this skill bind the
   MAIN session; a dispatched checker that hits one cannot ask — it
   records the halt condition in its artifact and returns, and the main
   session resolves it (re-dispatch or inline).
5. **Mandatory artifact header.** The artifact's first lines record:
   `context: subagent` (or `context: inline`), and `model: <tier>` (or
   `model: inherit`, or `model: inherit (fallback from <tier>)`, or the
   per-issue forms `model: <tier> (per-issue)` /
   `model: inherit (per-issue)`).
6. **Inline fallback.** When no subagent mechanism exists (headless run,
   cron, degraded harness), run the check inline as before — and the
   artifact MUST record `context: inline` so the reduced independence
   stays visible in the record.

## Report validation — retry-then-stuck (#360)

When this check ran DISPATCHED, validate the returned artifact before adopting it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-lint.sh" "<artifact>" subagent
```

On FAIL (a garbled / no-tool-use report — the #117/#122/#76/#315 misfire class):
archive the reject to `<issue-dir>/analysis/rejected/<date>-improve-attempt<N>.md`,
re-dispatch ONCE with an explicit "your previous response did no work — actually do
the work with tools" nudge, and if it FAILs again mark the step `[!]` with the lint
reason. Never adopt a garbled report as a result (the #315 lesson). Inline runs skip
the lint (the operator sees the artifact directly).

## Checklist

Walk the three finding categories in order, then apply the pothole tripwire.

1. **Bugs in the plan.** Where would the proposed change introduce a
   bug, regression, off-by-one, race, or memory issue? For each, cite
   the task number and the specific line of reasoning that fails.
2. **Unintended side effects.** What downstream code, build target,
   API consumer, or test is touched indirectly? Cite call sites if
   known. If unknown but plausible, list as "investigate before
   committing".
3. **Ambiguities not resolved by scope.** What in the plan would
   confuse another engineer reading it cold? Concrete, not abstract:
   "task 2 says 'add a check' — check for what condition? null? empty?
   uninitialized?"
4. **Pothole register tripwire (#286).** Read the resolved register
   (packaged for you per Dispatch step 2) and judge which of its DOMAIN
   TRIGGERS actually match this issue's change. Then read the plan's
   `## Potholes considered` section: a register trigger that MATCHES
   this issue but is ABSENT from, or wrongly marked N/A in, that section
   is a finding — report it under `### Bugs` (the plan walks into a known
   trap). This is a check, not a fourth output bucket; its findings live
   in Bugs.

For each callout: tag with `[merge]`, `[defer]`, or `[dismiss]`. The
operator decides; the skill proposes a default tag based on severity.

## Output format (append to imPlan.md)

```markdown
## Improvements

(triaged from analysis/2026-05-19-improve.md — context: subagent)

### Bugs
- [merge] Task 2: strncpy with bound = strlen(src) is equivalent to
  strcpy; bound must be sizeof(dst) - 1 with explicit nul-term.

### Unintended side effects
- [defer] foo.c is included by three other TUs; rebuild cost +12s.
  Document, do not change.

### Ambiguities
- [merge] Task 1: which encoding does the source string use? If
  multi-byte, byte-truncation corrupts. Add encoding assertion.
```

## Halt and ask if

- `imPlan.md` lacks a `## Scope evaluation` section — operator must
  run `/devagent:scope` first.
- More than 10 bugs surface — propose returning to draft step rather
  than papering over a fundamentally broken plan.
- A bug callout requires reading source you cannot locate — halt and
  ask the operator to point you at the right file rather than guessing.

## Skipping policy

Never auto-skip. If the plan is trivially mechanical (e.g., a single
typo fix), surface the skip request rather than silently advancing:
"No improvements found; mark step `[-]` skipped?"

## Logging

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh "$ISSUE_DIR" improve \
  "Improvements appended; B bugs, S side-effects, A ambiguities; note: $NOTE"
```

## Templates referenced

- the resolved `imPlan_template.md` (§12 registry: project paths → devdoc → plugin default) (canonical section ordering;
  this step appends an `## Improvements` section, which the template does not define).
