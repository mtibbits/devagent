#!/usr/bin/env bash
# scripts/lib/question-actions.sh — #962: the one home of the operator-question
# format. hold.sh and next.sh call these functions and never re-spell a rule:
# the question-file grammar, the renderer that writes both the open record and
# the question STUCK, the number, the open-record finder, the hold-line reader,
# the questions/.lock, the no-clobber publish, and the option-tag registry.
#
# Sourced only. Sourcing prints nothing and sets no shell option. Every
# function returns a status and never exits. Requires paths.sh and io.sh;
# question_action_perform also needs config.sh (issue_dir_for).
#
# Question file (spec §5.3): CR stripped; the only `## ` headings are
# `## Question`, `## Impediment`, `## Options`, `## Evidence`, each once, in that
# order, each with a non-blank line, and only blank lines before the first.
# Every non-blank `## Options` line is an option (QUESTION_OPTION_RE).

# One option line: id, `(recommended)`, an optional `[tag: value]`, the text.
# shellcheck disable=SC2016  # the backticks are literal markdown
QUESTION_OPTION_RE='^- `([a-z0-9][a-z0-9-]{0,31})`( \(recommended\))?( \[([a-z][a-z0-9-]{0,31}): ([^]]+)\])? ([^[:space:]].*)$'
# The answer line, read back only after the `## How to answer` heading.
QUESTION_ANSWER_RE='^/devagent:answer [^ ]+ [^ ]+ ([0-9]{2,4}) ([a-z0-9][a-z0-9-]{0,31})$'
QUESTION_SECTIONS=(Question Impediment Options Evidence)

# ---- parsing --------------------------------------------------------------

# _question_load: read a question body from stdin into globals.
#   _QL_ORDER   headings in file order (duplicates repeated)
#   _QL_BODY[h] the section's lines, normalised: CR stripped, blank-only lines
#               emptied, leading and trailing blank lines dropped, runs of
#               blank lines collapsed to one
#   _QL_PRE     1 when a non-blank line precedes the first heading
_question_load() {
  local line cur="" have=0
  _QL_ORDER=()
  _QL_PRE=0
  declare -gA _QL_BODY=()
  declare -gA _QL_RAW=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    if [[ "$line" == "## "* ]]; then
      cur="${line#"## "}"
      _QL_ORDER+=("$cur")
      _QL_RAW[$cur]="${_QL_RAW[$cur]-}"
      continue
    fi
    [[ "$line" =~ ^[[:space:]]*$ ]] && line=""
    if (( ${#_QL_ORDER[@]} == 0 )); then
      [[ -z "$line" ]] || _QL_PRE=1
      continue
    fi
    _QL_RAW[$cur]+="$line"$'\n'
  done
  local h out l blank
  for h in "${!_QL_RAW[@]}"; do
    out="" blank=0 have=0
    while IFS= read -r l; do
      if [[ -z "$l" ]]; then
        (( have )) && blank=1
        continue
      fi
      (( blank )) && out+=$'\n'
      out+="$l"$'\n'
      blank=0 have=1
    done <<< "${_QL_RAW[$h]}"
    _QL_BODY[$h]="$out"
  done
}

# _question_check: validate what _question_load read. Sets _QV_ERR to the
# refusal id (empty when valid), _QV_REC to the recommended id and _QV_IDS to
# every option id in file order. Runs under LC_ALL=C.
_question_check() {
  local LC_ALL=C
  local h i line id tag val rc
  _QV_ERR="" _QV_REC="" _QV_IDS=()
  declare -A seen_h=() seen_id=()
  for h in "${_QL_ORDER[@]}"; do
    case "$h" in Question|Impediment|Options|Evidence) ;; *) _QV_ERR=heading; return 2 ;; esac
  done
  (( _QL_PRE == 0 )) || { _QV_ERR=heading; return 2; }
  for h in "${_QL_ORDER[@]}"; do
    [[ -z "${seen_h[$h]-}" ]] || { _QV_ERR=heading; return 2; }
    seen_h[$h]=1
  done
  for h in "${QUESTION_SECTIONS[@]}"; do
    [[ -n "${seen_h[$h]-}" ]] || { _QV_ERR=section; return 2; }
  done
  for i in 0 1 2 3; do
    [[ "${_QL_ORDER[$i]}" == "${QUESTION_SECTIONS[$i]}" ]] || { _QV_ERR=heading; return 2; }
  done
  [[ -n "${_QL_BODY[Options]}" ]] || { _QV_ERR=option; return 2; }
  for h in "${QUESTION_SECTIONS[@]}"; do
    [[ -n "${_QL_BODY[$h]}" ]] || { _QV_ERR=section; return 2; }
  done
  local -a tags=() vals=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" =~ $QUESTION_OPTION_RE ]] || { _QV_ERR=option; return 2; }
    id="${BASH_REMATCH[1]}"
    [[ -z "${seen_id[$id]-}" ]] || { _QV_ERR=option-id; return 2; }
    seen_id[$id]=1
    _QV_IDS+=("$id")
    if [[ -n "${BASH_REMATCH[2]}" ]]; then
      [[ -z "$_QV_REC" ]] || { _QV_ERR=recommended; return 2; }
      _QV_REC="$id"
    fi
    if [[ -n "${BASH_REMATCH[3]}" ]]; then
      tags+=("${BASH_REMATCH[4]}")
      vals+=("${BASH_REMATCH[5]}")
    fi
  done <<< "${_QL_BODY[Options]}"
  [[ -n "$_QV_REC" ]] || { _QV_ERR=recommended; return 2; }
  for i in "${!tags[@]}"; do
    tag="${tags[$i]}" val="${vals[$i]}"
    rc=0
    question_action_check "$tag" "$val" || rc=$?
    case "$rc" in
      0) ;;
      2) _QV_ERR=tag; return 2 ;;
      *) _QV_ERR="tag-check"; return 2 ;;
    esac
  done
  return 0
}

