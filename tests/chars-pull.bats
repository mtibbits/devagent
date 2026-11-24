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

# ---- Task 7: the escape and the record through the real pull ------------------

@test "pull: an allowlisted U+200F passes and is escaped" {
  qf_policy separate 'allowed_chars = ["\u200f"]'
  qf_ticket '"Body a\u200fb."' '[{"name": "bug"}, {"name": "x\u200fy"}]' '' '"T\u200fT"'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [[ "$(head -n 1 "$DEVDOC/Issue-9/issue.md")" == *' T<U+200F>T' ]]
  grep -qx -- '- Labels: bug, x<U+200F>y' "$DEVDOC/Issue-9/issue.md"
  grep -qx 'Body a<U+200F>b.' "$DEVDOC/Issue-9/issue.md"
  [ "$(_count "$DEVDOC/Issue-9/issue.md" '\xe2\x80\x8f')" -eq 0 ]
  [ ! -e "$DEVDOC/Issue-9/QUARANTINE" ]
}

@test "pull: three allowlisted U+200F in a row quarantine" {
  qf_policy separate 'allowed_chars = ["\u200f"]'
  qf_ticket '"a\u200f\u200f\u200fb"'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ]
  [ "$(sed -n 5p "$DEVDOC/Issue-9/QUARANTINE")" = "detail: body line 1 U+200F (+2 more)" ]
}

@test "pull: ZWNJ ZWJ ZWNJ quarantines" {
  qf_policy separate 'allowed_chars = ["\u200c", "\u200d"]'
  qf_ticket '"a\u200c\u200d\u200cb"'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ]
  [ "$(sed -n 5p "$DEVDOC/Issue-9/QUARANTINE")" = "detail: body line 1 U+200C (+2 more)" ]
}

@test "pull: the rainbow-flag sequence passes" {
  qf_policy separate 'allowed_chars = ["\ufe0f", "\u200d"]'
  qf_ticket '"Flag: \ud83c\udff3\ufe0f\u200d\ud83c\udf08."'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  grep -q '<U+FE0F><U+200D>' "$DEVDOC/Issue-9/issue.md"
}

@test "pull: a released chars quarantine passes once allowed_chars lists the character" {
  qf_policy separate
  qf_ticket '"Body a\u200fb."'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ]
  [ "$(sed -n 5p "$DEVDOC/Issue-9/QUARANTINE")" = "detail: body line 1 U+200F" ]
  _release
  qf_policy separate 'allowed_chars = ["\u200f"]'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [ ! -e "$DEVDOC/Issue-9/QUARANTINE" ]
  grep -qx 'Body a<U+200F>b.' "$DEVDOC/Issue-9/issue.md"
}

@test "pull: a control byte in the title is #715's; in the body it quarantines" {
  qf_policy separate
  qf_ticket '"Body."' '' '' '"a\u0007b"'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [[ "$(head -n 1 "$DEVDOC/Issue-9/issue.md")" == *' a<U+0007>b' ]]
  unset GH_STUB_TITLE_JSON
  qf_ticket '"a\u0007b"'
  run --separate-stderr "$PULL" wid origin 10
  [ "$status" -eq 6 ]
  [ "$(sed -n 5p "$DEVDOC/Issue-10/QUARANTINE")" = "detail: body line 1 U+0007" ]
  _fresh_tracker
  qf_ticket '"Body."' '[{"name": "x\u0085y"}]'
  run --separate-stderr "$PULL" wid origin 11
  [ "$status" -eq 6 ]
  [ "$(sed -n 5p "$DEVDOC/Issue-11/QUARANTINE")" = "detail: label line 1 U+0085" ]
}

@test "pull: size_cap counts the escaped bytes" {
  qf_policy separate 'allowed_chars = ["\u200f"]' 'size_cap = 100000'
  qf_ticket '"Body a\u200fb."'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  local size
  size="$(wc -c < "$DEVDOC/Issue-9/issue.md" | tr -d ' ')"
  # Re-pulled with a cap one below the escaped file: the raw text is 5 bytes
  # shorter (3 raw bytes against `<U+200F>`'s 8), so only a count of the
  # escaped bytes quarantines.
  qf_policy separate 'allowed_chars = ["\u200f"]' "size_cap = $((size - 1))"
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [ "$(sed -n 3p "$DEVDOC/Issue-9/QUARANTINE")" = "reason size" ]
}

_plugin_copy() {
  P2="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$P2"
  cp -r "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/templates" "$P2/"
}

@test "pull: a later verdict source finds the record beside the candidate" {
  qf_policy separate
  _plugin_copy
  local seen="$BATS_TEST_TMPDIR/seen.json"
  # A stand-in for #717's screen: a source appended after the floor that copies
  # the record aside and prints nothing (a PASS).
  printf '\n_rec_src() { [ -n "${3:-}" ] || return 3; cp "$3.mixed.json" %q || return 3; }\nQUARANTINE_SOURCES+=(_rec_src)\n' \
    "$seen" >> "$P2/scripts/lib/quarantine.sh"
  qf_ticket '"Body."' '' '' '"p\u0430ypal"'
  run --separate-stderr "$P2/scripts/pull.sh" wid origin 9
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [ "$(cat "$seen")" = '[{"field":"title","line":1,"word_scripts":["Cyrillic","Latin"]}]' ]
  local n=10 body
  for body in '"\u041f\u0440\u0438\u0432\u0435\u0442 \u043c\u0438\u0440"' \
              '"\u03b1 + \u03b2 = \u03b3"' '"\u6771\u4eac\u30bf\u30ef\u30fc"'; do
    unset GH_STUB_TITLE_JSON
    rm -f "$seen"
    qf_ticket "$body"
    run --separate-stderr "$P2/scripts/pull.sh" wid origin "$n"
    [ "$status" -eq 0 ] || { echo "$body: rc=$status stderr=$stderr" >&2; return 1; }
    [ "$(cat "$seen")" = '[]' ] || { echo "$body: $(cat "$seen")" >&2; return 1; }
    n=$((n + 1))
  done
}

@test "pull: the record is gone with the staged file" {
  qf_policy separate
  qf_ticket '"Body \u202e."' '' '' '"p\u0430ypal"'
  run --separate-stderr "$PULL" wid origin 9
  [ "$status" -eq 6 ]
  _empty_staging
  _fresh_tracker
  qf_ticket '"Body."' '' '' '"p\u0430ypal"'
  run --separate-stderr "$PULL" wid origin 10
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  _empty_staging
  [ -z "$(find "$DA_HOME" "$DEVDOC" -name '*.mixed.json')" ]
}
