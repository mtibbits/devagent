#!/usr/bin/env bash
# scripts/pull.sh — workflow step 0: fetch issue, scaffold Issue dir.
# Spec §3.5, §6.3 row 0.
# Usage: pull.sh <project> <issue-num> [--origin|--fork]
# The source defaults to [project.<p>] default_issue_source, else the only
# configured source, else origin (#1099; scripts/lib/issue-source.sh).

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
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/transition.sh"   # issue_repo_label (#1009)
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/trust.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/quarantine.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/issue-source.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/staging.sh"

PULL_USAGE="usage: pull.sh <project> <issue-num> [--origin|--fork]"

# _pull_staged <project> <issue_id> <issue_dir> <devdoc> <backend> <repo> <num>
# — the fetch under a trust policy in scope (#715; spec §9.3; the flow is
# scripts/lib/staging.sh's). No ticket byte is printed here: the backend's
# stderr is discarded, and every exit but PASS and QUARANTINE dies with a fixed
# message and nothing written. `trap staging_discard EXIT` is pull's only EXIT
# trap. Each status is captured with `|| rc=$?`, so `set -euo pipefail` cannot
# exit before the fixed message (Issue-589).
# SETTER-GLOBAL (via staging_render): STAGE_TRAILERS. Call it bare.
_pull_staged() {
  local project="$1" issue_id="$2" issue_dir="$3" devdoc="$4" backend="$5" repo="$6" num="$7"
  local backend_script="$PLUGIN_ROOT/scripts/issue/${backend}.sh" verdict rc
  [[ -x "$backend_script" ]] || die "backend script not executable: $backend_script"
  rc=0
  staging_open "$project" "$issue_id" "$devdoc" || rc=$?
  [[ "$rc" -eq 0 ]] || die "could not create the staging dir for ${repo}#${num} (exit $rc); nothing was written"
  trap staging_discard EXIT
  rc=0
  "$backend_script" fetch "$repo" "$num" > "$STAGE_RAW" 2>/dev/null || rc=$?
  [[ "$rc" -eq 0 ]] \
    || die "${backend}.sh fetch failed for ${repo}#${num} (exit $rc); its stderr is not shown under a trust policy: the operator can re-run '${backend_script} fetch ${repo} ${num} >/dev/null' by hand to see it"
  rc=0
  staging_render "$repo" "$num" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    [[ -z "$STAGE_REASON" ]] \
      || die "the fetched text of ${repo}#${num} is not in the fetch layout (${STAGE_REASON}); nothing was written"
    die "the fetched text of ${repo}#${num} could not be rendered (exit $rc); nothing was written"
  fi
  rc=0
  verdict="$(quarantine_verdict "$project" "$issue_dir" "$STAGE_MD")" || rc=$?
  case "$rc:$verdict" in
    "0:QUARANTINE "*)
      staging_discard
      quarantine_verdict_split "$verdict"
      quarantine_pull_quarantine "$project" "$issue_id" "$issue_dir" "$QV_TOKEN" "$QV_DETAIL" ;;
    0:PASS) ;;
    *) die "no quarantine verdict for ${repo}#${num} (exit $rc); nothing was written" ;;
  esac
  # #719's claim write and verify go here, between the verdict and the promote.
  rc=0
  staging_promote "$issue_dir" || rc=$?
  [[ "$rc" -eq 0 ]] || die "could not write issue.md for ${repo}#${num} (exit $rc); nothing was written"
}

