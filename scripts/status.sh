#!/usr/bin/env bash
# scripts/status.sh — multi-project dashboard. Spec §6.5.
# Usage: status.sh <project>      → one project
#        status.sh --all          → every configured project
#        status.sh                → every configured project (same as --all)

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/io.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/state.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/permission.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/devdoc-repo.sh"   # #1148: the not-pushed line

_print_one() {
  local project="$1"
  echo "── $project ──"
  local active issue_dir
  active="$(state_get "$project" active_issue 2>/dev/null || true)"
  issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"

  if [[ -z "$active" || "$active" == "null" ]]; then
    echo "  Active: (idle)"
  else
    local cur cur_state cur_name
    if [[ -f "$issue_dir/checklist.md" ]]; then
      cur="$(checklist_current_step "$issue_dir/checklist.md")"
      if [[ "$cur" == "done" ]]; then
        echo "  Active: $active — all steps complete"
      else
        cur_state="$(checklist_step_state "$issue_dir/checklist.md" "$cur")"
        cur_name="$(checklist_step_name "$issue_dir/checklist.md" "$cur")"
        echo "  Active: $active — step $cur ($cur_name) [$cur_state]"
      fi
    else
      echo "  Active: $active — (no checklist.md)"
    fi
    if [[ -n "$issue_dir" && -f "$issue_dir/STUCK" ]]; then
      local reason
      reason="$(awk -F': *' '/^Reason:/{ $1=""; sub(/^ /,""); print; exit }' "$issue_dir/STUCK")"
      echo "  STUCK: $reason"
    fi
  fi

  local parked
  parked="$(state_list_parked "$project" | paste -sd, -)"
  if [[ -n "$parked" ]]; then echo "  Parked: $parked"; fi
}

# _devdoc_lines <project>… — #1148: one line for each devDoc repository the named
# projects use that has commits not on origin, read from local refs only (no network
# call). A repository is in scope when it has an origin and at least one configured
# project with commit_devdoc = true uses it (the sync's scope, by repository), so a
# project whose own key is false can show its shared repository's line. A repository
# several projects share prints once. Called bare; prints nothing for a repository in
# sync, and nothing when git cannot read it. Each config read is a python3 run, so
# every project is read at most once, and scope reads stop once every needed
# repository is in scope.
_devdoc_lines() {
  local p dir top ref rc
  local -A top_of=() need=() inscope=() named=() seen=()
  for p in "$@"; do
    named[$p]=1
    dir="$(config_get_project_field "$p" devdoc_dir 2>/dev/null)" || continue
    [[ -n "$dir" ]] || continue
    devdoc_sync_repo "$dir" || continue
    top_of[$p]="$DEVDOC_SYNC_TOP"; need[$DEVDOC_SYNC_TOP]=1
  done
  (( ${#need[@]} > 0 )) || return 0
  for p in "$@"; do
    top="${top_of[$p]:-}"
    [[ -n "$top" && -z "${inscope[$top]+x}" ]] || continue
    if [[ "$(permission_value "$p" commit_devdoc)" == true ]]; then inscope[$top]=1; fi
  done
  for p in "${ALL_PROJECTS[@]}"; do
    (( ${#inscope[@]} < ${#need[@]} )) || break
    [[ -z "${named[$p]+x}" ]] || continue
    [[ "$(permission_value "$p" commit_devdoc)" == true ]] || continue
    dir="$(config_get_project_field "$p" devdoc_dir 2>/dev/null)" || continue
    [[ -n "$dir" ]] || continue
    devdoc_sync_repo "$dir" || continue
    [[ -z "${need[$DEVDOC_SYNC_TOP]+x}" ]] || inscope[$DEVDOC_SYNC_TOP]=1
  done
  for p in "$@"; do
    top="${top_of[$p]:-}"
    [[ -n "$top" && -n "${inscope[$top]+x}" && -z "${seen[$top]+x}" ]] || continue
    seen[$top]=1
    rc=0; ref="$("$DEVAGENT_GIT" -C "$top" symbolic-ref -q HEAD 2>/dev/null)" || rc=$?
    if [[ "$rc" -eq 1 ]]; then
      echo "devDoc $top: HEAD is detached, so the devDoc sync cannot run"
      continue
    fi
    [[ "$rc" -eq 0 && "$ref" == refs/heads/?* ]] || continue
    rc=0; devdoc_unpushed_text "$top" "${ref#refs/heads/}" || rc=$?
    [[ "$rc" -eq 1 ]] || echo "devDoc $top: $DEVDOC_UNPUSHED_TEXT"
  done
}

main() {
  local mode="all"
  local project=""
  case "${1:-}" in
    --all) mode="all" ;;
    "")    mode="all" ;;
    *)     mode="one"; project="$1" ;;
  esac

  local -a projects=()
  mapfile -t projects < <(config_list_projects 2>/dev/null || true)
  ALL_PROJECTS=("${projects[@]}")
  if (( ${#projects[@]} == 0 )); then
    echo "No projects configured. Add one to ~/.claude/devagent/config.toml."
    return 0
  fi

  case "$mode" in
    one)
      config_is_project "$project" || die "unknown project '$project'"
      _print_one "$project"
      _devdoc_lines "$project"
      ;;
    all)
      local p
      for p in "${projects[@]}"; do _print_one "$p"; done
      _devdoc_lines "${projects[@]}"
      ;;
  esac
}

main "$@"
