#!/usr/bin/env bash
set -uo pipefail   # not -e: we want to accumulate failures, not abort
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/artifact.sh"
source "$PLUGIN_ROOT/scripts/lib/state.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/active.sh"      # #316: state_ctx_get for the coherence check
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"   # #316: checklist_step_state_by_name
source "$PLUGIN_ROOT/scripts/lib/secrets.sh"
# shellcheck source=/dev/null
# shellcheck disable=SC2034  # consumed by template_resolve.sh (sourced next), which keys its
# source-set off DEVAGENT_ROOT — pinned to the plugin so an ambient/other-lib value cannot redirect it.
DEVAGENT_ROOT="$PLUGIN_ROOT"
source "$PLUGIN_ROOT/scripts/lib/template_resolve.sh"   # #611: potholes.sh (private-name predicate)

declare -i ERRORS=0

check() {
  local label="$1" status="$2" detail="${3:-}"
  case "$status" in
    ok)   echo "  OK   $label" ;;
    # skip: a check that does not apply on this platform (e.g. a POSIX
    # mode audit on a filesystem that can't represent modes). Visible and
    # non-fatal — never report a skipped 644/755 as a bare OK (#289).
    skip) echo "  SKIP $label${detail:+ — $detail}" ;;
    # warn: advisory only (#541 recommend-not-require) — visible, never
    # counted in ERRORS, never flips doctor's exit code. NOT the auth-hook
    # protocol's WARN (doctor_auth.sh), which deliberately maps to fail.
    warn) echo "  WARN $label${detail:+ — $detail}" ;;
    *)    echo "  FAIL $label${detail:+ — $detail}"; ERRORS=$((ERRORS + 1)) ;;
  esac
}

# Sets global _FIELD_VALUE; writes check output directly to stdout of calling shell.
require_field() {
  local project="$1" field="$2"
  _FIELD_VALUE="$(config_get_project_field "$project" "$field" 2>/dev/null || true)"
  if [[ -z "$_FIELD_VALUE" ]]; then
    check "project.$project.$field" fail "required field unset"
  else
    check "project.$project.$field" ok
  fi
}

check_template_resolves() {
  # #120: §12 registry (an override is exactly what this check must bless).
  local name="$1" project="$2" path
  path="$(artifact_resolve_or "$project" "checklist-${name}")"
  if [[ -f "$path" ]]; then
    check "checklist template '$name'" ok
  else
    check "checklist template '$name'" fail "not resolvable via registry or plugin: $path"
  fi
}

