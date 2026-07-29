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
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/flags.sh"

main() {
  local project="${1:-}"
  local source="${2:-}"
  local num="${3:-}"

  [[ -n "$project" ]] || die "project required"
  config_require_project "$project"
  [[ "$source" == "origin" || "$source" == "fork" ]] \
    || die "second arg must be origin|fork, got: '${source:-<none>}'"
  [[ "$num" =~ ^[0-9]+$ ]] \
    || die "issue number must be numeric, got: '${num:-<none>}'"

  local section
  if [[ "$source" == "origin" ]]; then
    section="issue_source"
  else
    section="issue_source_fork"
  fi

  local backend repo dir_prefix devdoc
  backend="$(config_get_project_field "$project" "${section}.backend" 2>/dev/null || true)"
  repo="$(config_get_project_field "$project" "${section}.repo" 2>/dev/null || true)"
  dir_prefix="$(config_get_project_field "$project" "${section}.dir_prefix" 2>/dev/null || true)"
  devdoc="$(config_get_project_field "$project" "devdoc_dir" 2>/dev/null || true)"

  [[ -n "$backend" ]]    || die "$section.backend not configured for $project"
  [[ -n "$repo" ]]       || die "$section.repo not configured for $project"
  [[ -n "$dir_prefix" ]] || die "$section.dir_prefix not configured for $project"
  [[ -n "$devdoc" ]]     || die "devdoc_dir not configured for $project"

  local issue_id="${dir_prefix}${num}"
  local issue_dir="${devdoc%/}/${issue_id}"
  mkdir -p "$issue_dir"

  # Fetch issue body
  local backend_script="$PLUGIN_ROOT/scripts/issue/${backend}.sh"
  [[ -x "$backend_script" ]] || die "backend script not executable: $backend_script"
  if ! "$backend_script" fetch "$repo" "$num" > "$issue_dir/issue.md.tmp"; then
    rm -f "$issue_dir/issue.md.tmp"
    die "${backend}.sh fetch failed for ${repo}#${num}"
  fi
  mv "$issue_dir/issue.md.tmp" "$issue_dir/issue.md"

  # Scaffold checklist if missing; do not stomp on user edits.
  # Template resolution sits AFTER the fetch (and only in the scaffold
  # branch — re-pulls skip it) so the fetched body's `## Workflow flags`
  # tier key can override the project default (#537). The override is
  # validated against the allowlist BEFORE the remote-content value
  # touches any path; a tier key added after first scaffold is inert
  # (revise.sh --retier is the sole post-scaffold path).
  if [[ ! -f "$issue_dir/checklist.md" ]]; then
    local template tier
    template="$(config_get_project_field "$project" "checklist_template" 2>/dev/null || true)"
    [[ -n "$template" ]] || template="$(config_get_default checklist_template 2>/dev/null || echo standard)"
    [[ -n "$template" ]] || template="standard"
    tier="$(flags_get "$issue_dir/issue.md" tier || true)"
    local _shim_checking=""
    if [[ -n "$tier" ]]; then
      # #561 COMPAT SHIM: `tier: <model>-checking` is a MODEL annotation from a
      # convention that predates #537's claim on the `tier:` key (koopman-gnn used
      # it for "which model runs the checking steps"). #537 made those bodies die
      # pre-path; this intercepts the shape BEFORE tier_require_legal so they pull
      # again, leaving `template` on the project default chain.
      # PERMANENT grammar, warn-ALWAYS: the warning IS the migration nudge, and a
      # removal date would orphan capture drafts that are not yet filed.
      # tier_shim_model is non-fatal by contract, so it is safe in $().
      if _shim_checking="$(tier_shim_model "$tier")"; then
        printf "pull.sh: warn: 'tier: %s' is a model annotation, not a template tier — interpreted as 'checking-model: %s'; prefer 'checking-model:'\n" \
          "$tier" "$_shim_checking" >&2
      else
        # Not the shim shape ⇒ a genuinely unknown tier still dies listing the
        # legal template names, exactly as #537 shipped it.
        _shim_checking=""
        tier_require_legal "$tier" " in ## Workflow flags"
        template="$tier"
      fi
    fi

    # #561: the two per-issue model keys, resolved into ONE scalar per class.
    # Values are captured FIRST (flags_get is non-fatal, safe in $()), and only
    # THEN validated by a helper that dies — so the die executes in the main
    # shell rather than in a subshell that would swallow it (register: Issue-120,
    # a die-exiting resolver cannot live inside $()). Two plain scalars, not a
    # packed token or setter-globals reached through a subshell (Issue-282).
    # ALL of this runs BEFORE checklist_init, so a rejected value leaves neither
    # a checklist nor a marker behind — the #537 precedent pinned by
    # tests/pull.bats:345-352.
    local _body_thinking _body_checking _want_thinking="" _want_checking=""
    _body_thinking="$(flags_get "$issue_dir/issue.md" implementation-model || true)"
    _body_checking="$(flags_get "$issue_dir/issue.md" checking-model || true)"
    if [[ -n "$_body_thinking" ]]; then
      model_token_require_legal "$_body_thinking" " in ## Workflow flags (implementation-model)"
    fi
    if [[ -n "$_body_checking" ]]; then
      model_token_require_legal "$_body_checking" " in ## Workflow flags (checking-model)"
    fi

    # Per-class precedence, body sources only: explicit key > `tier:` shim.
    # (The label rung is appended below this, as the lowest.)
    _want_thinking="$_body_thinking"
    if [[ -n "$_body_checking" ]]; then
      _want_checking="$_body_checking"
      if [[ -n "$_shim_checking" ]]; then
        printf "pull.sh: warn: explicit 'checking-model: %s' beats 'tier: %s-checking' — using '%s'\n" \
          "$_body_checking" "$_shim_checking" "$_body_checking" >&2
      fi
    elif [[ -n "$_shim_checking" ]]; then
      _want_checking="$_shim_checking"
    fi

    ISSUE_ID="$issue_id" checklist_init "$issue_dir" "$template" "$project"

    # #561: write the per-issue marker from the resolved per-class steering.
    # Scaffold-branch only, like `tier:` — a key added after first scaffold is
    # inert on re-pull, and the documented post-scaffold path is hand-editing
    # this file. An EXISTING marker is never stomped for that same reason.
    if [[ -n "$_want_thinking" || -n "$_want_checking" ]]; then
      local _marker="$issue_dir/.devagent-step-models" _content=""
      if [[ -e "$_marker" ]]; then
        printf 'pull.sh: warn: %s already exists — leaving it untouched (hand-editing the marker is the documented post-scaffold path)\n' \
          "$_marker" >&2
        log_append "$issue_dir" "pull" "warn: .devagent-step-models already existed — scaffold model steering NOT written"
      else
        if [[ -n "$_want_checking" ]]; then _content+="checking: $_want_checking"$'\n'; fi
        if [[ -n "$_want_thinking" ]]; then _content+="thinking: $_want_thinking"$'\n'; fi
        printf '%s' "$_content" > "$_marker"
        log_append "$issue_dir" "pull" "wrote .devagent-step-models (${_want_checking:+checking=$_want_checking }${_want_thinking:+thinking=$_want_thinking})"
      fi
    fi

    # #535: table-driven optional-step row-flip. `_flag_rows` is the SINGLE SOURCE
    # of the flag->row mapping; each entry is "flag:trigger-value:row" and #536's
    # spike step appends an entry here rather than adding a second parser.
    # Reads the fetched body block via flags_get (body-segment + comment-aware +
    # contiguous). Scaffold-branch only, so a completed row is never reset; flips
    # only a `[-]` row. Absent row => warn + no-op (#231/#242: checklist_mark alone
    # dies, and a die mid-scaffold is a different product than a warning). A known
    # key with a non-trigger value warns too, so a typo is not silently inert
    # (#535 review: `research: yes` was indistinguishable from no flag).
    local _entry _fl _trig _row _val _glyph
    local -a _flag_rows=( "research:required:1" "spike:required:3" )
    for _entry in "${_flag_rows[@]}"; do
      IFS=: read -r _fl _trig _row <<<"$_entry"
      _val="$(flags_get "$issue_dir/issue.md" "$_fl" || true)"
      if [[ -n "$_val" && "$_val" != "$_trig" ]]; then
        printf "pull.sh: warn: '%s: %s' is not a recognized value for flag '%s' (expected '%s') — ignored\n" \
          "$_fl" "$_val" "$_fl" "$_trig" >&2
      fi
      [[ "$_val" == "$_trig" ]] || continue
      if _glyph="$(checklist_step_state "$issue_dir/checklist.md" "$_row" 2>/dev/null)"; then
        [[ "$_glyph" == "-" ]] && checklist_mark "$issue_dir/checklist.md" "$_row" " "
      else
        printf 'pull.sh: warn: %s flag set but checklist row %s absent (template-overridden?) — no-op\n' "$_fl" "$_row" >&2
        log_append "$issue_dir" "pull" "warn: ${_fl} flag set but row ${_row} absent — no-op"
      fi
    done
    # #535: block-level unknown-key WARN (deferred here from #537). Scaffold-branch
    # only — a key added after first scaffold is inert and unvalidated (documented).
    flags_validate "$issue_dir/issue.md"
  fi

  # Mark step 0 done; log
  checklist_mark "$issue_dir/checklist.md" 0 x pull
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
    elif state_is_displaced "$project" "$issue_id" && state_context_has "$project" "$issue_id"; then
      # #415: re-pull of a DISPLACEMENT-parked issue = "bring my displaced work
      # back" → RESTORE its snapshot (resume semantics), not a fresh start. The
      # issue this pull now displaces is itself snapshotted + parked + marked so
      # it is recoverable in turn. (Operator-parks — no displaced marker — fall
      # through to the else and keep the #98 MAJ-1 fresh-start GC below.)
      if [[ -n "$prev" && "$prev" != "null" && "$prev" != "$issue_id" ]]; then
        state_context_save "$project" "$prev"
        if state_context_has "$project" "$prev"; then
          state_add_parked "$project" "$prev"
          state_add_displaced "$project" "$prev"
          displaced="$prev"
        fi
      fi
      state_remove_parked "$project" "$issue_id"
      # (the displaced marker is cleared in-lock by state_resume_promote_restore)
      state_resume_promote_restore "$project" "$issue_id" "$issue_dir"
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
        if state_context_has "$project" "$snap_prev"; then
          displaced="$snap_prev"
          # #415: park + mark the displaced issue so the advertised recovery
          # (/devagent:resume | /devagent:switch) actually finds it (both key on
          # the parked flag). The displaced marker makes a later re-pull RESTORE
          # it rather than GC it.
          state_add_parked "$project" "$snap_prev"
          state_add_displaced "$project" "$snap_prev"
        fi
      fi
    fi
  fi
  # An active issue is by definition not parked: drop any stale parked flag
  # and PRE-PARK snapshot, so a later resume cannot restore stale context over
  # live work (#98). The snapshot GC is gated on the parked flag — under #240
  # the [context.<issue>] table is a pinned session's LIVE home, and an
  # unconditional unset on re-pull would delete the only copy (review CRIT).
  # #415: a displacement-park was already restored+cleared on the elif path
  # above, so anything still parked here is an operator-park → GC it (MAJ-1).
  if state_list_parked "$project" | grep -qxF "$issue_id"; then
    state_remove_parked "$project" "$issue_id"
    state_remove_displaced "$project" "$issue_id"
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
