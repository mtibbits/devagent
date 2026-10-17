#!/usr/bin/env bats

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

setup() {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/backend-common.sh"
  # #774: the paging tests below serve pages through this stub. No earlier test
  # calls bc_curl, so the override does not touch them.
  bc_curl() { _stub_bc_curl "$@"; }
  : > "$BATS_TEST_TMPDIR/calls"
}

# #774 stub for bc_curl <method> <url> …: logs the URL to $BATS_TEST_TMPDIR/calls
# (a file, because the helpers call it inside $(…)) and prints a body chosen by
# $STUB_MODE. After 20 calls it returns 97, so an unfixed helper that would loop
# forever ends red instead of hanging.
_stub_n() { if [[ "$2" =~ [?\&]$1=([0-9]+) ]]; then echo "${BASH_REMATCH[1]}"; else echo 0; fi; }
_gl_items() { jq -cn --argjson o "$1" --argjson n "$2" '[range($n) | {id: (. + 1 + $o)}]'; }
_jira_body() {
  jq -cn --argjson s "$1" --argjson t "$2" --argjson n "$3" \
    '{startAt: $s, total: $t, comments: [range($n) | {id: (. + 1 + $s)}]}'
}
_stub_bc_curl() {
  local url="$2" p s
  echo "$url" >> "$BATS_TEST_TMPDIR/calls"
  if [ "$(_calls)" -gt 20 ]; then echo "stub: breaker after 20 calls" >&2; return 97; fi
  p="$(_stub_n page "$url")"; s="$(_stub_n startAt "$url")"
  case "${STUB_MODE:-}" in
    gl-same)         _gl_items 0 100 ;;
    gl-distinct)     _gl_items $(( (p - 1) * 100 )) 100 ;;
    gl-short2)       if [ "$p" -eq 2 ]; then _gl_items 100 50; else _gl_items $(( (p - 1) * 100 )) 100; fi ;;
    gl-cycle)        if [ "$p" -eq 3 ]; then _gl_items 0 100; else _gl_items $(( (p - 1) * 100 )) 100; fi ;;
    gl-two-full)     if [ "$p" -ge 3 ]; then echo '[]'; else _gl_items $(( (p - 1) * 100 )) 100; fi ;;
    jira-same)       _jira_body 0 100000 100 ;;
    jira-distinct)   _jira_body "$s" 100000 100 ;;
    jira-short2)     if [ "$s" -ge 100 ]; then _jira_body "$s" 150 50; else _jira_body "$s" 150 100; fi ;;
    jira-cycle)      if [ "$s" -eq 200 ]; then _jira_body 0 100000 100; else _jira_body "$s" 100000 100; fi ;;
    html)            echo '<html><body>Sign in</body></html>' ;;
    jira-nocomments) echo '{"errorMessages":["proxy says no"]}' ;;
    jira-badtotal)   echo '{"total":"many","comments":[{"id":1}]}' ;;
    *) echo "stub: unknown STUB_MODE '${STUB_MODE:-}'" >&2; return 99 ;;
  esac
}
_calls() { wc -l < "$BATS_TEST_TMPDIR/calls" | tr -d ' '; }
_capped_caller() { local BC_MAX_PAGES=2; local rc=0; "$@" >/dev/null || rc=$?; echo "rc=$rc max=$BC_MAX_PAGES"; }

@test "bc_have_cli returns 0 when command exists" {
  bc_have_cli bash
}

@test "bc_have_cli returns 1 when command missing" {
  run bc_have_cli definitely-not-a-real-command-xyz
  [ "$status" -eq 1 ]
}

@test "bc_die_not_implemented exits 78 with message" {
  run bash -c "source scripts/lib/backend-common.sh; bc_die_not_implemented custom create"
  [ "$status" -eq 78 ]
  [[ "$output" == *"not implemented"* ]]
  [[ "$output" == *"custom"* ]]
  [[ "$output" == *"create"* ]]
}

