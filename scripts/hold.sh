#!/usr/bin/env bash
# scripts/hold.sh — #962: a step's one helper for an operator question.
#
#   hold.sh <project> <issue> --step <step-name> --reason <one line> --question-file <path>
#   hold.sh <project> <issue> --step <step-name> --no-ask [--reason <one line> --question-file <path>]
#
# Interactive (no unattended marker, no --no-ask): writes the open record
# questions/<NN>-<step>.md, prints its path and exits 3 — the session asks.
# Unattended or --no-ask: holds — writes the question STUCK, marks the step
# `[?]`, parks the issue and appends one `hold` line to the notifications file.
# Spec §5.3, §7.3; the format lives in scripts/lib/question-actions.sh.
#
# Exits: 0 held (also a completed re-entry); 3 ask; 2 refused
# (`hold.sh: refused (<id>): <rule>` on stderr); 1 a lock timeout, a notify
# check that could not run, or a hold line not appended; a trust or quarantine
# code; park's code after a refused park (2 and 3 reported as 1).

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
source "$PLUGIN_ROOT/scripts/lib/trust.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/quarantine.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/notify.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/question-actions.sh"

# The rule printed with each refusal id. A rule never repeats question text.
declare -A HOLD_RULE=(
  [usage]='hold.sh <project> <issue> --step <step-name> (--reason <one line> --question-file <path> | --no-ask [--reason <one line> --question-file <path>])'
  [issue]='the issue has no checklist'
  [no-log]='the checklist has no ## Log section'
  [step]='--step must name a row of the active revision block'
  [step-done]='--step names a row marked [x] or [-]'
  [reason]='--reason must be one non-blank line of at most 200 bytes'
  [question-file]='the question file cannot be read'
  [heading]='the only ## headings are Question, Impediment, Options and Evidence, once each, in that order, with nothing before the first'
  [section]='each of the four sections must be present and hold a non-blank line'
  [option]='every non-blank ## Options line must be an option line, and there must be one'
  [option-id]='option ids must be unique'
  [recommended]='exactly one option must be (recommended)'
  [tag]='an option tag must be registered'
  [tag-check]='an option tag value was refused by its check'
  [no-question]='--no-ask with no question file needs an open record for the step'
  [one-stop]='the issue already has a STUCK; one stop at a time'
  [notify]='the notifications check refused the hold line'
)

# _refuse <id>: the refusal line, exit 2.
_refuse() {
  printf 'hold.sh: refused (%s): %s\n' "$1" "${HOLD_RULE[$1]}" >&2
  exit 2
}

# The one EXIT trap: release the lock, and remove a questions/ directory this
# run created that is still empty (a refusal after the lock writes nothing).
_HOLD_MADE_QDIR=0
_hold_exit() {
  question_unlock
  if (( _HOLD_MADE_QDIR )); then rmdir "$issue_dir/questions" 2>/dev/null || true; fi
}

# _last_good <checklist> <N>: the nearest earlier `[x]` row as `<N> <name>`,
# or `(none)`. Copied from checklist-stuck.sh; #909 merges the writers.
_last_good() {
  local file="$1" cur="$2" i st
  for ((i = cur - 1; i >= 0; i--)); do
    st="$(checklist_step_state "$file" "$i" 2>/dev/null || true)"
    if [[ "$st" == "x" ]]; then
      printf '%s %s\n' "$i" "$(checklist_step_name "$file" "$i")"
      return 0
    fi
  done
  printf '(none)\n'
}

# _umask_mode: the mode a new file gets under the current umask (as STUCK).
_umask_mode() { printf '%o\n' "$(( 0666 & ~8#$(umask) ))"; }

# _render_to <tmp> <question-file> <NN>: render the question into <tmp> with
# the umask mode.
_render_to() {
  question_render "$2" "$project" "$issue" "$step" "$step_num" "$reason" \
    "$(_last_good "$checklist" "$step_num")" "$3" "$(date -Iseconds)" > "$1" || return 1
  chmod "$(_umask_mode)" "$1"
}