# _question_print_body: the four sections from _QL_BODY in canonical order —
# `## <name>`, a blank line, the section, and a blank line between sections.
_question_print_body() {
  local h first=1
  for h in "${QUESTION_SECTIONS[@]}"; do
    [[ -n "${_QL_BODY[$h]-}" ]] || continue
    (( first )) || printf '\n'
    printf '## %s\n\n%s' "$h" "${_QL_BODY[$h]}"
    first=0
  done
}

# _question_header_value <file> <key>: the first `<key>:` value in the header
# (lines before the first blank line), CR and surrounding blanks stripped.
_question_header_value() {
  awk -v key="$2:" '
    { sub(/\r$/, "") }
    /^[ \t]*$/ { exit }
    index($0, key) == 1 {
      v = substr($0, length(key) + 1); gsub(/^[ \t]+|[ \t]+$/, "", v)
      print v; exit
    }' "$1" 2>/dev/null
}

# ---- the public readers -----------------------------------------------------

# question_validate <file>: 0, or 2 with the refusal id on stdout.
question_validate() {
  [[ -f "$1" && -r "$1" ]] || { _QV_ERR=question-file; printf '%s\n' "$_QV_ERR"; return 2; }
  _question_load < "$1"
  _question_check || { printf '%s\n' "$_QV_ERR"; return 2; }
  return 0
}

# question_render <file> <project> <issue> <step> <N> <reason> <last-good> <NN> <created>
# The STUCK (and open record) text on stdout: the header, a blank line, the
# file's four sections, `## How to answer` and the answer block. 2 (with the
# refusal id on stdout) when the file is not a valid question.
question_render() {
  local file="$1" project="$2" issue="$3" step="$4" num="$5" reason="$6"
  local last_good="${7:-(none)}" nn="$8" created="$9" others="" id
  [[ "$nn" =~ ^[0-9]{2,4}$ ]] || { printf 'number\n'; return 2; }
  question_validate "$file" > /dev/null || { printf '%s\n' "$_QV_ERR"; return 2; }
  for id in "${_QV_IDS[@]}"; do
    [[ "$id" == "$_QV_REC" ]] && continue
    others+="${others:+, }$id"
  done
  printf 'Kind:        question\nStep:        %s %s\nReason:      %s\nLast good:   %s\nCreated:     %s\n\n' \
    "$num" "$step" "$reason" "$last_good" "$created"
  _question_print_body
  printf '\n## How to answer\n\n/devagent:answer %s %s %02d %s\nOther options: %s\n' \
    "$project" "$issue" "$((10#$nn))" "$_QV_REC" "${others:-(none)}"
}

