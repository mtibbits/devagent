#!/usr/bin/env bats
# #458: the dedicated checker agents for steps 16 (redmr) and 17 (preship).
# #527: + the step-5 (improve) agent — same structural pins, third row.
#
# These agents are the STRUCTURAL half of fresh-context checking: the isolation
# is enforced by the harness (tool denial + pinned model + system prompt) rather
# than depending on the model choosing to spawn a generic subagent correctly.
# The named failure mode is silently-ignored frontmatter — `claude plugin
# validate --strict` never opens these files (verified 2.1.211), so these
# canaries plus the live smoke test are the only gates. Field spellings are
# probe-verified: agents take `disallowedTools` (camelCase); the hyphenated
# `disallowed-tools` is the SKILL.md spelling and is silently ignored here.
# The Write/Edit denial is tool-level isolation, not a filesystem sandbox —
# that residual is adjudicated ACCEPTED in #529; each agent header carries
# the caveat (swept by the #529 test below).

load 'lib/bats-helpers'
load 'helpers/common'
bats_require_minimum_version 1.5.0

REPO="${BATS_TEST_DIRNAME}/.."
PRESHIP="$REPO/agents/preship-verifier.md"
REDTEAM="$REPO/agents/redteam-reviewer.md"
IMPROVE="$REPO/agents/plan-improver.md"

# Read each frontmatter ONCE per test rather than re-awking per assertion.
setup() {
    FM_PRESHIP="$(skill_frontmatter "$PRESHIP")"
    FM_REDTEAM="$(skill_frontmatter "$REDTEAM")"
    FM_IMPROVE="$(skill_frontmatter "$IMPROVE")"
}
# Only a test that built a project fixture (devagent_test_setup) has one to remove.
teardown() { [ -z "${DEVAGENT_TMP:-}" ] || devagent_test_teardown; }

@test "all three checker agents exist at the plugin's auto-discovered agents/ root (#458/#527)" {
  # agents/ is scanned by default; plugin.json must NOT gain an "agents" key —
  # that REPLACES the default scan rather than adding to it.
  [ -s "$PRESHIP" ]
  [ -s "$REDTEAM" ]
  [ -s "$IMPROVE" ]
  run grep -c '"agents"' "$REPO/.claude-plugin/plugin.json"
  [ "$output" -eq 0 ]
}

@test "agent identity comes from name: frontmatter and matches its binding (#458/#527)" {
  run grep -c '^name: preship-verifier$' <<<"$FM_PRESHIP"
  [ "$output" -eq 1 ]
  run grep -c '^name: redteam-reviewer$' <<<"$FM_REDTEAM"
  [ "$output" -eq 1 ]
  run grep -c '^name: plan-improver$' <<<"$FM_IMPROVE"
  [ "$output" -eq 1 ]
  # The skills bind these exact names; a typo'd agent: silently falls back to
  # general-purpose (no system prompt, no tool denial, no isolation).
  run grep -c '^agent: devagent:preship-verifier$' "$REPO/skills/core-preship/SKILL.md"
  [ "$output" -eq 1 ]
  run grep -c '^agent: devagent:redteam-reviewer$' "$REPO/skills/core-redmr/SKILL.md"
  [ "$output" -eq 1 ]
  run grep -c '^agent: devagent:plan-improver$' "$REPO/skills/core-improve/SKILL.md"
  [ "$output" -eq 1 ]
}

@test "all checker agents deny Write/Edit with the camelCase agent spelling (#458/#527)" {
  local fm
  for fm in "$FM_PRESHIP" "$FM_REDTEAM" "$FM_IMPROVE"; do
    run grep -c '^disallowedTools:' <<<"$fm"
    [ "$output" -eq 1 ] || { echo "no disallowedTools in: $fm" >&2; false; }
    grep -qE '^disallowedTools:.*\bWrite\b' <<<"$fm"
    grep -qE '^disallowedTools:.*\bEdit\b' <<<"$fm"
    # The hyphenated skill spelling here would be silently ignored — the exact
    # failure mode this issue exists to close.
    run grep -c '^disallowed-tools:' <<<"$fm"
    [ "$output" -eq 0 ] || { echo "uses the SKILL spelling (silently ignored on agents)" >&2; false; }
  done
}

