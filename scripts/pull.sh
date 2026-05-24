#!/usr/bin/env bash
# scripts/pull.sh — workflow step 0: fetch issue, scaffold Issue dir.
# Spec §3.5, §6.3 row 0.
# Usage: pull.sh <project> <origin|fork> <issue-num>

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
source "$PLUGIN_ROOT/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/active.sh"

main() {
  local project="${1:-}"
  local source="${2:-}"
  local num="${3:-}"

  [[ -n "$project" ]] || die "pull.sh: project required"
  [[ "$source" == "origin" || "$source" == "fork" ]] \
    || die "pull.sh: second arg must be origin|fork, got: '${source:-<none>}'"
  [[ "$num" =~ ^[0-9]+$ ]] \
    || die "pull.sh: issue number must be numeric, got: '${num:-<none>}'"

  local section
  if [[ "$source" == "origin" ]]; then
    section="issue_source"
  else
    section="issue_source_fork"
  fi

  local backend repo dir_prefix devdoc template
  backend="$(config_get_project_field "$project" "${section}.backend" 2>/dev/null || true)"
  repo="$(config_get_project_field "$project" "${section}.repo" 2>/dev/null || true)"
  dir_prefix="$(config_get_project_field "$project" "${section}.dir_prefix" 2>/dev/null || true)"
  devdoc="$(config_get_project_field "$project" "devdoc_dir" 2>/dev/null || true)"
  template="$(config_get_project_field "$project" "checklist_template" 2>/dev/null || true)"
  [[ -n "$template" ]] || template="$(config_get_default checklist_template 2>/dev/null || echo standard)"
  [[ -n "$template" ]] || template="standard"

  [[ -n "$backend" ]]    || die "pull.sh: $section.backend not configured for $project"
  [[ -n "$repo" ]]       || die "pull.sh: $section.repo not configured for $project"
  [[ -n "$dir_prefix" ]] || die "pull.sh: $section.dir_prefix not configured for $project"
  [[ -n "$devdoc" ]]     || die "pull.sh: devdoc_dir not configured for $project"

  local issue_id="${dir_prefix}${num}"
  local issue_dir="${devdoc%/}/${issue_id}"
  mkdir -p "$issue_dir"

  # Fetch issue body
  local backend_script="$PLUGIN_ROOT/scripts/issue/${backend}.sh"
  [[ -x "$backend_script" ]] || die "pull.sh: backend script not executable: $backend_script"
  if ! "$backend_script" fetch "$repo" "$num" > "$issue_dir/issue.md.tmp"; then
    rm -f "$issue_dir/issue.md.tmp"
    die "pull.sh: ${backend}.sh fetch failed for ${repo}#${num}"
  fi
  mv "$issue_dir/issue.md.tmp" "$issue_dir/issue.md"

  # Scaffold checklist if missing; do not stomp on user edits
  if [[ ! -f "$issue_dir/checklist.md" ]]; then
    ISSUE_ID="$issue_id" checklist_init "$issue_dir" "$template"
  fi

  # Mark step 0 done; log
  checklist_mark "$issue_dir/checklist.md" 0 x
  log_append "$issue_dir" "pull" "fetched ${repo}#${num}, scaffold created"

  # Promote to active issue
  state_set "$project" active_issue "$issue_id"
  active_set_project "$project"
  state_set "$project" issue_dir   "$issue_dir"

  info "pulled ${repo}#${num} into ${issue_dir}"
  checklist_print_next_hint "$issue_dir/checklist.md"
}

main "$@"
