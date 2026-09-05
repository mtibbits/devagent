#!/usr/bin/env bash
# scripts/rederive.sh — mechanism 5 (#361; design: Issue-333/designs/
# m5-rederive-gate.md, normative). A small ADVISORY prober: extract the code
# inputs an issue.md names and re-derive them at HEAD, so a plan is not written
# against a stale premise (7 issues were — #274's `PR:` line existed nowhere;
# #116 sat queued while #276 landed option B). Writes
# <issue-dir>/analysis/<date>-rederive.txt; the MODEL judges the ✗s (never blocks).
# Also reports whether HEAD itself is current against default_baseline after a
# best-effort fetch, and flags a pre-branch checkout behind that base as a STALE
# CHECKOUT premise (#590: Issue-570 planned three commits behind it); a bare
# basename or path suffix is resolved against the HEAD tree before it is called
# absent.
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
# shellcheck source=lib/upstream.sh
. "$DEVAGENT_ROOT/scripts/lib/upstream.sh"

: "${DEVAGENT_GIT:=git}"

active_resolve_project_try "${1:-}" 2>/dev/null || true
project="$ACTIVE_RESOLVED_PROJECT"
[ -n "$project" ] || die "rederive: project required (no arg and no active project)"
config_is_project "$project" || die "rederive: unknown project '$project'"
active_guard_scope rederive
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

# --- Is HEAD itself current? (#590) -------------------------------------------
# The named-file probes below answer "does X exist at HEAD"; this answers "is
# HEAD the tree the branch will be cut from" (Issue-570 ran draft→improve on a
# checkout three commits behind its base and every probe said ✓). Compare
# against default_baseline after a best-effort fetch of its remote, and stamp
# which fetch branch ran so a reader can tell a fresh count from a last-known
# one. Tri-state on purpose (#243): a count, or an explicit "undetermined" with
# its reason — never a silent 0. Every revision re-runs this step ON the issue
# branch (revise.sh re-copies the draft row), where being behind the base is
# expected drift: that shape prints as ℹ, not as a premise. A #162
# .devagent-baseline marker is acknowledged by EXISTENCE only — its content is
# read by branch.sh at step 8; parsing it here could die on a non-git error,
# which this advisory prober must not do. A rev-list FAULT on a resolvable
# ref dies (#117).
base_ref="$(config_get_project_field "$project" default_baseline 2>/dev/null || true)"
marker_note=""
[ -r "$issue_dir/.devagent-baseline" ] \
  && marker_note="; a .devagent-baseline marker is present — step 8 cuts from it, this count is vs default_baseline"
head_short="$("$DEVAGENT_GIT" -C "$source_dir" rev-parse --short HEAD)" \
  || die "rederive: git rev-parse HEAD failed in $source_dir"
head_branch="$("$DEVAGENT_GIT" -C "$source_dir" rev-parse --abbrev-ref HEAD)" \
  || die "rederive: git rev-parse --abbrev-ref HEAD failed in $source_dir"
issue_branch="$(state_ctx_get "$project" branch "$issue_arg" 2>/dev/null || true)"
if [ -z "$base_ref" ]; then
  base_src="(none configured)"
  gap_line="? behind-count undetermined — no default_baseline configured for project '$project'"
