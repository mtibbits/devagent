#!/usr/bin/env bats
# #714 Task 6: pull and quarantine — the pre-fetch guard (exit 7), the
# pre-work quarantine (exit 6), the read-back, and release by a trusted
# approver (pre-work: an ordinary first pull; in-work: context restored).

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'lib/bats-helpers'
load 'lib/trust-fixture'
load 'lib/quarantine-fixture'

setup() {
  qf_project
  STATE="$DA_HOME/state/wid.toml"
  PULL="$PLUGIN_ROOT/scripts/pull.sh"
  unset DEVAGENT_TEST_QUARANTINE
}

teardown() { teardown_tmp_devagent_home; }

_sha() { sha256sum "$1" | cut -d' ' -f1; }

# _seq: the call log as verbs, the gh-stub's issue view read as `fetch`.
_seq() {
  sed -E 's/^\[issue\] \[view\].*/fetch/' "$QB_DIR/calls" | cut -d' ' -f1 | tr '\n' ' '
}

# _mark <dir> <time> <seq>: a marker as an earlier quarantine wrote it.
_mark() {
  mkdir -p "$1"
  printf 'devagent-quarantine 1\nkey github:github.com/acme/widgets#%s\nreason screen\nevent %s %s\n' \
    "${1##*-}" "$2" "$3" > "$1/QUARANTINE"
}

# _guard: an entry point in miniature (trust check, then the guard), as
# next.sh will be once Task 7 wires it.
_guard() {
  run --separate-stderr bash -c '
    set -euo pipefail
    for l in paths io config state active trust quarantine; do source "$PLUGIN_ROOT/scripts/lib/$l.sh"; done
    trust_entry_check "next" wid
    quarantine_guard "next" wid
    echo PROCEED'
}

@test "pull AC1: pre-work → only QUARANTINE on disk, rc 6, state sha unchanged, stub call log exactly: whoami, state-exists, events, fetch, transition, events" {
  qf_policy separate 'test_seams = true'
  local st
  st="$(_sha "$STATE")"
  DEVAGENT_TEST_QUARANTINE=screen run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [ "$(ls -A "$DEVDOC/Issue-9")" = QUARANTINE ]
  [ "$(_sha "$STATE")" = "$st" ]
  [ "$(_seq)" = "whoami state-exists events fetch transition events " ]
  [ "$(sed -n 2,4p "$DEVDOC/Issue-9/QUARANTINE")" = "key github:github.com/acme/widgets#9
reason screen
event 2026-11-02T10:00:00Z 1" ]
  [ "$output" = "" ]
  [ "$stderr" = "$(bash -c 'source "$PLUGIN_ROOT/scripts/lib/refusals.sh"; quarantine_message github:github.com/acme/widgets#9')" ]
}

@test "pull AC1: no sentinel in marker, stdout or stderr" {
  qf_policy separate 'test_seams = true'
  export GH_STUB_BODY_JSON='"SENTINEL-TITLE-7f3a\n\nSENTINEL-BODY-9c1e"'
  export GH_STUB_COMMENTS_JSON='[{"author":{"login":"SENTINEL-TITLE-7f3a"},"body":"SENTINEL-BODY-9c1e","createdAt":"2026-05-12T00:00:00Z"}]'
  DEVAGENT_TEST_QUARANTINE=screen run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ]
  [[ "$output$stderr" != *SENTINEL* ]]
  run grep -rl SENTINEL "$DEVDOC" "$DA_HOME"
  [ "$status" -eq 1 ]
}

@test "pull AC2: deleted marker → recreated" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  rm -f "$DEVDOC/Issue-7/QUARANTINE"
  run --separate-stderr "$PULL" wid origin 7
  [ "$status" -eq 7 ]
  [ "$(sed -n 3,4p "$DEVDOC/Issue-7/QUARANTINE")" = "reason tracker
event 2026-11-02T10:00:00Z 5" ]
  run grep -c '^\[issue\] \[view\]' "$QB_DIR/calls"
  [ "$output" = 0 ]
}

