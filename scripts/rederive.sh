#!/usr/bin/env bash
# scripts/rederive.sh — mechanism 5 (#361; design: Issue-333/designs/
# m5-rederive-gate.md, normative). A small ADVISORY prober: extract the code
# inputs an issue.md names and re-derive them at HEAD, so a plan is not written
# against a stale premise (7 issues were — #274's `PR:` line existed nowhere;
# #116 sat queued while #276 landed option B). Writes
# <issue-dir>/analysis/<date>-rederive.txt; the MODEL judges the ✗s (never blocks).
# Fails loud on git errors (#117); 0 extractable inputs → an explicit line (visible).
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
[ -n "$project" ] || die "rederive: project required (no arg and no active project)"
config_is_project "$project" || die "rederive: unknown project '$project'"
issue_arg="${2:-}"
issue_dir="$(issue_context_dir "$project" "$issue_arg" 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "rederive: issue_dir not set or missing"
issue_md="$issue_dir/issue.md"
[ -f "$issue_md" ] || die "rederive: no issue.md at $issue_md (run /devagent:pull first)"
source_dir="$(config_get_project_field "$project" source_dir)"
[ -d "$source_dir/.git" ] || [ -f "$source_dir/.git" ] || die "rederive: source_dir is not a git repo: $source_dir"

# Filing date: prefer the tracker's Created: header (pull writes it, #361); fall
# back to the checklist's Created: (scaffold time — noted in the artifact).
created="$(sed -n 's/^- Created:[[:space:]]*\([0-9][0-9-]*\).*/\1/p' "$issue_md" | head -1)"
date_note=""
if [ -z "$created" ]; then
  created="$(sed -n 's/.*[Cc]reated:[[:space:]]*\([0-9][0-9-]*\).*/\1/p' "$issue_dir/checklist.md" 2>/dev/null | head -1)"
  [ -n "$created" ] && date_note=" (fallback: checklist scaffold date, not the tracker filing date)"
fi

# Extract backtick tokens that look like code inputs.
mapfile -t toks < <(grep -oE '`[^`]+`' "$issue_md" 2>/dev/null | tr -d '`' | sort -u || true)
declare -a files=() filelines=() funcs=()
for t in "${toks[@]:-}"; do
  [ -n "$t" ] || continue
  if   printf '%s' "$t" | grep -qE '^[A-Za-z0-9_./-]+:[0-9]+$'; then filelines+=("$t")
  elif printf '%s' "$t" | grep -qE '^[A-Za-z0-9_][A-Za-z0-9_]*\(\)$'; then funcs+=("$t")
  elif printf '%s' "$t" | grep -qE '^[A-Za-z0-9_./-]+\.[A-Za-z0-9]+$'; then files+=("$t")
  fi
done
# file:line cites also contribute their file to the exists/since set.
for fl in "${filelines[@]:-}"; do [ -n "$fl" ] && files+=("${fl%%:*}"); done
mapfile -t files < <(printf '%s\n' "${files[@]:-}" | grep -v '^$' | sort -u || true)

date_str="$(date +%F)"
mkdir -p "$issue_dir/analysis"
artifact="$issue_dir/analysis/${date_str}-rederive.txt"

age_days="?"
if [ -n "$created" ]; then
  c_epoch="$(date -d "$created" +%s 2>/dev/null || true)"
  [ -n "$c_epoch" ] && age_days="$(( ( $(date +%s) - c_epoch ) / 86400 ))"
fi

{
  echo "rederive — $date_str"
  echo "issue: $(basename "$issue_dir")   filing date: ${created:-unknown}${date_note}   age: ${age_days}d"
  echo "note: assumes the local issue.md is current (pull owns refetch)."
  echo "---"
  if [ "${#files[@]}" -eq 0 ] && [ "${#funcs[@]}" -eq 0 ]; then
    echo "0 named inputs found (heuristic extracted nothing — derive inputs by hand)."
  else
    if [ "${#files[@]}" -gt 0 ]; then
      echo "## Named files (exists at HEAD?)"
      for f in "${files[@]}"; do
        if "$DEVAGENT_GIT" -C "$source_dir" cat-file -e "HEAD:$f" 2>/dev/null; then
          echo "  ✓ $f"
        else
          echo "  ✗ $f  — NOT at HEAD (falsified premise — address in Preconditions)"
        fi
      done
    fi
    if [ "${#filelines[@]}" -gt 0 ]; then
      echo "## Cited lines at HEAD (drift check)"
      for fl in "${filelines[@]}"; do
        f="${fl%%:*}"; ln="${fl##*:}"
        cur="$("$DEVAGENT_GIT" -C "$source_dir" show "HEAD:$f" 2>/dev/null | sed -n "${ln}p" || true)"
        echo "  $fl → ${cur:-<file/line absent at HEAD>}"
      done
    fi
    if [ "${#funcs[@]}" -gt 0 ]; then
      echo "## Named functions (advisory — not path-verified)"
      for fn in "${funcs[@]}"; do echo "  · $fn"; done
    fi
    if [ "${#files[@]}" -gt 0 ] && [ -n "$created" ]; then
      echo "## Merged commits touching these files since $created (what landed while queued)"
      log="$("$DEVAGENT_GIT" -C "$source_dir" log --oneline "--since=$created" -- "${files[@]}" 2>/dev/null || true)"
      if [ -n "$log" ]; then printf '%s\n' "$log" | sed 's/^/  /'; else echo "  (none)"; fi
    fi
  fi
  echo "---"
  echo "ADVISORY: the draft judges every ✗ (falsified premise → question-return or a plan delta)."
} > "$artifact"
echo "rederive: wrote $artifact (${#files[@]} files, ${#filelines[@]} line-cites)" >&2
