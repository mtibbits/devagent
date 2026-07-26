#!/usr/bin/env bash
# scripts/analyze-shellcheck.sh — #55: the bash analyzer family for step 13.
# Diff-scoped: shellcheck --severity=warning runs once over the shell files
# changed vs baseline (working-tree endpoint, matching static_analysis_diff.py's
# deliberate choice so uncommitted review-fix edits stay visible), and a finding
# is NEW iff its line falls inside a changed hunk's new-side range — the same
# novelty gate as the C path's filter_novel(). No baseline run, no worktree.
# Report-not-fail: new findings are surfaced in the artifact; failure semantics
# for step 13 are #117's remit. Every git call is -C anchored (cwd resets are a
# known hazard and the origin of this issue's sibling CWD bug).
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/active.sh"

project="${1:-}"
[ -n "$project" ] || die "project required"
config_is_project "$project" || die "unknown project '$project'"

issue_arg="${2:-}"
if [ -z "$issue_arg" ]; then
    # #240: mutating steps never act on a scan-GUESSED issue (the scan tier
    # can adopt a parked issue's checklist) — pin/state only, else die.
    # (stderr NOT suppressed: an invalid pin must die loudly here, F6.)
    active_resolve_issue_src "$project" || true
    if [ -z "$ACTIVE_RESOLVED_ISSUE" ] || [ "$ACTIVE_ISSUE_RESOLVED_FROM" = "scan" ]; then
        die "no active issue and no issue arg"
    fi
    issue_arg="$ACTIVE_RESOLVED_ISSUE"
fi

issue_dir="$(issue_context_dir "$project" "$issue_arg" 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "issue_dir not set or missing"

command -v shellcheck >/dev/null 2>&1 \
    || die "shellcheck not found on PATH"

baseline="$(state_ctx_get "$project" baseline_sha "$issue_arg" 2>/dev/null || true)"
[ -n "$baseline" ] || baseline="$(config_get_project_field "$project" default_baseline 2>/dev/null || true)"
[ -n "$baseline" ] || die "no baseline_sha in state and no default_baseline in config"

source_dir="$(config_get_project_field "$project" source_dir)"
[ -d "$source_dir" ] || die "source_dir missing: $source_dir"

mkdir -p "$issue_dir/analysis"
out="$issue_dir/analysis/$(date_tag)-shellcheck.txt"

# Scope: shell files changed baseline→working tree. --diff-filter=d drops
# deletions (shellcheck on a missing path is a hard exit-2); the -f filter is
# belt-and-braces for rename halves and races.
#
# #314: capture the diff EXPLICITLY — not via `< <(...)`, whose non-zero exit is
# invisible — so an unresolvable baseline DIES loud instead of yielding an empty
# scope and a vacuous "0 findings" pass (the #117 class, in the shellcheck family
# devagent itself runs). Plain `git diff` (no --exit-code) exits non-zero only on
# ERROR, never merely because diffs exist, so `|| die` fires on exactly the
# bad-ref case; an empty result (no shell files changed) falls through to the
# legitimate empty-scope path below.
diff_list="$(git -C "$source_dir" diff --name-only --diff-filter=d "$baseline" \
                 -- '*.sh' '*.bats' '*.bash')" \
    || die "git diff against baseline '$baseline' failed (unresolvable ref? — no analysis performed; step 13 left unmarked, fix the baseline and re-run)"
files=()
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$source_dir/$f" ] && files+=("$f")
done <<< "$diff_list"

{
    echo "=== shellcheck (diff-scoped) ==="
    echo "date: $(date_tag)"
    echo "baseline: $baseline"
    echo "scope: ${#files[@]} file(s)"
    for f in "${files[@]}"; do echo "  $f"; done
} > "$out"

if [ "${#files[@]}" -eq 0 ]; then
    echo "NEW findings: 0 (empty scope)" >> "$out"
    cat "$out"
    exit 0
fi

# All findings at severity=warning, gcc format: file:line:col: level: msg [SCnnnn]
# (shellcheck exiting 1 just means it has findings — data here, not failure.)
findings="$(cd "$source_dir" && shellcheck --severity=warning -f gcc "${files[@]}" || true)"

# New-side hunk ranges per file ("start end" pairs) from a -U0 diff; a finding
# is NEW iff its line falls in one of its file's ranges (filter_novel semantics).
new_findings=""
for f in "${files[@]}"; do
    # The count-0 skip must be an `if` — a `[ ... ] &&` tail on the LAST hunk
    # (pure deletion, `+c,0`) would exit the $() nonzero and set -e kills us.
    ranges="$(git -C "$source_dir" diff -U0 "$baseline" -- "$f" \
        | sed -n 's/^@@ -[0-9,]* +\([0-9][0-9,]*\) @@.*/\1/p' \
        | while IFS=, read -r start count; do
              count="${count:-1}"
              if [ "$count" -gt 0 ]; then
                  echo "$start $((start + count - 1))"
              fi
          done)"
    [ -n "$ranges" ] || continue
    # Fixed-string prefix match: the filename must not act as a regex
    # (`a.b.sh` would cross-match `axb.sh` and inflate NEW).
    file_hits="$(printf '%s\n' "$findings" | awk -v p="${f}:" 'index($0, p) == 1' || true)"
    [ -n "$file_hits" ] || continue
    while IFS= read -r hit; do
        line="$(printf '%s' "$hit" | cut -d: -f2)"
        while read -r start end; do
            if [ "$line" -ge "$start" ] && [ "$line" -le "$end" ]; then
                new_findings+="${hit}"$'\n'
                break
            fi
        done <<< "$ranges"
    done <<< "$file_hits"
done

total_count="$(printf '%s' "$findings" | grep -c ':' || true)"
new_count="$(printf '%s' "$new_findings" | grep -c ':' || true)"

{
    echo "total findings in scoped files: $total_count"
    echo "NEW findings: $new_count (on changed lines vs baseline)"
    if [ "$new_count" -gt 0 ]; then
        printf '%s' "$new_findings"
        echo "-- review before the commit gate (#117 owns hard-fail semantics)"
    fi
} >> "$out"
cat "$out"
