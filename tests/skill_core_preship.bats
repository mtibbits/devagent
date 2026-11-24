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
# commands/preship.md is a doc the main session EXECUTES (register Issue-461/583). Since
# review finding 1 every preflight call is scripts/preship-preflight.sh, whose behaviour
# tests/preship-preflight.bats runs; these tests pin the doc and its tie to the script.
# One assertion per line: in bats a failing non-final `A && B` conjunct fails nothing.

# _line_of <fixed text> - the first line number of CMD holding it (fails when absent).
_line_of() { local n; n="$(grep -nF -m1 -- "$1" "$CMD" | cut -d: -f1)"; [ -n "$n" ] || { echo "absent: $1" >&2; return 1; }; echo "$n"; }
# _preflight - the preflight section's text: from its title to step 2a.
_preflight() { awk '/^\*\*Preflight \(between 2 and 2a\)/{f=1} /^2a\. /{f=0} f' "$CMD"; }
PF='bash "${CLAUDE_PLUGIN_ROOT}/scripts/preship-preflight.sh"'

@test "preflight: every command in the section is a script call under the plugin grant (#1122 review)" {
  local t span n=0
  t="$(_preflight)"
  [ -n "$t" ]
  run grep -c '^[[:space:]]*```' <<<"$t"                               # no fenced shell to run
  [ "$output" -eq 0 ]
  run grep -c '<<' <<<"$t"                                             # no heredoc: multi-line, outside the grant (Issue-584)
  [ "$output" -eq 0 ]
  [[ "$t" == *'`$ISSUE_DIR/.preflight-reason` with the Write'* ]]      # the reason travels in a file
  while IFS= read -r span; do
    n=$((n + 1))
    [[ "$span" == 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/'* ]] || { echo "outside the grant: $span"; return 1; }
  done < <(grep -oE '`bash [^`]*`' <<<"$t" | tr -d '`')
  [ "$n" -ge 2 ]                                                       # the selector sees the calls
}

@test "preflight: each subcommand the section names is in the script's usage (#1122 review)" {
  local t sub usage
  t="$(_preflight)"
  usage="$(grep -m1 '^usage=' "$BATS_TEST_DIRNAME/../scripts/preship-preflight.sh")"
  for sub in evidence claims 'prior <L>' 'save <L>' 'log corrected <L>' 'log named-commit <L>' \
             'log left-as-written <L>' 'log unresolved <L>' 'log could-not-run' 'log preflight'; do
    [[ "$t" == *"… $sub"* || "$t" == *"preship-preflight.sh\" $sub "* ]] || { echo "doc lacks: $sub"; return 1; }
    [[ "$usage" == *"${sub%% *}"* ]] || { echo "usage lacks: $sub"; return 1; }
  done
}

@test "preflight: evidence check before the head pin, with --attestable-exit (#1122)" {
  local step2 ev pin
  step2="$(_line_of '2. Verify `mr.md` exists')"
  ev="$(_line_of "$PF evidence <project> <Issue-N>")"
  pin="$(_line_of 'preship-verified-head.sh" pin')"
  [ "$step2" -lt "$ev" ]
  [ "$ev" -lt "$pin" ]
  _preflight | grep -qF '**Preflight (between 2 and 2a)'
  _preflight | grep -qF -- '--attestable-exit'
  _preflight | grep -qi 'Zero-diff'                                    # the zero-diff decision comes first
}

@test "preflight: an evidence stop is pre-dispatch, with no preship.md (#1122)" {
  local t; t="$(_preflight)"
  [[ "$t" == *"before any dispatch"* ]]
  [[ "$t" == *"preship: evidence preflight:"* ]]
  [[ "$t" == *"no preship.md"* ]]
}

@test "preflight: an evidence stop moves an existing preship.md to analysis/<date>-<HHMMSS>-preship-superseded.md and logs it (#1122)" {
  _preflight | grep -qF 'analysis/<date>-<HHMMSS>-preship-superseded.md'
  grep -qF 'sup="analysis/$(date_tag)-$(date +%H%M%S)-preship-superseded.md"' "$BATS_TEST_DIRNAME/../scripts/preship-preflight.sh"
}

@test "preflight: no run-suite.sh or evidence-stamp.sh (#1122)" {
  local t; t="$(_preflight)"
  [[ "$t" == *'neither `run-suite.sh` nor `evidence-stamp.sh`'* ]]
  run grep -cE 'scripts/(run-suite|evidence-stamp)\.sh' <<<"$t"
  [ "$output" -eq 0 ]
}

@test "preflight: exit 4 continues, 9/10/11 quarantine (#1122)" {
  local t; t="$(_preflight)"
  [[ "$t" == *"0 or 4: continue"* ]]
  [[ "$t" == *"9, 10 or 11: the quarantine rule"* ]]
}

@test "preflight: order evidence, claims, head pin, dispatch (#1122)" {
  local ev cl pin dc
  ev="$(_line_of "$PF evidence <project> <Issue-N>")"
  cl="$(_line_of "$PF claims <project> <Issue-N>")"
  pin="$(_line_of 'preship-verified-head.sh" pin')"
  dc="$(_line_of '## Dispatch contract')"
  [ "$ev" -lt "$cl" ]
  [ "$cl" -lt "$pin" ]
  [ "$pin" -lt "$dc" ]
  _preflight | grep -qF '**evidence check, claims check, head pin, dispatch**'
}

@test "preflight: three correction rules, no Evidence-block edit (#1122)" {
  local t p; t="$(_preflight)"
  for p in 'prompt to look' 'correct the line' 'keep the value' 'name the commit' 'leave the line as written' \
           'Never edit the `## Evidence` block' '**name the commit** as `` at `<sha>` `` (the form the check reads)'; do
    [[ "$t" == *"$p"* ]] || { echo "missing: $p"; return 1; }
  done
}

@test "preflight: at most three runs; unresolved and could-not-run logged, verifier still dispatched (#1122)" {
  local t p; t="$(_preflight)"
  for p in 'at most three runs' 'unresolved' 'could not run' 'the verifier is still dispatched' 'dispatch anyway' \
           'Edit nothing after the last run'; do
    [[ "$t" == *"$p"* ]] || { echo "missing: $p"; return 1; }
  done
}

@test "preflight: each of the 7 log spellings present once (#1122)" {
  local s
  for s in "claims: mr.md:<L> corrected: '<old>' -> '<new>'" \
           "claims: mr.md:<L> named commit: '<old>' -> '<new>'" \
           "claims: mr.md:<L> left as written: '<text>' — <reason>" \
           "claims: mr.md:<L> unresolved after run <n>: '<text>'" \
           "claims: could not run (exit <rc>): <first stderr line>; verifier dispatched" \
           "preflight: moved preship.md to analysis/<date>-<HHMMSS>-preship-superseded.md" \
           "preflight: evidence exit <rc>; claims runs <n>, last exit <rc>; <the last claims summary line, or (none)>"; do
    [ "$(grep -cF -- "$s" "$CMD")" -eq 1 ] || { echo "not exactly once: $s"; return 1; }
  done
}

@test "preflight: a re-run looks up 'left as written' first (#1122)" {
  local t look act
  t="$(_preflight)"
  look="$(grep -nF 'Before acting on a report, run `… prior <L>`' <<<"$t" | cut -d: -f1)"
  act="$(grep -nF '**correct the line**' <<<"$t" | cut -d: -f1)"
  [ -n "$look" ]
  [ -n "$act" ]
  [ "$look" -le "$act" ]
  [[ "$t" == *"Do not revisit a line left as written"* ]]
}

@test "#1122 docs: the spec's step-17 row and section, FR-142 (in UC-3) and the CHANGELOG name the preflight" {
  local root="$BATS_TEST_DIRNAME/.." spec req
  spec="$root/docs/specs/2026-05-19-devagent-plugin-design.md"; req="$root/docs/requirements.md"
  grep -qE '^\| 17 \|.*main-session preflight \(#1122\): `preship-evidence.sh --attestable-exit` stops pre-dispatch; `claims-check.sh` reports stale `mr.md` claims for correction; never passes' "$spec"
  grep -qF 'claims-check.sh (#1122)' "$spec"                          # the tree
  grep -qF 'All three pytest-invoking scripts use it' "$spec"
  grep -qF 'stay with verification 3' "$spec"                          # the stated blind spot
  grep -qF -- '- FR-142: Before dispatching the preship verifier, devagent stops on evidence the verifier would fail and reports MR-body claims that differ from the branch' "$req"
  grep -E '^  \{needs: \[FR-1, ' "$req" | head -1 | grep -qF 'FR-142'
  # From [Unreleased] to the end: a release cut moves the entry under a dated section.
  local unrel; unrel="$(sed -n '/^## \[Unreleased\]/,$p' "$root/CHANGELOG.md")"
  [[ "$unrel" == *'scripts/claims-check.sh'* ]] && [[ "$unrel" == *'--attestable-exit'* ]] && [[ "$unrel" == *'(#1122)'* ]]
}

# ---- #1097: imPlan.md as a verifier input, and the post-ship stops ------------------
# Rule 1a (agents/preship-verifier.md) takes a test's name from issue.md, else imPlan.md.
# The verifier's inputs have two homes: <INPUTS> in the wrapper and the fork's own input
# list in core-preship. imPlan.md joins each only for a project with required checks, so
# every other project's dispatch is what it was.

# _flat <awk program> <file> - the lines the program selects, whitespace-normalised.
_flat() { awk "$1" "$2" | tr -s '[:space:]' ' '; }
RC_CALL='bash "${CLAUDE_PLUGIN_ROOT}/scripts/required-checks.sh" <project>'

@test "#1097 preship dispatch packages imPlan.md only for a project with required checks" {
  local inputs step s2 p pin b disp
  # the wrapper's step: one call, after the head pin and before the dispatch
  step="$(_flat '/^2b[.] /{f=1} /^3[.] /{f=0} f' "$CMD")"
  [ -n "$step" ] || { echo "no step 2b in $CMD" >&2; return 1; }
  pin="$(_line_of '2a. **Pin the head')"
  b="$(_line_of '2b. **Required checks')"
  disp="$(_line_of '3. **Dispatch**')"
  [ "$pin" -lt "$b" ]
  [ "$b" -lt "$disp" ]
  [[ "$step" == *"\`$RC_CALL\`"* ]] || { echo "step 2b lacks the call: $RC_CALL" >&2; return 1; }
  grep -qF 'usage: required-checks.sh <project>' "$BATS_TEST_DIRNAME/../scripts/required-checks.sh"   # the call's arity is the script's
  # a list that could not be read stops the wrapper; it is never an empty list (devagent Issue-713)
  for p in 'non-zero' 'STOP' 'before any dispatch' 'never "no required checks"' 'prints nothing'; do
    [[ "$step" == *"$p"* ]] || { echo "step 2b lacks: $p" >&2; return 1; }
  done
  # <INPUTS>: imPlan.md under that condition, and no other change to the list
  inputs="$(_flat '/^- [*][*]`<INPUTS>`[*][*]/{f=1; print; next} f && /^- [*][*]`</{exit} f' "$CMD")"
  [ -n "$inputs" ]
  [[ "$inputs" == *'the absolute paths of `issue.md`, `mr.md`, and the latest-dated review/redmr artifacts, plus the diff spec `<baseline_sha>..<SHA>`'* ]]
  [[ "$inputs" == *'Only when step 2b printed a required check'*'`imPlan.md`'* ]] || { echo "<INPUTS> does not name imPlan.md under the condition: $inputs" >&2; return 1; }
  [ "$(grep -c 'imPlan\.md' "$CMD")" -eq "$(awk '/^2b[.] /{f=1} /^3[.] /{f=0} f; /^- [*][*]`<INPUTS>`[*][*]/{g=1; print; next} g && /^- [*][*]`</{g=0} g' "$CMD" | grep -c 'imPlan\.md')" ]   # named nowhere unconditionally
  # the fork's list (core-preship step 2): the same condition, read off rule 1a's own first line
  s2="$(_flat '/^2[.] /{f=1} /^3[.] /{f=0} f' "$SKILL/SKILL.md")"
  [[ "$s2" == *'`<issue-dir>/issue.md`'*'`<issue-dir>/mr.md`'* ]]
  [[ "$s2" == *'Only when'*'`<issue-dir>/imPlan.md`'* ]] || { echo "core-preship step 2 does not name imPlan.md under a condition: $s2" >&2; return 1; }
  [[ "$s2" == *'`required checks: (none)`'* ]]
  [ "$(grep -c 'imPlan\.md' "$SKILL/SKILL.md")" -eq "$(awk '/^2[.] /{f=1} /^3[.] /{f=0} f' "$SKILL/SKILL.md" | grep -c 'imPlan\.md')" ]
  # and that line is the one the verifier's rule and the script both spell
  grep -qF '`required checks: (none)`' "$AGENT"
  grep -qF "printf 'required checks: (none)\n'" "$BATS_TEST_DIRNAME/../scripts/preship-deferred.sh"
}

@test "#1097 re-verifying after ship: a passing preship clears a required-check stop, never rule 20 or 21" {
  local t p mm vh
  mm="$BATS_TEST_DIRNAME/../scripts/mergemr.sh"; vh="$BATS_TEST_DIRNAME/../scripts/preship-verified-head.sh"
  t="$(_flat '/^## Re-verifying after ship$/{f=1; next} /^## /{f=0} f' "$CMD")"
  [ -n "$t" ]
  # rule 15's required-check stops, each by the text mergemr stops with
  for p in 'required check not successful on head' 'required check not reported on head' \
           'merges only when every required check is successful'; do
    [[ "$t" == *"$p"* ]] || { echo "the section lacks: $p" >&2; return 1; }
    grep -qF -- "$p" "$mm" || { echo "mergemr.sh does not stop with: $p" >&2; return 1; }
  done
  [[ "$t" == *'as it clears red CI'* ]]
  # the two operator-only stops, and each one's exit
  for p in 'rule 20' '`CI NOT CHECKED`' 'by hand' 'rule 21' '`<issue-dir>/.devagent-selfcert-ack`' 'never clears'; do
    [[ "$t" == *"$p"* ]] || { echo "the section lacks: $p" >&2; return 1; }
  done
  grep -qF '_stop 20 "CI NOT CHECKED: ' "$mm"
  grep -qF '_stop 21 "self-certifying diff' "$mm"
  # what `record` clears is the script's own list: rule 15 is in it, 20 and 21 are not
  grep -qF "clear_mergemr_stop preship '^(mergemr rule (10|11|14|15): |mergemr rule 17: head [0-9a-f]{7} was recorded by forward |preship: )'" "$vh"
}
