#!/usr/bin/env bats
# #714 Task 5: quarantine_guard, the refusing guard every entry point calls on
# the line after trust_entry_check. Trust off it reads the marker alone; in
# scope it reads the tracker (one `events` read through the backend seam).

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'lib/bats-helpers'
load 'lib/trust-fixture'
load 'lib/quarantine-fixture'

KEY="github:github.com/acme/widgets#7"

setup() {
  qf_project
  D="$DEVDOC/Issue-7"
  STATE="$DA_HOME/state/wid.toml"
}

teardown() { teardown_tmp_devagent_home; }

# _drive [<issue-arg>]: an entry point in miniature — trust_entry_check, then
# quarantine_guard on the next line, then PROCEED.
_drive() {
  run --separate-stderr bash -c '
    set -euo pipefail
    for l in paths io config state active trust quarantine; do source "$PLUGIN_ROOT/scripts/lib/$l.sh"; done
    trust_entry_check "drive" wid
    quarantine_guard "drive" wid "${1:-}"
    echo PROCEED' _ "$@"
}

_msg() { quarantine_message_text="$(bash -c 'source "$PLUGIN_ROOT/scripts/lib/refusals.sh"; quarantine_message "$1"' _ "$KEY")"; }

_sha() { sha256sum "$1" | cut -d' ' -f1; }

@test "guard: no policy, no marker → rc 0, silent, no backend call" {
  _drive
  [ "$status" -eq 0 ]
  [ "$output" = PROCEED ]
  [ "$stderr" = "" ]
  [ ! -s "$QB_DIR/calls" ]
}

@test "guard: marker, trust off → rc 11, stderr == message" {
  printf 'devagent-quarantine 1\nkey %s\nreason screen\nevent ? ?\n' "$KEY" > "$D/QUARANTINE"
  local st
  st="$(_sha "$STATE")"
  _msg
  _drive
  [ "$status" -eq 11 ]
  [ "$output" = "" ]
  [ "$stderr" = "$quarantine_message_text" ]
  [ ! -s "$QB_DIR/calls" ]
  [ "$(_sha "$STATE")" = "$st" ]
}

@test "guard: held, no marker → rc 11, marker reason tracker, slot cleared, parked list and glyphs unchanged" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 2002 user labeled
  local cl
  cl="$(_sha "$D/checklist.md")"
  _msg
  _drive
  [ "$status" -eq 11 ]
  [ "$stderr" = "$quarantine_message_text" ]
  [ "$(head -n 4 "$D/QUARANTINE")" = "devagent-quarantine 1
key $KEY
reason tracker
event 2026-11-02T10:00:00Z 5" ]
  [ "$(qf_calls | tr '\n' ' ')" = "whoami events " ]
  run grep -E '^(active_issue|issue_dir) *=' "$STATE"
  [ "$status" -eq 1 ]
  grep -qE '^Issue-8 *= *true' "$STATE"
  run grep -E '^Issue-7 *=' "$STATE"
  [ "$status" -eq 1 ]
  [ "$(_sha "$D/checklist.md")" = "$cl" ]
}

@test "guard: held, label absent → one transition call" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 2002 user labeled
  qf_ev 2026-11-02T11:00:00Z 9 1001 user unlabeled
  echo 9 > "$QB_DIR/seq"
  echo 2026-11-02T12:00:00Z > "$QB_DIR/clock"
  _drive
  [ "$status" -eq 11 ]
  [ "$(grep -c '^transition ' "$QB_DIR/calls")" -eq 1 ]
  grep -qxF 'transition acme/widgets 7 quarantine --project wid' "$QB_DIR/calls"
}

@test "guard: a re-apply invalidates the memo; the refreshed marker carries the new Q time and seq" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 2002 user labeled
  qf_ev 2026-11-02T11:00:00Z 9 1001 user unlabeled
  echo 9 > "$QB_DIR/seq"
  echo 2026-11-02T12:00:00Z > "$QB_DIR/clock"
  _drive
  [ "$status" -eq 11 ]
  [ "$(qf_calls | tr '\n' ' ')" = "whoami events transition events " ]
  [ "$(sed -n 4p "$D/QUARANTINE")" = "event 2026-11-02T12:00:00Z 10" ]
}

@test "guard: a failed re-apply only warns; the marker reads ? ?" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 2002 user labeled
  qf_ev 2026-11-02T11:00:00Z 9 1001 user unlabeled
  echo 1 > "$QB_DIR/transition.rc"
  _msg
  _drive
  [ "$status" -eq 11 ]
  [[ "$stderr" == *"quarantine label could not be re-applied"* ]]
  [[ "$stderr" == *"$quarantine_message_text" ]]
  [ "$(sed -n 4p "$D/QUARANTINE")" = "event ? ?" ]
}

@test "guard: events rc 75 → rc 10, or rc 11 with a marker" {
  qf_policy separate
  echo 75 > "$QB_DIR/events.rc"
  _drive
  [ "$status" -eq 10 ]
  [[ "$stderr" == *"events for acme/widgets#7 could not run (exit 75)"* ]]
  [ ! -e "$D/QUARANTINE" ]
  printf 'devagent-quarantine 1\nkey %s\nreason screen\nevent ? ?\n' "$KEY" > "$D/QUARANTINE"
  _msg
  _drive
  [ "$status" -eq 11 ]
  [ "$stderr" = "$quarantine_message_text" ]
}

