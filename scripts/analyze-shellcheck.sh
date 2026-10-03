#!/usr/bin/env bash
# scripts/analyze-shellcheck.sh — #55: the bash analyzer family for step 13.
# Diff-scoped: shellcheck --severity=warning runs once over the shell files
# changed vs baseline (working-tree endpoint, matching static_analysis_diff.py's
# deliberate choice so uncommitted review-fix edits stay visible) PLUS every
# untracked, non-ignored *.sh/*.bats/*.bash as a whole file (#591, matching that
# file's untracked scope), and a finding is NEW iff its line falls inside a changed
# hunk's new-side range — or anywhere in an untracked file — the same novelty gate
# as the C path's filter_novel(). No baseline run, no worktree.
# Report-not-fail: new findings are surfaced in the artifact, never a failure.
# A failed scan is different (#675): a ShellCheck status other than 0/1, or a
# failed cd into source_dir, fails step 13 loud — write-then-die, with the
# status and stderr in the artifact and no count lines.
# Every git call is -C anchored (cwd resets are a known hazard and the origin of
# this issue's sibling CWD bug).
#
# Analyzer version (#657): the artifact header's `analyzer: shellcheck <version>`
# line names the shellcheck that produced the findings — `(version unknown)` when
# `shellcheck --version` names none. Policy: the analyzer runs under the SAME
# floor as the test suite and the CI lint gate (CONTRIBUTING.md "What you need";
# the SC2314 self-tests in .githooks/pre-push and .github/workflows/shellcheck.yml).
# A floor, not a pin: versions above it can disagree on PRE-EXISTING findings
# (#550). Enforced nowhere — no runtime version gate (#657 scope): a mismatch
# surfaces only in that header line, and a below-floor or unknown stamp leaves
# the artifact's NEW-findings count unattested.
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

# Resolved once (#657): the binary whose version is stamped below IS the one
# that produces the findings, by construction rather than by a matching lookup.
sc_bin="$(command -v shellcheck 2>/dev/null)" \
    || die "shellcheck not found on PATH"
# A relative PATH entry answers with a relative path, which the findings run
# would re-resolve from source_dir after its cd: no binary there, so every
# relative-PATH run would fail loud with exit=127 (#675) — and the stamped binary
# would not be the one that scans (#657). Anchor it.
case "$sc_bin" in /*) ;; */*) sc_bin="$PWD/$sc_bin" ;; esac

# #657: name the shellcheck that produces the findings — stamped in the artifact
# header below. The output is captured whole, then parsed from a here-string: no
# producer pipe exists for the early-quitting sed to SIGPIPE under pipefail.
# `|| true` plus the fallback because there is no runtime version gate: an
# unreadable version is recorded as such, and the run goes on.
sc_version_out="$("$sc_bin" --version 2>/dev/null || true)"
sc_version="$(sed -n '/^version:/{s/^version:[[:space:]]*\([^[:space:]]*\).*/\1/p;q;}' <<< "$sc_version_out")"
[ -n "$sc_version" ] || sc_version="(version unknown)"

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
# One pathspec for BOTH scope producers — this diff and the untracked enumeration
# below (#591): a suffix added to one call and not the other would put a tracked
# file of that kind in scope while an untracked one silently stayed out.
# core.quotePath=false on both as well: --name-only QUOTES a non-ASCII name
# ("caf\303\251.sh") exactly as ls-files does, and the quoted form fails the -f
# test below and vanishes — the same silent drop, one call up (redmr 2026-09-06).
shell_pathspec=('*.sh' '*.bats' '*.bash')
diff_list="$(git -C "$source_dir" -c core.quotePath=false diff --name-only \
                 --diff-filter=d "$baseline" -- "${shell_pathspec[@]}")" \
    || die "git diff against baseline '$baseline' failed (unresolvable ref? — no analysis performed; step 13 left unmarked, fix the baseline and re-run)"
files=()
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$source_dir/$f" ] && files+=("$f")
done <<< "$diff_list"

# #591: `git diff` lists TRACKED changes only, so a brand-new *.sh that was never
# `git add`-ed produced no hunks — it never entered scope and every warning in it
# counted as pre-existing, the vacuous pass in exactly the least-reviewed file of
# the branch. Enumerate the untracked, non-ignored shell files too. READ-ONLY: no
# `git add`, no `git add -N`, no temp commit (staging is step 12's job).
# --exclude-standard honours .gitignore / .git/info/exclude / core.excludesFile as
# `git status` does, so ignored build output stays out; --full-name keeps the paths
# repo-root relative like --name-only's (ls-files prints CWD-relative by default);
# core.quotePath=false keeps a non-ASCII name from arriving QUOTED
# ("caf\303\251.sh"), which would fail the -f test below and vanish silently.
# Same `|| die` discipline as the diff above (#314): a swallowed enumeration
# failure is an empty set, which is precisely the vacuous pass being closed here —
# record-scope.sh:66 / io.sh:76 / born-red.sh:92 run this idiom with `|| true`,
# deliberately NOT copied.
untracked_list="$(git -C "$source_dir" -c core.quotePath=false ls-files --others \
                     --exclude-standard --full-name -- "${shell_pathspec[@]}")" \
    || die "git ls-files in '$source_dir' failed (no untracked enumeration performed; step 13 left unmarked, fix the repo state and re-run)"
