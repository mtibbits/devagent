#!/usr/bin/env bats
# tests/chars-pull.bats -- #923 end to end: the real pull.sh and the floor's
# `chars` check (invisible, unassigned and control characters, and invalid
# UTF-8, in the title, body, labels, state and author), the `<U+XXXX>` escape
# of allowlisted characters, the marker's detail line and the mixed-script
# record. Fixtures as tests/floor-pull.bats. Every character is written as an
# escape (JSON \uXXXX, printf \xHH, TOML \uXXXX): this file stays ASCII.
# shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr` (bats idiom)
bats_require_minimum_version 1.5.0   # run --separate-stderr

load 'lib/bats-helpers'
load 'lib/trust-fixture'
load 'lib/quarantine-fixture'

setup() {
  qf_project
  PULL="$PLUGIN_ROOT/scripts/pull.sh"
  STAGING="$DA_HOME/state/staging"
  POLICY="$HOME/.config/devagent/trust/policy.toml"
  unset DEVAGENT_TEST_QUARANTINE GH_STUB_BODY_JSON GH_STUB_LABELS_JSON GH_STUB_COMMENTS_JSON GH_STUB_TITLE_JSON
}

teardown() { teardown_tmp_devagent_home; }

# _count <file> <printf-bytes>: how many times the bytes occur in the file,
# counted on bytes (LC_ALL=C).
_count() {
  local pat
  pat="$(printf '%b' "$2")"
  LC_ALL=C grep -o -F -- "$pat" "$1" | wc -l | tr -d ' '
}

@test "trust off: a ticket holding U+202E is written verbatim" {
  [ ! -e "$POLICY" ]
  qf_ticket '"Body \u202e here."' '[{"name": "bug"}, {"name": "x\u202ey"}]'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [ "$(_count "$DEVDOC/Issue-9/issue.md" '\xe2\x80\xae')" -eq 2 ]
  [ ! -e "$DEVDOC/Issue-9/QUARANTINE" ]
}

_sha() { sha256sum "$1" | cut -d' ' -f1; }
_floor() { printf 'pull.sh: floor: %s\n' "$@"; }
REMEDY_CHARS="for the operator: edit the text, remove the label that holds the character, or add the character to the trust policy's allowed_chars (a run longer than two, or invalid UTF-8, can only be edited out); a trusted approver then releases the quarantine"
REMEDY_CHARS_LAST="for the operator: a chars quarantine released without one of these fixes quarantines again on every pull"

# _empty_staging: the staging root holds nothing (or was never made).
_empty_staging() {
  [ ! -e "$STAGING" ] || [ -z "$(ls -A "$STAGING")" ] || { echo "staged: $(ls -A "$STAGING")" >&2; return 1; }
}

# _release: the approver removes the quarantine label (after the stub's
# labeled record at 10:00, seq 1), and the next label write is dated later.
_release() {
  qf_ev 2026-11-02T11:00:00Z 2 2002 user unlabeled
  echo 2 > "$QB_DIR/seq"
  echo 2026-11-02T12:00:00Z > "$QB_DIR/clock"
}

_print() {
  bash -c 'for l in paths io config state active trust quarantine; do source "$PLUGIN_ROOT/scripts/lib/$l.sh"; done
    quarantine_print "$1"' _ "$1"
}

@test "pull: U+202E in a label quarantines with chars" {
  qf_policy separate
  qf_ticket '"Body."' '[{"name": "bug"}, {"name": "x\u202ey"}]'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [ "$(ls -A "$DEVDOC/Issue-9")" = QUARANTINE ]
  [ "$(sed -n 3p "$DEVDOC/Issue-9/QUARANTINE")" = "reason chars" ]
  [ "$(sed -n 5p "$DEVDOC/Issue-9/QUARANTINE")" = "detail: label line 1 U+202E" ]
  [ "$output" = "" ]
  local want
  want="$(_floor "chars: label line 1 U+202E" "$REMEDY_CHARS" "$REMEDY_CHARS_LAST")"
  want+=$'\n'"$(bash -c 'source "$PLUGIN_ROOT/scripts/lib/refusals.sh"; quarantine_message github:github.com/acme/widgets#9')"
  [ "$stderr" = "$want" ] || { diff <(echo "$stderr") <(echo "$want") >&2; return 1; }
  _empty_staging
  [ "$(_print "$DEVDOC/Issue-9" | tail -n 2)" = "Reason: chars
detail: label line 1 U+202E" ]
}

@test "pull: U+202E on body line 3, and with a second hit" {
  qf_policy separate
  qf_ticket '"one\ntwo\nthree \u202e"'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ]
  [ "$(sed -n 5p "$DEVDOC/Issue-9/QUARANTINE")" = "detail: body line 3 U+202E" ]
  rm -rf "$DEVDOC/Issue-9"
  _fresh_tracker
  qf_ticket '"one\ntwo\nthree \u202e\nfour \u200b"'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ]
  [ "$(sed -n 5p "$DEVDOC/Issue-9/QUARANTINE")" = "detail: body line 3 U+202E (+1 more)" ]
}

_fresh_tracker() { rm -f "$QB_DIR/events.tsv" "$QB_DIR/seq"; }

@test "pull: an in-work re-pull that hits leaves the old issue.md byte-identical" {
  qf_policy separate
  printf 'the issue.md an earlier pull wrote\n' > "$DEVDOC/Issue-7/issue.md"
  local old
  old="$(_sha "$DEVDOC/Issue-7/issue.md")"
  qf_ticket '"Changed \u202e."'
  run --separate-stderr "$PULL" wid origin 7
  [ "$status" -eq 6 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [ "$(_sha "$DEVDOC/Issue-7/issue.md")" = "$old" ]
  [ "$(sed -n 5p "$DEVDOC/Issue-7/QUARANTINE")" = "detail: body line 1 U+202E" ]
  _empty_staging
}

@test "pull: a released chars quarantine quarantines again" {
  qf_policy separate
  qf_ticket '"Body \u202e."'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ]
  local ev
  ev="$(sed -n 4p "$DEVDOC/Issue-9/QUARANTINE")"
  _release
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [ "$(sed -n 3p "$DEVDOC/Issue-9/QUARANTINE")" = "reason chars" ]
  [ "$(sed -n 4p "$DEVDOC/Issue-9/QUARANTINE")" != "$ev" ]
  [ "$(sed -n 4p "$DEVDOC/Issue-9/QUARANTINE")" = "event 2026-11-02T12:00:00Z 3" ]
}

@test "pull: it passes once the text is edited" {
  qf_policy separate
  qf_ticket '"Body \u202e."'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ]
  _release
  qf_ticket '"Body, edited."'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [ ! -e "$DEVDOC/Issue-9/QUARANTINE" ]
  grep -qx 'Body, edited.' "$DEVDOC/Issue-9/issue.md"
}

@test "pull: it passes once the label is removed" {
  qf_policy separate
  qf_ticket '"Body."' '[{"name": "bug"}, {"name": "x\u202ey"}]'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ]
  _release
  qf_ticket '"Body."' '[{"name": "bug"}]'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [ ! -e "$DEVDOC/Issue-9/QUARANTINE" ]
}
