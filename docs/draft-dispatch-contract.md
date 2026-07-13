## Dispatch contract (#284 — thinking-class up-delegation)

Planning is the INVERSE of #151's checking dispatch: a checker wants
isolation (paths, no author context); a planner is better the more
operator INTENT it holds — packaged to disk, never "paste the
conversation".

1. **When to dispatch.** Resolve the tier:
   `tier="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/step-model.sh" <project> 1 || true)"`
   (canonical step number 1; the thinking class). A NON-EMPTY tier ⇒
   dispatch a fresh-context planner subagent with that model override.
   EMPTY ⇒ stay inline — note this deliberately differs from #151,
   where dispatch is unconditional and empty means dispatch-with-
   inherit; for planning, inline IS the fully-informed default and
   dispatch exists for up-delegation. An explicit operator instruction
   ("dispatch the draft" / "plan inline") overrides either way. If
   the resolved tier is unavailable at dispatch, retry once with no
   override and record the fallback form (rule 5).
   Per-issue `.devagent-step-models` markers do NOT apply — the #291
   layer is checking-class only (config.sh gate).
2. **Package intent to disk, then dispatch paths.** Before dispatching,
   write `<issue-dir>/intent.md` from the resolved `intent_template`
   (§12 registry key) — sections: `## Goals`, `## Constraints`,
   `## Rejected alternatives`, `## Answers` (append-only across
   rounds) — distilled from `$NOTE`, the conversation's constraints,
   and any scope answers. The dispatch prompt carries NO
   conversation transcript; its content is: the absolute paths of
   `issue.md` and `intent.md`, the project source repo directory,
   `$NOTE` verbatim, the output path `<issue-dir>/imPlan.md`, the
   contract duties the planner must honor (provenance header grammar,
   the question-return protocol, the house plan shape) — and, when
   `pending_comments_file` is set in state, that file's path as a
   REQUIRED input (the Phase-6 revision flow; a re-draft that omits
   it silently drops reviewer feedback).
3. **Question-return protocol (ask-don't-guess, dispatched).** A
   dispatched planner cannot ask the operator anything. If packaged
   intent leaves a load-bearing gap, the planner writes the plan with
   an `## Open questions (dispatch round N)` section INSTEAD of
   guessed content for the affected parts. A discovery that FALSIFIES
   an intent.md premise is an open question too — correct the record,
   but route the decision the correction opens back to the operator
   rather than resolving it unilaterally (sourced from the #284
   dogfood, where a planner corrected a false "guard already exists"
   premise unilaterally — the behavior this rule now forbids). The main session answers
   into intent.md's `## Answers` and re-dispatches. Bounded: at most
   two rounds; if questions remain, fall back to INLINE drafting
   (the operator is one message away there), reading intent.md — the
   accumulated Answers are the inline draft's input, not dead state.
4. **Round overwrite exemption.** Within a round sequence, the round-N
   plan supersedes round N-1 WITHOUT triggering the existing-imPlan
   halt below; that halt applies only to a NEW `/devagent:draft`
   invocation. The round number is DERIVED, not remembered: count the
   `## Open questions (dispatch round N)` headings already answered in
   intent.md's `## Answers` — that makes the bound enforceable across
   sessions.
5. **Provenance header.** A DISPATCHED imPlan.md carries the #151
   grammar as its first two lines, BEFORE the `# Issue-N:` title:
   `context: subagent` and `model: <tier>` (or
   `model: inherit (fallback from <tier>)` on the retry-once
   degradation; an operator-instructed dispatch with an EMPTY tier
   records `model: inherit`). Inline drafting writes NO header (no
   `context: inline` line — absence = inline, which keeps the
   historical plan corpus valid). The imPlan template does not define
   these lines; the planner prepends them.
6. **Finalization is the MAIN session's, once.** The marker files
   (workflow step 6), clearing `pending_comments_file` (step 7), the
   log entry (step 8), and the checklist mark happen ONLY after the
   FINAL accepted plan — questions resolved, or the bound exhausted
   and the inline fallback finished. A round plan still carrying
   UNRESOLVED `## Open questions` is never what `/devagent:scope`
   sees (an explicitly emptied/"None" section on the accepted plan is
   fine — it is the record that the protocol ran).
7. **Generalization note.** The other thinking-class steps (7/8/9/12)
   can adopt this contract later; draft is the payoff case and the
   only carrier today.
