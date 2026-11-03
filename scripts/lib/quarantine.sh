#!/usr/bin/env bash
# scripts/lib/quarantine.sh — quarantine (#714): a tracker-anchored hold on an
# issue, separate from STUCK and [!]. The tracker label is the authority; the
# issue dir's QUARANTINE file is a cache of it. Source-only.
#
# Load after paths.sh, io.sh and config.sh; it sources state.sh, trust.sh,
# refusals.sh and issue-events.sh when they are not loaded yet.
# None of these functions dies inside $(…): the setter-globals are called bare.
#
# shellcheck shell=bash

_QUARANTINE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
declare -F quarantine_message >/dev/null || source "$_QUARANTINE_LIB_DIR/refusals.sh"
# shellcheck source=/dev/null
declare -F bc_rec_parse >/dev/null || source "$_QUARANTINE_LIB_DIR/issue-events.sh"
# shellcheck source=/dev/null
declare -F state_get >/dev/null || source "$_QUARANTINE_LIB_DIR/state.sh"
# shellcheck source=/dev/null
declare -F trust_key >/dev/null || source "$_QUARANTINE_LIB_DIR/trust.sh"

# Every script that calls a quarantine guard, by its path under scripts/
# minus .sh — the #714 census. tests/quarantine-entry.bats holds it equal to
# the scripts carrying a column-0 guard call, both directions. Step-boundary
# guards (tracker read in scope): pull and quarantine_guard callers; the rest
# are marker-only (#714 operator answer, round 2).
# shellcheck disable=SC2034  # read by tests/quarantine-entry.bats
QUARANTINE_GUARD_POINTS=(
  pull next park resume switch stuck unstuck revise branch commit ship
  mergetoall mergemr comments cleanup spike sync transition-draft-start
  checklist-advance checklist-init checklist-log checklist-mark checklist-stuck
  checklist-unstuck promote-potholes migrate-checklist-numbering depends step-model
  analyze analyze-static analyze-shellcheck analyze-sanitizers born-red
  oneshot-zerodiff preship-evidence preship-verified-head rebaseline rederive
  record-scope run-suite evidence-stamp quarantine-check
)

# The scripts the census sweep reaches that act on no issue dir's work: they
# read and report (#904 gives them the reader message) or touch no issue dir.
# shellcheck disable=SC2034  # read by tests/quarantine-entry.bats
declare -gA QUARANTINE_UNGUARDED=(
  [where]=reader [catchup]=reader [history]=reader [grep]=reader [status]=reader
  [statusreport]=reader [wbs-update]=reader [doctor]=reader [wbs-init]=reader
  [capture/file]="captures, not issue dirs"
)

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

# ---- the refusing guard ------------------------------------------------------

# _quarantine_events <backend> <repo> <num>: one `events` read through the
# backend seam, memoised per process. SETTER-GLOBAL QE_RC QE_OUT; call bare.
# A transition write clears the memo (QE_FOR=""), so a read-back is fresh.
QE_FOR=""
_quarantine_events() {
  local want="$1 $2 $3"
  [ "$QE_FOR" != "$want" ] || return 0
  QE_RC=0
  QE_OUT="$("$(transition_backend_sh "$1")" events "$2" "$3" 2>/dev/null)" || QE_RC=$?
  QE_FOR="$want"
}

# _quarantine_refuse <code> <key>: the message on stderr, then exit <code>.
_quarantine_refuse() {
  quarantine_message "$2" >&2
  exit "$1"
}

# _quarantine_clear_slot <project> <issue> <dir>: when <dir> holds a
# checklist and <issue> is the shared active_issue, empty the slot as park.sh
# does (context saved). Never the parked list, never a glyph.
_quarantine_clear_slot() {
  local active
  [ -f "$3/checklist.md" ] || return 0
  active="$(state_get "$1" active_issue 2>/dev/null || true)"
  [ "$active" = "$2" ] || return 0
  state_context_save "$1" "$2"
  state_unset "$1" active_issue
  state_unset "$1" issue_dir
  state_context_clear "$1"
}

# _quarantine_read_state <label>: quarantine_state over the memoised events.
# SETTER-GLOBAL QS_STATE QS_PRESENT QS_TIME QS_SEQ; returns 1 when the records
# do not parse.
_quarantine_read_state() {
  local out
  out="$(printf '%s\n' "$QE_OUT" | quarantine_state "$1" trusted_approvers)" || return 1
  read -r QS_STATE QS_PRESENT QS_TIME QS_SEQ <<<"$out"
}