untracked=()
declare -A is_untracked=()
while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$source_dir/$f" ] || continue
    untracked+=("$f")
    is_untracked["$f"]=1
done <<< "$untracked_list"
files+=("${untracked[@]}")

{
    echo "=== shellcheck (diff-scoped + untracked) ==="
    echo "date: $(date_tag)"
    echo "baseline: $baseline"
    echo "analyzer: shellcheck $sc_version"
    echo "scope: ${#files[@]} file(s)"
    for f in "${files[@]}"; do echo "  $f"; done
    # #591: printed only when non-empty. This line IS the shell family's
    # artifact-visible notice (the twin of static_analysis_diff.py's
    # `Untracked files (whole-file scope):` progress line) and
    # tests/analyze-shellcheck.bats pins it exactly — one line, space-joined, no
    # trailing space.
    if [ "${#untracked[@]}" -gt 0 ]; then
        echo "untracked (whole-file scope): ${untracked[*]}"
    fi
} > "$out"

if [ "${#files[@]}" -eq 0 ]; then
    echo "NEW findings: 0 (empty scope)" >> "$out"
    cat "$out"
    exit 0
fi

# All findings at severity=warning, gcc format: file:line:col: level: msg [SCnnnn]
# #675: the scan's status is classified, never swallowed. 0/1 mean the scan
# completed (1 means findings — data here, not failure); anything else, or the
# reserved 125 for a failed cd, is a failed scan: write-then-die, no counts.
# stderr is kept apart from $findings because a `:` in it would inflate the
# `grep -c ':'` count below. `--` keeps option-shaped names (`-x.sh`,
# `--rcfile=rc.sh`) from being parsed as options; `./`-prefixing was rejected
# because the fixed-string prefix match below would miss `./-x.sh`.
sc_err="$(mktemp)" || die "mktemp failed (no scan performed; step 13 left unmarked)"
trap 'rm -f "$sc_err"' EXIT
sc_cd_failed=125   # free: ShellCheck exits 0-4; bash's exec failures 126/127; signals 128+n
sc_rc=0
findings="$(exec 2>"$sc_err"
            cd "$source_dir" || exit "$sc_cd_failed"
            "$sc_bin" --severity=warning -f gcc -- "${files[@]}")" || sc_rc=$?
case "$sc_rc" in
    0|1)
        echo "shellcheck: exit=$sc_rc" >> "$out"
        cat "$sc_err" >&2
        ;;
    "$sc_cd_failed")
        {
            echo "shellcheck: not run (cd into source_dir failed)"
            cat "$sc_err"
        } >> "$out"
        cat "$out"
        die "shellcheck scan not run: cd into source_dir '$source_dir' failed → $out (no findings counted; step 13 left unmarked — fix the source_dir and re-run /devagent:analyze)"
        ;;
    *)
        {
            echo "shellcheck: exit=$sc_rc"
            if [ -n "$findings" ]; then
                printf '%s\n' "$findings"
            fi
            cat "$sc_err"
        } >> "$out"
        cat "$out"
        die "shellcheck scan FAILED (exit=$sc_rc) → $out (no findings counted; step 13 left unmarked — fix what shellcheck's stderr in the artifact names, e.g. a bad SHELLCHECK_OPTS, an unreadable or vanished file (on a shared checkout, often another session's uncommitted script: re-run once it settles), a missing binary, and re-run /devagent:analyze; to skip the analyzer for a project, set analyze = \"none\")"
        ;;
esac

# New-side hunk ranges per file ("start end" pairs) from a -U0 diff; a finding
# is NEW iff its line falls in one of its file's ranges (filter_novel semantics).
new_findings=""
for f in "${files[@]}"; do
    # Fixed-string prefix match: the filename must not act as a regex
    # (`a.b.sh` would cross-match `axb.sh` and inflate NEW).
    file_hits="$(printf '%s\n' "$findings" | awk -v p="${f}:" 'index($0, p) == 1' || true)"
    [ -n "$file_hits" ] || continue
    if [[ -n "${is_untracked[$f]:-}" ]]; then
        # #591: an untracked file has NO hunks — `git diff -U0 <baseline> -- <path>`
        # prints nothing for a path git does not track (measured), so the range
        # block below would leave $ranges empty and `continue` past it. Every line
        # of it is new, so every finding in it is NEW — the shell twin of
        # static_analysis_diff.py's whole-file range. Keyed on UNTRACKEDNESS, never
        # on "no hunks": a tracked file whose only hunks are pure deletions must
        # keep its empty range, or tool.sh's baseline SC2164 would be re-reported
        # as NEW.
        new_findings+="${file_hits}"$'\n'
        continue
    fi
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
    echo "NEW findings: $new_count (on changed lines vs baseline, or anywhere in an untracked file)"
    if [ "$new_count" -gt 0 ]; then
        printf '%s' "$new_findings"
        echo "-- review before the commit gate"
    fi
} >> "$out"
cat "$out"
