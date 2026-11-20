#!/usr/bin/env bash
# scripts/lib/floor.sh — pull's deterministic floor under a trust policy (#715;
# spec §9.3). Runs on the candidate issue.md in the staging dir, before anything
# reads or prints it, as the first source of quarantine_verdict
# (scripts/lib/quarantine.sh).
#
# FLOOR_CHECKS run in order; #923 appends `chars`. Every check runs, each
# failure prints its diagnostic on stderr, and floor_run prints the FIRST
# failing check's token (a QUARANTINE_REASONS token) on stdout. A failing check
# wins over one that could not run, so a hostile ticket always quarantines;
# floor_run reports could-not-run (rc 3, no token) only when no check failed.
#
#   steering  every live `## Workflow flags` key line (flags_enumerate: the
#             validate machine's quiet mode, so what is checked is what
#             flags_get later applies) and every `tier:*` label (issue_labels,
#             the scaffold's own reader) must be listed in the policy's
#             allowed_steering. Body entries `<key>: <value>` are compared
#             only with body-shaped entries, labels only with label-shaped
#             ones, by string equality (never as a pattern or a subscript).
#   size      the candidate's byte length must not exceed size_cap.
#
# Diagnostics name a key of flags_known_keys, a body line number, a label's
# index, or a count — never a ticket byte. Each ends with remedy lines
# addressed to the operator, never to the worker session.
#
# Reads only the candidate it is handed and TRUST_VAL; reads no config, writes
# nothing, never dies. Source-only file: do not execute directly.

_FLOOR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Issue-1050: the guard names every flags.sh function used here.
# shellcheck source=/dev/null
{ declare -F flags_enumerate && declare -F issue_labels && declare -F flags_known_keys \
    && declare -F tier_is_legal && declare -F tier_shim_model && declare -F model_token_is_legal; } >/dev/null \
  || source "$_FLOOR_LIB_DIR/flags.sh"
# shellcheck source=/dev/null
declare -F _trust_list >/dev/null || source "$_FLOOR_LIB_DIR/trust.sh"

FLOOR_CHECKS=(steering size)

# _floor_say <text>: one diagnostic line on stderr.
_floor_say() { printf '%s: floor: %s\n' "$(basename "$0")" "$1" >&2; }

# floor_run <candidate>: the first failing check's token on stdout, or nothing.
# rc 0 whenever a check failed or all passed; rc 3, no token, when no check
# failed and one could not run.
floor_run() {
  local cand="$1" check rc token="" cannot=0
  _FLOOR_CLASS_LISTABLE=0 _FLOOR_CLASS_UNLISTABLE=0 _FLOOR_CLASS_SIZE=0
  for check in "${FLOOR_CHECKS[@]}"; do
    rc=0
    "_floor_$check" "$cand" || rc=$?
    case "$rc" in
      0) ;;
      1) [ -n "$token" ] || token="$check" ;;
      *) cannot=1 ;;
    esac
  done
  if [ -n "$token" ]; then
    if [ "$_FLOOR_CLASS_LISTABLE" = 1 ]; then
      _floor_say "for the operator: remove the flag or label from the ticket, or list the entry in the trust policy's allowed_steering; a trusted approver then releases the quarantine"
    fi
    if [ "$_FLOOR_CLASS_UNLISTABLE" = 1 ]; then
      _floor_say "for the operator: remove the flag or label from the ticket (it cannot be listed in allowed_steering); a trusted approver then releases the quarantine"
    fi
    if [ "$_FLOOR_CLASS_SIZE" = 1 ]; then
      _floor_say "for the operator: shorten the ticket, or raise size_cap in the trust policy; a trusted approver then releases the quarantine"
    fi
    _floor_say "for the operator: a release without one of these fixes quarantines again on the next pull (until #953)"
    printf '%s\n' "$token"
    return 0
  fi
  [ "$cannot" = 0 ] || return 3
  return 0
}

# _floor_listed <entry> [<allowed>…]: 0 iff <entry> equals one of <allowed>,
# by string equality (the _trust_in_scopes shape: never a pattern or a key).
_floor_listed() {
  local want="$1" e
  shift
  for e in "$@"; do [ "$e" = "$want" ] && return 0; done
  return 1
}