@test "checker agents pin effort but MUST NOT pin model (#458 redmr BLOCKING)" {
  # Measured at 2.1.211: the Agent tool's model param is a closed enum
  # (sonnet|opus|haiku|fable) with NO inherit value, and omitting the param
  # resolves to "the agent definition's model, or inherits from the parent".
  # So a frontmatter model pin makes the #291 'inherit' escape (rc 2)
  # unreachable — the pinned model wins on every dispatch shape. The step
  # default therefore lives in the WRAPPERS (rc-3 row); the agents stay
  # unpinned so the rc-2 skill-fork genuinely inherits the session model
  # (transcript-verified: unpinned fork ran the main chain's model).
  local fm
  for fm in "$FM_PRESHIP" "$FM_REDTEAM" "$FM_IMPROVE"; do
    grep -qE '^effort:[[:space:]]+(low|medium|high|xhigh|max)$' <<<"$fm"
    run grep -c '^model:' <<<"$fm"
    [ "$output" -eq 0 ] || { echo "agent pins a model — rc 2 becomes unreachable" >&2; false; }
  done
}

@test "preship-verifier names all five verifications (#458)" {
  grep -qi 'acceptance criteria' "$PRESHIP"
  grep -qi 'findings applied' "$PRESHIP"
  grep -qi 'push preview' "$PRESHIP"
  grep -qi 'evidence cross-check' "$PRESHIP"
  grep -qi 'spec-touch' "$PRESHIP"
}

@test "redteam-reviewer carries the severity taxonomy and template precedence (#458)" {
  local t
  for t in '[BLOCKING]' '[MAJOR]' '[MINOR]' '[INFO]'; do
    grep -qF "$t" "$REDTEAM" || { echo "missing severity tag: $t" >&2; false; }
  done
  # §12 registry stays authoritative for WHAT to attack; this file owns OUTPUT.
  grep -qF 'redteam_mr' "$REDTEAM"
  grep -qi 'authority for WHAT to attack' "$REDTEAM"
  # The statusreport-parsed count line is contract.
  grep -qF 'B blocking, M major, m minor, I info' "$REDTEAM"
}

@test "plan-improver names the three categories, the pothole tripwire, and self-resolves the register (#527)" {
  # The procedure moved skill→agent; these content pins moved with it. The
  # register self-resolution is AC4's mechanism: the #286 tripwire's input is
  # no longer a dispatch-packaging line that can silently rot (dead-tripwire
  # class) — the agent resolves `potholes` via the §12 walk itself.
  grep -qi 'bug' "$IMPROVE"
  grep -qi 'side effect' "$IMPROVE"
  grep -qi 'ambiguit' "$IMPROVE"
  grep -qi 'Pothole register tripwire' "$IMPROVE"
  grep -qF 'show potholes' "$IMPROVE"
  grep -qF 'template.sh' "$IMPROVE"
  # Findings return UNTAGGED — [merge]/[defer]/[dismiss] triage is the main
  # session's judgment, and the count line matches the wrapper's log format.
  grep -qF 'B bugs, S side-effects, A ambiguities' "$IMPROVE"
}

@test "all checker agents return the artifact instead of writing it (#458/#527)" {
  local f
  for f in "$PRESHIP" "$REDTEAM" "$IMPROVE"; do
    grep -qi 'cannot write files' "$f"
    grep -qi 'final message' "$f"
    # context: subagent is the linter's required token; a fork must never stamp
    # 'context: fork' into an artifact header.
    grep -qF 'context: subagent' "$f"
    grep -qi 'never .*context: fork' "$f"
  done
}

@test "every disallowedTools agent carries the Bash-escape residual caveat (#529)" {
  # The caveat is a contract enumerated in N homes (#458 sweep pothole): derive
  # the subject set mechanically so a fourth agent cannot land without it, and
  # guard the subject COUNT so a file move cannot silently empty the sweep (#439).
  local subjects
  subjects="$(grep -rln 'disallowedTools' "$REPO/agents")"
  run grep -c . <<<"$subjects"
  [ "$output" -ge 3 ]
  local f header
  while IFS= read -r f; do
    # Scope to the header slice (frontmatter + intro, above ## Operating rules):
    # the caveat is a HEADER contract, so presence buried elsewhere must not
    # pass (redmr minor). A file lacking the heading degrades to a whole-file
    # check — superset-safe for a future agent with a different layout.
    header="$(sed -n '1,/^## Operating rules$/p' "$f")"
    grep -q 'tool-level isolation, not a filesystem sandbox' <<<"$header" \
      || { echo "missing residual caveat in header: $f" >&2; false; }
    grep -q '#529' <<<"$header" \
      || { echo "caveat lacks the adjudication pointer (#529): $f" >&2; false; }
  done <<<"$subjects"
}

@test "plan-improver no longer permits reading the plugin default as a fallback (#611)" {
  run grep -n 'read the plugin default directly' "$IMPROVE"
  [ "$status" -eq 1 ]
  grep -qi 'checking with less' "$IMPROVE"
  grep -qi 'once per layer' "$IMPROVE"
}

