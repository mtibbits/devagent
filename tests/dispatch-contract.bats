#!/usr/bin/env bats
# #151: dispatch-contract carrier sweep (pattern: completion-handoff-mark.bats).
#
# Every file that names step-model.sh carries OR points to the checking-class
# dispatch contract: fresh-context packaging, model resolution with inherit
# fallback, and the mandatory context:/model: artifact-header grammar.
# Discovering carriers by grep (not a hardcoded list) means a future carrier —
# a new checking-class skill, or review gaining its own core- skill — is covered
# the day it appears. #528 extracted the shared contract text into
# docs/checking-dispatch-contract.md: the checking wrappers (improve/redmr/
# preship) retain the step-model.sh tier call (so they stay discovered) but now
# POINT to the doc, so they are classified out like the #441 draft.md stub. The
# vacuous-pass guard therefore pins a by-name set of THREE full-contract
# carriers — review.md + the two extracted contract docs (draft + checking) —
# not a bare floor.

REPO="${BATS_TEST_DIRNAME}/.."

_contract_carriers() {
  grep -rl 'step-model.sh' "$REPO/skills" "$REPO/commands"
  # #441: the #284 draft planner contract was extracted from commands/draft.md
  # (now a conditional-load STUB) into its own file — add it explicitly so the
  # full-contract sweep still covers the draft planner.
  echo "$REPO/docs/draft-dispatch-contract.md"
  # #528: the checking-class dispatch contract was extracted from the
  # improve/redmr/preship wrappers (now pointer STUBS) into its own file — add
  # it so the full-contract sweep still covers the checking dispatch.
  echo "$REPO/docs/checking-dispatch-contract.md"
}

@test "every dispatch-contract carrier states the full contract (#151/#528)" {
  local files; mapfile -t files < <(_contract_carriers)
  local f p missing=() full_names=()
  for f in "${files[@]}"; do
    # A POINTER stub names the extracted contract file instead of carrying it:
    # draft.md (#441) points to draft-dispatch-contract.md; the #528 checking
    # wrappers (improve/redmr/preship) point to checking-dispatch-contract.md.
    # Classify all pointer stubs out — their full text lives in the doc (added
    # above). The docs themselves never name their own file, so they stay.
    grep -qF 'draft-dispatch-contract.md' "$f" && continue
    grep -qF 'checking-dispatch-contract.md' "$f" && continue
    # Wrappers that merely hand the project through only need the pointer;
    # full-contract carriers are the files defining a dispatch.
    grep -qE '## Dispatch contract|requesting-code-review' "$f" || continue
    full_names+=("$(basename "$f")")
    for p in 'step-model.sh' 'inherit' 'context: subagent' 'context: inline'; do
      grep -qF "$p" "$f" || missing+=("$f:$p")
    done
  done
  # #528 (issue AC): assert the full-contract carrier set BY NAME, not a bare
  # floor — a lowered number cannot tell "a carrier correctly became a pointer"
  # from "a carrier silently vanished". After the extraction the full carriers
  # are review.md (the code-review dispatch) plus the two extracted contract
  # docs; the three checking wrappers dropped to pointer stubs this change.
  local expected='checking-dispatch-contract.md draft-dispatch-contract.md review.md'
  local got; got="$(printf '%s\n' "${full_names[@]}" | sort -u | tr '\n' ' ' | sed 's/ $//')"
  [ "$got" = "$expected" ] || { echo "carrier-set drift: got [$got] expected [$expected]" >&2; false; }
  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'missing contract token: %s\n' "${missing[@]}" >&2
  fi
  [ "${#missing[@]}" -eq 0 ]
}

@test "the checking-class dispatch contract is single-sourced; wrappers point to it (#151/#458/#527/#528)" {
  # #458 moved the redmr/preship contracts from the SKILL to the COMMAND, #527
  # completed the pattern for improve, and #528 extracted the near-identical
  # contract text — shared by all three wrappers — into ONE doc, leaving each
  # wrapper a pointer + per-step delta block. The full section (the section
  # heading + the path-packaging rule) now lives in the doc; each wrapper still
  # keeps its `## Dispatch contract` heading (pins cmd_wrappers.bats) and names
  # the doc it points at.
  local doc="$REPO/docs/checking-dispatch-contract.md"
  grep -q '## Dispatch contract' "$doc" || { echo "no contract section in doc: $doc" >&2; false; }
  grep -q 'paths, not' "$doc" || { echo "no path-packaging rule in doc: $doc" >&2; false; }
  local f
  for f in "$REPO/commands/improve.md" \
           "$REPO/commands/redmr.md" \
           "$REPO/commands/preship.md"; do
    grep -q '## Dispatch contract' "$f" || { echo "wrapper dropped its heading: $f" >&2; false; }
    grep -qF 'checking-dispatch-contract.md' "$f" || { echo "wrapper does not point to the doc: $f" >&2; false; }
    # #528 redmr BLOCKING-1: a pointer wrapper must not ALSO re-paste a divergent
    # inline copy of the contract. The rc-exit-code table row `| 0 | a tier
    # resolved` lives ONLY in the doc; a wrapper that carries it has re-inlined
    # the contract (the exact anti-divergence regression this change blocks).
    # This guard does not depend on the carrier-discovery sweep (which keys off
    # step-model.sh), so it fires even if a re-paste omits that token.
    run grep -cF '| 0 | a tier resolved' "$f"
    [ "$output" -eq 0 ] || { echo "wrapper re-inlined the rc table (divergent copy): $f" >&2; false; }
  done
}

@test "the fork-bound checking skills hand off to their agent without re-stating the contract (#458/#527)" {
  # The twin-drift guard: the procedure lives in the agent system prompt, and the
  # skill must NOT carry a second copy that can rot away from it.
  local f
  for f in "$REPO/skills/core-redmr/SKILL.md" "$REPO/skills/core-preship/SKILL.md" \
           "$REPO/skills/core-improve/SKILL.md"; do
    run grep -c '^context: fork$' "$f"
    [ "$output" -eq 1 ]
    grep -qE '^agent: devagent:(redteam-reviewer|preship-verifier|plan-improver)$' "$f"
    # No second contract copy, and no tier resolution: those are the wrapper's.
    run grep -c '## Dispatch contract' "$f"
    [ "$output" -eq 0 ]
    run grep -c 'step-model.sh' "$f"
    [ "$output" -eq 0 ]
  done
}

@test "the thinking-class planner contract is defined in its extracted file (#284/#441)" {
  # #441: the #284 planner contract moved out of draft.md into its own
  # conditionally-loaded file. Its OWN tokens (the generic sweep above covers the
  # shared four): intent packaging, question-return, the round bound, and the
  # Phase-6 required input — must all survive the move.
  local f="$REPO/docs/draft-dispatch-contract.md"
  grep -q '## Dispatch contract' "$f"
  grep -qF 'intent.md' "$f"
  grep -qF 'Open questions' "$f"
  grep -qF 'pending_comments_file' "$f"
  grep -qF 'two rounds' "$f"
  grep -qF 'intent_template' "$f"
  # draft.md retains a stub that points to the extracted contract.
  grep -qF 'draft-dispatch-contract.md' "$REPO/commands/draft.md"
}