main() {
  local project="${1:-}"
  local source="" num=""

  [[ -n "$project" ]] || die "project required — $PULL_USAGE"
  [[ "$project" != -* ]] \
    || die "a flag cannot come before <project>, got: '$project' — $PULL_USAGE"
  config_require_project "$project"
  issue_source_take_flag "${@:2}" || die "$ISRC_ERR — $PULL_USAGE"

  if [[ "${ISRC_REST[0]:-}" == "origin" || "${ISRC_REST[0]:-}" == "fork" ]]; then
    # Legacy positional form, kept for existing automation (#1099): the
    # source token, then the number; anything after the number is ignored as
    # before, except a source flag, which take_flag already made a usage error.
    [[ -z "$ISRC_FLAG" ]] \
      || die "the origin|fork token and --origin/--fork cannot be combined; drop one — $PULL_USAGE"
    source="${ISRC_REST[0]}"
    num="${ISRC_REST[1]:-}"
  else
    local tok
    for tok in "${ISRC_REST[@]}"; do
      [[ "$tok" != -* ]] || die "unknown flag: '$tok' — $PULL_USAGE"
    done
    [[ "${#ISRC_REST[@]}" -eq 1 ]] \
      || die "expected <issue-num> [--origin|--fork], got: '${ISRC_REST[*]}' — $PULL_USAGE"
    num="${ISRC_REST[0]}"
    source="$ISRC_FLAG"
  fi
  [[ "$num" =~ ^[0-9]+$ ]] \
    || die "issue number must be numeric, got: '${num:-<none>}'"
  # The number is checked before the default is read, so a bad key never
  # hides a bad number.
  if [[ -z "$source" ]]; then
    issue_source_default "$project" || die "$ISRC_ERR"
    source="$ISRC_DEFAULT"
  fi

  local section
  section="$(issue_source_section "$source")" \
    || die "internal: unresolved source '$source'"

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
trust_entry_check "pull" "$project" "$source"
quarantine_pull_guard "$project" "$issue_id" "$issue_dir"
  # #963: a held issue is never re-pulled (the fetch would rewrite issue.md
  # and drop its saved context); after the trust and quarantine checks, so
  # their codes win.
  [[ "$(stuck_kind "$issue_dir")" != question ]] || hold_refuse pull "$issue_dir"
  STAGE_TRAILERS=""
  if [[ "${TRUST_IN_SCOPE:-0}" == 1 ]]; then
    # #715: staged, rendered and checked before anything reads or prints it;
    # issue.md is written only on PASS (or this exits 6, or dies).
    _pull_staged "$project" "$issue_id" "$issue_dir" "$devdoc" "$backend" "$repo" "$num"
  else
    mkdir -p "$issue_dir"

    # Fetch issue body
    local backend_script="$PLUGIN_ROOT/scripts/issue/${backend}.sh"
    [[ -x "$backend_script" ]] || die "backend script not executable: $backend_script"
    if ! "$backend_script" fetch "$repo" "$num" > "$issue_dir/issue.md.tmp"; then
      rm -f "$issue_dir/issue.md.tmp"
      die "${backend}.sh fetch failed for ${repo}#${num}"
    fi
    mv "$issue_dir/issue.md.tmp" "$issue_dir/issue.md"

    # #714: the quarantine verdict on the fetched ticket, before anything reads
    # it. Out of scope it is always PASS.
    local verdict
    verdict="$(quarantine_verdict "$project" "$issue_dir")"
    if [[ "$verdict" == "QUARANTINE "* ]]; then
      quarantine_verdict_split "$verdict"
      quarantine_pull_quarantine "$project" "$issue_id" "$issue_dir" "$QV_TOKEN" "$QV_DETAIL"
    fi
  fi

  # #582: block-level flags diagnostics (the roster lives in flags_validate's
  # docblock). Runs on EVERY pull, as soon as the fetched body lands, not only at
  # first scaffold: a flags key edited onto the issue body AFTER scaffold arrives
  # here on the next re-pull, and until #582 that path performed no validation at
  # all. Warn-only by contract (forward-compat): it never dies, so it cannot
  # pre-empt the die-class validations that still run inside the scaffold branch.
  flags_validate "$issue_dir/issue.md"

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
    # An EMPTY value (`checking-model:` with nothing after it) is inert, not an
    # error: flags_get trims it away, the -n guards below skip validation, and
    # flags_validate stays silent because the key IS known. That mirrors `tier:`'s
    # shipped empty-value handling, so it is consistency rather than oversight —
    # but note the asymmetry: `checking-model: bogus` dies (#561 review F2).
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

    # #561 LABEL CHANNEL. factorAI steers exclusively by labels
    # (`tier:impl-<model>` / `tier:check-<model>`, no flags block anywhere) and
    # koopman-gnn duplicates its body convention as `tier:<model>-checking`.
    # Both backends already fetch the label set and render it; nothing consumed
    # it, so factorAI#85 ran every checking step at the config floor despite a
    # `tier:check-fable` label.
    #
    # SOURCE (operator answer A1): the backend-rendered `- Labels:` HEADER line of
    # the issue.md this run just wrote from the backend's stdout — read once,
    # header segment only, never the body and never a comment. There is no JSON
    # payload to parse here: the §9.1 backend contract defines `fetch` as
    # markdown-to-stdout (spec §9.1) and, with no policy in scope, pull.sh writes
    # it verbatim (§9.3; under trust it writes the trust render, whose header is
    # the fetch's, control bytes escaped), so the markdown IS the payload here.
    #
    # The loop is fed by process substitution, NOT a pipe: the body must run in
    # THIS shell so `die` below actually exits the script instead of a subshell
    # (register: Issue-314 — a pipe hides a non-zero exit as "found nothing").
    # Keyed by class, so the conflict check and its message exist ONCE rather than
    # once per class. `_src` keeps the operator's LITERAL label text, which is not
    # derivable from the model (three spellings map to one class).
    local _lbl _lmodel _lclass
    local -A _lbl_want=() _lbl_src=()
    while IFS= read -r _lbl; do
      [[ -n "$_lbl" ]] || continue
      # Not our namespace at all: silently ignored, no warning. Ordinary labels
      # like `bug` are the common case and must stay quiet.
      [[ "$_lbl" == tier:* ]] || continue
      _lmodel=""; _lclass=""
      # FIXED match order; the first shape a label matches wins.
      if [[ "$_lbl" == tier:impl-* ]]; then
        _lclass="thinking"; _lmodel="${_lbl#tier:impl-}"
      elif [[ "$_lbl" == tier:check-* ]]; then
        _lclass="checking"; _lmodel="${_lbl#tier:check-}"
      elif [[ "$_lbl" == tier:*-checking ]]; then
        _lclass="checking"; _lmodel="${_lbl#tier:}"; _lmodel="${_lmodel%-checking}"
      else
        # Our namespace but NOT a recognized shape — this includes template tier
        # names used as labels (`tier:standard`). Warn and ignore, NEVER die: the
        # label namespace is shared forge metadata that anyone may write, and
        # template selection stays body-only. A die here would also halt an
        # --auto chain on someone else's label hygiene (register: Issue-242).
        printf "pull.sh: warn: unrecognized steering label '%s' — ignored (recognized shapes: tier:impl-<model>, tier:check-<model>, tier:<model>-checking)\n" \
          "$_lbl" >&2
        continue
      fi
      # Validated UNCONDITIONALLY, and BEFORE precedence is applied (operator
      # answer A2). A same-class label pair is ambiguous authored intent ON THE
      # FORGE — a fact about the issue regardless of what the body says — so
      # letting a body key mask it would surface the failure later, on some other
      # issue with no body key. That is the fail-open shape the register's
      # Issue-558 trigger warns about.
      model_token_require_legal "$_lmodel" " in forge label '$_lbl'"
      if [[ -n "${_lbl_want[$_lclass]:-}" && "${_lbl_want[$_lclass]}" != "$_lmodel" ]]; then
        die "conflicting ${_lclass}-class labels: '${_lbl_src[$_lclass]}' and '$_lbl' steer the same class to different models — remove one"
      fi
      _lbl_want[$_lclass]="$_lmodel"; _lbl_src[$_lclass]="$_lbl"
    done < <(issue_labels "$issue_dir/issue.md")
    local _lbl_thinking="${_lbl_want[thinking]:-}" _lbl_checking="${_lbl_want[checking]:-}"
    local _lbl_thinking_src="${_lbl_src[thinking]:-}" _lbl_checking_src="${_lbl_src[checking]:-}"

    # Labels are the LOWEST rung: body key > body `tier:` shim > label > config
    # chain. When a body source beats a DIFFERENT label the label is ignored with
    # a warning — the unambiguous case warns, it does not die.
    if [[ -z "$_want_thinking" ]]; then
      _want_thinking="$_lbl_thinking"
    elif [[ -n "$_lbl_thinking" && "$_want_thinking" != "$_lbl_thinking" ]]; then
      printf "pull.sh: warn: body 'implementation-model: %s' beats label '%s' — label ignored\n" \
        "$_want_thinking" "$_lbl_thinking_src" >&2
    fi
    if [[ -z "$_want_checking" ]]; then
      _want_checking="$_lbl_checking"
    elif [[ -n "$_lbl_checking" && "$_want_checking" != "$_lbl_checking" ]]; then
      printf "pull.sh: warn: body checking-class steering '%s' beats label '%s' — label ignored\n" \
        "$_want_checking" "$_lbl_checking_src" >&2
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
  fi

  # Mark step 0 done; log
  checklist_mark_by_name "$issue_dir/checklist.md" pull x
  # #1009: a disk repo is a folder on this machine; the log names it `disk`.
  log_append "$issue_dir" "pull" "fetched $(issue_repo_label "$backend" "$repo")#${num}, scaffold created"
  # #713: under a trust policy in scope, the run record names the policy.
  if [[ "${TRUST_IN_SCOPE:-0}" == 1 ]]; then
    local trust_rec
    trust_rec="$(trust_run_record "$backend" "$repo" "$num")"
    log_append "$issue_dir" "pull" "$trust_rec"
    info "$trust_rec"
    # #715: a second trailer-shaped heading (a body or comment imitating the
    # fetch layout) means the body was cut at the first one (spec §9.3).
    if [[ "${STAGE_TRAILERS:-0}" =~ ^[0-9]+$ ]] && (( 10#$STAGE_TRAILERS > 1 )); then
      local trailers_note="trust: the fetched text holds ${STAGE_TRAILERS} comments headings; the body was read up to the first (spec §9.3)"
      log_append "$issue_dir" "pull" "$trailers_note"
      info "$trailers_note"
    fi
  fi

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
    elif { [[ "$QUARANTINE_RELEASED" == inwork ]] || state_is_displaced "$project" "$issue_id"; } \
         && state_context_has "$project" "$issue_id"; then
      # #714: a release of an in-work quarantine is the same return as a
      # displacement — the guard saved the context when it cleared the slot.
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
  # #1099: the one stdout line, a machine-read contract
  # (^pulled (Issue-[A-Za-z-]*[0-9]+)$). It is the dir's own issue_id, so it
  # cannot disagree with the dir; every other line goes to stderr.
  printf 'pulled %s\n' "$issue_id"
}

main "$@"
