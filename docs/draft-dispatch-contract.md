## Dispatch contract (#284 — thinking-class up-delegation)

Planning is the INVERSE of #151's checking dispatch: a checker wants
isolation (paths, no author context); a planner is better the more
operator INTENT it holds — packaged to disk, never "paste the
conversation".

1. **When to dispatch.** Resolve the tier AND READ THE EXIT CODE — do not
   collapse the codes with `|| true` (#561; see the rc table below):

   ```bash
   err="$(mktemp)"
   tier="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/step-model.sh" <project> 2 2>"$err")"; rc=$?
   prov="$(cat "$err")"; rm -f "$err"
   ```
   <!-- This fenced snippet is byte-pinned to the checking-class contract's by
        tests/dispatch-contract.bats, which also executes it per exit code and
        requires exactly ONE bash fence per contract file: add no second bash
        example here, and reflow this snippet only together with its sibling. -->

   (canonical step number 2; the thinking class).

   | rc | meaning | action |
   |----|---------|--------|
   | 0 | a tier resolved | dispatch a fresh-context planner with that model override |
   | 2 | the reserved `inherit` token | **stay INLINE** — FINAL (#583); see the note below |
   | 3 | nothing configured | stay INLINE |
   | 1 | **error: a bad/unreadable marker** | **STOP.** Fix or remove the marker; never silently fall inline |

   **rc 2 stays INLINE — decided and final (#583; ratifies the #561 review-F1
   choice, which had shipped as an open question).** `inherit` is the operator's
   escape from a project pin back to the class's DEFAULT shape, and this class's
   default shape is inline at the session model: inline drafting already runs
   there, so there is nothing to up-delegate. The checking class dispatches on
   rc 2 only because ITS default shape is a fresh-context fork; planning is the
   inverse (top of this file). Under the rejected alternative,
   dispatch-with-`model: inherit`, a project thinking pin plus
   `implementation-model: inherit` would produce a THIRD behavior — a
   fresh-context fork at the session model — and no marker value could express
   "plain inline on this issue". That fresh-context shape stays reachable on
   demand through the explicit operator instruction (rule 5's `model: inherit`
   case).

   Inline IS the fully-informed default here and dispatch exists for
   up-delegation — this deliberately differs from #151, where dispatch is
   unconditional. An explicit operator instruction ("dispatch the draft" /
   "plan inline") overrides either way. If the resolved tier is unavailable at
   dispatch, retry once with no override and record the fallback form (rule 5).

   **Why rc 1 must STOP (#561).** Before #561 this rule resolved the tier with
   `$(… || true)`, which mapped rc 1, 2 and 3 alike to an empty string ⇒ "stay
   inline". #561 made `step_models_tier`'s structural marker faults apply to the
   THINKING class as well as the checking one, so rc 1 became reachable at step 2
   for the first time — and a broken keyed marker would have silently disabled
   draft dispatch instead of stopping. That is the same silent fallback the
   CHECKING-class dispatch contract forbids (its rc-1 row says STOP), at the one
   place `implementation-model` is enforced.
   <!-- The sibling contract is referenced by CLASS above, never by filename, on
        purpose: tests/dispatch-contract.bats treats any file that names a
        dispatch-contract doc as a POINTER STUB rather than a full-contract
        carrier, so writing that filename anywhere in this file silently drops
        THIS file out of the asserted carrier set. Do not "helpfully" add it --
        and note this comment cannot name it either, for exactly that reason.
        Nor may this file name the step-14 draft-MR command: the class-map sweep
        in tests/generic-templates.bats selects the homes it checks by that
        command's bare name, and this file would then count as a twelfth home. -->

   **Per-issue `.devagent-step-models` markers DO apply to this step (#561).**
   The KEYED marker form (`thinking: <token>`) covers the thinking class, so a
   per-issue marker can steer draft's planner. (The legacy BARE token form
   remains checking-class only, so it is still invisible here — the pre-#561
   claim that markers never apply to draft was true only of that form.)
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
   (draft command item 6), clearing `pending_comments_file` (item 7), the
   log entry (item 8), and the checklist mark happen ONLY after the
   FINAL accepted plan — questions resolved, or the bound exhausted
   and the inline fallback finished. A round plan still carrying
   UNRESOLVED `## Open questions` is never what `/devagent:scope`
   sees (an explicitly emptied/"None" section on the accepted plan is
   fine — it is the record that the protocol ran).
7. **Generalization note.** The other thinking-class steps (9/10/11/14)
   can adopt this contract later; draft is the payoff case and the
   only carrier today.