check_one_project() {
  local project="$1"
  echo "[project: $project]"
  config_is_project "$project" \
    || { check "project block" fail "no [project.$project] in $(config_path)"; return; }

  local src devdoc
  require_field "$project" source_dir;         src="$(expand_tilde "$_FIELD_VALUE")"
  require_field "$project" devdoc_dir;         devdoc="$(expand_tilde "$_FIELD_VALUE")"
  require_field "$project" issue_source.backend
  require_field "$project" issue_source.repo
  require_field "$project" code_source.backend
  if [[ -d "$src" ]]; then
    check "source_dir exists ($src)" ok
  else
    check "source_dir exists ($src)" fail "directory not found"
  fi
  if [[ -d "$devdoc" ]]; then
    check "devdoc_dir exists ($devdoc)" ok
  else
    check "devdoc_dir exists ($devdoc)" fail "directory not found"
  fi

  # State file
  if state_exists "$project"; then
    local mode
    mode="$(stat -c '%a' "$(state_path "$project")")"
    # Mode-first (probe only on mismatch): matches doctor_auth.sh and avoids a
    # probe file on the healthy 600 path.
    if [[ "$mode" == "600" ]]; then
      check "state file ($mode)" ok
    elif ! posix_modes_representable "$(dirname "$(state_path "$project")")"; then
      check "state file ($mode)" skip "filesystem can't represent POSIX modes — verify access control by other means"
    else
      check "state file ($mode)" fail "expected mode 600"
    fi
    # #316: state coherence — an ACTIVE issue whose branch step (8) is DONE but
    # whose recorded branch is empty is the resume-after-cleanup corruption
    # (cleanup GC'd the [context.<issue>] table but left the issue parked; a
    # later bare resume restored defaults, branch=""). Gate on branch-step == x
    # so a fresh issue between pull and branch — where an empty branch is
    # legitimate — is not flagged. Active issue only; the broader last_step vs
    # checklist audit is the state epic's remit.
    local ai ai_dir ai_branch ai_bstep ai_lstep ai_lstep_glyph
    ai="$(state_get "$project" active_issue 2>/dev/null || true)"
    if [[ -n "$ai" && "$ai" != "null" ]]; then
      ai_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"
      ai_branch="$(state_ctx_get "$project" branch "$ai" 2>/dev/null || true)"
      if [[ -n "$ai_dir" && -f "$ai_dir/checklist.md" ]]; then
        ai_bstep="$(checklist_step_state_by_name "$ai_dir/checklist.md" branch 2>/dev/null || true)"
        if [[ -z "$ai_branch" && "$ai_bstep" == "x" ]]; then
          check "state coherence ($ai)" fail "branch step complete but no branch recorded — resume-after-cleanup corruption (#316); re-run /devagent:branch"
        else
          check "state coherence ($ai)" ok
        fi
      fi
      # #329: broader last_step vs checklist cross-check. Each step writes state
      # (last_step_name=X) THEN marks checklist step X — two files, no ordering
      # contract; a crash between leaves state claiming a step the checklist
      # doesn't reflect. last_step_name always names the last COMPLETED step, so
      # a healthy in-progress issue (step N [x], step N+1 [ ]) stays coherent;
      # only the crash-between window diverges. [-] (skipped) counts as done.
      ai_lstep="$(state_ctx_get "$project" last_step_name "$ai" 2>/dev/null || true)"
      if [[ -n "$ai_lstep" && "$ai_lstep" != "null" && -n "$ai_dir" && -f "$ai_dir/checklist.md" ]]; then
        ai_lstep_glyph="$(checklist_step_state_by_name "$ai_dir/checklist.md" "$ai_lstep" 2>/dev/null || true)"
        if [[ "$ai_lstep_glyph" == "x" || "$ai_lstep_glyph" == "-" ]]; then
          check "step coherence ($ai)" ok
        else
          check "step coherence ($ai)" fail "state records last_step_name=$ai_lstep but that checklist step is '${ai_lstep_glyph:-unmarked}' — likely a crash between the state write and the checklist mark (the checklist is authoritative); re-run the step or mark it"
        fi
      fi
    fi
  else
    check "state file" fail "missing — run /devagent:init $project"
  fi

  # Checklist template resolution
  local tpl
  tpl="$(config_get_project_field "$project" checklist_template 2>/dev/null || true)"
  [[ -z "$tpl" ]] && tpl="$(config_get_default checklist_template 2>/dev/null || echo standard)"
  check_template_resolves "$tpl" "$project"

  # #611: the shared workflow pothole register, surfaced per project (a
  # [project.<name>.paths] override may differ from the global [paths] key).
  local wf
  if ! wf="$(potholes_workflow_path "$project")"; then
    check "potholes_workflow register" fail "lookup failed (a relative [paths] potholes_workflow, or an unreadable config) — see above"
  elif [[ -z "$wf" ]]; then
    check "potholes_workflow register: not configured ([paths] potholes_workflow — shared lessons cannot be staged)" ok
  elif [[ -s "$wf" ]]; then
    check "potholes_workflow register: $wf" ok
  else
    check "potholes_workflow register: $wf (absent — bootstrapped by the first --apply)" ok
  fi

  # #613 (redmr): the register FILE contract over each PRESENT devdoc layer — the
  # predicate --apply runs on its temp copy before writing, so a pre-existing
  # violation is a diagnostic here rather than a DEFER at the next closeout's
  # drain (which cleanup only warns about). Absent files are the rows above.
  local pr ly f crc cout
  pr="$(potholes_project_path "$project" 2>/dev/null || true)"
  for ly in workflow project; do
    if [[ "$ly" == workflow ]]; then f="${wf:-}"; else f="$pr"; fi
    [[ -n "$f" && -s "$f" ]] || continue
    if ! type potholes_file_check >/dev/null 2>&1; then
      check "potholes register contract ($ly layer)" fail "predicate potholes_file_check not loaded (scripts/lib/potholes.sh)"
      continue
    fi
    crc=0; cout="$(potholes_file_check "$ly" "$f" 2>&1)" || crc=$?
    if [[ "$crc" -eq 0 ]]; then
      check "potholes register contract ($ly layer): $f" ok
    elif [[ "$crc" -eq 1 ]]; then
      check "potholes register contract ($ly layer)" warn "$(printf '%s' "$cout" | tr '\n' ';') — the next --apply (cleanup's drain) DEFERs on this; fix the quoted line by hand (#613)"
    else
      check "potholes register contract ($ly layer)" fail "$f unreadable — the predicate could not run"
    fi
  done

  # Phase 8 auth hook.
  local hook="$PLUGIN_ROOT/scripts/lib/doctor_auth.sh"
  if [[ -x "$hook" ]]; then
    local issue_backend code_backend backends=()
    issue_backend="$(config_get_project_field "$project" issue_source.backend 2>/dev/null || true)"
    code_backend="$(config_get_project_field "$project"  code_source.backend  2>/dev/null || true)"
    [[ -n "$issue_backend" ]] && backends+=("$issue_backend")
    [[ -n "$code_backend"  ]] && [[ "$code_backend" != "$issue_backend" ]] && backends+=("$code_backend")
    backends+=(ssh)
    local line
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      # Lines look like "<key>: <STATUS> <details>" — promote STATUS to our check().
      local label="${line%%:*}" rest="${line#*: }"
      local status="${rest%% *}"
      local detail="${rest#* }"; [[ "$detail" == "$rest" ]] && detail=""
      case "$status" in
        OK)               check "auth/${label}" ok ;;
        SKIP)             check "auth/${label}" skip "${detail:-mode audit skipped (modes unrepresentable)}" ;;
        MISSING)          echo "  INFO auth/${label} — not configured (run /devagent:auth create $project ${label})" ;;
        WARN|ERROR)       check "auth/${label}" fail "${status}${detail:+ — $detail}" ;;
        *)                check "auth/${label}" fail "unparsed: $line" ;;
      esac
    done < <(DEVAGENT_SECRETS_DIR="$(secrets_dir)" "$hook" check "$project" "${backends[@]}")
  fi
}