# question_body <record-or-STUCK>: the four sections, as the renderer wrote them.
question_body() {
  [[ -f "$1" ]] || return 1
  _question_load < <(awk '
    { sub(/\r$/, "") }
    /^## How to answer$/ { exit }
    /^## / { on = 1 }
    on' "$1")
  _question_print_body
}

question_reason() { _question_header_value "$1" Reason; }

# question_step <file>: the step NAME of the `Step:` header (`5 improve` → improve).
question_step() {
  local v
  v="$(_question_header_value "$1" Step)"
  [[ -n "$v" ]] || return 1
  printf '%s\n' "${v##* }"
}

# question_step_row <file>: the `Step:` header as written (`5 improve`).
question_step_row() {
  local v
  v="$(_question_header_value "$1" Step)"
  [[ -n "$v" ]] || return 1
  printf '%s\n' "$v"
}

# question_answer_line <file>: the answer line, read only after the
# `## How to answer` heading (a quoted answer line in a section never counts).
question_answer_line() {
  local LC_ALL=C line on=0
  [[ -f "$1" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if (( ! on )); then
      [[ "$line" == "## How to answer" ]] && on=1
      continue
    fi
    if [[ "$line" =~ $QUESTION_ANSWER_RE ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  done < "$1"
  return 1
}

# question_number <file>: the NN of the answer line.
question_number() {
  local LC_ALL=C line
  line="$(question_answer_line "$1")" || return 1
  [[ "$line" =~ $QUESTION_ANSWER_RE ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# question_answered <file>: 0 iff the file has a `## Answer` line.
question_answered() { grep -q '^## Answer' "$1" 2>/dev/null; }

# question_open_record <issue-dir> <step>: the path of the highest-numbered open
# in-session record for <step> — named `NN-<step>.md`, no `Blocking: no` header
# line, no `## Answer` line — or nothing.
question_open_record() {
  local dir="$1/questions" step="$2" f name nn best="" bestn=-1
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*.md; do
    [[ -f "$f" ]] || continue
    name="${f##*/}"
    nn="${name%%-*}"
    [[ "$nn" =~ ^[0-9]{2,4}$ && "$name" == "$nn-$step.md" ]] || continue
    [[ "$(_question_header_value "$f" Blocking)" == no ]] && continue
    question_answered "$f" && continue
    if (( 10#$nn > bestn )); then bestn=$((10#$nn)); best="$f"; fi
  done
  [[ -z "$best" ]] || printf '%s\n' "$best"
}

# question_next_number <issue-dir>: one more than the highest number among the
# questions/ file names, the STUCK's answer line and the `question NN` numbers
# of the checklist log's hold-line and park entries; `01` when there is none.
# A hand-removed STUCK therefore never frees its number. 1 past 9999.
question_next_number() {
  local d="$1" f name nn top=0
  if [[ -d "$d/questions" ]]; then
    for f in "$d/questions"/*.md; do
      [[ -e "$f" ]] || continue
      name="${f##*/}"; nn="${name%%-*}"
      [[ "$nn" =~ ^[0-9]{2,4}$ ]] || continue
      (( 10#$nn > top )) && top=$((10#$nn))
    done
  fi
  if [[ -f "$d/STUCK" ]] && nn="$(question_number "$d/STUCK")"; then
    (( 10#$nn > top )) && top=$((10#$nn))
  fi
  if [[ -f "$d/checklist.md" ]]; then
    while IFS= read -r nn; do
      [[ "$nn" =~ ^[0-9]{2,4}$ ]] || continue
      (( 10#$nn > top )) && top=$((10#$nn))
    done < <(sed -nE \
      -e 's/^- .*: hold line written for question ([0-9]{2,4})\r?$/\1/p' \
      -e 's/^- .*park: issue parked.*: operator question ([0-9]{2,4}): .*$/\1/p' \
      "$d/checklist.md")
  fi
  (( top < 9999 )) || return 1
  printf '%02d\n' "$((top + 1))"
}

# question_line_logged <issue-dir> <step> <NN>: 0 iff the checklist log holds
# that exact hold-line entry — the hold's proof that its line was appended.
question_line_logged() {
  local nn
  [[ "$3" =~ ^[0-9]{2,4}$ ]] || return 1
  nn="$(printf '%02d' "$((10#$3))")"
  grep -Eq "^- [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}  $2: hold line written for question $nn\$" \
    "$1/checklist.md" 2>/dev/null
}

# ---- the lock and the publish ---------------------------------------------

# question_lock <issue-dir> [wait-seconds]: take <issue-dir>/questions/.lock
# (a `set -C` create holding this process's pid), polling every 0.1 s until
# the wait (default 10 s) has passed. On timeout prints the lock-busy line and
# returns 1. Never breaks a lock. Not re-entrant: a holder must not call it
# again, nor question_action_perform.
question_lock() {
  local lock="$1/questions/.lock" wait="${2:-10}" me="$BASHPID" start="$SECONDS"
  while :; do
    # Made on every try: a holder that finishes removes an empty questions/.
    mkdir -p "$1/questions" 2>/dev/null || return 1
    if ( set -C; printf '%s\n' "$me" > "$lock" ) 2>/dev/null; then
      _QUESTION_LOCK="$lock" _QUESTION_LOCK_PID="$me"
      return 0
    fi
    (( SECONDS - start > wait )) && break
    sleep 0.1
  done
  printf 'hold: lock busy: %s (remove it if no devagent command is running)\n' "$lock" >&2
  return 1
}

# question_unlock: remove the lock this process took, and no other. Called from
# the caller's one EXIT trap; always returns 0.
question_unlock() {
  if [[ -n "${_QUESTION_LOCK:-}" ]] \
     && [[ "$(cat "$_QUESTION_LOCK" 2>/dev/null)" == "${_QUESTION_LOCK_PID:-}" ]]; then
    rm -f "$_QUESTION_LOCK"
  fi
  _QUESTION_LOCK="" _QUESTION_LOCK_PID=""
  return 0
}

# question_publish <tmp> <target>: publish <tmp> at <target> without ever
# replacing an existing target. `ln` makes the link and fails on an existing
# target (Linux and Git Bash alike: U1); the temp is removed either way. Only
# where `ln` fails with the target absent (no hard links) does it fall back to
# a `set -C` redirect. 1 when the target exists. The caller chmods <tmp> first.
question_publish() {
  local tmp="$1" target="$2" rc=0
  if ln "$tmp" "$target" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  if [[ -e "$target" || -L "$target" ]]; then
    rm -f "$tmp"
    return 1
  fi
  ( set -C; cat "$tmp" > "$target" ) 2>/dev/null || rc=1
  rm -f "$tmp"
  return "$rc"
}

# ---- the option-tag registry ----------------------------------------------
# A tag names an action an option performs when it is chosen (`[grant: …]`).
# Registration is by function name; a re-source keeps what is registered.
declare -gA _QA_CHECK _QA_PERFORM
declare -ga _QA_TAGS

# question_action_register <tag> <check-fn> <perform-fn>: 1 on a bad tag, a
# duplicate tag or an undefined function.
question_action_register() {
  local tag="$1" check="$2" perform="$3"
  [[ "$tag" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || return 1
  [[ -z "${_QA_CHECK[$tag]+set}" ]] || return 1
  declare -F "$check" > /dev/null && declare -F "$perform" > /dev/null || return 1
  _QA_CHECK[$tag]="$check"
  _QA_PERFORM[$tag]="$perform"
  _QA_TAGS+=("$tag")
}

# question_action_check <tag> <value>: 0 accepted, 1 refused, 2 unregistered.
question_action_check() {
  [[ -n "${_QA_CHECK[$1]+set}" ]] || return 2
  "${_QA_CHECK[$1]}" "$2" || return 1
}

# question_action_perform <tag> <value> <project> <issue> <NN>: once per
# question. Under question_lock it returns 0 at once when
# questions/.performed-<NN>-<tag> exists; else it checks the value (1 refused),
# performs, and writes that marker when the perform succeeded. 2 unregistered.
question_action_perform() {
  local tag="$1" value="$2" project="$3" issue="$4" nn="$5" d marker rc=0
  [[ -n "${_QA_CHECK[$tag]+set}" ]] || return 2
  [[ "$nn" =~ ^[0-9]{2,4}$ ]] || return 1
  nn="$(printf '%02d' "$((10#$nn))")"
  d="$(issue_dir_for "$project" "$issue" 2>/dev/null)" || return 1
  question_lock "$d" || return 1
  marker="$d/questions/.performed-$nn-$tag"
  if [[ -e "$marker" ]]; then
    question_unlock
    return 0
  fi
  if ! "${_QA_CHECK[$tag]}" "$value"; then
    question_unlock
    return 1
  fi
  "${_QA_PERFORM[$tag]}" "$value" "$project" "$issue" "$nn" || rc=$?
  (( rc != 0 )) || : > "$marker"
  question_unlock
  return "$rc"
}

# question_action_tags: the registered tags, one per line.
question_action_tags() {
  local t
  for t in "${_QA_TAGS[@]}"; do printf '%s\n' "$t"; done
}

# Production tags: none. #965 registers `grant`, #927 `rerecord`, here.