@test "pull AC2: deleted dir → only the marker" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  rm -rf "$DEVDOC/Issue-7"
  run --separate-stderr "$PULL" wid origin 7
  [ "$status" -eq 7 ]
  [ "$(ls -A "$DEVDOC/Issue-7")" = QUARANTINE ]
}

@test "pull AC2: fresh DA_HOME, same user policy → marker created" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  local cfg
  cfg="$(cat "$DA_HOME/config.toml")"
  teardown_tmp_devagent_home
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devDoc2/wid"
  printf '%s\n' "$cfg" | sed "s|$BATS_TEST_TMPDIR/devDoc/wid|$DEVDOC|" > "$DA_HOME/config.toml"
  run --separate-stderr "$PULL" wid origin 7
  [ "$status" -eq 7 ]
  [ "$(ls -A "$DEVDOC/Issue-7")" = QUARANTINE ]
  [ ! -e "$DA_HOME/state/wid.toml" ] || ! grep -q Issue-7 "$DA_HOME/state/wid.toml"
}

@test "pull AC2: trust off + marker → no backend call" {
  _mark "$DEVDOC/Issue-7" 2026-11-02T10:00:00Z 5
  run --separate-stderr "$PULL" wid origin 7
  [ "$status" -eq 7 ]
  [ ! -s "$QB_DIR/calls" ]
  [[ "$stderr" == "QUARANTINED: github:github.com/acme/widgets#7 is held for human review."* ]]
}

@test "pull AC3: removal by worker 1001 (separate) → one re-apply, rc 7" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 2002 user labeled
  qf_ev 2026-11-02T11:00:00Z 6 1001 user unlabeled
  echo 6 > "$QB_DIR/seq"
  echo 2026-11-02T12:00:00Z > "$QB_DIR/clock"
  _mark "$DEVDOC/Issue-7" 2026-11-02T10:00:00Z 5
  run --separate-stderr "$PULL" wid origin 7
  [ "$status" -eq 7 ]
  [ "$(grep -c '^transition ' "$QB_DIR/calls")" -eq 1 ]
  [ "$(sed -n 4p "$DEVDOC/Issue-7/QUARANTINE")" = "event 2026-11-02T12:00:00Z 7" ]
}

@test "pull: read-back miss → event <write time> ?; next pull re-applies, rc 7" {
  qf_policy separate 'test_seams = true'
  touch "$QB_DIR/transition.silent"
  DEVAGENT_TEST_QUARANTINE=screen run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ]
  [[ "$(sed -n 4p "$DEVDOC/Issue-9/QUARANTINE")" =~ ^event\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ \?$ ]]
  rm -f "$QB_DIR/transition.silent"
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 7 ]
  [ "$(grep -c '^transition ' "$QB_DIR/calls")" -eq 2 ]
  [ "$(sed -n 3,4p "$DEVDOC/Issue-9/QUARANTINE")" = "reason screen
event 2026-11-02T10:00:00Z 1" ]
}

@test "pull: a release after a missed read-back is honoured, not re-applied (final review #3)" {
  qf_policy separate 'test_seams = true'
  touch "$QB_DIR/transition.silent"
  DEVAGENT_TEST_QUARANTINE=screen run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ]
  # the write landed; the tracker shows it only now, then the approver's removal
  local now later
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  later="$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)"
  qf_ev "$now" 41 1001 user labeled
  qf_ev "$later" 42 2002 user unlabeled
  rm -f "$QB_DIR/transition.silent"
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 0 ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  [ "$(grep -c '^transition ' "$QB_DIR/calls")" -eq 1 ]
  [ ! -e "$DEVDOC/Issue-9/QUARANTINE" ]
}

