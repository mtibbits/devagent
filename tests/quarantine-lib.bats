#!/usr/bin/env bats
# #714 Task 3: scripts/lib/quarantine.sh — the marker codec (the local cache)
# and the events predicate (the tracker authority) over trust_grants.

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'lib/bats-helpers'
load 'lib/trust-fixture'
load 'lib/quarantine-fixture'

setup() {
  qf_project
  D="$DEVDOC/Issue-7"
}

teardown() { teardown_tmp_devagent_home; }

_lib() {
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
  source "$PLUGIN_ROOT/scripts/lib/state.sh"
  source "$PLUGIN_ROOT/scripts/lib/active.sh"
  source "$PLUGIN_ROOT/scripts/lib/trust.sh"
  source "$PLUGIN_ROOT/scripts/lib/quarantine.sh"
}

# _state <shape> [toml…]: load the policy of <shape>, then run quarantine_state
# over the stub's events for trusted_approvers.
_state() {
  qf_policy "$@"
  _lib
  trust_locate_host
  trust_load
  TRUST_WHOAMI=github:1001
  touch "$QB_DIR/events.tsv"
  run --separate-stderr quarantine_state "$QF_LABEL" trusted_approvers github < "$QB_DIR/events.tsv"
}

@test "marker: round-trip" {
  _lib
  run ! quarantine_marked "$D"
  quarantine_marker_write "$D" "github:github.com/acme/widgets#7" screen 2026-11-02T10:00:00Z 41
  quarantine_marked "$D"
  [ "$(head -n 4 "$D/QUARANTINE")" = "devagent-quarantine 1
key github:github.com/acme/widgets#7
reason screen
event 2026-11-02T10:00:00Z 41" ]
  [ "$(sed -n 5p "$D/QUARANTINE")" = "" ]
  [ "$(tail -n +6 "$D/QUARANTINE")" = "$(quarantine_message "github:github.com/acme/widgets#7")" ]
  [ "$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().count(13))' "$D/QUARANTINE")" = 0 ]
  quarantine_marker_read "$D"
  [ "$QM_KEY" = "github:github.com/acme/widgets#7" ]
  [ "$QM_REASON" = screen ]
  [ "$QM_TIME" = 2026-11-02T10:00:00Z ]
  [ "$QM_SEQ" = 41 ]
  quarantine_marker_write "$BATS_TEST_TMPDIR/fresh/Issue-9" "wid/Issue-9" tracker '?' '?'
  quarantine_marker_read "$BATS_TEST_TMPDIR/fresh/Issue-9"
  [ "$QM_TIME" = "?" ] && [ "$QM_SEQ" = "?" ] && [ "$QM_KEY" = wid/Issue-9 ]
}

@test "marker: hand-edited sentinels never reach quarantine_print" {
  _lib
  printf '%s\n' 'devagent-quarantine 1' 'key SENTINEL TITLE-7f3a' 'reason SENTINEL-BODY-9c1e' \
    'event 2026-11-02T10:00:00Z 1' '' 'SENTINEL-TITLE-7f3a SENTINEL-BODY-9c1e' > "$D/QUARANTINE"
  run --separate-stderr quarantine_print "$D"
  [ "$status" -eq 0 ]
  [[ "$output" != *SENTINEL* ]]
  [ "$(tail -n 1 <<<"$output")" = "Reason: ?" ]
  [ "$(head -n 1 <<<"$output")" = "QUARANTINED: ? is held for human review." ]
}

@test "marker: malformed fields read ?; garbage header still marked" {
  _lib
  printf '%s\n' 'devagent-quarantine 1' 'key a b' 'reason nope' 'event yesterday 1e9' > "$D/QUARANTINE"
  quarantine_marker_read "$D"
  [ "$QM_KEY" = "?" ] && [ "$QM_REASON" = "?" ] && [ "$QM_TIME" = "?" ] && [ "$QM_SEQ" = "?" ]
  printf 'garbage\nkey github:x#7\nreason screen\nevent 2026-11-02T10:00:00Z 4\n' > "$D/QUARANTINE"
  quarantine_marked "$D"
  quarantine_marker_read "$D"
  [ "$QM_KEY" = "?" ] && [ "$QM_REASON" = "?" ] && [ "$QM_TIME" = "?" ] && [ "$QM_SEQ" = "?" ]
  : > "$D/QUARANTINE"
  quarantine_marked "$D"
  quarantine_marker_read "$D"
  [ "$QM_KEY" = "?" ]
}

@test "marker: symlink counts" {
  _lib
  ln -s "$BATS_TEST_TMPDIR/nowhere" "$D/QUARANTINE"
  quarantine_marked "$D"
  quarantine_marker_read "$D"
  [ "$QM_KEY" = "?" ] && [ "$QM_TIME" = "?" ]
}

@test "state: none/held/released" {
  _state separate
  [ "$status" -eq 0 ] && [ "$output" = "none 0 ? ?" ]
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  _state separate
  [ "$output" = "held 1 2026-11-02T10:00:00Z 5" ]
  qf_ev 2026-11-02T11:00:00Z 9 2002 user unlabeled
  _state separate
  [ "$output" = "released 0 2026-11-02T10:00:00Z 5" ]
}

@test "state: another label's records are ignored; the name is case-folded" {
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled DevAgent:Quarantine
  qf_ev 2026-11-02T11:00:00Z 9 2002 user unlabeled bug
  _state separate
  [ "$output" = "held 1 2026-11-02T10:00:00Z 5" ]
}

@test "state[separate]: removal by whoami is held" {
  qf_ev 2026-11-02T10:00:00Z 5 2002 user labeled
  qf_ev 2026-11-02T11:00:00Z 9 1001 user unlabeled
  _state separate
  [ "$output" = "held 0 2026-11-02T10:00:00Z 5" ]
}

@test "state[separate]: by another listed worker is held" {
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  qf_ev 2026-11-02T11:00:00Z 9 3003 user unlabeled
  QF_WORKERS='"github:1001", "github:3003"' _state separate
  [ "${output%% *}" = held ]
}

@test "state[*]: by an unlisted bot is held" {
  local shape
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  qf_ev 2026-11-02T11:00:00Z 9 4004 bot unlabeled
  for shape in separate single hardened; do
    _state "$shape"
    [ "${output%% *}" = held ] || { echo "$shape: $output" >&2; return 1; }
  done
}

@test "state[*]: before the quarantine is held" {
  local shape
  qf_ev 2026-11-02T09:00:00Z 3 2002 user unlabeled
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  for shape in separate single hardened; do
    _state "$shape"
    [ "$output" = "held 1 2026-11-02T10:00:00Z 5" ] || { echo "$shape: $output" >&2; return 1; }
  done
}

@test "state[*]: same second with ? seq is held" {
  local shape
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  qf_ev 2026-11-02T10:00:00Z '?' 2002 user unlabeled
  for shape in separate single hardened; do
    _state "$shape"
    [ "${output%% *}" = held ] || { echo "$shape: $output" >&2; return 1; }
  done
}

@test "state[*]: same second with a larger seq is held (U2 unmeasured: fail closed)" {
  local shape
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  qf_ev 2026-11-02T10:00:00Z 6 2002 user unlabeled
  for shape in separate single hardened; do
    _state "$shape"
    [ "${output%% *}" = held ] || { echo "$shape: $output" >&2; return 1; }
  done
}

@test "state[*]: by approver 2002 is released" {
  local shape
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  qf_ev 2026-11-02T11:00:00Z 9 2002 user unlabeled
  for shape in separate single hardened; do
    _state "$shape"
    [ "$output" = "released 0 2026-11-02T10:00:00Z 5" ] || { echo "$shape: $output" >&2; return 1; }
  done
}

@test "state[*]: by the approver who applied it is released" {
  local shape
  qf_ev 2026-11-02T10:00:00Z 5 2002 user labeled
  qf_ev 2026-11-02T11:00:00Z 9 2002 user unlabeled
  for shape in separate single hardened; do
    _state "$shape"
    [ "${output%% *}" = released ] || { echo "$shape: $output" >&2; return 1; }
  done
}

@test "state[single]: by whoami releases (D20 residual)" {
  qf_ev 2026-11-02T10:00:00Z 5 2002 user labeled
  qf_ev 2026-11-02T11:00:00Z 9 1001 user unlabeled
  _state single
  [ "$output" = "released 0 2026-11-02T10:00:00Z 5" ]
}

@test "state[hardened]: by whoami is held" {
  qf_ev 2026-11-02T10:00:00Z 5 2002 user labeled
  qf_ev 2026-11-02T11:00:00Z 9 1001 user unlabeled
  _state hardened
  [ "$output" = "held 0 2026-11-02T10:00:00Z 5" ]
}

@test "state: re-quarantine after release is held" {
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  qf_ev 2026-11-02T11:00:00Z 9 2002 user unlabeled
  qf_ev 2026-11-02T12:00:00Z 12 1001 user labeled
  _state separate
  [ "$output" = "held 1 2026-11-02T12:00:00Z 12" ]
}

@test "state: an unknown actor never grants" {
  qf_ev 2026-11-02T10:00:00Z 5 1001 user labeled
  qf_ev 2026-11-02T11:00:00Z 9 '?' user unlabeled
  _state separate
  [ "$output" = "held 0 2026-11-02T10:00:00Z 5" ]
}

@test "key: longest dir_prefix wins" {
  printf '\n[project.wid.issue_source_fork]\nbackend = "github"\nrepo = "me/widgets"\ndir_prefix = "Issue-Fork-"\n' \
    >> "$DA_HOME/config.toml"
  _lib
  quarantine_key wid Issue-Fork-12
  [ "$QK_SOURCE" = fork ] && [ "$QK_REPO" = me/widgets ] && [ "$QK_NUM" = 12 ] && [ "$QK_BACKEND" = github ]
  [ "$QK_KEY" = "github:github.com/me/widgets#12" ]
  quarantine_key wid Issue-7
  [ "$QK_SOURCE" = origin ] && [ "$QK_KEY" = "github:github.com/acme/widgets#7" ]
  quarantine_key wid Notes-3
  [ "$QK_SOURCE" = "" ] && [ "$QK_KEY" = "wid/Notes-3" ]
}