@test "bc_emit_fetch_header produces spec-shape markdown" {
  run bc_emit_fetch_header "foo/bar" "42" "Sample title" "open" "alice" "bug,perf" "https://example/42"
  [ "$status" -eq 0 ]
  [[ "$output" == *"# foo/bar#42 — Sample title"* ]]
  [[ "$output" == *"- State: open"* ]]
  [[ "$output" == *"- Author: @alice"* ]]
  [[ "$output" == *"- Labels: bug,perf"* ]]
  [[ "$output" == *"- URL: https://example/42"* ]]
}

@test "bc_emit_comment produces spec-shape comment block" {
  run bc_emit_comment "reviewer" "2026-05-12" "Looks good"
  [ "$status" -eq 0 ]
  [[ "$output" == *"### @reviewer · 2026-05-12"* ]]
  [[ "$output" == *"Looks good"* ]]
}

@test "bc_gitlab_paginate returns 6 when a page repeats the one before it (#774)" {
  STUB_MODE=gl-same
  run bc_gitlab_paginate https://gl.invalid/x
  [ "$status" -eq 6 ]
  [ "$(_calls)" -eq 2 ]
  [[ "$output" == *"bc_gitlab_paginate: page 2 of https://gl.invalid/x repeats page 1"* ]]
}

@test "bc_gitlab_paginate returns 6 at its page cap (#774)" {
  export DEVAGENT_BC_MAX_PAGES=3
  STUB_MODE=gl-distinct
  run bc_gitlab_paginate https://gl.invalid/x
  [ "$status" -eq 6 ]
  [ "$(_calls)" -eq 3 ]
  [[ "$output" == *"stopped at its cap of 3 pages"* ]]
}

@test "bc_gitlab_paginate returns 5 on a 2xx page that is not JSON (#774)" {
  STUB_MODE=html
  run bc_gitlab_paginate https://gl.invalid/x
  [ "$status" -eq 5 ]
  [ "$(_calls)" -eq 1 ]
  [[ "$output" == *"bc_gitlab_paginate: page 1 of https://gl.invalid/x is not a JSON array"* ]]
}

@test "bc_jira_paginate returns 6 when a page repeats the one before it (#774)" {
  STUB_MODE=jira-same
  run bc_jira_paginate https://jira.invalid/c
  [ "$status" -eq 6 ]
  [ "$(_calls)" -eq 2 ]
  [[ "$output" == *"bc_jira_paginate: page at startAt=100 of https://jira.invalid/c repeats the page at startAt=0"* ]]
}

@test "bc_jira_paginate returns 6 at its page cap (#774)" {
  export DEVAGENT_BC_MAX_PAGES=3
  STUB_MODE=jira-distinct
  run bc_jira_paginate https://jira.invalid/c
  [ "$status" -eq 6 ]
  [ "$(_calls)" -eq 3 ]
  [[ "$output" == *"stopped at its cap of 3 pages"* ]]
}

@test "bc_jira_paginate returns 5 on a 2xx page that is not JSON (#774)" {
  STUB_MODE=html
  run bc_jira_paginate https://jira.invalid/c
  [ "$status" -eq 5 ]
  [ "$(_calls)" -eq 1 ]
  [[ "$output" == *"bc_jira_paginate: page at startAt=0 of https://jira.invalid/c lacks a .comments array"* ]]
}

@test "bc_jira_paginate returns 5 on a JSON object without .comments (#774)" {
  STUB_MODE=jira-nocomments
  run bc_jira_paginate https://jira.invalid/c
  [ "$status" -eq 5 ]
  [[ "$output" == *"bc_jira_paginate: page at startAt=0 of https://jira.invalid/c lacks a .comments array"* ]]
}

@test "bc_jira_paginate returns 5 on a .total that is not a count (#774)" {
  STUB_MODE=jira-badtotal
  run bc_jira_paginate https://jira.invalid/c
  [ "$status" -eq 5 ]
  [[ "$output" == *"bc_jira_paginate: page at startAt=0 of https://jira.invalid/c has a .total that is not a count"* ]]
}

