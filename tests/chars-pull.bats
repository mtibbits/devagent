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
  STATE="$DA_HOME/state/wid.toml"
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
