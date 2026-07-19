---
description: Surface latent bugs, side effects, ambiguities in the active issue's plan.
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read, Write, Edit, Skill, Agent
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:improve

Step 3 of the 22-step devAgent workflow. The check runs in the
`devagent:plan-improver` agent, which cannot write files and carries the
checking procedure (three finding categories + the #286 pothole tripwire) as
its system prompt; it reads the plan cold and resolves the pothole register
itself (§12 registry: project paths → devdoc → plugin default). This command
resolves the tier, dispatches, writes the returned report to
`<issue-dir>/analysis/YYYY-MM-DD-improve.md`, triages the findings, and
appends the tagged `## Improvements` section to `imPlan.md`.

## Argument parsing

Per `commands/draft.md`. In short: optional `project`, optional issue
dir, remainder = `$NOTE`; `--` halts positional consumption.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify `imPlan.md` exists AND contains a `## Scope evaluation`
   section. If not, halt and tell the operator to run scope first.
3. **Dispatch** per the contract below. The checker authors the findings and
   returns them; it cannot write files.
4. **Write the returned body VERBATIM** to
   `<issue-dir>/analysis/YYYY-MM-DD-improve.md` (create `analysis/` if
   missing — pull scaffolds only the issue dir). Never rewrite the checker's
   findings in place — triage them, act on them, but leave the record as
   authored.
5. Validate the report (below), then **triage**: assign each finding
   `[merge]`, `[defer]`, or `[dismiss]` — tag assignment is the main
   session's judgment, not the checker's — and append the tagged
   `## Improvements` section to `imPlan.md` citing the artifact:

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

6. Log the finding counts:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" improve \
     "Improvements appended; B bugs, S side-effects, A ambiguities; note: $NOTE"
   ```

## Dispatch contract

Fresh context is what makes the check real; the model override is conditional.
The `core-improve` skill invoked below is a fork prompt bound to the agent —
invoking it IS the fresh-context dispatch.

1. **Resolve the model tier and read the EXIT CODE** (#458). Pass the
   CANONICAL step number (3) even on a renumbered checklist — the class map is
   keyed to canonical numbers (config.sh). The three no-tier states are not
   interchangeable here, so discriminate on the code, never on stderr prose:

   ```bash
   err="$(mktemp)"
   tier="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/step-model.sh" <project> 3 2>"$err")"; rc=$?
   prov="$(cat "$err")"; rm -f "$err"
   ```

   (`$prov` is load-bearing: the per-issue provenance note arrives on stderr,
   and command substitution alone would discard it — the `(per-issue)` stamp
   forms key off `$prov`, not off eyeballed terminal output.)

   | rc | meaning | dispatch | stamp |
   |----|---------|----------|-------|
   | 0 | a tier resolved | Agent tool, `subagent_type: devagent:plan-improver`, `model: <tier>` | `<tier>`, or `<tier> (per-issue)` when `$prov` carries a `per-issue` line |
   | 2 | the reserved `inherit` token — the operator's explicit escape from a project pin (per-issue marker #291, or a config-table tier of `inherit`) | **invoke the `core-improve` skill**, passing in its args: "stamp `model: <form>`" — the fork inherits the session model | `inherit (per-issue)` when `$prov` says `per-issue`; plain `inherit` when it says `config tier` |
   | 3 | nothing configured | Agent tool, explicit `model: opus` — the wrapper-carried step default | `agent-default (plan-improver)` |
   | 1 | error: a bad/unreadable marker | — | **STOP**; fix or remove the marker |

   rc 2 must never collapse into rc 3: that would silently defeat the only way
   to opt out of a pinned tier.

   **Why the model default lives HERE and not in the agent's frontmatter, and
   why rc 2 rides the skill (measured at 2.1.211, #458 redmr BLOCKING):** the
   Agent tool's `model` parameter is a closed enum (`sonnet|opus|haiku|fable`)
   with NO `inherit` value — passing the literal `inherit` hard-fails
   validation — and omitting the parameter resolves to *the agent definition's
   model* before the parent's. A frontmatter pin therefore makes rc 2
   unsatisfiable on every dispatch shape. So the agent carries NO `model:` pin
   (`effort` stays pinned there; the Agent tool has no effort parameter), and:
   an unpinned fork inherits the session model (transcript-verified — the
   fork's recorded model ID equaled the main chain's), which is exactly rc 2's
   semantics; rc 3's default is this table's `model: opus`, passed explicitly
   (transcript-verified — an explicit param's model ID is the one recorded).

2. **Both dispatch shapes run the same agent** — system prompt, Write/Edit
   denial, and fresh context hold on either path; only the model source
   differs. Never pass the literal `inherit` as the Agent-tool `model`
   parameter — it is not a legal value and fails validation.

3. **Package inputs as paths, not conversation.** The dispatch prompt contains
   only: the project name, the absolute paths of `issue.md` and `imPlan.md`
   (including its Scope evaluation), the project source repo directory, the
   output artifact path, and the `model:` value to stamp. The checker resolves
   the pothole register itself via
   `template.sh --project <project> show potholes` (#286: self-resolution is
   what makes the tripwire un-droppable). Do NOT paste plan summaries, your
   own assessment, or prior findings into the prompt — that re-imports the
   author bias the dispatch exists to shed.

4. **Mandatory artifact header.** First lines: `context: subagent` (always —
   a fork IS a subagent context; `context: inline` only on the degraded path
   below), then `model:` as one of `<tier>`, `<tier> (per-issue)`, `inherit`,
   `inherit (per-issue)`, `inherit (fallback from <tier>)`, or
   `agent-default (plan-improver)`. This set must stay identical to the
   stamp column of rung 1's table, to the agent's own `## Artifact format`,
   and to the stamps the fork-prompt skill names — the single-source test
   sweeps all nine homes (#458 shipped divergent twice before the sweep).

5. **Degraded-harness fallback.** When no subagent mechanism exists (headless
   run, cron, degraded harness), run the check inline against the agent
   definition's contract and the resolved register; the artifact MUST record
   `context: inline` so the reduced independence stays visible in the record.
   If dispatch fails because the tier is unavailable, retry once with NO
   override and record `model: inherit (fallback from <tier>)`.

6. **Report validation — retry-then-stuck (#360).** When this ran DISPATCHED,
   validate before adopting:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-lint.sh" "<artifact>" subagent`
   (no `--class` — improve is not a verdict class; there is no SHIP/BLOCK
   token to require). On FAIL (a garbled / no-tool-use report — the
   #117/#122/#76/#315 misfire class): archive the reject to
   `<issue-dir>/analysis/rejected/<date>-improve-attempt<N>.md`, re-dispatch
   ONCE with an explicit "your previous response did no work — actually do
   the work with tools" nudge, and if it FAILs again mark the step `[!]` with
   the lint reason. Never adopt a garbled report as a result (the #315
   lesson). Inline runs skip the lint (the operator sees the artifact
   directly).

## Halt and ask if

- Plan lacks `## Scope evaluation` (run scope first).
- Plan already has an `## Improvements` section (overwrite? append
  sub-section? abort?).
- More than 10 bugs surface — propose returning to the draft step rather
  than papering over a fundamentally broken plan.
- The checker reports a halt condition (unresolvable register, unlocatable
  source) — resolve it with the operator, then re-dispatch or run inline.

## Skipping policy

Never auto-skip. If the plan is trivially mechanical (e.g., a single typo
fix), surface the skip request rather than silently advancing:
"No improvements found; mark step `[-]` skipped?"

## Completion handoff

First, **mark this step done** — `next.sh` keys off the checklist mark
(not the log), so without it an `--auto`/`--through` chain re-dispatches
this same step forever:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-mark.sh" "$ISSUE_DIR" <N> x
```

`<N>` is this step's number on the issue's checklist; use `-` instead of
`x` if the step was skipped. Then run the Logging command above (if this
skill/command defines one).

**STOP.** Do not invoke any other `/devagent:*` command on your own.
End your final message with this exact question (substituting the
correct next-step slash command from the checklist):

> Would you like to continue on to /devagent:<next-step-name>?

The next-step name is the first step in the issue's checklist.md not
marked `[x]` or `[-]` -- read that line, take the verb after the
step number, and substitute it into the question.

The only exception: if you were invoked under a `/devagent:next
--auto` or `--through` chain (recognizable because the preceding
turn's tool output contained a `CHAIN: /devagent:next ...` line),
then do NOT ask the question -- instead invoke that exact CHAIN:
command verbatim to continue the chain.

If the operator typed a one-off `/devagent:<name>` directly (no
preceding CHAIN: line), DO ask the question and wait for the
operator's answer. Do not advance even if your internal TODO list
still has steps after this one -- the operator's last explicit
instruction is the authoritative scope.