# ---- main ----------------------------------------------------------------

echo "devagent doctor — $(date -Iseconds)"
echo "home: $(devagent_home)"
echo

# Global checks
if [[ -f "$(config_path)" ]]; then
  check "config exists" ok
  if python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" validate "$(config_path)" >/dev/null 2>&1; then
    check "config is valid TOML" ok
  else
    check "config is valid TOML" fail "tomllib failed to parse $(config_path)"
  fi
  # #352/#432: report the opt-in git-reflex guard state, but per what the HOOK
  # will ACTUALLY do — never "ON" for a hook that won't fire. tomllib (via
  # config_get_default) accepts any valid-TOML `git_guard = true`, INCLUDING a
  # trailing comment / extra whitespace; the hook's awk gate (git-guard.sh)
  # requires a LITERALLY BARE line. Run the hook's own gate here and reconcile:
  # both-off / both-on → report that state (off is a valid default, never a
  # failure); tomllib-on but gate-off → a silently-disabled guard the operator
  # opted into, which IS a failure (the divergence #432 exists to surface). The
  # gate awk below is byte-identical to the hook's (drift-pinned by a bats canary).
  # #433: resolve per the project doctor was invoked with (a [project.<name>]
  # override wins over [defaults]); no arg → defaults-only. The gate awk below is
  # BYTE-IDENTICAL to the hook's (drift-pinned by a bats canary). The tomllib side
  # mirrors the same project→defaults order so the divergence check compares like
  # for like.
  # An explicit `doctor <project>` arg checks THAT project; with no arg, resolve the
  # active project via the hook's own chain (DEVAGENT_ACTIVE_PROJECT env > pointer) so
  # a bare `doctor` predicts what the hook will do in the active session (#433).
  gproj="${1:-}"
  if [[ -z "$gproj" ]]; then
    gproj="${DEVAGENT_ACTIVE_PROJECT:-}"
    [[ -n "$gproj" ]] || gproj="$(awk -F'"' '/^active_project[[:space:]]*=/{print $2; exit}' \
      "$(dirname "$(config_path)")/state/_active.toml" 2>/dev/null || true)"
  fi
  gtoml="$(config_get_project_field "$gproj" git_guard 2>/dev/null || true)"
  [[ -z "$gtoml" ]] && gtoml="$(config_get_default git_guard 2>/dev/null || true)"
  if awk -v proj="$gproj" '
    /^\[/ {
      in_def  = ($0 == "[defaults]")
      in_proj = (proj != "" && $0 == "[project." proj "]")
    }
    in_proj && /^[[:space:]]*git_guard[[:space:]]*=[[:space:]]*true[[:space:]]*$/  { pv = 1; ps = 1 }
    in_proj && /^[[:space:]]*git_guard[[:space:]]*=[[:space:]]*false[[:space:]]*$/ { pv = 0; ps = 1 }
    in_def  && /^[[:space:]]*git_guard[[:space:]]*=[[:space:]]*true[[:space:]]*$/  { dv = 1 }
    END { exit((ps ? pv : dv) ? 0 : 1) }
  ' "$(config_path)" 2>/dev/null; then
    check "git-reflex guard: ON (blocks reflexive stash/checkout--/restore/clean on a dirty tree)" ok
  elif [[ "$gtoml" == "true" ]]; then
    check "git-reflex guard: OFF despite git_guard=true — the hook's gate needs a LITERALLY BARE line (no trailing comment or extra tokens); the guard will NOT fire. Fix: git_guard = true" fail
  else
    check "git-reflex guard: off (opt-in; set [defaults] or [project.<name>] git_guard = true to enable)" ok
  fi
  # #611: private project names vs the shipped seed — WARN only (the suite
  # canary tests/potholes-seed-canary.bats is the gate, live since #613 curated
  # the seed; a hit here is a seed-curation regression, fixed by PR). The
  # roster is the LIVE config's project keys (private, on the operator's box)
  # minus the public allowlist; a key not in the suite fixture is reported as
  # INFO only — the fixture must never grow a new private name (red-team #611).
  seed="$(potholes_seed_path)"   # via the resolver (#425 canary), never a hand-rolled path
  fx="$PLUGIN_ROOT/tests/fixtures/private-project-names.txt"
  if [[ -f "$seed" && -f "$fx" ]]; then
    pub=" $(potholes_fixture_public "$fx" | tr '\n' ' ') "
    live=(); missing=()
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      [[ "${pub,,}" == *" ${p,,} "* ]] && continue
      live+=("$p")
      potholes_fixture_private_names "$fx" | grep -qixF -- "$p" || missing+=("$p")
    done < <(config_list_projects)
    if (( ${#missing[@]} )); then
      echo "  INFO private project(s) checked live only (not in the suite fixture, by design): ${missing[*]}"
    fi
    if ! type potholes_private_name_hits >/dev/null 2>&1; then
      # Issue-316: a missing function must not drive the WARN branch with an empty hit list.
      check "seed carries no private project name" fail "predicate potholes_private_name_hits not loaded (scripts/lib/potholes.sh)"
    elif (( ${#live[@]} )); then
      hrc=0; hits="$(potholes_private_name_hits "$seed" "${live[@]}")" || hrc=$?
      if [[ "$hrc" -eq 0 ]]; then
        check "seed carries no private project name" ok
      elif [[ "$hrc" -eq 1 ]]; then
        check "seed carries no private project name" warn "$(printf '%s' "$hits" | tr '\n' ';') — seed-curation regression (#613): move the line to a devDoc layer by PR"
      else
        check "seed carries no private project name" fail "seed unreadable ($seed) — the predicate could not run"
      fi
    else
      check "seed carries no private project name" ok
    fi
  else
    # FAIL CLOSED (red-team r2): a missing input must never read as "checked".
    check "seed carries no private project name" fail "check did not run — seed ($seed) or fixture ($fx) missing"
  fi
else
  check "config exists" fail "no $(config_path) — run /devagent:init"
fi

if [[ -d "$(secrets_dir)" ]]; then
  if ! posix_modes_representable "$(secrets_dir)"; then
    # secrets_audit would skip-and-pass here; say so visibly rather than
    # printing a bare OK that implies the 700/600 invariant was verified (#289).
    check "secrets dir clean" skip "filesystem can't represent POSIX modes — verify access control by other means"
  elif secrets_audit 2>/dev/null; then
    check "secrets dir clean" ok
  else
    check "secrets dir clean" fail "mode drift — see warnings (re-run secrets_audit)"
  fi
else
  check "secrets dir present" fail "no $(secrets_dir)"
fi

# #541: recommended-plugin check — WARN only, never touches ERRORS.
# Tri-state (Issue-314/243): capture the CLI output, never pipe-under-`!`;
# a CLI failure or empty output is "undetermined", NOT "absent" — no WARN.
if command -v claude >/dev/null 2>&1; then
  # Issue-314: capture; a CLI failure/hang is NOT "absent". timeout guarded:
  # absent coreutils must not turn the whole check into a silent no-op (redmr).
  if command -v timeout >/dev/null 2>&1; then
    plugins="$(timeout 5 claude plugin list 2>/dev/null)" || plugins=""
  else
    plugins="$(claude plugin list 2>/dev/null)" || plugins=""
  fi
  if [[ -z "$plugins" ]]; then
    : # undetermined (CLI errored / empty) — fail closed, no claim either way (Issue-243)
  elif printf '%s\n' "$plugins" | awk '/❯/{f=($0 ~ /superpowers@/)} f && /✔ enabled/{ok=1} END{exit !ok}'; then
    : # present AND enabled — silent. Stanza-scoped (❯-delimited record, header
    # line included), not a fixed -A window: an inserted OR merged line in a
    # future `plugin list` layout must not false-WARN. '✔ enabled' exact:
    # plain 'enabled' would substring-match 'disabled'.
  elif printf '%s\n' "$plugins" | grep -q '❯ superpowers@'; then
    # installed but not enabled — the fix is enable, not a second install;
    # name taken from the actual stanza (any marketplace, redmr finding)
    sp_name="$(printf '%s\n' "$plugins" | grep -o '❯ superpowers@[^[:space:]]*' | head -1 | cut -d' ' -f2)"
    check "superpowers (recommended)" warn "installed but disabled: draft/implement/review use built-in fallbacks — recommended: claude plugin enable ${sp_name}"
  else
    check "superpowers (recommended)" warn "not installed: draft/implement/review use built-in fallbacks — recommended: claude plugin install superpowers@claude-plugins-official"
  fi
fi

echo

if (( ERRORS > 0 )); then
  echo "doctor: aborting per-project checks due to $ERRORS global error(s)"
  exit 1
fi

if [[ $# -ge 1 ]]; then
  check_one_project "$1"
else
  any=0
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    check_one_project "$p"
    any=1
  done < <(config_list_projects)
  (( any == 1 )) || { echo "no projects configured"; exit 1; }
fi

echo
if (( ERRORS == 0 )); then
  echo "OK ($(date -Iseconds))"
  exit 0
else
  echo "FAIL ($ERRORS error(s))"
  exit 1
fi
