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

# #583: the rc cases at the end of this file need a project fixture (config +
# state + issue dir) — the tests/step-model.bats pattern. The carrier sweeps
# above read only $REPO and are unaffected.
bats_require_minimum_version 1.5.0
load 'helpers/common'
setup() { devagent_test_setup; }
teardown() { devagent_test_teardown; }

DRAFT_CONTRACT="$REPO/docs/draft-dispatch-contract.md"
CHECKING_CONTRACT="$REPO/docs/checking-dispatch-contract.md"

_add_step_models() {  # $1 = TOML lines for the table body
  printf '[project.%s.step_models]\n%s\n' "$TEST_PROJECT" "$1" \
    >> "$HOME/.claude/devagent/config.toml"
}
_marker() { printf '%s' "$1" > "$DEVDOC_DIR/Issue-1/.devagent-step-models"; }

# _contract_snippet <doc> — rule 1's fenced resolution idiom, extracted from the
# contract ITSELF (so this test cannot drift from what the wrapper runs), with the
# placeholders substituted for the fixture. Exactly ONE bash fence per doc is a
# pinned precondition: a second fence would silently change what runs here.
_contract_snippet() {
  local doc="$1" n
  n="$(grep -c '^ *```bash' "$doc")"
  [ "$n" -eq 1 ] || { echo "expected exactly one bash fence in $doc, got $n" >&2; return 1; }
  awk '/^ *```bash/{f=1;next} /^ *```/{if(f)exit} f{sub(/^ */,""); print}' "$doc" \
    | sed -e 's|\${CLAUDE_PLUGIN_ROOT}|'"$REPO"'|g' \
          -e 's|<project>|'"$TEST_PROJECT"'|g' \
          -e 's|<STEP>|2|g'
}

# _run_draft_snippet — execute the draft contract's snippet VERBATIM in a child
# bash (no `set -e`: the idiom captures rc=$? itself) and print exactly what the
# wrapper then discriminates on: the exit code, the stdout tier, the stderr
# provenance ($prov is what the idiom transports — the checking class stamps its
# artifact header from it, and it is the only provenance channel the wrapper
# has; command substitution alone would drop it — so the tests assert it too).
_run_draft_snippet() {
  local body; body="$(_contract_snippet "$DRAFT_CONTRACT")" || return 1
  bash -c "$body"$'\n''printf "rc=%s tier=%s prov=%s\n" "$rc" "$tier" "$prov"'
}

# _draft_resolves <expected-prefix> — run the snippet and assert its printed tuple
# starts with the expected `rc=… tier=…`; the caller adds its own asserts on
# $output, which `run` leaves set.
_draft_resolves() {
  run _run_draft_snippet
  [ "$status" -eq 0 ] && [[ "$output" == "$1"* ]] || { echo "got: $output" >&2; return 1; }
}

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
  # #528 redmr-rerun MINOR: pin the re-inline sentinel to its source of truth.
  # The negative assertion below greps wrappers for the rc-0 row `| 0 | a tier
  # resolved`; if a doc reformat renames that cell, the sentinel would exist
  # nowhere and the negative check would silently never match (vacuous). Assert
  # the doc still owns the exact string so sentinel and source cannot drift.
  grep -qF '| 0 | a tier resolved' "$doc" || { echo "doc lost the rc-0 sentinel row: $doc" >&2; false; }
  local f
  for f in "$REPO/commands/improve.md" \
           "$REPO/commands/redmr.md" \
           "$REPO/commands/preship.md"; do
    grep -q '## Dispatch contract' "$f" || { echo "wrapper dropped its heading: $f" >&2; false; }
    grep -qF 'checking-dispatch-contract.md' "$f" || { echo "wrapper does not point to the doc: $f" >&2; false; }
    # #528 redmr-rerun MAJOR: pin discovery liveness. dispatch-contract.bats
    # discovers carriers via `grep -rl step-model.sh`; if a wrapper loses that
    # token it silently drops out of the sweep and its reclassification goes
    # dead (the exact prior BLOCKING). Nothing else asserts the wrappers keep
    # the token, so assert it here — a careless removal must red, not vanish.
    grep -qF 'step-model.sh' "$f" || { echo "wrapper lost step-model.sh (drops out of carrier discovery): $f" >&2; false; }
    # #528 redmr BLOCKING-1: a pointer wrapper must not ALSO re-paste a divergent
    # inline copy of the contract. The rc-exit-code table row `| 0 | a tier
    # resolved` lives ONLY in the doc; a wrapper that carries it has re-inlined
    # the contract (the exact anti-divergence regression this change blocks).
    # This guard does not depend on the carrier-discovery sweep, so it fires
    # even if a re-paste omits step-model.sh.
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

# ---- #583: the four exit codes at step 2, executed through the contract's own
# snippet. The rc cases are PINS (the resolver already behaves this way — they
# are green at baseline by design); the two decision assertions further down
# are the born-red ones. Stated so a green run is not mistaken for a born-red
# proof (register: Issue-282).

