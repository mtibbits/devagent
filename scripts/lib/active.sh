#!/usr/bin/env bash
# scripts/lib/active.sh — context resolution: which project + which issue?
#
# Resolution priority (project):
#   1. positional arg
#   2. DEVAGENT_ACTIVE_PROJECT env var
#   3. global pointer at $(devagent_home)/state/_active.toml
#   4. config_active_project (single-project shortcut; dies with a
#      helpful message when 0 or 2+ projects are configured)
#
# Resolution priority (issue, given a project):
#   1. positional arg
#   2. DEVAGENT_ACTIVE_ISSUE env var
#   3. per-project state file's `active_issue`
#   4. scan <devdoc>/Issue-*/checklist.md for the most-recently-modified
#      checklist that still has at least one incomplete box
#
# Requires: paths.sh, io.sh, config.sh, state.sh sourced first.

active_pointer_path() {
  echo "$(devagent_home)/state/_active.toml"
}

# active_set_project <project>
# Writes the global active-project pointer (mode 600).
active_set_project() {
  local project="$1"
  [ -n "$project" ] || { echo "active_set_project: project required" >&2; return 2; }
  local f
  f="$(active_pointer_path)"
  mkdir -p "$(dirname "$f")"
  printf 'active_project = "%s"\nlast_active_at = "%s"\n' \
    "$project" "$(date -Iseconds)" > "$f"
  chmod 600 "$f"
}

# active_get_project
# Prints the global active-project pointer, or empty + exit 1 if absent.
active_get_project() {
  local f
  f="$(active_pointer_path)"
  [ -f "$f" ] || return 1
  awk -F' *= *' '$1=="active_project" { gsub(/"/, "", $2); print $2; exit }' "$f"
}

# active_resolve_project_src [arg]
# Resolution engine (#282). Sets, in the CALLING shell (no stdout — callers
# must NOT command-substitute this, or the variables die in the subshell):
#   ACTIVE_RESOLVED_PROJECT  the resolved project name
#   ACTIVE_RESOLVED_FROM     arg | env | pointer | fallback
# Writers gate the pointer write on the source so an arg/env-pinned session
# never clobbers the pointer another session relies on. NB: `fallback` also
# fires when the pointer names a project failing config_is_project — with
# 2+ projects config_active_project then dies, so no write happens there.
active_resolve_project_src() {
  local arg="${1:-}"
  ACTIVE_RESOLVED_PROJECT=""
  ACTIVE_RESOLVED_FROM=""
  if [ -n "$arg" ]; then
    ACTIVE_RESOLVED_FROM="arg"; ACTIVE_RESOLVED_PROJECT="$arg"; return 0
  fi
  if [ -n "${DEVAGENT_ACTIVE_PROJECT:-}" ]; then
    ACTIVE_RESOLVED_FROM="env"; ACTIVE_RESOLVED_PROJECT="$DEVAGENT_ACTIVE_PROJECT"; return 0
  fi
  local p
  p="$(active_get_project 2>/dev/null || true)"
  if [ -n "$p" ] && config_is_project "$p"; then
    ACTIVE_RESOLVED_FROM="pointer"; ACTIVE_RESOLVED_PROJECT="$p"; return 0
  fi
  # shellcheck disable=SC2034  # consumed by callers (next.sh gate), not here
  ACTIVE_RESOLVED_FROM="fallback"
  ACTIVE_RESOLVED_PROJECT="$(config_active_project)"
}

# active_resolve_project [arg]
# Echo wrapper over the setter — keeps the existing $(...) callers
# byte-compatible (their subshell copies of the vars are discarded; none of
# them write the pointer — verified 2026-07-02).
active_resolve_project() {
  active_resolve_project_src "${1:-}" || return $?
  printf '%s\n' "$ACTIVE_RESOLVED_PROJECT"
}

# active_scan_recent_incomplete <project>
# Walks <devdoc>/Issue-* (and Issue-Fork-*), prints the basename of the
# most-recently-modified checklist that still has any "- [ ]" or "- [~]"
# line. Empty + exit 1 if no candidate.
active_scan_recent_incomplete() {
  local project="$1"
  local devdoc
  devdoc="$(config_get_project_field "$project" devdoc_dir 2>/dev/null || true)"
  devdoc="$(expand_tilde "$devdoc")"
  [ -d "$devdoc" ] || return 1
  local best="" best_ts=0
  local d cl ts
  shopt -s nullglob
  for d in "$devdoc"/Issue-*/; do
    [ -d "$d" ] || continue
    cl="$d/checklist.md"
    [ -f "$cl" ] || continue
    grep -qE '^- \[[ ~]\]' "$cl" || continue
    ts="$(stat -c '%Y' "$cl")"
    if [ "$ts" -gt "$best_ts" ]; then
      best_ts="$ts"
      best="$(basename "$d")"
    fi
  done
  shopt -u nullglob
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# active_resolve_issue <project> [arg]
# Implements the issue priority chain.
active_resolve_issue() {
  local project="$1" arg="${2:-}"
  [ -n "$project" ] || { echo "active_resolve_issue: project required" >&2; return 2; }
  if [ -n "$arg" ]; then printf '%s\n' "$arg"; return 0; fi
  if [ -n "${DEVAGENT_ACTIVE_ISSUE:-}" ]; then
    printf '%s\n' "$DEVAGENT_ACTIVE_ISSUE"; return 0
  fi
  local ai
  ai="$(state_get "$project" active_issue 2>/dev/null || true)"
  if [ -n "$ai" ] && [ "$ai" != "null" ] && [ "$ai" != '""' ]; then
    printf '%s\n' "$ai"; return 0
  fi
  active_scan_recent_incomplete "$project"
}
