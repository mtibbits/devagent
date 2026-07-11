#!/usr/bin/env bash
# scripts/run-suite.sh — mechanism 2/3 (#359; design: Issue-333/designs/
# m2m3-preship-evidence.md, normative). The canonical suite runner + provenance
# artifact. Runs bats + pytest (per tree presence) with the hermetic env-unset
# baked in, and writes <issue-dir>/analysis/<date>-suite-count.txt:
#     head: <sha>  dirty: yes|no
#     bats: <ok>/<plan> notok=<n>
#     pytest: <passed> passed, <failed> failed
# Counts come from `grep -c '^ok '` + the `1..N` plan line — NEVER the tail (#85
# shipped a tail-derived false count). preship-evidence.sh cross-checks mr.md
# against this artifact (verification #4).
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=lib/paths.sh
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
# shellcheck source=lib/io.sh
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
# shellcheck source=lib/config.sh
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
# shellcheck source=lib/state.sh
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
# shellcheck source=lib/active.sh
. "$DEVAGENT_ROOT/scripts/lib/active.sh"

: "${DEVAGENT_GIT:=git}"

project="$(active_resolve_project "${1:-}" 2>/dev/null || true)"
[ -n "$project" ] || die "run-suite: project required (no arg and no active project)"
config_is_project "$project" || die "run-suite: unknown project '$project'"
issue_dir="$(issue_context_dir "$project" 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "run-suite: issue_dir not set or missing"
source_dir="$(config_get_project_field "$project" source_dir)"
[ -d "$source_dir" ] || die "run-suite: source_dir missing: $source_dir"

cd "$source_dir"
head="$("$DEVAGENT_GIT" rev-parse HEAD 2>/dev/null || true)"
[ -n "$head" ] || die "run-suite: could not resolve HEAD in $source_dir"
if [ -n "$("$DEVAGENT_GIT" status --porcelain 2>/dev/null)" ]; then dirty=yes; else dirty=no; fi

bats_line="bats: (none)"
if compgen -G "tests/*.bats" >/dev/null 2>&1; then
  tap="$(env -u DEVAGENT_ACTIVE_PROJECT -u DEVAGENT_ACTIVE_ISSUE bats --tap tests/ 2>&1 || true)"
  ok="$(printf '%s\n' "$tap"    | grep -c '^ok '     || true)"
  notok="$(printf '%s\n' "$tap" | grep -c '^not ok ' || true)"
  plan="$(printf '%s\n' "$tap"  | sed -n 's/^1\.\.\([0-9][0-9]*\)$/\1/p' | tail -1)"
  [ -n "$plan" ] || die "run-suite: no bats plan line (1..N) — bats did not run cleanly"
  # #406: bats --tap emits the plan (1..N) up front, so a killed/crashed run leaves
  # ok+notok < plan while still looking well-formed. Recording ok/plan without this
  # invariant lets a truncated run pass as "green" (the #85 never-trust-the-tail
  # class, one layer up). Fail loud — a truncated suite must not ship evidence.
  [ "$((ok + notok))" -eq "$plan" ] \
    || die "run-suite: suite truncated — accounted for $((ok + notok)) of $plan planned tests (ok=$ok notok=$notok); a killed/crashed bats run leaves ok+notok<plan"
  bats_line="bats: $ok/$plan notok=$notok"
fi

pytest_line="pytest: (none)"
if compgen -G "tests/test_*.py" >/dev/null 2>&1; then
  pout="$(env -u DEVAGENT_ACTIVE_PROJECT -u DEVAGENT_ACTIVE_ISSUE python3 -m pytest tests/ -q 2>&1 || true)"
  passed="$(printf '%s\n' "$pout" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) passed.*/\1/p' | tail -1)"
  failed="$(printf '%s\n' "$pout" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) failed.*/\1/p' | tail -1)"
  pytest_line="pytest: ${passed:-0} passed, ${failed:-0} failed"
fi

date_str="$(date +%F)"
mkdir -p "$issue_dir/analysis"
artifact="$issue_dir/analysis/${date_str}-suite-count.txt"
{
  echo "head: $head  dirty: $dirty"
  echo "$bats_line"
  echo "$pytest_line"
} > "$artifact"
echo "run-suite: wrote $artifact ($bats_line; $pytest_line; dirty=$dirty)" >&2
