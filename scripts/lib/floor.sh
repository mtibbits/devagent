#!/usr/bin/env bash
# scripts/lib/floor.sh — pull's deterministic floor under a trust policy (#715;
# spec §9.3). Runs on the candidate issue.md in the staging dir, before anything
# reads or prints it, as the first source of quarantine_verdict
# (scripts/lib/quarantine.sh).
#
# FLOOR_CHECKS run in order. Every check runs, each
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
#   chars     (#923) the title, body, Labels, State and Author values must hold
#             no character of the pinned-Unicode invisible set (chars.py,
#             chars_table.py: Bidi_Control, Default_Ignorable_Code_Point, gc
#             Cf, Cn, Cs, and Cc other than TAB, LF and CR) and no invalid
#             UTF-8. The render (staging_render.py) has already written each
#             allowlisted character as `<U+XXXX>` and each C0 byte or DEL of the
#             title and header values as #715's `<U+00HH>`, so the floor scans
#             with the empty allowlist: a raw set character left is a hit.
#             When `chars` is the token, floor_run's stdout gains a second line,
#             `detail: <first hit>[ (+N more)]` (refusals.sh's
#             QUARANTINE_DETAIL_RE), which quarantine_verdict carries to the
#             marker.
#
# Diagnostics name a key of flags_known_keys, a body line number, a label's
# index, a field, line and code point, or a count — never a ticket byte. Each
# ends with remedy lines addressed to the operator, never to the worker session.
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
# shellcheck source=/dev/null
declare -F info >/dev/null || source "$_FLOOR_LIB_DIR/io.sh"
# Issue-1050: chars needs the detail grammar; trust.sh is not relied on for it.
# shellcheck source=/dev/null
[ -n "${QUARANTINE_DETAIL_RE:-}" ] || source "$_FLOOR_LIB_DIR/refusals.sh"

FLOOR_CHECKS=(steering size chars)

# A check prints at most FLOOR_SAY_MAX diagnostics, then `<check>: <n> more not
# shown`: the ticket's author must not set how much the worker session reads.
FLOOR_SAY_MAX=20

# _floor_say <text>: one diagnostic line, on fd 3 (floor_run points it at
# stderr), unless this check has already said FLOOR_SAY_MAX (it counts them).
_floor_say() {
  _FLOOR_SAID=$((_FLOOR_SAID + 1))
  [ "$_FLOOR_SAID" -le "$FLOOR_SAY_MAX" ] || return 0
  info "floor: $1" 2>&3
}

# floor_run <candidate>: the first failing check's token on stdout, or nothing.
# rc 0 whenever a check failed or all passed; rc 3, no token, when no check
# failed and one could not run.
floor_run() { _floor_run "$1" 3>&2; }

# _floor_run <candidate>: floor_run's body. Each check runs with its stderr on
# /dev/null, so a tool's own line (gawk's "Invalid multibyte data" warning on a
# non-UTF-8 byte under a UTF-8 locale) is never printed before PASS; a check
# speaks only through _floor_say and reports a failed read by its status.
_floor_run() {
  local cand="$1" check rc more token="" cannot=0
  _FLOOR_CLASS_LISTABLE=0 _FLOOR_CLASS_UNLISTABLE=0 _FLOOR_CLASS_SIZE=0 _FLOOR_CLASS_CHARS=0 _FLOOR_DETAIL=""
  for check in "${FLOOR_CHECKS[@]}"; do
    rc=0 _FLOOR_SAID=0
    "_floor_$check" "$cand" 2>/dev/null || rc=$?
    if [ "$_FLOOR_SAID" -gt "$FLOOR_SAY_MAX" ]; then
      more=$((_FLOOR_SAID - FLOOR_SAY_MAX)) _FLOOR_SAID=0
      _floor_say "$check: $more more not shown"
    fi
    case "$rc" in
      0) ;;
      1) [ -n "$token" ] || token="$check" ;;
      *) cannot=1 ;;
    esac
  done
  _FLOOR_SAID=0
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
    # #953's human PASS can lift these classes; it never overrides chars, which
    # has its own last line.
    if [ "$_FLOOR_CLASS_LISTABLE" = 1 ] || [ "$_FLOOR_CLASS_UNLISTABLE" = 1 ] || [ "$_FLOOR_CLASS_SIZE" = 1 ]; then
      _floor_say "for the operator: a release without one of these fixes quarantines again on the next pull (until #953)"
    fi
    if [ "$_FLOOR_CLASS_CHARS" = 1 ]; then
      _floor_say "for the operator: edit the text, remove the label that holds the character, or add the character to the trust policy's allowed_chars (a run longer than two, or invalid UTF-8, can only be edited out); a trusted approver then releases the quarantine"
      _floor_say "for the operator: a chars quarantine released without one of these fixes quarantines again on every pull"
    fi
    printf '%s\n' "$token"
    if [ "$token" = chars ]; then printf 'detail: %s\n' "$_FLOOR_DETAIL"; fi
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