# _quarantine_decide <dir> <project> <id> <step|pull>: refuse (exit 11 in step
# mode, 7 in pull mode) when <dir>'s issue is quarantined; return otherwise.
# Out of trust scope only the marker counts, with no network. In scope the
# tracker decides:
#   - no quarantine label in the policy refuses (9, quarantine-unmapped);
#   - events unsupported (2|78) refuses (9); any other failure refuses with the
#     mode's code when a marker exists, else asks for a retry (10);
#   - held refuses; so does a marker, unless the mode is pull and the tracker
#     released the very quarantine the marker read back. Before refusing it
#     re-applies an absent label (held, none with a marker, or a marker whose
#     quarantine the tracker does not show released) — never over a release of
#     the marker's own quarantine — writes or refreshes the marker, and clears
#     the shared slot;
#   - pull mode, released, marker confirmed: returns with
#     QUARANTINE_RELEASED=prework|inwork (the caller removes the marker).
QUARANTINE_RELEASED=""
# shellcheck disable=SC2034  # QUARANTINE_RELEASED is read by pull.sh
_quarantine_decide() {
  local dir="$1" project="$2" id="$3" mode="$4" code=11 marked=0 label
  local reason tt="?" ts="?" apply=0 confirmed=0 rc
  [ "$mode" = pull ] && code=7
  QUARANTINE_RELEASED=""
  quarantine_marked "$dir" && marked=1
  if [ "${TRUST_IN_SCOPE:-0}" != 1 ]; then
    [ "$marked" = 1 ] || return 0
    quarantine_key "$project" "$id"
    _quarantine_refuse "$code" "$QK_KEY"
  fi
  label="$(printf '%s' "${TRUST_VAL[quarantine]:-null}" | jq -r '. // empty' 2>/dev/null | tr -d '\r')"
  [ -n "$label" ] || refuse quarantine-unmapped
  quarantine_key "$project" "$id"
  if [ -z "$QK_SOURCE" ] || [ -z "$QK_REPO" ]; then
    [ "$marked" = 1 ] || return 0
    _quarantine_refuse "$code" "$QK_KEY"
  fi
  _quarantine_events "$QK_BACKEND" "$QK_REPO" "$QK_NUM"
  case "$QE_RC" in
    0) ;;
    2|78) refuse events-unsupported "$QK_BACKEND" "$QE_RC" ;;
    *) [ "$marked" = 1 ] && _quarantine_refuse "$code" "$QK_KEY"
       try_later events-unavailable "$QK_REPO#$QK_NUM" "$QE_RC" ;;
  esac
  if ! _quarantine_read_state "$label"; then
    [ "$marked" = 1 ] && _quarantine_refuse "$code" "$QK_KEY"
    try_later events-unavailable "$QK_REPO#$QK_NUM" parse
  fi
  if [ "$marked" = 1 ]; then
    quarantine_marker_read "$dir"
    # the marker's quarantine is the tracker's latest one when the marker read
    # its record back and the tracker's latest is not older than it.
    if [ "$QM_TIME" != "?" ] && [ "$QS_TIME" != "?" ] && [[ ! "$QS_TIME" < "$QM_TIME" ]]; then confirmed=1; fi
  fi
  case "$QS_STATE" in
    held) [ "$QS_PRESENT" = 1 ] || apply=1 ;;
    none) [ "$marked" = 1 ] || return 0
          apply=1 ;;
    released)
      [ "$marked" = 1 ] || return 0
      if [ "$confirmed" = 1 ]; then
        if [ "$mode" = pull ]; then
          QUARANTINE_RELEASED=prework
          [ ! -f "$dir/checklist.md" ] || QUARANTINE_RELEASED=inwork
          return 0
        fi
      else
        apply=1
      fi ;;
  esac
  if [ "$apply" = 1 ]; then
    rc=0
    "$(transition_backend_sh "$QK_BACKEND")" transition "$QK_REPO" "$QK_NUM" quarantine --project "$project" >/dev/null 2>&1 || rc=$?
    QE_FOR=""
    QS_STATE="?" QS_PRESENT=0
    if [ "$rc" -ne 0 ]; then
      printf 'quarantine: the quarantine label could not be re-applied on %s#%s (exit %s); the next guarded call retries\n' \
        "$QK_REPO" "$QK_NUM" "$rc" >&2
    else
      _quarantine_events "$QK_BACKEND" "$QK_REPO" "$QK_NUM"
      if [ "$QE_RC" = 0 ]; then _quarantine_read_state "$label" || QS_STATE="?"; fi
    fi
  fi
  if [ "$QS_STATE" = held ] && [ "$QS_PRESENT" = 1 ]; then tt="$QS_TIME" ts="$QS_SEQ"; fi
  reason=tracker
  if [ "$marked" = 1 ]; then
    [ "$QM_REASON" = "?" ] || reason="$QM_REASON"
    # a marker left alone keeps its event when the tracker shows no fresher one
    if [ "$apply" = 0 ] && [ "$tt" = "?" ]; then tt="$QM_TIME" ts="$QM_SEQ"; fi
  fi
  if [ "$marked" = 0 ] || [ "$QM_KEY" != "$QK_KEY" ] || [ "$QM_REASON" != "$reason" ] \
     || [ "$QM_TIME" != "$tt" ] || [ "$QM_SEQ" != "$ts" ]; then
    quarantine_marker_write "$dir" "$QK_KEY" "$reason" "$tt" "$ts"
  fi
  _quarantine_clear_slot "$project" "$id" "$dir"
  _quarantine_refuse "$code" "$QK_KEY"
}

