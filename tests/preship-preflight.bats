#!/usr/bin/env bats
# bats file_tags=gitbash
# #1122 scripts/preship-preflight.sh — the preship preflight's evidence stop, claims runs,
# prior-decision lookup and log spellings, as ONE script under the plugin's allowed-tools
# grant (the recipes it replaces were compound shell, outside the grant: review finding 1).
# The script runs from a copy of the real scripts/ tree; only preship-evidence.sh,
# claims-check.sh, run-suite.sh and evidence-stamp.sh are stubbed, so checklist-log.sh,
# checklist-stuck.sh and log_append are the REAL ones (review finding 2's test gap).
load 'lib/bats-helpers'
bats_require_minimum_version 1.5.0

setup() {
  setup_tmp_devagent_home
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
  ISSUE_DIR="$DA_HOME/devdoc/Issue-7"
  mkdir -p "$ISSUE_DIR/analysis"
  checklist_init "$ISSUE_DIR" standard
  ROOT="$BATS_TEST_TMPDIR/root"; mkdir -p "$ROOT"
  cp -r "$PLUGIN_ROOT/scripts" "$ROOT/"
  SENT="$BATS_TEST_TMPDIR/sentinel"
  # Stubs: the checkers print $STUB_ERR / $STUB_OUT and exit $STUB_RC; the suite runners touch the sentinel.
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "${STUB_OUT-}"' 'printf "%s" "${STUB_ERR-}" >&2' 'exit "${STUB_RC:-0}"' \
    > "$ROOT/scripts/preship-evidence.sh"
  cp "$ROOT/scripts/preship-evidence.sh" "$ROOT/scripts/claims-check.sh"
  printf '%s\n' '#!/usr/bin/env bash' "touch '$SENT'" > "$ROOT/scripts/run-suite.sh"
  cp "$ROOT/scripts/run-suite.sh" "$ROOT/scripts/evidence-stamp.sh"
  chmod +x "$ROOT"/scripts/*.sh
  export TMPDIR="$BATS_TEST_TMPDIR"
  printf '# Title\n- `tests/x.bats` (26 tests)\n## Evidence\nsuite: 1/1 bats @ %040d\n' 0 > "$ISSUE_DIR/mr.md"
}
teardown() { teardown_tmp_devagent_home; }

# _pf <subcommand> [args...] - the real script, from the copied tree.
_pf() { local sub="$1"; shift; run --separate-stderr bash "$ROOT/scripts/preship-preflight.sh" "$sub" fake Issue-7 "$ISSUE_DIR" "$@"; }
_log() { awk '/^## Log/{f=1; next} /^## /{f=0} f' "$ISSUE_DIR/checklist.md"; }
# _lastlog - the last log entry's message (after "  preship: ").
_lastlog() { _log | grep -F '  preship: ' | tail -n 1 | sed 's/^- [0-9-]* [0-9:]*  preship: //'; }
HOSTILE='  - Evidence suite line mismatch — write it with `bash "$CLAUDE_PLUGIN_ROOT/scripts/evidence-stamp.sh" fake Issue-7` and don'"'"'t; $(touch SENTINEL) C:\Users\me \n## Revision 2'

@test "evidence: exits 0, 4, 9, 10 and 11 pass through and stop nothing" {
  local rc
  for rc in 0 4 9 10 11; do
    STUB_RC="$rc" STUB_ERR=$'preship-evidence: FAIL\n  - TREE UNATTESTED — x\n' _pf evidence
    [ "$status" -eq "$rc" ] || { echo "rc $rc → $status"; return 1; }
    [[ "$output" == *"evidence rc=$rc"* ]]
    [ ! -e "$ISSUE_DIR/STUCK" ]
  done
}

# shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr` (bats idiom)
@test "evidence: any other exit stops the step [!] with the first failure line, byte-equal and shell-safe" {
  local err="preship-evidence: FAIL"$'\n'"${HOSTILE//SENTINEL/$SENT}"$'\n''  - dirty: yes'$'\n'
  local first="${HOSTILE//SENTINEL/$SENT}"; first="${first#  - }"
  STUB_RC=1 STUB_ERR="$err" _pf evidence
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"preship-evidence: FAIL"* ]]                          # the checker's stderr is shown
  grep -qF -- "preship: evidence preflight: $first (+1 more)" "$ISSUE_DIR/STUCK"
  grep -q '^- \[!\]' "$ISSUE_DIR/checklist.md"
  [ ! -e "$SENT" ]
  run grep -c '^## Revision 2' "$ISSUE_DIR/checklist.md"; [ "$output" -eq 0 ]
  STUB_RC=1 STUB_ERR='' _pf evidence                                      # no stderr at all
  [ "$status" -eq 1 ]
  grep -qF 'preship: evidence preflight: (no stderr)' "$ISSUE_DIR/STUCK"
}

@test "evidence: an older preship.md moves to analysis/<date>-<HHMMSS>-preship-superseded.md and is logged" {
  echo 'old verdict: PASS' > "$ISSUE_DIR/preship.md"
  DEVAGENT_DATE_OVERRIDE=2026-07-09 STUB_RC=1 STUB_ERR=$'preship-evidence: FAIL\n  - x\n' _pf evidence
  [ "$status" -eq 1 ]
  [ ! -e "$ISSUE_DIR/preship.md" ]
  local moved; moved="$(cd "$ISSUE_DIR" && ls analysis/*-preship-superseded.md)"
  [[ "$moved" =~ ^analysis/2026-07-09-[0-9]{6}-preship-superseded\.md$ ]]   # date_tag's #338 freeze
  [ "$(cat "$ISSUE_DIR/$moved")" = 'old verdict: PASS' ]
  _log | grep -qF "preship: preflight: moved preship.md to $moved"
  echo 'kept' > "$ISSUE_DIR/preship.md"
  STUB_RC=4 _pf evidence                                                  # a passing check moves nothing
  [ -e "$ISSUE_DIR/preship.md" ]
}

@test "claims: output and exit pass through; a fourth run is refused; evidence starts a fresh count" {
  STUB_RC=0 _pf evidence
  local i
  for i in 1 2 3; do
    STUB_RC=3 STUB_OUT=$'mr.md:2: MISMATCH bats-count: x — claimed 26, found 27 (at HEAD)\nclaims-check: checked 1 (…); 1 mismatched; 0 not checked\n' _pf claims
    [ "$status" -eq 3 ]
    [[ "$output" == *"mr.md:2: MISMATCH bats-count:"* ]]
    [[ "$output" == *"claims run $i of 3, rc=3"* ]]
  done
  STUB_RC=0 _pf claims
  [ "$status" -eq 2 ]; [[ "$stderr" == *"at most three runs"* ]]
  STUB_RC=0 _pf evidence
  STUB_RC=0 _pf claims
  [ "$status" -eq 0 ]; [[ "$output" == *"claims run 1 of 3, rc=0"* ]]
}

@test "save + log corrected and named-commit: old -> new, byte-equal, through the real checklist-log.sh" {
  local line='- `tests/x.bats` (26 tests) $(touch '"$SENT"') "dq" '"'"'sq'"'"' C:\Users\me \n## Revision 2'
  printf '# Title\n%s\n' "$line" > "$ISSUE_DIR/mr.md"
  _pf save 2
  [ "$status" -eq 0 ]
  printf '# Title\n%s\n' '- `tests/x.bats` (27 tests)' > "$ISSUE_DIR/mr.md"
  _pf log corrected 2
  [ "$status" -eq 0 ]
  [ "$(_lastlog)" = "claims: mr.md:2 corrected: '$line' -> '- \`tests/x.bats\` (27 tests)'" ]
  _pf log named-commit 2
  [ "$(_lastlog)" = "claims: mr.md:2 named commit: '$line' -> '- \`tests/x.bats\` (27 tests)'" ]
  [ ! -e "$SENT" ]
  run grep -c '^## Revision 2' "$ISSUE_DIR/checklist.md"; [ "$output" -eq 0 ]
  _pf log corrected 3                                                     # nothing saved for line 3
  [ "$status" -eq 2 ]; [[ "$stderr" == *"save 3"* ]]
}

@test "log left-as-written: the reason from stdin, verbatim; an empty reason is refused" {
  local why='an earlier run; see $(touch '"$SENT"') and `id` "x" '"'"'y'"'"' C:\tmp'
  run --separate-stderr bash -c 'bash "$1" log fake Issue-7 "$2" left-as-written 2 <<<"$3"' _ "$ROOT/scripts/preship-preflight.sh" "$ISSUE_DIR" "$why"
  [ "$status" -eq 0 ]
  [ "$(_lastlog)" = "claims: mr.md:2 left as written: '- \`tests/x.bats\` (26 tests)' — $why" ]
  [ ! -e "$SENT" ]
  run --separate-stderr bash -c 'bash "$1" log fake Issue-7 "$2" left-as-written 2 </dev/null' _ "$ROOT/scripts/preship-preflight.sh" "$ISSUE_DIR"
  [ "$status" -eq 2 ]; [[ "$stderr" == *"reason"* ]]
}

@test "log unresolved: the run number; a 300-character line is cut to 200 plus …" {
  local long; printf -v long '%0300d' 0
  printf '# Title\n%s\n' "$long" > "$ISSUE_DIR/mr.md"
  STUB_RC=0 _pf evidence; STUB_RC=3 _pf claims; STUB_RC=3 _pf claims
  _pf log unresolved 2
  [ "$status" -eq 0 ]
  [ "$(_lastlog)" = "claims: mr.md:2 unresolved after run 2: '${long:0:200}…'" ]
}

@test "log could-not-run: the first stderr line, hostile; log preflight: the summary line, or (none)" {
  local bad='claims-check: COULD NOT RUN — no mr.md at `$(touch '"$SENT"')` C:\x'
  local sum='claims-check: checked 2 (bats-count 1, pytest-count 0, suite-total 0, commit-count 0, files-count 0, cited-commit 0, signoff 1); 0 mismatched; 0 not checked'
  STUB_RC=4 _pf evidence
  STUB_RC=1 STUB_ERR="$bad"$'\nmore\n' _pf claims
  [ "$status" -eq 1 ]
  _pf log could-not-run
  [ "$(_lastlog)" = "claims: could not run (exit 1): $bad; verifier dispatched" ]
  STUB_RC=0 STUB_OUT="$sum"$'\n' _pf claims
  _pf log preflight
  [ "$status" -eq 0 ]
  [ "$(_lastlog)" = "preflight: evidence exit 4; claims runs 2, last exit 0; $sum" ]
  [ ! -e "$SENT" ]
  STUB_RC=0 _pf evidence
  _pf log preflight                                                       # no claims run yet
  [ "$(_lastlog)" = "preflight: evidence exit 0; claims runs 0, last exit (none); (none)" ]
}

@test "prior <L>: 0 when that exact text was left as written, 1 otherwise" {
  _pf prior 2
  [ "$status" -eq 1 ]; [[ "$output" == *"no prior decision"* ]]
  run bash -c 'bash "$1" log fake Issue-7 "$2" left-as-written 2 <<<"kept: an earlier run"' _ "$ROOT/scripts/preship-preflight.sh" "$ISSUE_DIR"
  _pf prior 2
  [ "$status" -eq 0 ]; [[ "$output" == *"left as written"* ]]
  printf '# Title\n%s\n' '- `tests/x.bats` (25 tests)' > "$ISSUE_DIR/mr.md"   # the line changed since
  _pf prior 2
  [ "$status" -eq 1 ]
}

@test "usage: unknown subcommand, a non-numeric line, or an issue dir that is not <Issue-N> → 2" {
  _pf bogus
  [ "$status" -eq 2 ]; [[ "$stderr" == *"usage: preship-preflight.sh"* ]]
  _pf save 2x
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$ROOT/scripts/preship-preflight.sh" evidence fake Issue-8 "$ISSUE_DIR"
  [ "$status" -eq 2 ]; [[ "$stderr" == *"Issue-8"* ]]
  _pf log bogus 2
  [ "$status" -eq 2 ]
  _pf save 2                                                              # the survivor
  [ "$status" -eq 0 ]
}

@test "the preflight never runs run-suite.sh or evidence-stamp.sh" {
  STUB_RC=1 STUB_ERR="${HOSTILE//SENTINEL/$SENT}" _pf evidence
  STUB_RC=3 _pf claims
  _pf log preflight
  [ ! -e "$SENT" ]
  run bash -c "grep -v '^[[:space:]]*#' '$PLUGIN_ROOT/scripts/preship-preflight.sh' | grep -cE 'run-suite\.sh|evidence-stamp\.sh'"
  [ "$output" -eq 0 ]                                                     # code lines only; the header names them to forbid them
}

@test "log takes its kind after 'log' too: the order two of three eval subjects wrote" {
  _pf save 2
  run --separate-stderr bash "$ROOT/scripts/preship-preflight.sh" log corrected fake Issue-7 "$ISSUE_DIR" 2
  [ "$status" -eq 0 ]
  [ "$(_lastlog)" = "claims: mr.md:2 corrected: '- \`tests/x.bats\` (26 tests)' -> '- \`tests/x.bats\` (26 tests)'" ]
  run --separate-stderr bash "$ROOT/scripts/preship-preflight.sh" log preflight fake Issue-7 "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  [[ "$(_lastlog)" == "preflight: evidence exit (none);"* ]]
}
