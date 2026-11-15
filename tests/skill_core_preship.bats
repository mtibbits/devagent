#!/usr/bin/env bats
load 'lib/bats-helpers'

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-preship"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-preship"
  # #458: the skill is now a fork prompt. Its procedure lives in the bound agent
  # and its main-session protocol in the command wrapper — each assertion below
  # names the file that OWNS the contract, so a contract deleted in the move
  # fails here rather than passing by relocation.
  AGENT="$BATS_TEST_DIRNAME/../agents/preship-verifier.md"
  CMD="$BATS_TEST_DIRNAME/../commands/preship.md"
}

@test "core-preship passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "core-preship is bound to the preship-verifier agent, which cannot write (#458)" {
  run grep -c '^context: fork$' "$SKILL/SKILL.md"
  [ "$output" -eq 1 ]
  run grep -c '^agent: devagent:preship-verifier$' "$SKILL/SKILL.md"
  [ "$output" -eq 1 ]
  # The isolation is the agent's, and it is a denial — not a declaration.
  grep -qE '^disallowedTools:.*\bWrite\b' "$AGENT"
  grep -qE '^disallowedTools:.*\bEdit\b' "$AGENT"
  grep -qE '^effort:[[:space:]]+\S' "$AGENT"
  # No model pin — a pinned agent model defeats the #291 inherit escape (rc 2);
  # the step default is wrapper-carried. See tests/agents.bats for the measurement.
  run grep -c '^model:' <(skill_frontmatter "$AGENT")
  [ "$output" -eq 0 ]
}

@test "the preship verifications live in the agent system prompt (#458)" {
  grep -qi 'acceptance criteria' "$AGENT"
  grep -qi 'findings applied' "$AGENT"
  grep -qi 'push preview' "$AGENT"
  grep -qi 'preship-evidence.sh' "$AGENT"
}

@test "preship fails to [!] via checklist-stuck with the correct signature (#149/#458)" {
  # No step-number argument — the script marks the CURRENT step. The failure
  # protocol binds the MAIN session, so #458 homes it in the wrapper.
  grep -q 'checklist-stuck.sh" "$ISSUE_DIR" "preship:' "$CMD"
  grep -q '/devagent:unstuck' "$CMD"
}

@test "preship zero-diff auto-skip is fail-safe (#149/#458)" {
  grep -q 'zero_diff_classify' "$CMD"
  grep -qi 'indeterminate' "$CMD"
}

@test "preship writes the checker's returned artifact verbatim (#458)" {
  # The checker cannot write files; a main session that rewrites the verdict it
  # dislikes would reinstate the #101/#102 class this step exists to catch.
  grep -qi 'verbatim' "$CMD"
}

@test "core-preship fixture exists" {
  [ -s "$FIXT/mr.md" ]
  [ -s "$FIXT/checklist.md" ]
}

@test "the preship spec-touch verification covers adds/renames/removals (#435/#458)" {
  # Lives with the procedure, in the agent system prompt.
  grep -qi 'spec-touch' "$AGENT"
  grep -qiE 'renam' "$AGENT"
  grep -qiE 'remov' "$AGENT"
  grep -qiE 'config key' "$AGENT"
  grep -qiE 'top-level director' "$AGENT"
}

# ---- #1122: the main-session preflight (between 2 and 2a) --------------------------
# commands/preship.md is a doc the main session EXECUTES (register Issue-461/583), so the
# recipes are extracted and run, not only grepped.