# _quarantine_issue_token <project> <token>: 0 iff <token> is a configured
# dir_prefix followed by digits (an issue id this project's sources map).
_quarantine_issue_token() {
  local which prefix
  [ -n "$2" ] || return 1
  for which in issue_source issue_source_fork; do
    prefix="$(config_get_project_field "$1" "$which.dir_prefix" 2>/dev/null || true)"
    prefix="${prefix//$'\r'/}"
    [ -n "$prefix" ] || continue
    if [[ "$2" == "$prefix"* ]] && [[ "${2#"$prefix"}" =~ ^[0-9]+$ ]]; then return 0; fi
  done
  return 1
}

# _quarantine_resolve <project> [<issue-arg>]: SETTER-GLOBAL QG_ISSUE QG_DIR —
# the issue a caller's resolver will act on, found without dying:
# <issue-arg> when it is a mapped issue id, else a valid DEVAGENT_ACTIVE_ISSUE,
# else the state's active_issue. Returns 1 when none resolves (the caller's
# own error path then runs unchanged).
_quarantine_resolve() {
  local project="$1" arg="${2:-}" issue=""
  QG_ISSUE="" QG_DIR=""
  [ -n "$project" ] || return 1
  if _quarantine_issue_token "$project" "$arg"; then
    issue="$arg"
  elif [ -n "${DEVAGENT_ACTIVE_ISSUE:-}" ]; then
    [[ "$DEVAGENT_ACTIVE_ISSUE" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    issue="$DEVAGENT_ACTIVE_ISSUE"
  else
    issue="$(state_get "$project" active_issue 2>/dev/null || true)"
    [[ "$issue" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  fi
  QG_DIR="$(issue_dir_for "$project" "$issue" 2>/dev/null)" || return 1
  QG_ISSUE="$issue"
}

# _quarantine_marker_refuse <dir> <project> <id>: the marker-only check —
# exit 11 when <dir> is marked, with no network whatever the trust scope.
# The key is the issue's (as every guard prints it), or the marker's own when
# no project is known.
_quarantine_marker_refuse() {
  quarantine_marked "$1" || return 0
  if [ -n "$2" ]; then
    quarantine_key "$2" "$3"
  else
    quarantine_marker_read "$1"
    QK_KEY="$QM_KEY"
  fi
  _quarantine_refuse 11 "$QK_KEY"
}

# quarantine_guard <caller> <project> [<issue-arg>]: the step-boundary guard
# (#714 operator answer, round 2): call BARE on the line after
# trust_entry_check. In scope it reads the tracker (_quarantine_decide); out of
# scope only the marker counts. Exits 11 on a quarantined issue.
quarantine_guard() {
  _quarantine_resolve "$2" "${3:-}" || return 0
  _quarantine_decide "$QG_DIR" "$2" "$QG_ISSUE" step
}

# quarantine_guard_marker <caller> <project> [<issue-arg>]: quarantine_guard's
# resolution, marker only — for helpers that run inside a step (analyzers,
# evidence, scope, depends): the step boundary already read the tracker.
quarantine_guard_marker() {
  _quarantine_resolve "$2" "${3:-}" || return 0
  _quarantine_marker_refuse "$QG_DIR" "$2" "$QG_ISSUE"
}

# quarantine_guard_dir <caller> <issue_dir>: the marker-only check for an entry
# point handed an issue dir (the checklist-* family, promote-potholes,
# migrate-checklist-numbering). The project is the trust check's in scope,
# else the one config project owning the dir's parent — looked up only when
# the dir is marked, so an unmarked run stays [ -e ] / [ -L ].
quarantine_guard_dir() {
  local dir="${2%/}" project
  [ -n "$dir" ] || return 0
  quarantine_marked "$dir" || return 0
  project="${TRUST_PROJECT:-}"
  [ "${TRUST_IN_SCOPE:-0}" = 1 ] || project="$(trust_project_for_devdoc "$(dirname -- "$dir")")"
  _quarantine_marker_refuse "$dir" "$project" "$(basename -- "$dir")"
}

# ---- pull --------------------------------------------------------------------

# quarantine_pull_guard <project> <issue_id> <issue_dir>: pull's pre-fetch
# guard, called bare on the line after trust_entry_check, before the issue dir
# is created. In scope the policy's label must exist on the repo (4 refuses 9:
# a deleted or renamed label stops the queue; any other failure asks for a
# retry). Then the decision in pull mode: exit 7 while quarantined. On a
# release by a trusted approver it removes the marker and leaves
# QUARANTINE_RELEASED=prework|inwork for the promotion block.
quarantine_pull_guard() {
  local project="$1" id="$2" dir="$3" label rc=0
  if [ "${TRUST_IN_SCOPE:-0}" = 1 ]; then
    label="$(printf '%s' "${TRUST_VAL[quarantine]:-null}" | jq -r '. // empty' 2>/dev/null | tr -d '\r')"
    [ -n "$label" ] || refuse quarantine-unmapped
    quarantine_key "$project" "$id"
    if [ -n "$QK_REPO" ]; then
      "$(transition_backend_sh "$QK_BACKEND")" state-exists "$QK_REPO" "$label" >/dev/null 2>&1 || rc=$?
      case "$rc" in
        0) ;;
        4) refuse quarantine-label-missing "$label" "$QK_REPO" ;;
        *) try_later events-unavailable "$QK_REPO#$QK_NUM" "$rc" ;;
      esac
    fi
  fi
  _quarantine_decide "$dir" "$project" "$id" pull
  if [ -n "$QUARANTINE_RELEASED" ]; then rm -f "$dir/QUARANTINE"; fi
}

# quarantine_verdict <project> <issue_dir>: `PASS` or `QUARANTINE <token>` on
# stdout; never dies. #714 has one source, the policy-gated test seam:
# DEVAGENT_TEST_QUARANTINE=<token>, honoured only in scope, with
# test_seams = true, and a token in QUARANTINE_REASONS. The deciders (#715 on)
# add sources here; none may turn another source's QUARANTINE into PASS.
quarantine_verdict() {
  local t="${DEVAGENT_TEST_QUARANTINE:-}" r
  if [ -n "$t" ] && [ "${TRUST_IN_SCOPE:-0}" = 1 ] && [ "${TRUST_VAL[test_seams]:-false}" = true ]; then
    for r in "${QUARANTINE_REASONS[@]}"; do
      if [ "$r" = "$t" ]; then echo "QUARANTINE $t"; return 0; fi
    done
  fi
  echo PASS
}

# quarantine_pull_quarantine <project> <issue_id> <issue_dir> <token>: pull's
# quarantine of the ticket it just fetched; exits 6. Pre-work (no checklist)
# the fetched issue.md is removed; in-work the files stay and the shared slot
# is cleared. One label write, one fresh read-back; the marker carries the
# quarantine's time and seq when the read-back shows it, else `? ?` (the next
# guarded call re-applies). No state change and no log line pre-work.
quarantine_pull_quarantine() {
  local project="$1" id="$2" dir="$3" token="$4" label rc=0 tt="?" ts="?"
  label="$(printf '%s' "${TRUST_VAL[quarantine]:-null}" | jq -r '. // empty' 2>/dev/null | tr -d '\r')"
  quarantine_key "$project" "$id"
  if [ -f "$dir/checklist.md" ]; then
    _quarantine_clear_slot "$project" "$id" "$dir"
  else
    rm -f "$dir/issue.md"
  fi
  "$(transition_backend_sh "$QK_BACKEND")" transition "$QK_REPO" "$QK_NUM" quarantine --project "$project" >/dev/null 2>&1 || rc=$?
  QE_FOR=""
  if [ "$rc" -ne 0 ]; then
    printf 'quarantine: the quarantine label could not be applied on %s#%s (exit %s); the next guarded call retries\n' \
      "$QK_REPO" "$QK_NUM" "$rc" >&2
  else
    _quarantine_events "$QK_BACKEND" "$QK_REPO" "$QK_NUM"
    if [ "$QE_RC" = 0 ] && [ -n "$label" ] && _quarantine_read_state "$label" \
       && [ "$QS_STATE" = held ] && [ "$QS_PRESENT" = 1 ]; then
      tt="$QS_TIME" ts="$QS_SEQ"
    fi
  fi
  quarantine_marker_write "$dir" "$QK_KEY" "$token" "$tt" "$ts"
  _quarantine_refuse 6 "$QK_KEY"
}
