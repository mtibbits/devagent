#!/usr/bin/env bats
# bats file_tags=gitbash
# tests/chars.bats -- #923: the chars.py CLI (scripts/lib/chars.py). Bytes in,
# bytes out, LF only; exit 0 ran, 2 usage, 3 could not run. This file stays
# ASCII: characters are printf \x escapes.
# shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr` (bats idiom)
bats_require_minimum_version 1.5.0   # run --separate-stderr

load 'lib/bats-helpers'

setup() {
  CHARS="$PLUGIN_ROOT/scripts/lib/chars.py"
  T="$BATS_TEST_TMPDIR"
  printf 'plain text\n' > "$T/clean"
  printf 'a\xe2\x80\xaeb\r\nc\xe2\x80\x8bd\n' > "$T/hit"
}

_chars() { python3 -I -X utf8 "$CHARS" "$@"; }

# _cand <title> <state> <author> <labels> <body>: a rendered issue.md, each
# argument a printf format.
_cand() {
  # shellcheck disable=SC2059  # the arguments are the test's own formats
  printf "# acme/widgets#7 \xe2\x80\x94 $1\n\n- State: $2\n- Author: $3\n- Labels: $4\n- URL: u\n\n---\n\n$5\n\n---\n\n## Comments (0)\n"
}

@test "cli: scan prints hits as LF-only bytes" {
  run --separate-stderr _chars scan body "$T/clean"
  [ "$status" -eq 0 ]
  [ "$output" = "hits 0" ]
  _chars scan body "$T/hit" > "$T/out" 2> "$T/err"
  [ "$(cat "$T/out")" = "$(printf 'hits 2\nbody line 1 U+202E\nbody line 2 U+200B')" ]
  { printf '# DIAG923 grep:'; LC_ALL=C grep -c $'\r' "$T/out" | od -An -c | tr -s ' \n' ' '; printf ' rc=%s\n' "${PIPESTATUS[0]}"; } >&3 || true
  [ "$(tr -cd '\r' < "$T/out" | wc -c)" -eq 0 ]   # byte count: no locale, no $(...) CR-stripping
  [ ! -s "$T/err" ]
}

@test "cli: --max caps the lines, not the total" {
  run --separate-stderr _chars scan body "$T/hit" --max 1
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'hits 2\nbody line 1 U+202E')" ]
}

@test "cli: usage is 2" {
  local -a forms=(
    ''
    'bogus'
    'scan'
    'scan body'
    "scan body $T/clean extra"
    "scan body $T/clean --nope x"
    "scan body $T/clean --max 1 --max 2"
    "scan body $T/clean --allow"
    "scan body $T/clean --max 0"
    "scan body $T/clean --max -1"
    "scan body $T/clean --max 1x"
    "scan nofield $T/clean"
    "scan --candidate $T/clean body"
    "escape"
    "escape $T/clean --max 3"
    "mixed body"
    "mixed body $T/clean --allow $T/clean"
  )
  local f
  for f in "${forms[@]}"; do
    # shellcheck disable=SC2086  # each form is split on purpose
    run --separate-stderr _chars $f
    [ "$status" -eq 2 ] || { echo "form '$f': rc=$status" >&2; return 1; }
    [ -z "$output" ] || { echo "form '$f': stdout" >&2; return 1; }
  done
  run --separate-stderr _chars scan body "$T/clean" --allow ''
  [ "$status" -eq 2 ]
  run --separate-stderr _chars scan body "$T/clean" --max ''
  [ "$status" -eq 2 ]
}

@test "cli: a missing file, a malformed allow file or a candidate outside the fetch layout is 3" {
  run --separate-stderr _chars scan body "$T/missing"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  local a
  for a in 'null' '{}' '["ab"]' '[1]' '["a"'; do
    printf '%s' "$a" > "$T/allow.json"
    run --separate-stderr _chars scan body "$T/clean" --allow "$T/allow.json"
    [ "$status" -eq 3 ] || { echo "allow '$a': rc=$status" >&2; return 1; }
    [ -z "$output" ] || { echo "allow '$a': stdout" >&2; return 1; }
  done
  run --separate-stderr _chars scan --candidate "$T/clean"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "cli: candidate mode names fields in order" {
  local h='\xe2\x80\xae'
  _cand "T$h" "open$h" "@a$h" "bug$h" "one\ntwo$h" > "$T/cand"
  run --separate-stderr _chars scan --candidate "$T/cand"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'hits 5\ntitle line 1 U+202E\nbody line 2 U+202E\nlabel line 1 U+202E\nstate line 1 U+202E\nauthor line 1 U+202E')" ]
  printf '# acme/widgets#7 - T\n\n- State: open\n- Author: @a\n- Labels: \n- URL: u\n\n---\n\nb\n\n---\n\n## Comments (0)\n' > "$T/cand2"
  run --separate-stderr _chars scan --candidate "$T/cand2"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "cli: escape and mixed" {
  printf '["\\u200f"]' > "$T/allow.json"
  printf 'a\xe2\x80\x8fb\n' > "$T/rlm"
  run --separate-stderr _chars escape "$T/rlm" --allow "$T/allow.json"
  [ "$status" -eq 0 ]
  [ "$output" = "a<U+200F>b" ]
  printf 'p\xd0\xb0ypal\n' > "$T/mixed"
  run --separate-stderr _chars mixed title "$T/mixed"
  [ "$status" -eq 0 ]
  [ "$output" = '[{"field":"title","line":1,"word_scripts":["Cyrillic","Latin"]}]' ]
  run --separate-stderr _chars mixed body "$T/clean"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "cli: a table that cannot load is exit 3, and the render's exit 4" {
  local lib="$T/lib"
  cp -r "$PLUGIN_ROOT/scripts/lib" "$lib"
  rm "$lib/chars_table.py"
  printf '# acme/widgets#7 \xe2\x80\x94 T\n' > "$T/raw"
  run --separate-stderr python3 -I -X utf8 "$lib/chars.py" scan body "$T/clean"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  run --separate-stderr python3 -I -X utf8 "$lib/staging_render.py" "$T/raw" "$T/out" acme/widgets 7
  [ "$status" -eq 4 ]
  [ ! -e "$T/out" ]
  [ ! -e "$T/out.mixed.json" ]
}