# ---- #1097: rule 1a, an acceptance criterion that a required CI check meets -----------
# agents/preship-verifier.md is a doc an agent EXECUTES (register Issue-461/583). The
# first test pins the tokens the rule turns on, each in the script's own spelling; the
# second runs every call the rule publishes and holds those tokens to what the script
# prints. Both read rule 1a's own text, so a call or a token that leaves the rule fails.

PD_BARE='bash "${CLAUDE_PLUGIN_ROOT}/scripts/preship-deferred.sh" <project> <Issue-N>'

# _rule_1a - rule 1a as the file's lines: from its title to verification 2's.
_rule_1a() { awk '/^ +[*][*]1a[.] /{f=1} /^2[.] [*][*]/{f=0} f' "$PRESHIP"; }
# _rule_1a_flat - the same, whitespace-normalised: the prose wraps mid-phrase.
_rule_1a_flat() { _rule_1a | tr -s '[:space:]' ' '; }
# _n_of <ERE> - the number of the first line of the verifier prompt matching it.
_n_of() { local n; n="$(grep -nE -m1 -- "$1" "$PRESHIP" | cut -d: -f1)"; [ -n "$n" ] || { echo "no line matches: $1" >&2; return 1; }; echo "$n"; }

@test "#1097 preship-verifier carries rule 1a" {
  local t p v1 at v2
  t="$(_rule_1a_flat)"
  [ -n "$t" ] || { echo "no rule 1a in $PRESHIP" >&2; return 1; }
  # under verification 1: after its title and before verification 2's
  v1="$(_n_of '^1[.] [*][*]Acceptance criteria executed')"
  at="$(_n_of '^ +[*][*]1a[.] ')"
  v2="$(_n_of '^2[.] [*][*]Findings applied')"
  [ "$v1" -lt "$at" ]
  [ "$at" -lt "$v2" ]
  for p in 'scripts/preship-deferred.sh' \
           '`deferred to CI at merge: <check>`' \
           '`self-certification warning:`' \
           '`required checks: (none)`' \
           '`code backend:`' '`mr-checks: no`' \
           "\`transcript '<test file>'\`" \
           '`issue.md`' '`imPlan.md`' \
           'not N/A' 'could not run' 'verified as worded'; do
    [[ "$t" == *"$p"* ]] || { echo "rule 1a lacks: $p" >&2; return 1; }
  done
  # the exits the script has, each with its verdict (devagent Issue-713: a new exit code)
  [[ "$t" == *'Exit 0: PASS'* ]]
  [[ "$t" == *'Exit 1: FAIL'* ]]
  [[ "$t" == *'Any other exit'*'FAIL'* ]]
  # still five verifications: 1a is a rule of the first, not a sixth
  run grep -cE '^[0-9]+[.] [*][*]' <(awk '/^## The five verifications$/{f=1} /^## Return contract$/{f=0} f' "$PRESHIP")
  [ "$output" -eq 5 ]
}

