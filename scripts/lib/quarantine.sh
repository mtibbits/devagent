#!/usr/bin/env bash
# scripts/lib/quarantine.sh — quarantine (#714): a tracker-anchored hold on an
# issue, separate from STUCK and [!]. The tracker label is the authority; the
# issue dir's QUARANTINE file is a cache of it. Source-only.
#
# Load after paths.sh, io.sh, config.sh, state.sh, active.sh and trust.sh.
# None of these functions dies inside $(…): the setter-globals are called bare.
#
# shellcheck shell=bash

_QUARANTINE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
declare -F quarantine_message >/dev/null || source "$_QUARANTINE_LIB_DIR/refusals.sh"
# shellcheck source=/dev/null
declare -F bc_rec_parse >/dev/null || source "$_QUARANTINE_LIB_DIR/issue-events.sh"

# ---- the marker (the local cache) ------------------------------------------
#
# <issue_dir>/QUARANTINE, LF only, exactly:
#   devagent-quarantine 1
#   key <key>
#   reason <token>
#   event <time> <seq>          (`? ?`: the tracker record was not read back)
#   <blank>
#   <the five quarantine_message lines>
# Only lines 1-4 are ever read back, each field against its rule; the message
# lines are for a human who opens the file.

# quarantine_marked <issue_dir>: 0 iff the marker exists, a dangling or
# unreadable one included.
quarantine_marked() {
  [ -e "$1/QUARANTINE" ] || [ -L "$1/QUARANTINE" ]
}

# quarantine_marker_write <issue_dir> <key> <token> <time> <seq>: write the
# marker atomically (temp file, then mv), creating the dir.
quarantine_marker_write() {
  local dir="$1" key="$2" token="$3" time="$4" seq="$5" tmp
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.QUARANTINE.XXXXXX")"
  {
    printf 'devagent-quarantine 1\nkey %s\nreason %s\nevent %s %s\n\n' "$key" "$token" "$time" "$seq"
    quarantine_message "$key"
  } > "$tmp"
  mv -f "$tmp" "$dir/QUARANTINE"
}