@test "draft rc 0: the contract's own snippet consumes a KEYED thinking marker — dispatch (#583; #561 DoD-8)" {
  # The wrapper half of the keyed-marker contract, exercised for the first time:
  # a `thinking: <tok>` marker beats the project thinking pin, arrives on stdout
  # with per-issue provenance on stderr, and rc 0 is the table's dispatch row.
  _add_step_models 'thinking = "opus"'
  _marker 'thinking: sonnet'
  _draft_resolves 'rc=0 tier=sonnet prov='
  [[ "$output" == *"per-issue"* ]]
  [[ "$output" == *"$DEVDOC_DIR/Issue-1/.devagent-step-models"* ]]
  grep -qF '| 0 | a tier resolved | dispatch' "$DRAFT_CONTRACT"
}

@test "draft rc 2: a per-issue 'thinking: inherit' is NOT a dispatch trigger — the table says stay INLINE (#583 decision)" {
  _add_step_models 'thinking = "opus"'
  _marker 'thinking: inherit'
  _draft_resolves 'rc=2 tier= prov='
  [[ "$output" == *"per-issue"* ]]
  [[ "$output" == *"inherit"* ]]
  # rc 2 must never collapse into rc 3 (it is the escape from a pin), and the
  # row the wrapper reads for it is the decided one.
  grep -qE '^ *\| 2 \| .*`inherit`.* \| \*\*stay INLINE\*\*' "$DRAFT_CONTRACT"
}

@test "draft rc 2 via the config table: thinking = \"inherit\" is the same inline escape (#583)" {
  _add_step_models 'thinking = "inherit"'
  _draft_resolves 'rc=2 tier= prov='
  [[ "$output" == *"config tier"* ]]
  [[ "$output" != *"per-issue"* ]]
}

@test "draft rc 3: nothing configured — stay INLINE (#583)" {
  _draft_resolves 'rc=3 tier= prov='
  [ "$output" = "rc=3 tier= prov=" ]
  grep -qE '^ *\| 3 \| nothing configured \| stay INLINE' "$DRAFT_CONTRACT"
}

@test "draft rc 1: a malformed keyed marker STOPS — never a silent inline (#583; #561)" {
  _add_step_models 'thinking = "opus"'
  _marker 'thinking: a b'
  _draft_resolves 'rc=1 tier= prov='
  # the INTENDED path's message, not a bare code (register: Issue-Fork-132)
  [[ "$output" == *"exactly one token"* ]]
  grep -qE '^ *\| 1 \| .* \| \*\*STOP' "$DRAFT_CONTRACT"
}

# #561 shipped the rc-2 choice as an open question in two homes and named the
# inverse as a follow-up. Each home must now state the decision as final and no
# longer call it open. One @test PER HOME (register: Issue-123 — a multi-assertion
# guard reddens only at its first failing assert; per-home tests keep both homes
# independently red-capable). Pinned as a CLAIM (a phrase family), not one
# sentence (register: Issue-561 — a guard that reddens on improved wording trains
# people to weaken guards). Known width of that trade: the positive leg also
# admits wording like "stays inline until the final ruling" — it pins that the
# decision is STATED with "final"; the negative leg is what bans the open-question
# wording, file-wide (so an unrelated "provisional" reds it and names its line).
_assert_rc2_final() {  # <file>
  grep -qiE 'stays? INLINE[^.]*final' "$1" \
    || { echo "no final rc-2 decision stated in $1" >&2; return 1; }
  run grep -ciE 'deliberately NOT decided|left undecided|provisional' "$1"
  [ "$output" -eq 0 ] || { echo "$1 still calls the rc-2 decision open (banned wording, file-wide): $(grep -niE 'deliberately NOT decided|left undecided|provisional' "$1")" >&2; return 1; }
}

@test "the rc-2 stay-inline decision is FINAL in the draft contract (#583)" {
  _assert_rc2_final "$DRAFT_CONTRACT"
}

@test "the rc-2 stay-inline decision is FINAL in the draft.md stub (#583)" {
  _assert_rc2_final "$REPO/commands/draft.md"
}

@test "the thinking-class resolution idiom is byte-aligned with the checking-class one (#583)" {
  # AC: "align the thinking-class idiom with the checking contract". Both docs
  # carry ONE fenced snippet; after placeholder substitution (<STEP> -> 2) they
  # must be identical, so the two idioms cannot drift apart again. (Each rc row
  # of the draft table is pinned by its own rc test above.)
  # Extract UNPIPED so the fence-count precondition's rc is not swallowed (register:
  # Issue-314 — improve bug 4), and refuse an empty snippet before comparing: two
  # empty strings are equal, which is the vacuous pass this pin must never take.
  local a b
  a="$(_contract_snippet "$DRAFT_CONTRACT")" || { echo "draft snippet extraction failed" >&2; false; }
  b="$(_contract_snippet "$CHECKING_CONTRACT")" || { echo "checking snippet extraction failed" >&2; false; }
  [ -n "$a" ] && [ -n "$b" ] || { echo "empty snippet: draft=[$a] checking=[$b]" >&2; false; }
  [ "$a" = "$b" ] || { printf 'draft:\n%s\nchecking:\n%s\n' "$a" "$b" >&2; false; }
}