@test "#1097 every preship-deferred.sh call in the agent prompt runs with its placeholders filled" {
  # Register Issue-106: running a VARIANT of a published command is not running it. Each
  # call is read from the rule, its placeholders filled, and run as one line.
  local t line span cmd sub cfg st base pin tx i
  local -a calls=()
  t="$(_rule_1a_flat)"
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ "$line" = "$PD_BARE" ] || { echo "not the one-line form the tool grant covers: $line" >&2; return 1; }
    calls+=("$line")
  done < <(_rule_1a | grep -F 'preship-deferred.sh')
  [ "${#calls[@]}" -eq 1 ] || { echo "rule 1a publishes ${#calls[@]} preship-deferred.sh lines, not 1" >&2; return 1; }
  [ "$(grep -cF 'preship-deferred.sh' "$PRESHIP")" -eq 1 ]             # and the prompt none elsewhere
  # a subcommand form is a code span of the rule; it is added to the bare call
  while IFS= read -r span; do
    calls+=("$PD_BARE $span")
  done < <(grep -oE '`(static|transcript) [^`]+`' <<<"$t" | tr -d '`')
  for sub in static transcript; do                                      # every form of the script's usage
    grep -qF "$sub <" <(grep -m1 '^usage=' "$REPO/scripts/preship-deferred.sh")
    [[ " ${calls[*]} " == *"<Issue-N> $sub '"* ]] || { echo "rule 1a publishes no $sub call" >&2; return 1; }
  done

  # the fixture: a project that requires "Zeta check"; the branch adds a tagged test
  # file and a workflow file; that commit is the pinned head; a transcript is at it
  devagent_test_setup
  cfg="$HOME/.claude/devagent/config.toml"; st="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
  awk -v h="[project.$TEST_PROJECT]" '{print} $0 == h {print "required_checks = [\"Zeta check\"]"}' "$cfg" > "$cfg.new"
  mv "$cfg.new" "$cfg"
  run bash "$REPO/scripts/required-checks.sh" "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ "$output" = "Zeta check" ]                                          # the key took (register Issue-106)
  base="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
  mkdir -p "$SOURCE_DIR/tests" "$SOURCE_DIR/.github/workflows"
  cp "$REPO/tests/fixtures/preship-deferred/guards.bats" "$SOURCE_DIR/tests/guards.bats"
  echo 'name: ci' > "$SOURCE_DIR/.github/workflows/ci.yml"
  git -C "$SOURCE_DIR" add -A
  git -C "$SOURCE_DIR" commit -q -m head
  pin="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
  devagent_state_set "$st" baseline_sha "$base"
  devagent_state_set "$st" preship_pin_head "$pin"
  tx="2026-11-20-gitbash-guards-${pin:0:7}.txt"
  mkdir -p "$DEVDOC_DIR/Issue-1/evidence"
  printf '%s\n' "$pin" 'MINGW64_NT-10.0-26100 runner 3.5.4 x86_64 Msys' > "$DEVDOC_DIR/Issue-1/evidence/$tx"

  cd "$SOURCE_DIR"
  export CLAUDE_PLUGIN_ROOT="$REPO"
  for i in "${!calls[@]}"; do
    cmd="${calls[$i]}"
    cmd="${cmd//<project>/$TEST_PROJECT}"; cmd="${cmd//<Issue-N>/Issue-1}"
    cmd="${cmd//<check>/Zeta check}"; cmd="${cmd//<test file>/tests/guards.bats}"; cmd="${cmd//<test name>/pass: or-skip}"
    [[ "$cmd" != *'<'*'>'* ]] || { echo "a placeholder this test cannot fill: $cmd" >&2; return 1; }
    run --separate-stderr bash -c "$cmd"
    # shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`
    [ "$status" -eq 0 ] || { echo "rc $status from: $cmd"; echo "stdout: $output"; echo "stderr: $stderr"; return 1; }
    # one `&&` chain per arm: inside `case ... ||` only an arm's last status counts
    case "$cmd" in
      *" static "*)     [ "$output" = "deferred to CI at merge: Zeta check" ] ;;
      *" transcript "*) [ "$output" = "transcript accepted: evidence/$tx is at the pinned head $pin" ] ;;
      *)                [ "${#lines[@]}" -eq 3 ] \
                          && [ "${lines[0]}" = "required checks: Zeta check" ] \
                          && [ "${lines[1]}" = "code backend: github (mr-checks: yes)" ] \
                          && [[ "${lines[2]}" == "self-certification warning: .github/workflows/ci.yml changed in ${base:0:7}..${pin:0:7}; "* ]] ;;
    esac || { echo "unexpected output from: $cmd"; echo "stdout: $output"; return 1; }
  done

  # a check that fails is exit 1 with its one line, never the usage exit 2
  rm -f "$DEVDOC_DIR/Issue-1/evidence/$tx"
  for cmd in "${calls[@]}"; do
    [[ "$cmd" == *" transcript "* ]] || continue
    cmd="${cmd//<project>/$TEST_PROJECT}"; cmd="${cmd//<Issue-N>/Issue-1}"; cmd="${cmd//<test file>/tests/guards.bats}"
    run --separate-stderr bash -c "$cmd"
    [ "$status" -eq 1 ] || { echo "rc $status from: $cmd"; return 1; }
    [[ "$output" == "transcript check failed: no evidence/"* ]]
  done
  # and the capability line the rule's transcript gate reads is the script's own spelling
  devagent_config_set "$cfg" "project.$TEST_PROJECT.code_source.backend" local
  run --separate-stderr bash -c "${PD_BARE/<project> <Issue-N>/$TEST_PROJECT Issue-1}"
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "code backend: local (mr-checks: no)" ]
  [[ "$t" == *'`mr-checks: no`'* ]]
}

@test "#1097 rule 1a reads the accepted transcript for the named test's ok line" {
  local t
  t="$(awk '/\*\*1a\./{f=1} /^2\. \*\*Findings/{f=0} f' "$BATS_TEST_DIRNAME/../agents/preship-verifier.md" | tr '\n' ' ' | tr -s ' ')"
  [[ "$t" == *"transcript '<test file>'"*'On exit 0, read the transcript the printed line names'* ]] || { echo "no read of the accepted transcript"; return 1; }
  [[ "$t" == *'`ok` line'* ]] || { echo "no ok line quoted"; return 1; }
  [[ "$t" == *'`not ok`'*'`# skip`'*'FAIL'* ]] || { echo "not ok / skip / absent is not FAIL"; return 1; }
}