# shellcheck disable=SC2034  # setter-globals, read by the callers
# quarantine_marker_read <issue_dir>: SETTER-GLOBAL QM_KEY QM_REASON QM_TIME
# QM_SEQ. A field that fails its rule reads `?`; a bad header, a symlink or an
# unreadable file reads all four as `?` (and the dir still counts as marked).
quarantine_marker_read() {
  local f="$1/QUARANTINE" l1="" l2="" l3="" l4="" v t s r
  QM_KEY="?" QM_REASON="?" QM_TIME="?" QM_SEQ="?"
  [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] || return 0
  { IFS= read -r l1; IFS= read -r l2; IFS= read -r l3; IFS= read -r l4; } < <(head -n 4 "$f" 2>/dev/null) || true
  [ "$l1" = "devagent-quarantine 1" ] || return 0
  v="${l2#key }"
  [ "$l2" != "$v" ] && [[ "$v" =~ ^[A-Za-z0-9:._/#-]{1,200}$ ]] && QM_KEY="$v"
  v="${l3#reason }"
  if [ "$l3" != "$v" ]; then
    for r in "${QUARANTINE_REASONS[@]}"; do [ "$r" = "$v" ] && QM_REASON="$v"; done
  fi
  v="${l4#event }"
  if [ "$l4" != "$v" ] && [[ "$v" == *" "* ]]; then
    t="${v%% *}" s="${v#* }"
    [[ "$t" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z|\?)$ ]] && QM_TIME="$t"
    [[ "$s" =~ ^([0-9]{1,20}|\?)$ ]] && QM_SEQ="$s"
  fi
  return 0
}

# quarantine_print <issue_dir>: the message for the marker's key, then
# `Reason: <token>`, on stdout. No other marker byte is printed.
quarantine_print() {
  quarantine_marker_read "$1"
  quarantine_message "$QM_KEY"
  printf 'Reason: %s\n' "$QM_REASON"
}

# ---- the tracker state (the authority) -------------------------------------

# quarantine_state <label> <set>: bc_rec lines (an `events` read) on stdin →
# `<none|held|released> <label-present 0|1> <qtime> <qseq>` on stdout.
# Q is the latest `labeled` record for <label> (name matched
# case-insensitively). A removal counts only when it is strictly later than Q
# by time: a same-second removal is never after Q, whatever its seq (#714 U2,
# unmeasured: fail closed). Released iff trust_grants <set> accepts the actor of
# one removal after Q; there is no second predicate (D20). Needs a loaded
# policy (TRUST_ID/TRUST_VAL). Never dies; a parse failure returns 1.
quarantine_state() {
  local label="$1" set="$2" recs line kind actor atype qt="?" qs="?" present=1 state=none
  recs="$(bc_rec_parse | jq -rs --arg l "$label" '
    [ .[] | select((.kind == "labeled" or .kind == "unlabeled")
                   and ((.rest // "") | ascii_downcase) == ($l | ascii_downcase)) ] as $r
    | ([ $r[] | select(.kind == "labeled") ]
       | sort_by([.time, (if (.seq | test("^[0-9]+$")) then (.seq | tonumber) else -1 end)])
       | last) as $q
    | if $q == null then "none"
      else "Q \($q.time) \($q.seq)",
        ($r[] | select(.kind == "unlabeled" and .time > $q.time)
         | "U \(if (.actor | test("^[A-Za-z0-9:._-]+$")) then .actor else "?" end) \(if (.atype | test("^[a-z?]+$")) then .atype else "?" end)")
      end' | tr -d '\r')" || return 1
  while IFS= read -r line; do
    kind="${line%% *}"
    case "$kind" in
      Q) line="${line#Q }"; qt="${line%% *}" qs="${line#* }"; state=held ;;
      U) line="${line#U }"; actor="${line%% *}" atype="${line#* }"
         present=0
         if trust_grants "$set" github "$actor" "$atype"; then state=released; fi ;;
    esac
  done <<<"$recs"
  if [ "$state" = none ]; then
    echo "none 0 ? ?"
    return 0
  fi
  printf '%s %s %s %s\n' "$state" "$present" "$qt" "$qs"
}

# shellcheck disable=SC2034  # setter-globals, read by the callers
# quarantine_key <project> <issue_id>: SETTER-GLOBAL QK_BACKEND QK_REPO QK_NUM
# QK_SOURCE (origin|fork, empty when no source maps the id) and QK_KEY — the
# trust key of the issue, from the source whose dir_prefix is the longest one
# that <issue_id> carries followed by digits; `<project>/<issue_id>` when no
# source maps it or the key cannot be built.
quarantine_key() {
  local project="$1" id="$2" which section prefix best=-1 k
  QK_BACKEND="" QK_REPO="" QK_NUM="" QK_SOURCE=""
  for which in origin fork; do
    section=issue_source
    [ "$which" = fork ] && section=issue_source_fork
    prefix="$(config_get_project_field "$project" "$section.dir_prefix" 2>/dev/null || true)"
    prefix="${prefix//$'\r'/}"
    [ -n "$prefix" ] || continue
    [[ "$id" == "$prefix"* ]] && [[ "${id#"$prefix"}" =~ ^[0-9]+$ ]] || continue
    [ "${#prefix}" -gt "$best" ] || continue
    best="${#prefix}" QK_SOURCE="$which" QK_NUM="${id#"$prefix"}"
    QK_BACKEND="$(config_get_project_field "$project" "$section.backend" 2>/dev/null || true)"
    QK_REPO="$(config_get_project_field "$project" "$section.repo" 2>/dev/null || true)"
    QK_BACKEND="${QK_BACKEND//$'\r'/}" QK_REPO="${QK_REPO//$'\r'/}"
    QK_BACKEND="${QK_BACKEND,,}"
  done
  QK_KEY="$project/$id"
  if [ -n "$QK_SOURCE" ] && [ -n "$QK_BACKEND" ] && [ -n "$QK_REPO" ]; then
    declare -p TRUST_VAL >/dev/null 2>&1 || declare -gA TRUST_VAL=()
    if k="$(trust_key "$QK_BACKEND" "$QK_REPO" "$QK_NUM" 2>/dev/null)" && [ -n "$k" ]; then
      QK_KEY="${k//$'\r'/}"
    fi
  fi
  return 0
}
