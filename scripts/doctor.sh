#!/usr/bin/env bash
set -uo pipefail   # not -e: we want to accumulate failures, not abort
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/config.sh"
source "$PLUGIN_ROOT/scripts/lib/state.sh"
source "$PLUGIN_ROOT/scripts/lib/secrets.sh"

declare -i ERRORS=0

check() {
  local label="$1" status="$2" detail="${3:-}"
  if [[ "$status" == "ok" ]]; then
    echo "  OK   $label"
  else
    echo "  FAIL $label${detail:+ — $detail}"
    ERRORS=$((ERRORS + 1))
  fi
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
  local name="$1" path
  path="$PLUGIN_ROOT/templates/checklist-${name}.md"
  if [[ -f "$path" ]]; then
    check "checklist template '$name'" ok
  else
    check "checklist template '$name'" fail "no such file: $path"
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
    if [[ "$mode" == "600" ]]; then
      check "state file ($mode)" ok
    else
      check "state file ($mode)" fail "expected mode 600"
    fi
  else
    check "state file" fail "missing — run /devagent:init $project"
  fi

  # Checklist template resolution
  local tpl
  tpl="$(config_get_project_field "$project" checklist_template 2>/dev/null || true)"
  [[ -z "$tpl" ]] && tpl="$(config_get_default checklist_template 2>/dev/null || echo standard)"
  check_template_resolves "$tpl"

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
else
  check "config exists" fail "no $(config_path) — run /devagent:init"
fi

if [[ -d "$(secrets_dir)" ]]; then
  if secrets_audit 2>/dev/null; then
    check "secrets dir clean" ok
  else
    check "secrets dir clean" fail "mode drift — see warnings (re-run secrets_audit)"
  fi
else
  check "secrets dir present" fail "no $(secrets_dir)"
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