@test "pull: a quarantine older than the write is not taken for it" {
  qf_policy separate 'test_seams = true'
  # an earlier quarantine, released long before this pull's write
  qf_ev 2026-01-01T10:00:00Z 3 1001 user labeled
  qf_ev 2026-01-01T11:00:00Z 4 2002 user unlabeled
  touch "$QB_DIR/transition.silent"
  DEVAGENT_TEST_QUARANTINE=screen run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ]
  rm -f "$QB_DIR/transition.silent"
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 7 ]
  [ "$(grep -c '^transition ' "$QB_DIR/calls")" -eq 2 ]
}

@test "pull: label missing → rc 9, nothing written" {
  qf_policy separate
  echo 4 > "$QB_DIR/label.rc"
  local st
  st="$(_sha "$STATE")"
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 9 ]
  [[ "$stderr" == *"the quarantine label devagent:quarantine is not on acme/widgets"* ]]
  [ ! -e "$DEVDOC/Issue-9" ]
  [ "$(_sha "$STATE")" = "$st" ]
}

@test "pull: approver release, pre-work → marker gone, checklist scaffolded, rc 0" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  qf_ev 2026-11-02T11:00:00Z 9 2002 user unlabeled
  _mark "$DEVDOC/Issue-9" 2026-11-02T10:00:00Z 5
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [ ! -e "$DEVDOC/Issue-9/QUARANTINE" ]
  [ -f "$DEVDOC/Issue-9/checklist.md" ]
  grep -qE '^active_issue *= *"Issue-9"' "$STATE"
}

@test "pull AC in-work release: same row, [context.Issue-7] restored, not parked" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  local rows
  rows="$(grep '^- \[' "$DEVDOC/Issue-7/checklist.md")"
  _guard
  [ "$status" -eq 11 ]
  run grep -E '^active_issue *=' "$STATE"
  [ "$status" -eq 1 ]
  qf_ev 2026-11-02T11:00:00Z 9 2002 user unlabeled
  run --separate-stderr "$PULL" wid origin 7
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [ ! -e "$DEVDOC/Issue-7/QUARANTINE" ]
  grep -qE '^active_issue *= *"Issue-7"' "$STATE"
  grep -qE '^branch *= *"feat/7-widgets"' "$STATE"
  run grep -E '^\[context\.Issue-7\]' "$STATE"
  [ "$status" -eq 1 ]
  run grep -E '^Issue-7 *=' "$STATE"
  [ "$status" -eq 1 ]
  grep -qE '^Issue-8 *= *true' "$STATE"
  [ "$(grep '^- \[' "$DEVDOC/Issue-7/checklist.md")" = "$rows" ]
}

@test "pull: re-entry end to end — held: guard rc 11; approver removes the label; pull rc 0 (release branch); guard proceeds" {
  qf_policy separate 'test_seams = true'
  DEVAGENT_TEST_QUARANTINE=screen run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ]
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 7 ]
  qf_ev 2026-11-02T11:00:00Z 9 2002 user unlabeled
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  grep -qE '^active_issue *= *"Issue-9"' "$STATE"
  _guard
  [ "$status" -eq 0 ]
  [ "$output" = PROCEED ]
}

@test "pull: test seam ignored without test_seams and with trust off" {
  qf_policy separate
  DEVAGENT_TEST_QUARANTINE=screen run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [ ! -e "$DEVDOC/Issue-9/QUARANTINE" ]
  rm -rf "$HOME/.config/devagent/trust" "$DEVDOC/Issue-9"
  DEVAGENT_TEST_QUARANTINE=screen run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 0 ]
  [ ! -e "$DEVDOC/Issue-9/QUARANTINE" ]
}

@test "pull: a seam token outside QUARANTINE_REASONS is ignored" {
  qf_policy separate 'test_seams = true'
  DEVAGENT_TEST_QUARANTINE=bogus run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [ ! -e "$DEVDOC/Issue-9/QUARANTINE" ]
}
