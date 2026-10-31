#!/usr/bin/env bats
# backend-contract.bats — aggregator that runs the per-backend contract
# suites in a known order and prints a one-line summary per backend.

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

setup() {
  BATS_DIR="${BATS_TEST_DIRNAME}"
}

run_backend_suite() {
  local backend="$1"
  local file="${BATS_DIR}/backend-${backend}.bats"
  [ -f "$file" ] || { echo "missing: $file" >&2; return 1; }
  run bats "$file"
  printf '[contract:%s] %s\n' "$backend" "$status" >&2
  return "$status"
}

@test "contract: github backend" {
  run_backend_suite github
}

@test "contract: gitlab backend" {
  run_backend_suite gitlab
}

@test "contract: jira backend" {
  run_backend_suite jira
}

@test "contract: custom-stub backend" {
  run_backend_suite custom
}

@test "contract: every issue backend answers issue-list without a repo with 1 or 78, never 2 (#706)" {
  local f n=0
  for f in "${BATS_DIR}/../scripts/issue/"*.sh; do
    n=$((n + 1))
    run "$f" issue-list
    [ "$status" -eq 1 ] || [ "$status" -eq 78 ] || {
      echo "$(basename "$f") issue-list without a repo: status $status" >&2; false; }
  done
  [ "$n" -eq 4 ]
}

@test "contract: every issue backend answers events, comment-records and whoami without args as its status allows (#712)" {
  local f n=0 v b
  for f in "${BATS_DIR}/../scripts/issue/"*.sh; do
    n=$((n + 1))
    b="$(basename "$f")"
    for v in events comment-records whoami; do
      run "$f" "$v"
      case "$b" in
        github.sh) [ "$status" -eq 1 ] ;;
        custom.sh) [ "$status" -eq 78 ] ;;
        # Not implemented yet (#900): unknown verb, or a stub's 78.
        *) [ "$status" -eq 2 ] || [ "$status" -eq 78 ] ;;
      esac || { echo "$b $v without args: status $status" >&2; false; }
    done
  done
  [ "$n" -eq 4 ]
}

@test "contract: every issue backend's events --kinds is 78, 2 or D-g-well-formed (#712)" {
  local f n=0 b want re kinds order
  want="$(printf '%s\t%s\n' created full edited-title full edited-body full \
    edited-comment full deleted-comment detail-unknown labeled full \
    unlabeled full transitioned full assigned full unassigned full commented full)"
  re=$'^(created|edited-title|edited-body|edited-comment|deleted-comment|labeled|unlabeled|transitioned|assigned|unassigned|commented)\t(full|last-edit-only|actor-unknown|detail-unknown)$'
  order="created edited-title edited-body edited-comment deleted-comment labeled unlabeled transitioned assigned unassigned commented"
  for f in "${BATS_DIR}/../scripts/issue/"*.sh; do
    n=$((n + 1))
    b="$(basename "$f")"
    run "$f" events --kinds o/r
    case "$b" in
      github.sh)
        [ "$status" -eq 0 ]
        [ "$output" = "$want" ]
        local line
        for line in "${lines[@]}"; do [[ "$line" =~ $re ]]; done
        kinds="$(printf '%s\n' "$output" | cut -f1 | tr '\n' ' ')"
        [ "$kinds" = "$order " ]
        ;;
      custom.sh) [ "$status" -eq 78 ] ;;
      *) [ "$status" -eq 2 ] || [ "$status" -eq 78 ] \
           || { echo "$b events --kinds: status $status" >&2; false; } ;;
    esac
  done
  [ "$n" -eq 4 ]
}
