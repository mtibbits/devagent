#!/usr/bin/env bats
# bats file_tags=gitbash
# tests/floor.bats — #715: pull's deterministic floor (scripts/lib/floor.sh),
# the `steering` and `size` checks on the candidate issue.md, driven directly:
# each test sources the libraries and sets TRUST_VAL by hand. The end-to-end
# legs through the real pull.sh are tests/floor-pull.bats.
# shellcheck disable=SC2154,SC2034  # $stderr is set by `run --separate-stderr`; TRUST_VAL is read by floor.sh
bats_require_minimum_version 1.5.0   # run --separate-stderr

load 'lib/bats-helpers'

setup() {
  # shellcheck source=/dev/null
  source "$PLUGIN_ROOT/scripts/lib/floor.sh"
  declare -gA TRUST_VAL=([allowed_steering]='[]' [size_cap]=65536)
  C="$BATS_TEST_TMPDIR/issue.md"
}

# _allow <entry>…: TRUST_VAL[allowed_steering] as the loader prints it.
_allow() {
  local e out="" sep=""
  for e in "$@"; do out+="$sep\"$e\""; sep=","; done
  TRUST_VAL[allowed_steering]="[$out]"
}

# _cand <body> [<labels csv>]: a candidate issue.md in the trust render's
# layout. The header is 9 lines (title … the header rule), so body line n is
# file line n + 9.
_cand() {
  printf '# acme/widgets#7 — Demo\n\n- State: open\n- Author: @alice\n- Labels: %s\n- URL: https://example.com/7\n- Created: 2026-11-20\n\n---\n\n%s\n\n---\n\n## Comments (0)\n' \
    "${2:-}" "$1" > "$C"
}

# _diag: stderr with each line's `<prog>: floor: ` prefix checked and removed.
_diag() {
  local line
  while IFS= read -r line; do
    [[ "$line" == *": floor: "* ]] || { echo "unprefixed line: $line" >&2; return 1; }
    printf '%s\n' "${line#*: floor: }"
  done <<<"$stderr"
}

REMEDY_LISTABLE="for the operator: remove the flag or label from the ticket, or list the entry in the trust policy's allowed_steering; a trusted approver then releases the quarantine"
REMEDY_UNLISTABLE="for the operator: remove the flag or label from the ticket (it cannot be listed in allowed_steering); a trusted approver then releases the quarantine"
REMEDY_SIZE="for the operator: shorten the ticket, or raise size_cap in the trust policy; a trusted approver then releases the quarantine"
REMEDY_LAST="for the operator: a release without one of these fixes quarantines again on the next pull (until #953)"

@test "floor: a benign candidate → no token, empty stderr, rc 0" {
  _cand $'Plain prose.\n\n## Workflow notes\ntier: not a flags block' 'bug, performance'
  run --separate-stderr floor_run "$C"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$stderr" = "" ]
}