@test "guard: a failed events read carries the backend's first stderr line, charset-reduced (a 404 is not silent)" {
  qf_policy separate
  echo 1 > "$QB_DIR/events.rc"
  printf 'gh: Not Found (HTTP 404) `$(x)` <b>\nsecond line\n' > "$QB_DIR/events.err"
  _drive
  [ "$status" -eq 10 ]
  [[ "$stderr" == *"events for acme/widgets#7 could not run (exit 1; gh: Not Found (HTTP 404) (x) b)"* ]]
  [[ "$stderr" != *"second line"* ]]
}

@test "guard: events rc 2 → rc 9" {
  qf_policy separate
  echo 2 > "$QB_DIR/events.rc"
  _drive
  [ "$status" -eq 9 ]
  [[ "$stderr" == *"the github backend has no events verb (exit 2)"* ]]
}

@test "guard: trusted-worker policy + marker → rc 9 (host first)" {
  # the loader refuses a worker that is also trusted, so whoami answers the
  # approver's id, as trust-entry.bats does.
  qf_policy separate
  printf 'devagent-quarantine 1\nkey %s\nreason screen\nevent ? ?\n' "$KEY" > "$D/QUARANTINE"
  QB_WHOAMI=2002 _drive
  [ "$status" -eq 9 ]
  [[ "$stderr" == *"account github:2002 is in trusted_approvers"* ]]
  [[ "$stderr" != *QUARANTINED* ]]
}

@test "guard: unset quarantine key → rc 9 quarantine-unmapped" {
  trust_fixture_policy "$HOME/.config/devagent/trust" 'scopes = ["github:github.com/acme/widgets"]' \
    'worker_identities = ["github:1001"]' 'trusted_approvers = ["github:2002"]'
  _drive
  [ "$status" -eq 9 ]
  [[ "$stderr" == *"the trust policy sets no quarantine label; a scope cannot run without one"* ]]
  [ "$(qf_calls | tr '\n' ' ')" = "whoami " ]
}

@test "guard: invalid DEVAGENT_ACTIVE_ISSUE → rc 0, silent" {
  printf 'devagent-quarantine 1\nkey %s\nreason screen\nevent ? ?\n' "$KEY" > "$D/QUARANTINE"
  DEVAGENT_ACTIVE_ISSUE='Issue.7' _drive
  [ "$status" -eq 0 ]
  [ "$output" = PROCEED ]
  [ "$stderr" = "" ]
}

@test "guard: released on tracker + marker + step mode → rc 11, no transition call" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  qf_ev 2026-11-02T11:00:00Z 9 2002 user unlabeled
  printf 'devagent-quarantine 1\nkey %s\nreason screen\nevent 2026-11-02T10:00:00Z 5\n' "$KEY" > "$D/QUARANTINE"
  _drive
  [ "$status" -eq 11 ]
  run grep -c '^transition ' "$QB_DIR/calls"
  [ "$output" = 0 ]
}

@test "guard: a marker that never read its record back re-applies even when the tracker reads released" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  qf_ev 2026-11-02T11:00:00Z 9 2002 user unlabeled
  echo 9 > "$QB_DIR/seq"
  echo 2026-11-02T12:00:00Z > "$QB_DIR/clock"
  printf 'devagent-quarantine 1\nkey %s\nreason screen\nevent ? ?\n' "$KEY" > "$D/QUARANTINE"
  _drive
  [ "$status" -eq 11 ]
  [ "$(grep -c '^transition ' "$QB_DIR/calls")" -eq 1 ]
  [ "$(sed -n 3,4p "$D/QUARANTINE")" = "reason screen
event 2026-11-02T12:00:00Z 10" ]
}

@test "guard: released on tracker, no marker → rc 0" {
  qf_policy separate
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  qf_ev 2026-11-02T11:00:00Z 9 2002 user unlabeled
  _drive
  [ "$status" -eq 0 ]
  [ "$output" = PROCEED ]
  [ ! -e "$D/QUARANTINE" ]
}

@test "guard: a non-issue token (a reason word, a free-form note) falls through to the active issue" {
  printf 'devagent-quarantine 1\nkey %s\nreason screen\nevent ? ?\n' "$KEY" > "$D/QUARANTINE"
  _drive round-2
  [ "$status" -eq 11 ]
  _drive "a reason"
  [ "$status" -eq 11 ]
}

@test "guard: an explicit issue arg is the issue checked, not the active one" {
  printf 'devagent-quarantine 1\nkey github:github.com/acme/widgets#8\nreason screen\nevent ? ?\n' > "$DEVDOC/Issue-8/QUARANTINE"
  _drive Issue-8
  [ "$status" -eq 11 ]
  [[ "$stderr" == "QUARANTINED: github:github.com/acme/widgets#8 is held"* ]]
  _drive
  [ "$status" -eq 0 ]
}

@test "guard_dir: a marked dir refuses with the same bytes as guard" {
  printf 'devagent-quarantine 1\nkey %s\nreason screen\nevent ? ?\n' "$KEY" > "$D/QUARANTINE"
  _msg
  run --separate-stderr bash -c '
    set -euo pipefail
    for l in paths io config state active trust quarantine; do source "$PLUGIN_ROOT/scripts/lib/$l.sh"; done
    trust_entry_check_devdoc "drive" "$1"
    quarantine_guard_dir "drive" "$2"
    echo PROCEED' _ "$DEVDOC" "$D"
  [ "$status" -eq 11 ]
  [ "$stderr" = "$quarantine_message_text" ]
}
