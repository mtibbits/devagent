#!/usr/bin/env bash
# scripts/lib/checklist.sh — parse/mark the per-issue checklist.md.
# Format defined in spec §5.2. Requires paths.sh + io.sh sourced.
#
# Lines look like:
#   - [ ]  0. pull
#   - [x]  9. implement
# A single-space step number is allowed for steps 0-9.

# _checklist_template_path <template> [project] — #120: §12 registry with
# plugin-default fallback. checklist.sh's contract is "paths.sh + io.sh
# sourced" and MANY minimal sourcers honor exactly that, so the registry
# helper is touched ONLY when a project is passed (project-passing callers —
# pull.sh, checklist-init.sh — source artifact.sh; the guard keeps a missing
# helper from killing minimal sourcers, and the pull-path override test pins
# that the production path really resolves).
_checklist_template_path() {
  local template="$1" project="${2:-}"
  if [[ -n "$project" ]]; then
    # #78 fail-loud: a project-passing caller that forgot to source
    # artifact.sh is a bug — dying beats silently ignoring the override.
    command -v artifact_resolve_or >/dev/null 2>&1       || die "_checklist_template_path: caller passed a project but artifact.sh is not sourced (#120)"
    artifact_resolve_or "$project" "checklist-${template}"
  else
    echo "$(plugin_root)/templates/checklist-${template}.md"
  fi
}