# _line_of <fixed text> - the first line number of CMD holding it (fails when absent).
_line_of() { local n; n="$(grep -nF -m1 -- "$1" "$CMD" | cut -d: -f1)"; [ -n "$n" ] || { echo "absent: $1" >&2; return 1; }; echo "$n"; }
# _preflight - the preflight section's text: from its title to step 2a.
_preflight() { awk '/^\*\*Preflight \(between 2 and 2a\)/{f=1} /^2a\. /{f=0} f' "$CMD"; }
# _recipe <name> - the fenced recipe whose first line is `# recipe: <name>`, placeholders filled.
_recipe() {
  awk -v m="# recipe: $1" 'index($0, m) == 1 {f=1} f && /^```$/ {exit} f' "$CMD" \
    | sed -e 's/<project>/testproj/g' -e 's/<Issue-N>/Issue-1/g'
}
# _stubroot - a plugin root whose scripts record instead of acting. preship-evidence.sh
# prints $STUB_ERR on stderr and exits $STUB_RC; evidence-stamp.sh and run-suite.sh touch
# the sentinel; checklist-stuck.sh and checklist-log.sh record their message argument.
_stubroot() {
  ROOT="$BATS_TEST_TMPDIR/root"; ISSUE_DIR="$BATS_TEST_TMPDIR/Issue-1"; SENT="$BATS_TEST_TMPDIR/sentinel"
  mkdir -p "$ROOT/scripts" "$ISSUE_DIR/analysis"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$STUB_ERR" >&2' 'exit "$STUB_RC"' > "$ROOT/scripts/preship-evidence.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'touch "$SENT"' > "$ROOT/scripts/evidence-stamp.sh"
  cp "$ROOT/scripts/evidence-stamp.sh" "$ROOT/scripts/run-suite.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$2" > "$STUCK_REC"' > "$ROOT/scripts/checklist-stuck.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$3" >> "$LOG_REC"' > "$ROOT/scripts/checklist-log.sh"
  chmod +x "$ROOT"/scripts/*.sh
  export CLAUDE_PLUGIN_ROOT="$ROOT" ISSUE_DIR SENT STUCK_REC="$BATS_TEST_TMPDIR/stuck" LOG_REC="$BATS_TEST_TMPDIR/log"
}
# The stamper's own remedy text: backticks, "$", double quotes and an apostrophe.
HOSTILE1122='  - Evidence suite line mismatch — write it with `bash "$CLAUDE_PLUGIN_ROOT/scripts/evidence-stamp.sh" testproj Issue-1` and don'"'"'t edit by hand'

@test "preflight: evidence check before the head pin, with --attestable-exit (#1122)" {
  local step2 ev pin
  step2="$(_line_of '2. Verify `mr.md` exists')"
  ev="$(_line_of 'scripts/preship-evidence.sh" <project> <Issue-N> --attestable-exit')"
  pin="$(_line_of 'preship-verified-head.sh" pin')"
  [ "$step2" -lt "$ev" ] && [ "$ev" -lt "$pin" ]
  _preflight | grep -qF '**Preflight (between 2 and 2a)'
  # The zero-diff decision comes first: an empty diff never reaches the preflight.
  _preflight | grep -qi 'Zero-diff'
}

@test "preflight: an evidence stop is pre-dispatch, with no preship.md (#1122)" {
  local t; t="$(_preflight)"
  [[ "$t" == *"before any dispatch"* ]]
  [[ "$t" == *"preship: evidence preflight:"* ]]
  [[ "$t" == *"no preship.md"* ]]
  _stubroot
  STUB_RC=1 STUB_ERR=$'preship-evidence: FAIL\n  - artifact head: deadbeef is not HEAD\n  - dirty: yes' run bash -c "$(_recipe stop)"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUCK_REC")" = "preship: evidence preflight: artifact head: deadbeef is not HEAD (+1 more)" ]
  [ ! -e "$ISSUE_DIR/preship.md" ]
  [[ "$output" == *"evidence rc=1"* ]]
}

@test "preflight: an evidence stop moves an existing preship.md to analysis/<date>-<HHMMSS>-preship-superseded.md and logs it (#1122)" {
  local t moved; t="$(_preflight)"
  [[ "$t" == *'analysis/<date>-<HHMMSS>-preship-superseded.md'* ]]
  _stubroot
  echo 'old verdict: PASS' > "$ISSUE_DIR/preship.md"
  STUB_RC=1 STUB_ERR=$'preship-evidence: FAIL\n  - x' run bash -c "$(_recipe stop)"
  [ "$status" -eq 0 ]
  [ ! -e "$ISSUE_DIR/preship.md" ]
  moved="$(cd "$ISSUE_DIR" && ls analysis/*-preship-superseded.md)"
  [[ "$moved" =~ ^analysis/[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}-preship-superseded\.md$ ]]
  [ "$(cat "$ISSUE_DIR/$moved")" = 'old verdict: PASS' ]
  [ "$(cat "$LOG_REC")" = "preflight: moved preship.md to $moved" ]
  [ "$(cat "$STUCK_REC")" = "preship: evidence preflight: x" ]
}

@test "preflight: no run-suite.sh or evidence-stamp.sh (#1122)" {
  local t; t="$(_preflight)"
  [[ "$t" == *'neither `run-suite.sh` nor `evidence-stamp.sh`'* ]]
  # Nothing in the section invokes either. The shell-safety paragraph QUOTES the
  # stamper's remedy (`$CLAUDE_PLUGIN_ROOT`, unbraced); an invocation is the braced form.
  ! grep -qE 'bash "\$\{CLAUDE_PLUGIN_ROOT\}/scripts/(run-suite|evidence-stamp)\.sh"' <<<"$t"
  grep -qE 'bash "\$\{CLAUDE_PLUGIN_ROOT\}/scripts/preship-evidence\.sh"' <<<"$t"   # the selector reads invocations
  _stubroot
  STUB_RC=1 STUB_ERR=$'preship-evidence: FAIL\n  - x' run bash -c "$(_recipe stop)"
  [ ! -e "$SENT" ]
}

@test "preflight: exit 4 continues, 9/10/11 quarantine (#1122)" {
  local t rc; t="$(_preflight)"
  [[ "$t" == *"0 or 4: continue"* ]]
  [[ "$t" == *"9, 10 or 11: the quarantine rule"* ]]
  _stubroot
  for rc in 0 4 9 10 11; do
    rm -f "$STUCK_REC"
    STUB_RC="$rc" STUB_ERR=$'preship-evidence: FAIL\n  - TREE UNATTESTED — x' run bash -c "$(_recipe stop)"
    [ "$status" -eq 0 ]
    [ ! -e "$STUCK_REC" ] || { echo "rc $rc stopped the step"; return 1; }
    [[ "$output" == *"evidence rc=$rc"* ]]
  done
  STUB_RC=1 STUB_ERR='' run bash -c "$(_recipe stop)"            # no stderr at all
  [ "$(cat "$STUCK_REC")" = "preship: evidence preflight: (no stderr)" ]
}

@test "preflight: the stop recipe is shell-safe (#1122)" {
  local first="${HOSTILE1122#  - }" naive
  _stubroot
  STUB_RC=1 STUB_ERR="preship-evidence: FAIL"$'\n'"$HOSTILE1122" run bash -c "$(_recipe stop)"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUCK_REC")" = "preship: evidence preflight: $first" ]
  [ ! -e "$SENT" ]
  # Control: the naive spelling, the text interpolated into a double-quoted argument,
  # runs the stamper's backticks (so the assertion above can fail).
  naive="bash \"\$CLAUDE_PLUGIN_ROOT/scripts/checklist-stuck.sh\" \"\$ISSUE_DIR\" \"preship: evidence preflight: $first\""
  run bash -c "$naive"
  [ -e "$SENT" ]
}