# _floor_body_listable <key> <value>: 0 iff `<key>: <value>` is a value the
# scaffold would apply, so a policy could list it (flags.sh's own predicates).
_floor_body_listable() {
  case "$1" in
    tier) tier_is_legal "$2" || tier_shim_model "$2" >/dev/null ;;
    implementation-model|checking-model) model_token_is_legal "$2" ;;
    research|spike) [ "$2" = required ] ;;
    *) return 1 ;;
  esac
}

# _floor_label_listable <label>: 0 iff pull.sh's label channel recognises the
# shape and its model is legal (its fixed match order).
_floor_label_listable() {
  local l="$1" m
  case "$l" in
    tier:impl-*) m="${l#tier:impl-}" ;;
    tier:check-*) m="${l#tier:check-}" ;;
    tier:*-checking) m="${l#tier:}"; m="${m%-checking}" ;;
    *) return 1 ;;
  esac
  model_token_is_legal "$m"
}

# _floor_steering <candidate>: 0 pass, 1 fail, 3 could not run.
# The three reads below send their stderr to /dev/null: a tool's own line (gawk's
# "Invalid multibyte data" warning on a non-UTF-8 byte under a UTF-8 locale) is
# printed before PASS, and each read's status is checked instead (`wait $!`).
# LOAD-BEARING: the floor reads the candidate in the SAME locale as the scaffold
# that later applies it (flags_get, issue_labels). The block grammar depends on
# the locale ([[:space:]] matches U+3000 under UTF-8, not under C), so never pin
# LC_ALL for the floor's reads alone: checked and applied steering would part.
_floor_steering() {
  local cand="$1" e rule n key val lbl i=0 total=0 fail=0 rc=0
  [ -f "$cand" ] && [ -r "$cand" ] || return 3
  local -a body_ok=() label_ok=() labels=()
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    if [[ "$e" == *": "* ]]; then body_ok+=("$e"); else label_ok+=("$e"); fi
  done < <(_trust_list "${TRUST_VAL[allowed_steering]:-[]}")
  # The header ends at issue_labels' own `^---` rule; fetch puts one blank
  # line after it, so body line 1 is the ticket body's first line.
  rule="$(awk '/^---[[:space:]]*$/ { print NR; exit }' "$cand" 2>/dev/null)" || return 3
  [[ "$rule" =~ ^[0-9]+$ ]] || return 3
  while IFS=$'\t' read -r n key val; do
    _floor_listed "$key: $val" "${body_ok[@]}" && continue
    fail=1
    if [[ " $(flags_known_keys) " == *" $key "* ]]; then
      _floor_say "steering: '## Workflow flags' key '$key' on body line $((n - rule - 1)) is not listed in allowed_steering"
      if _floor_body_listable "$key" "$val"; then _FLOOR_CLASS_LISTABLE=1; else _FLOOR_CLASS_UNLISTABLE=1; fi
    else
      _floor_say "steering: an unrecognised '## Workflow flags' key on body line $((n - rule - 1)) cannot be listed"
      _FLOOR_CLASS_UNLISTABLE=1
    fi
  done < <(flags_enumerate "$cand" 2>/dev/null)
  wait $! || rc=$?
  [ "$rc" -eq 0 ] || return 3
  while IFS= read -r lbl; do
    [[ "$lbl" == tier:* ]] && labels+=("$lbl")
  done < <(issue_labels "$cand" 2>/dev/null)
  wait $! || return 3
  total="${#labels[@]}"
  for lbl in "${labels[@]}"; do
    i=$((i + 1))
    _floor_listed "$lbl" "${label_ok[@]}" && continue
    fail=1
    _floor_say "steering: 'tier:' label $i of $total is not listed in allowed_steering"
    if _floor_label_listable "$lbl"; then _FLOOR_CLASS_LISTABLE=1; else _FLOOR_CLASS_UNLISTABLE=1; fi
  done
  return "$fail"
}

# _floor_size <candidate>: 0 pass, 1 fail, 3 could not run.
_floor_size() {
  local cand="$1" cap="${TRUST_VAL[size_cap]:-}" bytes
  [[ "$cap" =~ ^[0-9]{1,10}$ ]] || return 3
  [ -f "$cand" ] && [ -r "$cand" ] || return 3
  bytes="$(wc -c < "$cand")" || return 3
  bytes="${bytes//[[:space:]]/}"
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 3
  if (( 10#$bytes > 10#$cap )); then
    _floor_say "size: $bytes bytes staged, size_cap is $((10#$cap))"
    _FLOOR_CLASS_SIZE=1
    return 1
  fi
  return 0
}
