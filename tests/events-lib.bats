#!/usr/bin/env bats
# #712: scripts/lib/issue-events.sh — the record contract shared by every
# backend that implements events / comment-records (spec §9.3.1): the
# emitter and its validator, sort/dedupe, the reference parse and the
# --kinds coverage reader.

load 'lib/bats-helpers'

setup() {
  # shellcheck source=../scripts/lib/issue-events.sh
  source "$PLUGIN_ROOT/scripts/lib/issue-events.sh"
  EVC="$PLUGIN_ROOT/tests/fixtures/events-custom"
}

# _jq: jq without the CR a Windows jq appends (D-k), keeping jq's status.
_jq() ( set -o pipefail; jq "$@" | tr -d '\r' )

# _rec <json-object> → the bc_rec line for one record (after bc_rec_check).
_rec() { _jq -nr --argjson r "$1" "$BC_EVENTS_JQ"' $r | bc_rec_check | bc_rec'; }

@test "bc_rec: a label name with TAB, LF and spaces is one six-field line" {
  local line rows
  line=$(_rec '{"time":"2026-10-01T10:00:00Z","seq":7,"actor":"894144","atype":"user","kind":"labeled","detail":["LA_x","a\tb\nc d  e"]}')
  [ "$(printf '%s\n' "$line" | wc -l)" -eq 1 ]
  [ "$(printf '%s\n' "$line" | awk -F'\t' 'NF==6' | wc -l)" -eq 1 ]
  rows=$(printf '%s\n' "$line" | bc_rec_parse)
  [ "$(_jq -r '.id' <<< "$rows")" = "LA_x" ]
  [ "$(_jq -c '.rest' <<< "$rows")" = '"a\tb\nc d  e"' ]
  [ "$(_jq -r '.kind' <<< "$rows")" = "labeled" ]
  [ "$(_jq -r '.seq' <<< "$rows")" = "7" ]
}

