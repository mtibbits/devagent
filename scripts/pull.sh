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
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/artifact.sh"

main() {
  local project="${1:-}"
  local source="${2:-}"
  local num="${3:-}"

  [[ -n "$project" ]] || die "pull.sh: project required"
  config_require_project "$project"
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
    ISSUE_ID="$issue_id" checklist_init "$issue_dir" "$template" "$project"
  fi

  # Mark step 0 done; log
  checklist_mark "$issue_dir/checklist.md" 0 x
  log_append "$issue_dir" "pull" "fetched ${repo}#${num}, scaffold created"

  # Promote to active issue. If this displaces a different in-flight issue,
  # snapshot its per-issue context first (it may not have been parked), then
  # start the new issue from clean defaults. Re-pull of the same issue must
  # not disturb in-flight context (#98).
  # #240: an env-pinned session's pin IS its pointer — the WHOLE displacement/
  # promote block is skipped (not just the pointer write): running the
  # save/clear here would wipe the other session's live top-level keys.
  local prev displaced=""
  if [[ -n "${DEVAGENT_ACTIVE_ISSUE:-}" ]]; then
    info "pull: session is issue-pinned (${DEVAGENT_ACTIVE_ISSUE}) — shared active_issue untouched"
  else
    prev="$(state_get "$project" active_issue 2>/dev/null || true)"
    if [[ "$prev" == "$issue_id" ]]; then
      # Re-pull of the live issue: refresh the pair only — NEVER clear live
      # context. (#96: one transaction; #282: no pointer write — pull's
      # project is always an explicit positional.)
      state_set_many "$project" str active_issue "$issue_id" str issue_dir "$issue_dir"
    else
      local snap_prev=""
      [[ -n "$prev" && "$prev" != "null" ]] && snap_prev="$prev"
      # #327: snapshot(displaced) + clear-to-defaults + promote as ONE locked
      # transaction (was save→clear→set_many — 3 compound calls whose
      # mid-sequence crash left active_issue=prev over defaults, the #316
      # branch="" shape). Clobber-warn carried inside (--print-old).
      state_pull_promote "$project" "$issue_id" "$issue_dir" "$snap_prev"
      if [[ -n "$snap_prev" ]]; then
        # #247: remember the displaced issue ONLY if a non-empty snapshot was
        # actually taken (genuinely in-flight); reads the table the
        # transaction above just wrote. No-prev and nothing-to-save cases
        # leave $displaced empty and stay silent.
        state_context_has "$project" "$snap_prev" && displaced="$snap_prev"
      fi
    fi
  fi
  # An active issue is by definition not parked: drop any stale parked flag
  # and PRE-PARK snapshot, so a later resume cannot restore stale context over
  # live work (#98). The snapshot GC is gated on the parked flag — under #240
  # the [context.<issue>] table is a pinned session's LIVE home, and an
  # unconditional unset on re-pull would delete the only copy (review CRIT).
  if state_list_parked "$project" | grep -qxF "$issue_id"; then
    state_remove_parked "$project" "$issue_id"
    state_unset "$project" "context.${issue_id}"
  fi

  # #247: targeted feedback when this pull set aside a different in-flight issue.
  # The #98 snapshot already preserved it; without this the operator only sees
  # the generic state_set concurrency warning (about suspected concurrent
  # sessions) and may believe their work was discarded. Distinct from that
  # warning via "context preserved" + a resume pointer.
  if [[ -n "$displaced" ]]; then
    warn "displaced in-flight issue ${displaced}: its context (branch, step, MR) was preserved, not discarded — return to it with /devagent:resume ${project} ${displaced} (or /devagent:switch)"
  fi

  info "pulled ${repo}#${num} into ${issue_dir}"
  checklist_print_next_hint "$issue_dir/checklist.md"
}

main "$@"