# ---- argv ----------------------------------------------------------------
project="" issue="" step="" reason="" qfile="" no_ask=0
declare -A _seen=()
_pos=()
while (( $# )); do
  case "$1" in
    --step|--reason|--question-file)
      [[ -z "${_seen[$1]-}" && $# -ge 2 && -n "$2" ]] || _refuse usage
      _seen[$1]=1
      case "$1" in
        --step) step="$2" ;;
        --reason) reason="$2" ;;
        --question-file) qfile="$2" ;;
      esac
      shift 2 ;;
    --no-ask)
      [[ -z "${_seen[--no-ask]-}" ]] || _refuse usage
      _seen[--no-ask]=1; no_ask=1; shift ;;
    -*) _refuse usage ;;
    *) _pos+=("$1"); shift ;;
  esac
done
(( ${#_pos[@]} == 2 )) || _refuse usage
project="${_pos[0]}" issue="${_pos[1]}"
[[ -n "$project" && -n "$issue" && -n "$step" ]] || _refuse usage
# --reason and --question-file come together; neither is legal only with --no-ask.
have_r=0 have_q=0
[[ -z "${_seen[--reason]-}" ]] || have_r=1
[[ -z "${_seen[--question-file]-}" ]] || have_q=1
(( have_r == have_q )) || _refuse usage
(( have_q || no_ask )) || _refuse usage
config_is_project "$project" || _refuse usage

trust_entry_check "hold" "$project"
quarantine_guard "hold" "$project" "$issue"

issue_dir="$(issue_dir_for "$project" "$issue" 2>/dev/null)" || _refuse issue
checklist="$issue_dir/checklist.md"
[[ -f "$checklist" ]] || _refuse issue
grep -q '^## Log' "$checklist" || _refuse no-log
step_state="$(checklist_active_step_state_by_name "$checklist" "$step" 2>/dev/null)" || _refuse step
[[ "$step_state" != x && "$step_state" != - ]] || _refuse step-done
step_num="$(checklist_step_num_by_name "$checklist" "$step")" || _refuse step
if (( have_r )); then
  # Bytes, under LC_ALL=C, whatever the session locale.
  ( LC_ALL=C
    [[ "$reason" == *[![:space:]]* && "$reason" != *$'\n'* && "$reason" != *$'\r'* && ${#reason} -le 200 ]]
  ) || _refuse reason
fi
if (( have_q )); then
  _id="$(question_validate "$qfile")" || _refuse "${_id:-question-file}"
fi

# ---- the lock: held to the end through the one EXIT trap -------------------
[[ -d "$issue_dir/questions" ]] || _HOLD_MADE_QDIR=1
trap _hold_exit EXIT
question_lock "$issue_dir" || exit 1

# ---- the mode --------------------------------------------------------------
if (( no_ask )) || devagent_unattended; then
  echo "hold.sh: the hold is not implemented yet" >&2
  exit 1
fi

# The ask: the open record's number, else the next; render, publish, exit 3.
record="$(question_open_record "$issue_dir" "$step")"
if [[ -n "$record" ]]; then
  nn="${record##*/}"; nn="${nn%%-*}"
else
  nn="$(question_next_number "$issue_dir")" || exit 1
  record="$issue_dir/questions/$nn-$step.md"
fi
tmp="$(mktemp "$issue_dir/questions/.tmp.XXXXXX")"
_render_to "$tmp" "$qfile" "$nn" || { rm -f "$tmp"; exit 1; }
# W:d-749: a Windows rename can fail while a reader holds the target open.
for _try in 1 2 3 4 5; do
  if mv -f "$tmp" "$record" 2>/dev/null; then
    _HOLD_MADE_QDIR=0
    printf '%s\n' "$record"
    exit 3
  fi
  sleep 0.2
done
rm -f "$tmp"
echo "hold.sh: could not write $record" >&2
exit 1