@test "floor: steering — a disallowed value" {
  _cand $'Intro.\n\n## Workflow flags\ntier: oneshot'
  run --separate-stderr floor_run "$C"
  [ "$status" -eq 0 ]
  [ "$output" = steering ]
  [ "$(_diag)" = "steering: '## Workflow flags' key 'tier' on body line 4 is not listed in allowed_steering
$REMEDY_LISTABLE
$REMEDY_LAST" ]
}

@test "floor: steering — an unknown key" {
  _cand $'## Workflow flags\nzz-unknown: 1'
  _allow 'tier: oneshot'
  run --separate-stderr floor_run "$C"
  [ "$status" -eq 0 ]
  [ "$output" = steering ]
  [ "$(_diag)" = "steering: an unrecognised '## Workflow flags' key on body line 2 cannot be listed
$REMEDY_UNLISTABLE
$REMEDY_LAST" ]
}

@test "floor: steering — a disallowed duplicate below an allowed key" {
  _cand $'## Workflow flags\ntier: standard\ntier: oneshot'
  _allow 'tier: standard'
  run --separate-stderr floor_run "$C"
  [ "$output" = steering ]
  [ "$(_diag)" = "steering: '## Workflow flags' key 'tier' on body line 3 is not listed in allowed_steering
$REMEDY_LISTABLE
$REMEDY_LAST" ]
}

@test "floor: steering — an empty value" {
  _cand $'## Workflow flags\nchecking-model:'
  _allow 'checking-model: fable'
  run --separate-stderr floor_run "$C"
  [ "$output" = steering ]
  [ "$(_diag)" = "steering: '## Workflow flags' key 'checking-model' on body line 2 is not listed in allowed_steering
$REMEDY_UNLISTABLE
$REMEDY_LAST" ]
}

@test "floor: steering — a disallowed tier: label" {
  _cand 'Body.' 'bug, tier:check-haiku, tier:impl-opus'
  _allow 'tier:impl-opus'
  run --separate-stderr floor_run "$C"
  [ "$output" = steering ]
  [ "$(_diag)" = "steering: 'tier:' label 1 of 2 is not listed in allowed_steering
$REMEDY_LISTABLE
$REMEDY_LAST" ]
}

@test "floor: steering — an unrecognised tier:* shape" {
  _cand 'Body.' 'tier:standard'
  _allow 'tier: standard'
  run --separate-stderr floor_run "$C"
  [ "$output" = steering ]
  [ "$(_diag)" = "steering: 'tier:' label 1 of 1 is not listed in allowed_steering
$REMEDY_UNLISTABLE
$REMEDY_LAST" ]
}

@test "floor: listed entries pass and ordinary labels are ignored" {
  _cand $'## Workflow flags\ntier: standard\nchecking-model: fable\nresearch: required' 'bug, tier:impl-opus, help wanted'
  _allow 'tier: standard' 'checking-model: fable' 'research: required' 'tier:impl-opus'
  run --separate-stderr floor_run "$C"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$stderr" = "" ]
}

@test "floor: tier: oneshot quarantines unless the policy lists it" {
  _cand $'## Workflow flags\ntier: oneshot'
  run --separate-stderr floor_run "$C"
  [ "$output" = steering ]
  _allow 'tier: oneshot'
  run --separate-stderr floor_run "$C"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "floor: a fenced flags block is not counted, nor a commented one" {
  _cand $'```\n## Workflow flags\ntier: oneshot\n```'
  run --separate-stderr floor_run "$C"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  _cand $'<!--\n## Workflow flags\ntier: oneshot\n-->'
  run --separate-stderr floor_run "$C"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  # positive control: the same block unfenced counts.
  _cand $'## Workflow flags\ntier: oneshot'
  run --separate-stderr floor_run "$C"
  [ "$output" = steering ]
}

@test "floor: size — exactly size_cap passes, one more gives size, a 3-byte code point counts 3" {
  local n
  _cand 'Body.'
  n="$(wc -c < "$C")"
  TRUST_VAL[size_cap]="$n"
  run --separate-stderr floor_run "$C"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  TRUST_VAL[size_cap]="$((n - 1))"
  run --separate-stderr floor_run "$C"
  [ "$output" = size ]
  [ "$(_diag)" = "size: $n bytes staged, size_cap is $((n - 1))
$REMEDY_SIZE
$REMEDY_LAST" ]
  # One code point of three bytes (U+20AC) over a cap of n + 2 is over.
  _cand $'Body.\xe2\x82\xac'
  [ "$(wc -c < "$C")" -eq "$((n + 3))" ]
  TRUST_VAL[size_cap]="$((n + 2))"
  run --separate-stderr floor_run "$C"
  [ "$output" = size ]
  TRUST_VAL[size_cap]=0
  run --separate-stderr floor_run "$C"
  [ "$output" = size ]
}

@test "floor: both fail → the token is steering and both diagnostics print" {
  _cand $'## Workflow flags\ntier: oneshot'
  TRUST_VAL[size_cap]=10
  run --separate-stderr floor_run "$C"
  [ "$status" -eq 0 ]
  [ "$output" = steering ]
  [ "$(_diag)" = "steering: '## Workflow flags' key 'tier' on body line 2 is not listed in allowed_steering
size: $(wc -c < "$C") bytes staged, size_cap is 10
$REMEDY_LISTABLE
$REMEDY_SIZE
$REMEDY_LAST" ]
}

@test "floor: a label shaped like a body entry quarantines" {
  local l
  _allow 'tier: oneshot' 'tier: opus-checking'
  for l in 'tier: oneshot' 'tier: opus-checking'; do
    _cand 'Body.' "$l"
    run --separate-stderr floor_run "$C"
    [ "$output" = steering ] || { echo "label '$l' passed" >&2; return 1; }
    [[ "$(_diag)" == *"$REMEDY_UNLISTABLE"* ]]
  done
}

@test "floor: each remedy line prints only for its class" {
  _cand 'Body.'
  TRUST_VAL[size_cap]=10
  run --separate-stderr floor_run "$C"
  [ "$output" = size ]
  [[ "$stderr" != *"allowed_steering"* ]]
  TRUST_VAL[size_cap]=65536
  _cand $'## Workflow flags\nzz-unknown: 1'
  run --separate-stderr floor_run "$C"
  [[ "$(_diag)" == *"$REMEDY_UNLISTABLE"* ]]
  [[ "$(_diag)" != *"$REMEDY_LISTABLE"* ]]
  [[ "$(_diag)" != *"$REMEDY_SIZE"* ]]
}

@test "floor: glob characters are not patterns" {
  local v
  _allow 'tier: oneshot'
  for v in 'one*' '?neshot' '[o]neshot'; do
    _cand $'## Workflow flags\ntier: '"$v"
    run --separate-stderr floor_run "$C"
    [ "$output" = steering ] || { echo "'tier: $v' passed" >&2; return 1; }
  done
  _allow 'tier:check-fable'
  _cand 'Body.' 'tier:check-*'
  run --separate-stderr floor_run "$C"
  [ "$output" = steering ]
}

@test "floor: cannot run → rc 3, no token" {
  run --separate-stderr floor_run "$BATS_TEST_TMPDIR/missing.md"
  [ "$status" -eq 3 ]
  [ "$output" = "" ]
  _cand 'Body.'
  unset 'TRUST_VAL[size_cap]'
  run --separate-stderr floor_run "$C"
  [ "$status" -eq 3 ]
  [ "$output" = "" ]
  TRUST_VAL[size_cap]='1e9'
  run --separate-stderr floor_run "$C"
  [ "$status" -eq 3 ]
  TRUST_VAL[size_cap]='12345678901'
  run --separate-stderr floor_run "$C"
  [ "$status" -eq 3 ]
}

@test "floor: a reader that fails is could-not-run, never an empty result" {
  # A hostile candidate: unlisted steering in the body and in a label. If a
  # failed reader read as "no rows", it would pass; it must be rc 3.
  _cand $'## Workflow flags\ntier: oneshot'
  flags_enumerate() { return 5; }
  run --separate-stderr floor_run "$C"
  [ "$status" -eq 3 ] || { echo "enumerate fails: rc $status out '$output'" >&2; return 1; }
  [ "$output" = "" ]
  unset -f flags_enumerate
  # shellcheck source=/dev/null
  source "$PLUGIN_ROOT/scripts/lib/flags.sh"
  _cand 'Body.' 'tier:check-haiku'
  issue_labels() { return 4; }
  run --separate-stderr floor_run "$C"
  [ "$status" -eq 3 ] || { echo "issue_labels fails: rc $status out '$output'" >&2; return 1; }
  [ "$output" = "" ]
}

@test "floor: a failing check wins over one that cannot run" {
  _cand $'## Workflow flags\ntier: oneshot'
  TRUST_VAL[size_cap]='bogus'
  run --separate-stderr floor_run "$C"
  [ "$status" -eq 0 ]
  [ "$output" = steering ]
}

# _forms: every stderr line is one of the fixed diagnostic forms.
_forms() {
  local line re
  re="^(steering: '## Workflow flags' key '(tier|research|spike|implementation-model|checking-model)' on body line [0-9]+ is not listed in allowed_steering"
  re+="|steering: an unrecognised '## Workflow flags' key on body line [0-9]+ cannot be listed"
  re+="|steering: 'tier:' label [0-9]+ of [0-9]+ is not listed in allowed_steering"
  re+="|size: [0-9]+ bytes staged, size_cap is [0-9]+"
  re+="|for the operator: .*)$"
  local diag
  diag="$(_diag)" || return 1   # an unprefixed line (a tool's own) fails here
  while IFS= read -r line; do
    [[ "$line" =~ $re ]] || { echo "unexpected line: $line" >&2; return 1; }
  done <<<"$diag"
}

@test "floor: diagnostics carry no ticket byte" {
  _cand $'## Workflow flags\nSENTINEL-key: x\ntier: SENTINEL-value\nchecking-model: opus SENTINEL' 'tier:check-SENTINEL, tier:SENTINEL, SENTINEL-plain'
  TRUST_VAL[size_cap]=10
  run --separate-stderr floor_run "$C"
  [ "$output" = steering ]
  [[ "$stderr" != *SENTINEL* ]]
  _forms
}

@test "floor: diagnostics carry no ticket byte — invalid UTF-8 and a NUL, under each awk" {
  local impl shim="$BATS_TEST_TMPDIR/awkshim"
  printf '# acme/widgets#7 — Demo\n\n- State: open\n- Author: @alice\n- Labels: tier:\xff\x00SENTINEL\n- URL: u\n- Created: \n\n---\n\n## Workflow flags\ntier: one\x00shot SENTINEL\xfe\nzz\xff-key: SENTINEL\nresearch: \x00SENTINEL\xc3\x28\n\n---\n\n## Comments (0)\n' > "$C"
  mkdir -p "$shim"
  for impl in awk "LC_ALL=C awk" mawk; do
    if [ "$impl" = mawk ]; then
      command -v mawk >/dev/null || continue
      printf '#!/usr/bin/env bash\nexec mawk "$@"\n' > "$shim/awk"
      chmod +x "$shim/awk"
      PATH="$shim:$PATH" run --separate-stderr floor_run "$C"
    elif [ "$impl" = "LC_ALL=C awk" ]; then
      LC_ALL=C run --separate-stderr floor_run "$C"
    else
      run --separate-stderr floor_run "$C"
    fi
    [ "$status" -eq 0 ] || { echo "$impl: rc $status" >&2; return 1; }
    [ "$output" = steering ] || { echo "$impl: token '$output'" >&2; return 1; }
    [[ "$stderr" != *SENTINEL* ]] || { echo "$impl: sentinel on stderr" >&2; return 1; }
    _forms || { echo "$impl: a tool-printed line" >&2; return 1; }
  done
}

@test "floor: a NUL beside a TAB in a value is read as the scaffold reads it (review I1)" {
  # bash drops the NUL on both sides; the floor must then keep the TAB that
  # flags_get keeps, so a value the scaffold would refuse is never listed.
  _allow 'tier: oneshot' 'checking-model: fable'
  local v
  for v in 'tier:\x00\toneshot' 'tier: oneshot\t\x00' 'checking-model:\x00\tfable'; do
    printf '# acme/widgets#7 — Demo\n\n- State: open\n- Author: @alice\n- Labels: \n- URL: u\n- Created: \n\n---\n\n## Workflow flags\n%b\n\n---\n\n## Comments (0)\n' "$v" > "$C"
    run --separate-stderr floor_run "$C"
    [ "$status" -eq 0 ] || { echo "$v: rc $status" >&2; return 1; }
    [ "$output" = steering ] || { echo "$v: token '$output'" >&2; return 1; }
    [[ "$(_diag)" == *"$REMEDY_UNLISTABLE"* ]] || { echo "$v: no unlistable remedy" >&2; return 1; }
  done
}