# _floor_steering <candidate>: 0 pass, 1 fail, 3 could not run. Each read's
# status is checked (`wait $!`), since its stderr is /dev/null (_floor_run).
# LOAD-BEARING: the floor reads the candidate in the SAME locale as the scaffold
# that later applies it (flags_get, issue_labels). The block grammar depends on
# the locale ([[:space:]] matches U+3000 under UTF-8, not under C), so never pin
# LC_ALL for the floor's reads alone: checked and applied steering would part.
_floor_steering() {
  local cand="$1" e rule row n key val line known lbl i=0 total=0 fail=0
  [ -f "$cand" ] && [ -r "$cand" ] || return 3
  local -a body_ok=() label_ok=() labels=()
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    if [[ "$e" == *": "* ]]; then body_ok+=("$e"); else label_ok+=("$e"); fi
  done < <(_trust_list "${TRUST_VAL[allowed_steering]:-[]}")
  # The header ends at issue_labels' own `^---` rule; fetch puts one blank
  # line after it, so body line 1 is the ticket body's first line.
  rule="$(awk '/^---[[:space:]]*$/ { print NR; exit }' "$cand")" || return 3
  [[ "$rule" =~ ^[0-9]+$ ]] || return 3
  known=" $(flags_known_keys) "
  # `read` alone runs in the C locale: under UTF-8 it takes the LF after an
  # incomplete lead byte as data, dropping a last row and merging a middle one
  # (red team); the awk reads above and below keep the scaffold's locale. Split
  # the row by expansion, never by IFS: `read` drops a NUL, and IFS=$'\t' would
  # then strip the TAB beside it that flags_get keeps (review I1).
  while IFS= LC_ALL=C read -r row; do
    n="${row%%$'\t'*}"; row="${row#*$'\t'}"; key="${row%%$'\t'*}"; val="${row#*$'\t'}"
    _floor_listed "$key: $val" "${body_ok[@]}" && continue
    fail=1 line=$((n - rule - 1))
    if [[ "$known" == *" $key "* ]]; then
      _floor_say "steering: '## Workflow flags' key '$key' on body line $line is not listed in allowed_steering"
      if _floor_body_listable "$key" "$val"; then _FLOOR_CLASS_LISTABLE=1; else _FLOOR_CLASS_UNLISTABLE=1; fi
    else
      _floor_say "steering: an unrecognised '## Workflow flags' key on body line $line cannot be listed"
      _FLOOR_CLASS_UNLISTABLE=1
    fi
  done < <(flags_enumerate "$cand")
  [ -z "$row" ] || return 3
  wait $! || return 3
  while IFS= LC_ALL=C read -r lbl; do
    [[ "$lbl" == tier:* ]] && labels+=("$lbl")
  done < <(issue_labels "$cand")
  [ -z "$lbl" ] || return 3
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

# _floor_chars <candidate>: 0 pass, 1 fail, 3 could not run. chars.py scans the
# candidate's five fields with the empty allowlist (the render already escaped
# the allowlisted characters) and prints `hits <total>` and the first
# min(total, FLOOR_SAY_MAX) hits. Its output is ASCII by contract and is
# accepted only whole: exit 0, a bounded count, exactly that many lines, each
# in refusals.sh's grammar pieces — anything else is could-not-run, never a
# pass and never a hit. SETTER-GLOBAL _FLOOR_DETAIL, _FLOOR_CLASS_CHARS.
_floor_chars() {
  local cand="$1" out rc=0 total want i re LC_ALL=C
  local -a rows=()
  [ -n "${QUARANTINE_DETAIL_RE:-}" ] && [ -n "${QUARANTINE_DETAIL_FIELD_RE:-}" ] || return 3
  [ -f "$cand" ] && [ -r "$cand" ] || return 3
  out="$(python3 -I -X utf8 "$_FLOOR_LIB_DIR/chars.py" scan --candidate "$cand" --max "$FLOOR_SAY_MAX")" || rc=$?
  [ "$rc" -eq 0 ] || return 3
  mapfile -t rows <<<"$out"
  [[ "${rows[0]:-}" =~ ^hits\ ([0-9]{1,9})$ ]] || return 3
  total=$((10#${BASH_REMATCH[1]}))
  want="$total"
  [ "$want" -le "$FLOOR_SAY_MAX" ] || want="$FLOOR_SAY_MAX"
  [ "${#rows[@]}" -eq $((want + 1)) ] || return 3
  re="^${QUARANTINE_DETAIL_FIELD_RE} line ${QUARANTINE_DETAIL_LINE_RE} ${QUARANTINE_DETAIL_POINT_RE}\$"
  for ((i = 1; i <= want; i++)); do
    [[ "${rows[i]}" =~ $re ]] || return 3
  done
  [ "$total" -gt 0 ] || return 0
  for ((i = 1; i <= want; i++)); do _floor_say "chars: ${rows[i]}"; done
  _FLOOR_SAID="$total"
  _FLOOR_DETAIL="${rows[1]}"
  [ "$total" -eq 1 ] || _FLOOR_DETAIL+=" (+$((total - 1)) more)"
  _FLOOR_CLASS_CHARS=1
  return 1
}
