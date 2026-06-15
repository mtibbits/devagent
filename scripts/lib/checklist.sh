#!/usr/bin/env bash
# scripts/lib/checklist.sh — parse/mark the per-issue checklist.md.
# Format defined in spec §5.2. Requires paths.sh + io.sh sourced.
#
# Lines look like:
#   - [ ]  0. pull
#   - [x]  7. implement
# A single-space step number is allowed for steps 0-9.

_checklist_template_path() {
  echo "$(plugin_root)/templates/checklist-${1}.md"
}

checklist_init() {
  local issue_dir="$1" template="${2:-standard}" tpl
  [[ -n "$issue_dir" ]] || die "checklist_init: issue-dir required"
  tpl="$(_checklist_template_path "$template")"
  [[ -f "$tpl" ]] || die "checklist_init: unknown template '$template' (no $tpl)"
  mkdir -p "$issue_dir"
  local issue_id="${ISSUE_ID:-$(basename "$issue_dir")}"
  local created
  created="$(date -Iseconds)"
  sed -e "s|{{ISSUE_ID}}|${issue_id}|g" \
      -e "s|{{CREATED_AT}}|${created}|g" \
      "$tpl" > "$issue_dir/checklist.md"
}

# Matches valid step lines into BASH_REMATCH: glyph=1 num=2 name=3
_checklist_line_re='^- \[(.)\][[:space:]]+([0-9]+)\.[[:space:]]+([A-Za-z][A-Za-z0-9_-]*)'

checklist_current_step() {
  local file="$1" line glyph num found=""
  [[ -f "$file" ]] || die "checklist_current_step: no such file '$file'"
  while IFS= read -r line; do
    if [[ "$line" =~ $_checklist_line_re ]]; then
      glyph="${BASH_REMATCH[1]}"
      num="${BASH_REMATCH[2]}"
      if [[ "$glyph" != "x" && "$glyph" != "-" ]]; then
        echo "$num"
        return 0
      fi
      found=1
    fi
  done < "$file"
  if [[ -n "$found" ]]; then
    echo "done"
    return 0
  fi
  die "checklist_current_step: no step lines found in '$file'"
}

checklist_step_state() {
  local file="$1" target="$2" line
  while IFS= read -r line; do
    if [[ "$line" =~ $_checklist_line_re ]]; then
      if [[ "${BASH_REMATCH[2]}" == "$target" ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
      fi
    fi
  done < "$file"
  return 1
}

checklist_step_name() {
  local file="$1" target="$2" line
  while IFS= read -r line; do
    if [[ "$line" =~ $_checklist_line_re ]]; then
      if [[ "${BASH_REMATCH[2]}" == "$target" ]]; then
        echo "${BASH_REMATCH[3]}"
        return 0
      fi
    fi
  done < "$file"
  return 1
}

# checklist_next_command <file>
# Composes current-step + step-name to return the slash command the
# operator should run next — e.g. "/devagent:scope". Prints "done" when
# all steps are checked. The checklist itself is the authority for what
# comes next; no central STEP_NAMES table is consulted.
checklist_next_command() {
  local file="$1" cur name
  cur="$(checklist_current_step "$file")" || return 1
  if [[ "$cur" == "done" ]]; then
    echo "done"
    return 0
  fi
  name="$(checklist_step_name "$file" "$cur")" || return 1
  printf '/devagent:%s\n' "$name"
}

# checklist_print_next_hint <file>
# Convenience for script-backed steps: prints a "Would you like to
# continue on to /devagent:X?" question on stderr after marking
# themselves complete, so the operator can answer yes/no without
# consulting the checklist by hand.
#
# Stderr keeps stdout clean for scripts that produce a result (branch
# name, MR url).
#
# Suppressed when DEVAGENT_CHAIN_ACTIVE=1 (set by next.sh's dispatch
# loop when it intends to run the next step immediately). Asking
# inside an active chain would defeat the chain.
#
# Silent on missing checklist or helper error.
checklist_print_next_hint() {
  local file="$1"
  local next
  next="$(checklist_next_command "$file" 2>/dev/null || true)"
  if [[ -z "$next" ]]; then
    return 0
  fi
  if [[ "$next" == "done" ]]; then
    echo "" >&2
    echo "Workflow complete on this issue." >&2
    return 0
  fi
  if [[ -n "${DEVAGENT_CHAIN_ACTIVE:-}" ]]; then
    # Chain dispatcher will run the next step immediately; asking would
    # break the autonomous flow. Caller sees chain progress in next.sh's
    # output instead.
    return 0
  fi
  echo "" >&2
  echo "Would you like to continue on to ${next}?" >&2
}

_checklist_valid_glyph() {
  case "$1" in
    ' '|x|-|'!'|'~'|'?'|P) return 0 ;;
    *) return 1 ;;
  esac
}

checklist_mark() {
  local file="$1" target="$2" glyph="$3"
  [[ -f "$file" ]] || die "checklist_mark: no such file '$file'"
  _checklist_valid_glyph "$glyph" || die "checklist_mark: bad glyph '$glyph'"
  local tmp
  tmp="$(mktemp)"
  awk -v target="$target" -v glyph="$glyph" '
    {
      if (match($0, /^- \[(.)\]([ \t]+)([0-9]+)\./, m)) {
        if (m[3] == target) {
          sub(/^- \[.\]/, "- [" glyph "]")
        }
      }
      print
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
  # Sanity: did we actually find the step?
  checklist_step_state "$file" "$target" >/dev/null \
    || die "checklist_mark: step $target not found in '$file'"
}

checklist_advance() {
  local file="$1" cur
  cur="$(checklist_current_step "$file")"
  if [[ "$cur" == "done" ]]; then
    echo "done"
    return 0
  fi
  checklist_mark "$file" "$cur" x
  checklist_current_step "$file"
}

# Returns the next step number whose state is one of [ ] [~], in FILE ORDER,
# on a line after the `after` step's line. Skips [x] [-] [?] [P] [!]. Empty if
# none. #77: the checklist's authority is file order, not the step number — a
# `n > after` comparison silently skips e.g. commit (10) under the deliberate
# 11-before-10 layout. `after=0` (default) returns the first pending step.
checklist_next_actionable() {
  local file="$1"
  local after="${2:-0}"
  awk -v after="$after" '
    match($0, /^- \[(.)\] +([0-9]+)\./, m) {
      n = m[2] + 0
      g = m[1]
      # Skip every line up to and including the `after` step (file order).
      if (after > 0 && !seen) { if (n == after) seen = 1; next }
      if (g == " " || g == "~") { print n; exit }
    }
  ' "$file"
}
