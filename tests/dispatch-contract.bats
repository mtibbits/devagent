#!/usr/bin/env bats
# #151: dispatch-contract carrier sweep (pattern: completion-handoff-mark.bats).
#
# Every file that names step-model.sh carries the checking-class dispatch
# contract: fresh-context packaging, model resolution with inherit fallback,
# and the mandatory context:/model: artifact-header grammar. Discovering
# carriers by grep (not a hardcoded list) means a future carrier — a new
# checking-class skill, or review gaining its own core- skill — is covered
# the day it appears, and a vacuous-pass guard pins today's floor of five
# full-contract carriers (4 checking-class + the #284 draft planner).

REPO="${BATS_TEST_DIRNAME}/.."

_contract_carriers() {
  grep -rl 'step-model.sh' "$REPO/skills" "$REPO/commands"
  # #441: the #284 draft planner contract was extracted from commands/draft.md
  # (now a conditional-load STUB) into its own file — add it explicitly so the
  # full-contract sweep still covers the draft planner.
  echo "$REPO/docs/draft-dispatch-contract.md"
}

@test "every dispatch-contract carrier states the full contract (#151)" {
  local files; mapfile -t files < <(_contract_carriers)
  local f p missing=() full=0
  for f in "${files[@]}"; do
    # #441: the draft.md stub is a POINTER to the extracted contract — not a full
    # carrier (its full text lives in docs/draft-dispatch-contract.md, added above).
    grep -qF 'draft-dispatch-contract.md' "$f" && continue
    # Wrappers that merely hand the project through only need the pointer;
    # full-contract carriers are the files defining a dispatch.
    grep -qE '## Dispatch contract|requesting-code-review' "$f" || continue
    full=$((full + 1))
    for p in 'step-model.sh' 'inherit' 'context: subagent' 'context: inline'; do
      grep -qF "$p" "$f" || missing+=("$f:$p")
    done
  done
  # Guard against a vacuous pass on FILTERED carriers (not merely discovered
  # files). Today's roster (#458 moved redmr/preship skill→command; #527 did
  # the same for improve — core-improve dropped out, improve.md replaced it):
  #   improve.md + review.md + preship.md + redmr.md + draft-dispatch-contract.md
  # A carrier silently dropping out of the sweep must fail here.
  [ "$full" -ge 5 ]
  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'missing contract token: %s\n' "${missing[@]}" >&2
  fi
  [ "${#missing[@]}" -eq 0 ]
}

@test "every checking-class dispatch defines the contract section + path packaging (#151/#458/#527)" {
  # #458 moved the redmr/preship contracts from the SKILL to the COMMAND, and
  # #527 completed the pattern for improve: all three skills are now fork
  # PROMPTS bound to dedicated agents, and the main-session duties the contract
  # describes (tier resolution, the verbatim artifact write, dispatch-lint,
  # the failure protocol) are the wrapper's — so all three contracts live
  # command-side (register #76: the test names each contract's home).
  local f
  for f in "$REPO/commands/improve.md" \
           "$REPO/commands/redmr.md" \
           "$REPO/commands/preship.md"; do
    grep -q '## Dispatch contract' "$f" || { echo "no contract section: $f" >&2; false; }
    grep -q 'paths, not' "$f" || { echo "no path-packaging rule: $f" >&2; false; }
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