checklist_init() {
  local issue_dir="$1" template="${2:-standard}" project="${3:-}" tpl
  [[ -n "$issue_dir" ]] || die "checklist_init: issue-dir required"
  tpl="$(_checklist_template_path "$template" "$project")"
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

# #74: revision blocks (templates/revision_block.md, appended by revise.sh) reuse
# step numbers 2,4..23 (#558). The ACTIVE revision is the LAST `## Revision N` block in the
# file; mark/read must be scoped to it or revision-2 work corrupts revision-1's
# recorded glyphs (and status/where/next read the stale block).
#
# _checklist_active_start: line number of the last `## Revision` heading, or 0
# when the checklist has no revision headings (legacy/none → operate file-wide).
_checklist_active_start() {
  awk '/^## Revision / { last = NR } END { print last + 0 }' "$1"
}

# _checklist_scope_start: the active-block start line IF the target step NUMBER
# appears in that block, else 0 (whole file). Resolution is membership-based:
# step 0 (pull) is unique to revision 1 and resolves file-wide, while the
# closeout steps 19-23 ARE reused in every revision block (#76) and therefore
# resolve to the active block once a revision is present. (The by-NAME analog
# used by the #149/#242 gates is _checklist_scope_start_by_name, below.)
_checklist_scope_start() {
  local file="$1" target="$2" start
  start="$(_checklist_active_start "$file")"
  if (( start > 0 )) && awk -v start="$start" -v t="$target" '
      NR > start && match($0, /^- \[.\][ \t]+[0-9]+\./) {
        num = substr($0, RSTART, RLENGTH)
        sub(/^- \[.\][ \t]+/, "", num); sub(/\.$/, "", num)
        if (num == t) { found = 1; exit }
      }
      END { exit (found ? 0 : 1) }
    ' "$file"; then
    printf '%s\n' "$start"
  else
    printf '0\n'
  fi
}

# _checklist_scope_start_by_name: the active-block start line IF the target step
# NAME appears in that block, else 0 (whole file). The name-keyed analog of
# _checklist_scope_start (#76): revision blocks now reuse the closeout step
# names 19-23, so the by-name gates (#149 preship, #242 closeout) must scope to
# the active revision like the number-keyed reads do — else they read revision
# 1's stale glyph and a revised cleanup sticks (gate reads rev1's pending copy;
# marks land in rev2; no CLI escape). Uses match+substr (not gawk match(s,r,arr))
# to stay mawk-safe (#73). start=0 (no revision headings, or the name is absent
# from the active block) preserves the legacy file-wide first-match.
_checklist_scope_start_by_name() {
  local file="$1" target="$2" start
  start="$(_checklist_active_start "$file")"
  if (( start > 0 )) && awk -v start="$start" -v t="$target" '
      NR > start && match($0, /^- \[.\][ \t]+[0-9]+\.[ \t]+[A-Za-z][A-Za-z0-9_-]*/) {
        seg = substr($0, RSTART, RLENGTH)
        sub(/^- \[.\][ \t]+[0-9]+\.[ \t]+/, "", seg)
        if (seg == t) { found = 1; exit }
      }
      END { exit (found ? 0 : 1) }
    ' "$file"; then
    printf '%s\n' "$start"
  else
    printf '0\n'
  fi
}

checklist_current_step() {
  local file="$1" line glyph num found="" start ln=0
  [[ -f "$file" ]] || die "checklist_current_step: no such file '$file'"
  start="$(_checklist_active_start "$file")"
  while IFS= read -r line; do
    ln=$((ln + 1))
    (( ln > start )) || continue
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
  local file="$1" target="$2" line start ln=0
  start="$(_checklist_scope_start "$file" "$target")"
  while IFS= read -r line; do
    ln=$((ln + 1))
    (( ln > start )) || continue
    if [[ "$line" =~ $_checklist_line_re ]]; then
      if [[ "${BASH_REMATCH[2]}" == "$target" ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
      fi
    fi
  done < "$file"
  return 1
}

# checklist_step_state_by_name <file> <name>
# Prints the glyph of the step whose NAME matches <name> (returns 0), or
# returns 1 if no such step exists. Resolves by name, not number, so callers
# survive cross-template step renumbering. Revision-scoped (#76): the by-name
# callers (cleanup's closeout gate #231/#242, ship's preship gate #149) target
# steps 19-23, which revision blocks now REUSE — so the lookup scopes to the
# active revision block when the name is present there, else falls back
# file-wide (legacy checklists / names unique to revision 1).
checklist_step_state_by_name() {
  local file="$1" target="$2" line ln=0 start
  start="$(_checklist_scope_start_by_name "$file" "$target")"
  while IFS= read -r line; do
    ln=$((ln + 1))
    (( ln > start )) || continue
    if [[ "$line" =~ $_checklist_line_re ]]; then
      if [[ "${BASH_REMATCH[3]}" == "$target" ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
      fi
    fi
  done < "$file"
  return 1
}

# checklist_nonterminal_by_names <file> [name ...]
# #242: prints one "name:[glyph]" line per named step that exists in the
# checklist and is NOT terminal ([x] done / [-] skipped). Absent names print
# nothing (absent step => no gate, the #231 pattern). Always returns 0; the
# caller decides what a non-empty result means. Resolution is BY NAME
# (step numbers vary across the four templates).
checklist_nonterminal_by_names() {
  local file="$1"; shift
  local name glyph
  for name in "$@"; do
    glyph="$(checklist_step_state_by_name "$file" "$name" 2>/dev/null || true)"
    [ -n "$glyph" ] || continue
    case "$glyph" in
      x|-) : ;;
      *) printf '%s:[%s]\n' "$name" "$glyph" ;;
    esac
  done
  return 0
}

checklist_step_name() {
  local file="$1" target="$2" line start ln=0
  start="$(_checklist_scope_start "$file" "$target")"
  while IFS= read -r line; do
    ln=$((ln + 1))
    (( ln > start )) || continue
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

# checklist_steps_with_glyph <file> <glyph>
# Prints the step NUMBER of every checklist line whose box holds exactly
# <glyph> (e.g. 'x' '!' 'P' '~' ' '), one per line in file order. mawk-safe:
# POSIX 2-arg match() + substr()/sub(), NOT gawk's 3-arg capture-array form
# match(s, r, arr), which mawk parse-errors on (#73/#313). Callers apply
# their own first/last/bound logic. Deliberately NOT revision-scoped: the
# recovery callers (stuck/unstuck/resume) act on raw glyphs across the whole
# file — a [!]/[P] mark is unique and a revision block never re-introduces one.
checklist_steps_with_glyph() {
  local file="$1" glyph="$2"
  [[ -f "$file" ]] || die "checklist_steps_with_glyph: no such file '$file'"
  awk -v glyph="$glyph" '
    match($0, /^- \[.\][ \t]+[0-9]+\./) {
      if (substr($0, 4, 1) != glyph) next    # box char is column 4: "- [G]"
      num = substr($0, RSTART, RLENGTH)
      sub(/^- \[.\][ \t]+/, "", num)
      sub(/\.$/, "", num)
      print num + 0
    }
  ' "$file"
}

checklist_mark() {
  local file="$1" target="$2" glyph="$3"
  [[ -f "$file" ]] || die "checklist_mark: no such file '$file'"
  _checklist_valid_glyph "$glyph" || die "checklist_mark: bad glyph '$glyph'"
  local tmp start
  start="$(_checklist_scope_start "$file" "$target")"
  # #329: same-dir temp → mv is an atomic rename on one filesystem (a bare
  # tmpfs mktemp + cross-fs mv can leave a TRUNCATED checklist on a mid-mv crash).
  tmp="$(mktemp "$(dirname "$file")/.tmp.XXXXXX")"
  if awk -v target="$target" -v glyph="$glyph" -v start="$start" '
    {
      # POSIX 2-arg match() (gawk 3-arg capture array is non-portable: mawk
      # parse-errors on it). Extract the step number with substr()/sub().
      # #74: only act inside the active revision block (NR > start).
      if (NR > start && match($0, /^- \[.\][ \t]+[0-9]+\./)) {
        num = substr($0, RSTART, RLENGTH)
        sub(/^- \[.\][ \t]+/, "", num)
        sub(/\.$/, "", num)
        if (num == target) {
          sub(/^- \[.\]/, "- [" glyph "]")
        }
      }
      print
    }
  ' "$file" > "$tmp"; then
    # #329: preserve the target's mode (mktemp is 0600) before replacing it.
    [ -e "$file" ] && chmod --reference="$file" "$tmp"
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    die "checklist_mark: awk failed processing '$file' (file left intact)"
  fi
  # Sanity: did we actually find the step?
  checklist_step_state "$file" "$target" >/dev/null \
    || die "checklist_mark: step $target not found in '$file'"
}

# checklist_mark_by_name <file> <name> <glyph> — set the glyph of the step whose
# NAME matches, scoped to the ACTIVE revision block (#76). The name-keyed WRITER
# (#363): the existing by-name funcs are readers, and checklist_mark is keyed by
# NUMBER; sync needs to flip closeout steps by name (numbers vary by template).
# No-op-safe: an absent name leaves the file byte-identical. Same-dir atomic write
# + mode-preserve (#329).
checklist_mark_by_name() {
  local file="$1" target="$2" glyph="$3" tmp start
  [[ -f "$file" ]] || die "checklist_mark_by_name: no such file '$file'"
  _checklist_valid_glyph "$glyph" || die "checklist_mark_by_name: bad glyph '$glyph'"
  start="$(_checklist_scope_start_by_name "$file" "$target")"
  tmp="$(mktemp "$(dirname "$file")/.tmp.XXXXXX")"
  if awk -v target="$target" -v glyph="$glyph" -v start="$start" '
    {
      if (NR > start && match($0, /^- \[.\][ \t]+[0-9]+\.[ \t]+[A-Za-z][A-Za-z0-9_-]*/)) {
        name = substr($0, RSTART, RLENGTH)
        sub(/^- \[.\][ \t]+[0-9]+\.[ \t]+/, "", name)
        if (name == target) sub(/^- \[.\]/, "- [" glyph "]")
      }
      print
    }
  ' "$file" > "$tmp"; then
    [ -e "$file" ] && chmod --reference="$file" "$tmp"
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    die "checklist_mark_by_name: awk failed processing '$file' (file left intact)"
  fi
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
# `n > after` comparison silently skips a step under any out-of-file-order
# numbering (e.g. the pre-#116 11-before-10 layout, or a pre-#558 checklist —
# both still live in checklists cut before those reorders).
# `after=0` (default) returns the first pending step.
checklist_next_actionable() {
  local file="$1"
  local after="${2:-0}"
  local start
  start="$(_checklist_active_start "$file")"
  awk -v after="$after" -v start="$start" '
    NR > start && match($0, /^- \[.\] +[0-9]+\./) {
      # POSIX 2-arg match() + substr() (mawk has no 3-arg capture array).
      g = substr($0, 4, 1)
      num = substr($0, RSTART, RLENGTH)
      sub(/^- \[.\] +/, "", num)
      sub(/\.$/, "", num)
      n = num + 0
      # Skip every line up to and including the `after` step (file order).
      if (after > 0 && !seen) { if (n == after) seen = 1; next }
      if (g == " " || g == "~") { print n; exit }
    }
  ' "$file"
}