@test "a caller's local BC_MAX_PAGES beats DEVAGENT_BC_MAX_PAGES and survives the call (#774)" {
  export DEVAGENT_BC_MAX_PAGES=1000
  STUB_MODE=gl-distinct
  run _capped_caller bc_gitlab_paginate https://gl.invalid/x
  [[ "$output" == *"rc=6 max=2"* ]]
  [[ "$output" == *"stopped at its cap of 2 pages"* ]]
  [ "$(_calls)" -eq 2 ]
  : > "$BATS_TEST_TMPDIR/calls"
  STUB_MODE=jira-distinct
  run _capped_caller bc_jira_paginate https://jira.invalid/c
  [[ "$output" == *"rc=6 max=2"* ]]
  [[ "$output" == *"stopped at its cap of 2 pages"* ]]
  [ "$(_calls)" -eq 2 ]
}

@test "the helpers never assign BC_MAX_PAGES (#774)" {
  unset BC_MAX_PAGES
  export DEVAGENT_BC_MAX_PAGES=2
  STUB_MODE=gl-same
  bc_gitlab_paginate https://gl.invalid/x >/dev/null 2>&1 || true
  [ -z "${BC_MAX_PAGES+x}" ]
  STUB_MODE=jira-same
  bc_jira_paginate https://jira.invalid/c >/dev/null 2>&1 || true
  [ -z "${BC_MAX_PAGES+x}" ]
}

@test "a page cap that is not a positive integer returns 1 before any request (#774)" {
  local cap
  for cap in 0 1k; do
    export DEVAGENT_BC_MAX_PAGES="$cap"
    : > "$BATS_TEST_TMPDIR/calls"
    STUB_MODE=gl-distinct
    run bc_gitlab_paginate https://gl.invalid/x
    [ "$status" -eq 1 ]
    [ ! -s "$BATS_TEST_TMPDIR/calls" ]
    [[ "$output" == *"is not a positive integer"* ]]
    STUB_MODE=jira-distinct
    run bc_jira_paginate https://jira.invalid/c
    [ "$status" -eq 1 ]
    [ ! -s "$BATS_TEST_TMPDIR/calls" ]
    [[ "$output" == *"is not a positive integer"* ]]
  done
}

@test "a short page inside the cap ends the walk (#774 control)" {
  export DEVAGENT_BC_MAX_PAGES=2
  STUB_MODE=gl-short2
  run bc_gitlab_paginate https://gl.invalid/x
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq length)" -eq 150 ]
  [ "$(_calls)" -eq 2 ]
  : > "$BATS_TEST_TMPDIR/calls"
  STUB_MODE=jira-short2
  run bc_jira_paginate https://jira.invalid/c
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq length)" -eq 150 ]
  [ "$(_calls)" -eq 2 ]
  # The documented exact-multiple rule: two full pages under a cap of 2 never
  # request the page that would end the walk, so they return 6.
  : > "$BATS_TEST_TMPDIR/calls"
  STUB_MODE=gl-two-full
  run bc_gitlab_paginate https://gl.invalid/x
  [ "$status" -eq 6 ]
  [ "$(_calls)" -eq 2 ]
  [[ "$output" == *"stopped at its cap of 2 pages"* ]]
}

@test "both helpers refuse a page seen earlier in the walk, not only the one before it (#774)" {
  STUB_MODE=gl-cycle
  run bc_gitlab_paginate https://gl.invalid/x
  [ "$status" -eq 6 ]
  [ "$(_calls)" -eq 3 ]
  [[ "$output" == *"bc_gitlab_paginate: page 3 of https://gl.invalid/x repeats page 1"* ]]
  : > "$BATS_TEST_TMPDIR/calls"
  STUB_MODE=jira-cycle
  run bc_jira_paginate https://jira.invalid/c
  [ "$status" -eq 6 ]
  [ "$(_calls)" -eq 3 ]
  [[ "$output" == *"bc_jira_paginate: page at startAt=200 of https://jira.invalid/c repeats the page at startAt=0"* ]]
}
