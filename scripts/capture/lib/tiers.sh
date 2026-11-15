#!/usr/bin/env bash
# scripts/capture/lib/tiers.sh — #1101 capture-time tier proposal. Sourced; functions only.
# shellcheck shell=bash
# shellcheck disable=SC2034 # TIERS_* are setter-globals, read by the sourcing caller
# Requires config.sh (_config_toml, config_get_project_field) and flags.sh sourced first. Never dies; call bare, never in $(...).
# tiers_read <file>        SETTER-GLOBALS TIERS_THINKING TIERS_CHECKING ("" = class not proposed), TIERS_ERR
#                          rc 0 valid · rc 1 invalid. Clears all three at entry.
# tiers_class_tier <project> <thinking|checking>
#                          SETTER-GLOBALS TIERS_RESOLVED ("" = no tier), TIERS_ERR
#                          rc 0 · rc 2 config unreadable. step_models.<class>, else step_models.default;
#                          step_models.<N> never read; a table value reads as absent (rc 1 from _toml get).
# tiers_label <thinking|checking> <token>   prints tier:impl-<token> | tier:check-<token> (pure)
#
# tiers.toml grammar: top-level keys thinking, checking, reason_thinking,
# reason_checking — each optional, no tables (a dotted key is a table). An empty
# file is a valid "no proposal". reason_* values are not type-checked.
#
# TABLE FALL-THROUGH IS DELIBERATE (Issue-782 disposition): a table-valued
# step_models.<class> reads as absent and falls to step_models.default, exactly
# as step_models_tier does. A loud refusal here would make file.sh and the
# resolver disagree about the same config; tests/capture-tiers.bats pins the
# agreement on every fixture without a per-step key.

TIERS_KEYS="thinking, checking, reason_thinking, reason_checking"

tiers_read() {
  local f="${1:-}" out rc k t v cls legal
  TIERS_THINKING=""; TIERS_CHECKING=""; TIERS_ERR=""
  if [[ ! -f "$f" || ! -r "$f" ]]; then
    TIERS_ERR="$f: not a regular readable file"; return 1
  fi
  # validate FIRST: list-keys / list-tables on invalid TOML raise a traceback.
  rc=0; out="$(_config_toml validate "$f" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    out="${out%%$'\n'*}"; out="${out//$'\r'/}"
    TIERS_ERR="$f: not valid TOML (${out})"; return 1
  fi
  rc=0; out="$(_config_toml list-tables "$f" 2>&1)" || rc=$?
  out="${out//$'\r'/}"
  if [[ "$rc" -ne 0 ]]; then
    TIERS_ERR="$f: not valid TOML (list-tables rc $rc)"; return 1
  fi
  if [[ -n "$out" ]]; then
    t="${out%%$'\n'*}"
    TIERS_ERR="$f: [$t] is not allowed (keys: $TIERS_KEYS)"; return 1
  fi
  rc=0; out="$(_config_toml list-keys "$f" 2>&1)" || rc=$?
  out="${out//$'\r'/}"
  if [[ "$rc" -ne 0 ]]; then
    TIERS_ERR="$f: not valid TOML (list-keys rc $rc)"; return 1
  fi
  local -a keys=()
  [[ -z "$out" ]] || mapfile -t keys <<<"$out"
  for k in ${keys[@]+"${keys[@]}"}; do
    case "$k" in
      thinking|checking|reason_thinking|reason_checking) ;;
      *) TIERS_ERR="$f: unknown key '$k' (keys: $TIERS_KEYS)"; return 1 ;;
    esac
  done
  legal=" $(model_token_allowlist) "; legal="${legal/ inherit / }"
  legal="${legal# }"; legal="${legal% }"
  local tv="" cv=""
  for cls in thinking checking; do
    case " ${keys[*]+"${keys[*]}"} " in *" $cls "*) ;; *) continue ;; esac
    rc=0; v="$(_config_toml get "$f" "$cls" 2>/dev/null)" || rc=$?
    v="${v//$'\r'/}"
    if [[ "$rc" -ne 0 ]]; then
      TIERS_ERR="$f: $cls could not be read (_toml get rc $rc)"; return 1
    fi
    if [[ "$v" == "inherit" ]]; then
      TIERS_ERR="$f: $cls = \"inherit\" is not a proposal; omit the key to keep the project tier"; return 1
    fi
    # The charset test guards model_token_is_legal, a space-padded substring
    # test that accepts "fable inherit" (#1117 fixes it at source).
    if [[ ! "$v" =~ ^[A-Za-z0-9._-]+$ ]] || ! model_token_is_legal "$v"; then
      TIERS_ERR="$f: $cls must be one model token ($legal), got: '$v'"; return 1
    fi
    if [[ "$cls" == thinking ]]; then tv="$v"; else cv="$v"; fi
  done
  TIERS_THINKING="$tv"; TIERS_CHECKING="$cv"
  return 0
}

tiers_class_tier() {
  local project="${1:-}" cls="${2:-}" field v rc
  TIERS_RESOLVED=""; TIERS_ERR=""
  for field in "step_models.$cls" step_models.default; do
    rc=0; v="$(config_get_project_field "$project" "$field" 2>/dev/null)" || rc=$?
    v="${v//$'\r'/}"
    # rc 2 (unparseable config) — or any rc but 0/1 — fails closed, never a fallback.
    if [[ "$rc" -ne 0 && "$rc" -ne 1 ]]; then
      TIERS_ERR="could not read [project.$project.step_models] (config rc $rc)"; return 2
    fi
    # rc 1 (absent, or a table) or an empty value falls to the next rung — the
    # resolver's rule (config.sh step_models_tier, rungs 2 and 3).
    if [[ "$rc" -eq 0 && -n "$v" ]]; then
      TIERS_RESOLVED="$v"; return 0
    fi
  done
  return 0
}

tiers_label() {
  case "${1:-}" in
    thinking) printf 'tier:impl-%s\n' "${2:-}" ;;
    checking) printf 'tier:check-%s\n' "${2:-}" ;;
  esac
}
