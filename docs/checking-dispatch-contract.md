# Checking-class dispatch contract (#528 — extracted from the wrappers)

The single source for the fresh-context dispatch contract shared by the
CHECKING-class step wrappers: `commands/improve.md` (step 5),
`commands/redmr.md` (step 16), and `commands/preship.md` (step 17). Each of
those wrappers retains a `## Dispatch contract` heading whose body is a pointer
to this file plus a compact **delta block** — the per-step values named by the
`<PLACEHOLDER>` tokens below. Precedent: #441 extracted the THINKING-class
planner contract into its own docs/ file the same way; this file is its
checking-class sibling. Unlike #441 there is no conditional-load stub — this
contract loads whenever its command runs, so the extraction is purely
anti-divergence (#528).

Per-step deltas each wrapper supplies (nothing else varies):

| token | meaning |
|-------|---------|
| `<INTRO>` | the one-line framing sentence above rung 1 |
| `<STEP>` | canonical step number — `5` improve / `16` redmr / `17` preship |
| `<AGENT>` | bound agent — `plan-improver` / `redteam-reviewer` / `preship-verifier` |
| `<SKILL>` | rc-2 fork-prompt skill — `core-improve` / `core-redmr` / `core-preship` |
| `<INPUTS>` | rung-3 path-packaging list (the artifacts the prompt names) |
| `<TEMPLATE-RES>` | rung-3 self-resolution clause (potholes / `redteam_mr` / none) |
| `<CLASS>` | rung-6 `dispatch-lint` class flag (`--class redmr` / `--class preship` / none — improve is not a verdict class) |
| `<REJECT-SLUG>` | rung-6 rejected-artifact filename slug (`improve` / `redmr` / `preship`) |

## Dispatch contract

`<INTRO>`

1. **Resolve the model tier and read the EXIT CODE** (#458). Pass the step
   number the ACTIVE checklist row carries (`<STEP>`). Since #558, numbers are
   POSITIONS assigned once from the standard template's execution order, and the
   class map (config.sh) is keyed to those same global numbers, so a checklist
   scaffolded at or after #558 agrees by construction. **A checklist scaffolded
   BEFORE #558 carries the old numbers and WILL resolve the wrong class** —
   regenerate its revision block with `/devagent:revise` before relying on a
   tier override. The three no-tier states are not interchangeable here, so
   discriminate on the code, never on stderr prose:

   ```bash
   err="$(mktemp)"
   tier="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/step-model.sh" <project> <STEP> 2>"$err")"; rc=$?
   prov="$(cat "$err")"; rm -f "$err"
   ```

   (`$prov` is load-bearing: the per-issue provenance note arrives on stderr,
   and command substitution alone would discard it — the `(per-issue)` stamp
   forms key off `$prov`, not off eyeballed terminal output.)

   | rc | meaning | dispatch | stamp |
   |----|---------|----------|-------|
   | 0 | a tier resolved | Agent tool, `subagent_type: devagent:<AGENT>`, `model: <tier>` | `<tier>`, or `<tier> (per-issue)` when `$prov` carries a `per-issue` line |
   | 2 | the reserved `inherit` token — the operator's explicit escape from a project pin (per-issue marker #291, or a config-table tier of `inherit`) | **invoke the `<SKILL>` skill**, passing in its args: "stamp `model: <form>`" — the fork inherits the session model | `inherit (per-issue)` when `$prov` says `per-issue`; plain `inherit` when it says `config tier` |
   | 3 | nothing configured | Agent tool, explicit `model: opus` — the wrapper-carried step default | `agent-default (<AGENT>)` |
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
   only: the project name, the project source repo directory, the output
   artifact path, the `model:` value to stamp, and this step's inputs —
   `<INPUTS>`. `<TEMPLATE-RES>` Do NOT paste your recollection of
   the change, prior findings, or summaries into the prompt — deriving
   everything from disk is exactly what the dispatch exists to enforce (a
   stranded fix, a report/branch divergence, or re-imported author bias is what
   it catches).

4. **Mandatory artifact header.** First lines: `context: subagent` (always —
   a fork IS a subagent context; `context: inline` only on the degraded path
   below), then `model:` as one of `<tier>`, `<tier> (per-issue)`, `inherit`,
   `inherit (per-issue)`, `inherit (fallback from <tier>)`, or
   `agent-default (<agent>)`. This set must stay identical to the stamp column
   of rung 1's table, to each bound agent's own `## Artifact format`, and to the
   stamps the fork-prompt skills name; it shipped divergent twice (#458 review
   MAJOR-1: `inherit (per-issue)` missing; redmr r2 MAJOR: the skill's
   direct-invocation `inherit` missing), so the single-source test
   (`tests/format-single-source.bats`) sweeps every home. The concrete
   `agent-default (<agent>)` token is the one form that is per-wrapper — each
   wrapper's delta block carries its own, and no neighbour's.

5. **Degraded-harness fallback.** When no subagent mechanism exists (headless
   run, cron, degraded harness), run the check inline against the bound agent
   definition's contract (and any template/register it resolves per rung 3); the
   artifact MUST record `context: inline` so the reduced independence stays
   visible in the record. If dispatch fails because the tier is unavailable,
   retry once with NO override and record `model: inherit (fallback from
   <tier>)`.

6. **Report validation — retry-then-stuck (#360).** When this ran DISPATCHED,
   validate before adopting — run
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-lint.sh" "<artifact>" subagent`,
   appending `<CLASS>` when this step is a verdict class.
   On FAIL (a garbled / no-tool-use report — the #117/#122/#76/#315 misfire
   class): archive the reject to
   `<issue-dir>/analysis/rejected/<date>-<REJECT-SLUG>-attempt<N>.md`,
   re-dispatch ONCE with an explicit "your previous response did no work —
   actually do the work with tools" nudge, and if it FAILs again mark the step
   `[!]` with the lint reason. Never adopt a garbled report as a verdict (the
   #315 lesson). Inline runs skip the lint (the operator sees the artifact
   directly).