else
  base_src="default_baseline"
  stale_note=""
  case "$base_ref" in
    */*)
      base_remote="${base_ref%%/*}"
      upstream_fetch "$source_dir" "$base_remote"        # skipped | ok | failed — never fatal
      case "$UPSTREAM_FETCH_STATUS" in
        ok)     fetch_note="fetch: ok" ;;
        failed) fetch_note="fetch: FAILED (offline?)"
                stale_note="; count is against the last-known '$base_remote' state" ;;
        *)      fetch_note="fetch: skipped ('$base_remote' is not a configured remote — treated as a local ref)" ;;
      esac ;;
    *)  fetch_note="fetch: n/a (local branch)" ;;
  esac
  if "$DEVAGENT_GIT" -C "$source_dir" rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null 2>&1; then
    counts="$("$DEVAGENT_GIT" -C "$source_dir" rev-list --left-right --count "${base_ref}...HEAD")" \
      || die "rederive: git rev-list ${base_ref}...HEAD failed in $source_dir"
    behind="${counts%%[[:space:]]*}"; ahead="${counts##*[[:space:]]}"
    if [ -n "$issue_branch" ] && [ "$head_branch" = "$issue_branch" ]; then
      gap_line="ℹ HEAD $head_short on issue branch $issue_branch vs $base_ref: behind $behind, ahead $ahead ($fetch_note$stale_note) — revision-time drift, not a premise; rebasing is a ship-time decision"
    elif [ "$behind" -gt 0 ]; then
      gap_line="✗ HEAD $head_short vs $base_ref: behind $behind, ahead $ahead ($fetch_note$stale_note) — STALE CHECKOUT: every ✓ below was checked against a tree $behind commit(s) behind the base the branch will be cut from (falsified premise — on the base branch run: git -C $source_dir merge --ff-only $base_ref, then re-run the prober via /devagent:draft; or state the delta in Preconditions)"
    else
      gap_line="✓ HEAD $head_short vs $base_ref: behind 0, ahead $ahead ($fetch_note$stale_note)"
    fi
  else
    gap_line="? behind-count undetermined — default_baseline '$base_ref' does not resolve in $source_dir ($fetch_note)"
  fi
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

# --- Name resolution (#590) ---------------------------------------------------
# Tokens are often a bare basename (`SKILL.md`) or a path suffix
# (`capture/capture.sh`), not a repo path; `cat-file -e HEAD:<tok>` fails on
# those, and Issue-570's artifact carried six ✗ rows of which zero were real —
# on a gate the draft must dispose of row by row. Resolve against the HEAD tree
# (ls-tree, not ls-files: the index may hold staged-uncommitted paths) by EXACT
# suffix at a `/` boundary — awk string compare, no regex, so no escaping and no
# rc-1-vs-2 ambiguity (an awk failure aborts the assignment under pipefail with
# awk's own stderr — loud by construction). One hit → resolved, several →
# ambiguous (advisory, not a premise), none → genuinely absent (✗). The
# extractor above is unchanged.
head_tree="$("$DEVAGENT_GIT" -C "$source_dir" ls-tree -r --name-only HEAD)" \
  || die "rederive: git ls-tree HEAD failed in $source_dir"
# rederive_resolve <token> — setter-globals: RES_KIND (exact|resolved|ambiguous|
# absent), RES_PATH (the one path for exact/resolved), RES_HITS (newline list
# for ambiguous).
rederive_resolve() {
  local t="$1" hits
  RES_KIND=absent; RES_PATH=""; RES_HITS=""
  if "$DEVAGENT_GIT" -C "$source_dir" cat-file -e "HEAD:$t" 2>/dev/null; then
    RES_KIND=exact; RES_PATH="$t"; return 0
  fi
  RES_HITS="$(printf '%s\n' "$head_tree" | awk -v t="$t" \
    'length($0) >= length(t) && substr($0, length($0)-length(t)+1) == t && (length($0) == length(t) || substr($0, length($0)-length(t), 1) == "/")')"
  [ -n "$RES_HITS" ] || return 0                   # absent
  mapfile -t hits <<< "$RES_HITS"
  if [ "${#hits[@]}" -eq 1 ]; then RES_KIND=resolved; RES_PATH="${hits[0]}"
  else RES_KIND=ambiguous; fi
}
declare -a since_paths=()

date_str="$(date_tag)"   # #413: honor the #338 DEVAGENT_DATE_OVERRIDE freeze seam
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
  echo "## Checkout vs baseline (is HEAD itself current? #590; base: $base_src$marker_note)"
  echo "  $gap_line"
  if [ "${#files[@]}" -eq 0 ] && [ "${#funcs[@]}" -eq 0 ]; then
    echo "0 named inputs found (heuristic extracted nothing — derive inputs by hand)."
  else
    if [ "${#files[@]}" -gt 0 ]; then
      echo "## Named files (exists at HEAD?)"
      for f in "${files[@]}"; do
        rederive_resolve "$f"
        case "$RES_KIND" in
          exact)     echo "  ✓ $f"; since_paths+=("$f") ;;
          resolved)  echo "  ✓ $f → $RES_PATH (resolved: one tracked path ends in /$f)"; since_paths+=("$RES_PATH") ;;
          ambiguous) mapfile -t hits <<< "$RES_HITS"
                     echo "  ~ $f — ambiguous: ${#hits[@]} tracked paths end in /$f ($(printf '%s, ' "${hits[@]:0:3}" | sed 's/, $//')${hits[3]:+, …}); advisory, not a falsified premise — cite the full path if it matters" ;;
          *)         echo "  ✗ $f  — NOT at HEAD (falsified premise — address in Preconditions)" ;;
        esac
      done
    fi
    if [ "${#filelines[@]}" -gt 0 ]; then
      echo "## Cited lines at HEAD (drift check)"
      for fl in "${filelines[@]}"; do
        f="${fl%%:*}"; ln="${fl##*:}"
        rederive_resolve "$f"
        case "$RES_KIND" in
          exact|resolved)
            cur="$("$DEVAGENT_GIT" -C "$source_dir" show "HEAD:$RES_PATH" 2>/dev/null | sed -n "${ln}p" || true)"
            if [ "$RES_KIND" = resolved ]; then echo "  $fl → ($RES_PATH) ${cur:-<file/line absent at HEAD>}"
            else echo "  $fl → ${cur:-<file/line absent at HEAD>}"; fi ;;
          ambiguous)
            mapfile -t hits <<< "$RES_HITS"
            echo "  $fl → <ambiguous: ${#hits[@]} tracked paths end in /$f>" ;;
          *) echo "  $fl → <file/line absent at HEAD>" ;;
        esac
      done
    fi
    if [ "${#funcs[@]}" -gt 0 ]; then
      echo "## Named functions (advisory — not path-verified)"
      for fn in "${funcs[@]}"; do echo "  · $fn"; done
    fi
    if [ "${#since_paths[@]}" -gt 0 ] && [ -n "$created" ]; then
      echo "## Merged commits touching these files since $created (what landed while queued)"
      log="$("$DEVAGENT_GIT" -C "$source_dir" log --oneline "--since=$created" -- "${since_paths[@]}" 2>/dev/null || true)"
      if [ -n "$log" ]; then printf '%s\n' "$log" | sed 's/^/  /'; else echo "  (none)"; fi
    fi
  fi
  echo "---"
  echo "ADVISORY: the draft judges every ✗ — a stale checkout or a falsified premise → question-return or a plan delta; ℹ and ~ rows are informational, not premises."
} > "$artifact"
echo "rederive: wrote $artifact (${#files[@]} files, ${#filelines[@]} line-cites)" >&2