@test "bc_rec: an empty detail still parses as six fields" {
  local line n
  line=$(_rec '{"time":"2026-10-01T10:00:00Z","seq":"?","actor":"894144","atype":"user","kind":"created","detail":[]}')
  [ "$line" = "$(printf '2026-10-01T10:00:00Z\t?\t894144\tuser\tcreated\t')" ]
  [ "$(printf '%s\n' "$line" | bc_rec_parse | jq -r '.detail')" = "" ]
  # F11: Bash `read` collapses the empty trailing field (TAB is IFS whitespace).
  IFS=$'\t' read -ra f <<< "$line"
  n=${#f[@]}
  [ "$n" -eq 5 ]
}

@test "bc_rec_check fails closed on an id with a space" {
  run _rec '{"time":"2026-10-01T10:00:00Z","seq":1,"actor":"1","atype":"user","kind":"commented","detail":["12 34"]}'
  [ "$status" -eq 5 ]
  [ -z "$output" ] || [[ "$output" == *"bc_rec_check"* ]]
}

@test "bc_rec_check fails closed on a non-UTC time and on a fraction" {
  run _rec '{"time":"2026-10-01T10:00:00+01:00","seq":1,"actor":"1","atype":"user","kind":"edited-title","detail":[]}'
  [ "$status" -eq 5 ]
  run _rec '{"time":"2026-10-01T10:00:00.123Z","seq":1,"actor":"1","atype":"user","kind":"edited-title","detail":[]}'
  [ "$status" -eq 5 ]
  run _rec '{"time":"2026-10-01T10:00:00Z\n","seq":1,"actor":"1","atype":"user","kind":"edited-title","detail":[]}'
  [ "$status" -eq 5 ]
}

@test "bc_rec_check fails closed on an unknown kind or atype" {
  run _rec '{"time":"2026-10-01T10:00:00Z","seq":1,"actor":"1","atype":"user","kind":"renamed","detail":[]}'
  [ "$status" -eq 5 ]
  run _rec '{"time":"2026-10-01T10:00:00Z","seq":1,"actor":"1","atype":"robot","kind":"edited-title","detail":[]}'
  [ "$status" -eq 5 ]
  run _rec '{"time":"2026-10-01T10:00:00Z","seq":1,"actor":"a b","atype":"user","kind":"edited-title","detail":[]}'
  [ "$status" -eq 5 ]
}

@test "bc_tsv_unescape round-trips the five escapes, NUL included" {
  local tsv
  tsv=$(_jq -nr '["a\tb\nc\rd\\e\u0000f"] | @tsv')
  [ "$tsv" = 'a\tb\nc\rd\\e\0f' ]
  run _jq -nr --arg t "$tsv" "$BC_EVENTS_JQ"' $t | bc_tsv_unescape == "a\tb\nc\rd\\e\u0000f"'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "bc_tsv_unescape rejects an unknown escape" {
  run _jq -nr --arg t 'a\qb' "$BC_EVENTS_JQ"' $t | bc_tsv_unescape'
  [ "$status" -eq 5 ]
  run _jq -nr --arg t 'ab\' "$BC_EVENTS_JQ"' $t | bc_tsv_unescape'
  [ "$status" -eq 5 ]
}

@test "bc_rec_sort orders by time then seq" {
  run _jq -nr "$BC_EVENTS_JQ"' [
      {time:"2026-10-01T10:00:01Z",seq:1,actor:"1",atype:"user",kind:"labeled",detail:["L1","x"]},
      {time:"2026-10-01T10:00:00Z",seq:9,actor:"1",atype:"user",kind:"labeled",detail:["L1","x"]},
      {time:"2026-10-01T10:00:00Z",seq:3,actor:"1",atype:"user",kind:"labeled",detail:["L1","x"]},
      {time:"2026-10-01T10:00:00Z",seq:"?",actor:"1",atype:"user",kind:"edited-body",detail:[]}
    ] | bc_rec_sort | .[] | "\(.time) \(.seq)"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "2026-10-01T10:00:00Z ?" ]
  [ "${lines[1]}" = "2026-10-01T10:00:00Z 3" ]
  [ "${lines[2]}" = "2026-10-01T10:00:00Z 9" ]
  [ "${lines[3]}" = "2026-10-01T10:00:01Z 1" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "bc_rec_sort drops an exact numeric-seq duplicate and keeps two ?-seq twins" {
  run _jq -nr "$BC_EVENTS_JQ"' [
      {time:"2026-10-01T10:00:00Z",seq:5,actor:"1",atype:"user",kind:"labeled",detail:["L1","x"]},
      {time:"2026-10-01T10:00:00Z",seq:5,actor:"1",atype:"user",kind:"labeled",detail:["L1","x"]},
      {time:"2026-10-01T10:00:00Z",seq:"?",actor:"1",atype:"user",kind:"edited-body",detail:[]},
      {time:"2026-10-01T10:00:00Z",seq:"?",actor:"1",atype:"user",kind:"edited-body",detail:[]}
    ] | bc_rec_sort | .[] | "\(.seq) \(.kind)"'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "? edited-body" ]
  [ "${lines[1]}" = "? edited-body" ]
  [ "${lines[2]}" = "5 labeled" ]
}

@test "bc_crec: a body with TAB, CR, LF and a backslash parses back byte-exact" {
  local line
  line=$(_jq -nr "$BC_EVENTS_JQ"' {id:6387235597,author:"894144",atype:"user",created:"2026-10-01T10:00:00Z",last_edited:null,body:"a\tb\r\nc\\d"} | bc_crec_check | bc_crec')
  [ "$(printf '%s\n' "$line" | awk -F'\t' 'NF==6' | wc -l)" -eq 1 ]
  run _jq -nr --arg l "$line" "$BC_EVENTS_JQ"' $l | split("\t") | map(bc_tsv_unescape) | .[4] == "" and .[5] == "a\tb\r\nc\\d"'
  [ "$output" = "true" ]
}

@test "bc_events_coverage: a partial custom backend reports an omitted kind unsupported" {
  run bc_events_coverage "$EVC/partial.sh" o/r edited-body
  [ "$status" -eq 0 ]
  [ "$output" = "unsupported" ]
  run bc_events_coverage "$EVC/partial.sh" o/r edited-title
  [ "$status" -eq 0 ]
  [ "$output" = "full" ]
}

@test "bc_events_coverage: exit 78 and exit 2 read as unsupported" {
  bats_require_minimum_version 1.5.0
  run --separate-stderr bc_events_coverage "$PLUGIN_ROOT/scripts/issue/custom.sh" o/r created
  [ "$status" -eq 0 ]
  [ "$output" = "unsupported" ]
  printf '#!/usr/bin/env bash\nexit 2\n' > "$BATS_TEST_TMPDIR/two.sh"
  chmod +x "$BATS_TEST_TMPDIR/two.sh"
  run bc_events_coverage "$BATS_TEST_TMPDIR/two.sh" o/r created
  [ "$status" -eq 0 ]
  [ "$output" = "unsupported" ]
}

@test "bc_events_coverage: a missing script exits 1, never unsupported" {
  run bc_events_coverage "$BATS_TEST_TMPDIR/nope.sh" o/r created
  [ "$status" -eq 1 ]
  [[ "$output" != *"unsupported"* ]]
}

@test "bc_events_coverage: a malformed --kinds line exits 1" {
  run bc_events_coverage "$EVC/badline.sh" o/r created
  [ "$status" -eq 1 ]
  [[ "$output" != *"unsupported"* ]]
}

@test "bc_events_coverage: any other non-zero exit is 1" {
  printf '#!/usr/bin/env bash\nexit 5\n' > "$BATS_TEST_TMPDIR/five.sh"
  chmod +x "$BATS_TEST_TMPDIR/five.sh"
  run bc_events_coverage "$BATS_TEST_TMPDIR/five.sh" o/r created
  [ "$status" -eq 1 ]
}
