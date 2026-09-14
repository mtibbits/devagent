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
      "$tpl" | checklist_filter_mergetoall "$project" > "$issue_dir/checklist.md"
}

# checklist_filter_mergetoall [project] — stdin→stdout. Templates ship the
# mergetoall row pre-skipped `[-]`; a project that configures all_prs_branch
# opts the step back in, so its row flips to pending here at scaffold time
# (mergetoall.sh keeps its runtime unconfigured-guard as backstop). Keyed by
# NAME, not number (#558). No project, or no all_prs_branch → passthrough.
checklist_filter_mergetoall() {
  local project="${1:-}" all_prs=""
  if [[ -n "$project" ]]; then
    # Same fail-loud contract as _checklist_template_path (#120): a
    # project-passing caller that forgot to source config.sh is a bug —
    # a silent passthrough would leave the step skipped on a configured
    # project, and next.sh never dispatches a `[-]` row.
    command -v config_get_project_field >/dev/null 2>&1       || die "checklist_filter_mergetoall: caller passed a project but config.sh is not sourced"
    all_prs="$(config_get_project_field "$project" all_prs_branch 2>/dev/null || true)"
  fi
  if [[ -n "$all_prs" ]]; then
    # Trailing [[:space:]]* tolerates CR / trailing blanks in devdoc override
    # templates (a $-anchored match silently no-ops on CRLF under GNU sed).
    sed 's/^- \[-\]\([[:space:]]\{1,\}[0-9]\{1,\}\. mergetoall[[:space:]]*\)$/- [ ]\1/'
  else
    cat
  fi
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
# #589: checklist_mark REFUSES a name-less write on the absent-from-active-block
# fall-through while readers keep relying on it; changing the 0 contract must
# update that guard.
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
# their own first/last/bound logic. Deliberately NOT revision-scoped, and after
# #587 the only recovery caller left is stuck.sh, which wants the file-wide scan
# by design (it asks for the last [x] BELOW the current step). The former
# rationale here — that a [!]/[P] row is unique to the file and no revision
# block ever re-introduces one — is FALSE: closeout numbers are REUSED across revision
# blocks (#76), so a [!]/[P] can sit in an older block while the active block
# holds a pending twin of the same number. That is exactly the #587 bug. A
# caller that must act on the ROW carrying a glyph uses
# checklist_find_glyph_line below, which returns the LINE, never the number.
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

# checklist_find_glyph_line <file> <glyph>
# Prints "<line>:<step-number>" for the row the RECOVERY callers (unstuck.sh,
# checklist-unstuck.sh, resume.sh) must act on: the first row carrying <glyph>
# inside the ACTIVE revision block if one is there, else the first such row
# file-wide (the #76 legacy fallback). Prints nothing (rc 0) when no row carries
# the glyph; the caller decides whether that is fatal.
#
# #587: the LINE is the answer, not the step number. Closeout numbers are REUSED
# across revision blocks (#76), so a caller that carries the NUMBER out of this
# scan and marks it with checklist_mark re-resolves it through
# _checklist_scope_start into the ACTIVE block, flipping the wrong block's twin
# while the real [!]/[P] survives (#558 r3 BLOCKING-2, re-found at two more
# sites in #587). Pair this with checklist_mark_line, never with checklist_mark.
# _checklist_scope_start is NOT the bug and is deliberately unchanged: its
# active-block re-scoping is correct for callers that mean the active block.
#
# mawk-safe: POSIX 2-arg match() + substr()/sub(), not gawk match(s,r,arr)
# (#73/#313). The glyph is compared as the COLUMN-4 character of "- [G]" and is
# never interpolated into a regex: '?' and '.' are legal glyphs and would be
# metacharacters. That is the SAME predicate checklist_steps_with_glyph uses, on
# purpose: one question, one matcher (Issue-585).
checklist_find_glyph_line() {
  local file="$1" glyph="$2"
  [[ -f "$file" ]] || die "checklist_find_glyph_line: no such file '$file'"
  awk -v glyph="$glyph" '
    /^## Revision / { blk = NR }
    match($0, /^- \[.\][ \t]+[0-9]+\./) {
      if (substr($0, 4, 1) != glyph) next    # box char is column 4: "- [G]"
      num = substr($0, RSTART, RLENGTH)
      sub(/^- \[.\][ \t]+/, "", num)
      sub(/\.$/, "", num)
      n++; ln[n] = NR; sn[n] = num + 0
    }
    END {
      for (i = 1; i <= n; i++) if (ln[i] > blk) { print ln[i] ":" sn[i]; exit }
      if (n) print ln[1] ":" sn[1]
    }
  ' "$file"
}

# checklist_step_name_at_line <file> <line>
# Prints the step NAME on <line>, whatever glyph the row carries. Returns 1 with
# no STDOUT when that line is not a step row, and names the reason on STDERR
# with the token "not a checklist step row" — a diagnostic printed to stdout
# inside $( ... ) is swallowed by the caller's capture (Issue-583), and a bare
# rc that pins no message is indistinguishable from an unrelated failure or from
# a missing function's 127 (Issue-Fork-132 / Issue-572). NOT die(): the callers
# (unstuck.sh, checklist-unstuck.sh) add their own context.
# The row grammar (glyph, number, name charset) comes from _checklist_line_re —
# this file's single source of what a step row looks like — so a future grammar
# change cannot silently miss this reader.
checklist_step_name_at_line() {
  local file="$1" line="$2" content
  [[ -f "$file" ]] || die "checklist_step_name_at_line: no such file '$file'"
  [[ "$line" =~ ^[0-9]+$ ]] || die "checklist_step_name_at_line: bad line '$line'"
  content="$(sed -n "${line}{p;q}" "$file")"
  if [[ "$content" =~ $_checklist_line_re ]]; then
    printf '%s\n' "${BASH_REMATCH[3]}"
    return 0
  fi
  printf '%s\n' \
    "checklist_step_name_at_line: line $line of '$file' is not a checklist step row" >&2
  return 1
}

# checklist_mark_line <file> <line> <glyph>
# Sets the glyph of the step row at <line>. No number resolution, no revision
# re-scoping (#587): the caller has already located the row.
#
# Fail-CLOSED: dies unless the row afterwards really carries <glyph>, so a caller
# that removes a STUCK sentinel after marking cannot remove it over a row that
# did not flip. The refusal lives in the shipped code path, not only in the suite
# (lawFirm Issue-14). Same-dir atomic write + mode preserve (#329).
checklist_mark_line() {
  local file="$1" line="$2" glyph="$3" tmp now
  [[ -f "$file" ]] || die "checklist_mark_line: no such file '$file'"
  [[ "$line" =~ ^[0-9]+$ ]] || die "checklist_mark_line: bad line '$line'"
  _checklist_valid_glyph "$glyph" || die "checklist_mark_line: bad glyph '$glyph'"
  awk -v ln="$line" '
    NR == ln && match($0, /^- \[.\][ \t]+[0-9]+\./) { found = 1 }
    END { exit (found ? 0 : 1) }
  ' "$file" || die "checklist_mark_line: line $line of '$file' is not a checklist step row"
  tmp="$(mktemp "$(dirname "$file")/.tmp.XXXXXX")"
  if awk -v ln="$line" -v glyph="$glyph" '
      NR == ln && match($0, /^- \[.\][ \t]+[0-9]+\./) { sub(/^- \[.\]/, "- [" glyph "]") }
      { print }
    ' "$file" > "$tmp"; then
    [ -e "$file" ] && chmod --reference="$file" "$tmp"
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    die "checklist_mark_line: awk failed processing '$file' (file left intact)"
  fi
  now="$(awk -v ln="$line" 'NR == ln { print substr($0, 4, 1); exit }' "$file")"
  [[ "$now" == "$glyph" ]] \
    || die "checklist_mark_line: line $line of '$file' did not take glyph '$glyph' (reads '[$now]') - do NOT treat the step as cleared"
}

# checklist_mark <file> <step-num> <glyph> [expected-name]
# #558: pass the CALLER'S OWN step name as the 4th argument. Step numbers are
# positions, so the same number means different steps on checklists scaffolded
# either side of a renumber — a step script marking its own number against an
# older checklist silently flips a DIFFERENT row: post-#558 commit.sh marking
# 12 on a pre-#558 checklist hit `12. draftmr`, left `10. commit` pending, and  #558-old-scheme
# `next.sh --auto` then re-dispatched commit forever). The check turns that
# silent wrong-row write into a loud stop naming the remedy. #589: omitting the
# argument gains exactly one NEW refusal — a checklist with `## Revision`
# headings where the number is absent from the ACTIVE block (the write would fall
# through to an older block's row); a number absent everywhere still dies the
# older `not found`. Legacy checklists and active-block numbers
# are unaffected; callers marking `$cur` from checklist_current_step are
# active-block scoped by construction.
checklist_mark() {
  local file="$1" target="$2" glyph="$3" expect_name="${4:-}"
  [[ -f "$file" ]] || die "checklist_mark: no such file '$file'"
  _checklist_valid_glyph "$glyph" || die "checklist_mark: bad glyph '$glyph'"
  if [[ -n "$expect_name" ]]; then
    # Resolved through the SAME scope logic that the write below uses, so this
    # names precisely the row that would be marked.
    local actual_name
    actual_name="$(checklist_step_name "$file" "$target" 2>/dev/null || true)"
    if [[ -n "$actual_name" && "$actual_name" != "$expect_name" ]]; then
      die "checklist_mark: refusing to mark step $target as '$expect_name' — that row is '$actual_name' in $file. This checklist predates the #558 renumber (numbers are positions, not IDs). Migrate it with scripts/migrate-checklist-numbering.sh, or start a fresh revision with /devagent:revise."
    fi
  fi
  local tmp start active
  start="$(_checklist_scope_start "$file" "$target")"
  # #589: name-less, fell through file-wide, the file HAS revision blocks, and the
  # number exists somewhere => it lives only in an OLDER block and the write would
  # flip that row silently. A number absent everywhere is left to the post-write
  # `not found` die below (a diagnostic must not assert a row that does not exist).
  # The resolver keeps its 0=file-wide return (readers depend on it); a
  # name-passing caller was already row-confirmed by the #558 guard above.
  # `|| true`: under an errexit caller a failing awk here must fall through to
  # the write's own `awk failed` die below, not exit with a bare rc.
  if [[ -z "$expect_name" && "$start" == "0" ]]; then
    active="$(_checklist_active_start "$file" || true)"
    if (( active > 0 )) && checklist_step_state "$file" "$target" >/dev/null; then
      die "checklist_mark: refusing a name-less mark of step $target in '$file': that number is absent from the active revision block, so the write would flip an OLDER revision's row (#589). Pass the step name as the 4th argument, or use scripts/checklist-mark.sh --by-name <issue-dir> <name> '$glyph'."
    fi
  fi
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
# NAME matches, scoped to the ACTIVE revision block when the name is there, else
# file-wide (#76; revision-1-only names like pull/research/spike). The name-keyed
# WRITER (#363): the existing by-name funcs are readers, and checklist_mark is
# keyed by NUMBER; sync needs to flip closeout steps by name (numbers vary by
# template). Fail-CLOSED since #589: an absent name leaves the bytes unchanged
# and DIES (was: returned 0 silently, so its consumer _sync_closeout_unblock in
# scripts/sync.sh got no signal when the flip never landed). The read-back
# checks the RESOLVED row (the first the resolver finds) and dies the same way
# when it does not carry the glyph. Same-dir atomic write + mode-preserve (#329).
checklist_mark_by_name() {
  local file="$1" target="$2" glyph="$3" tmp start now
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
  # #589: fail closed. Read back through the resolver the write used, so a
  # file-wide resolution (legacy checklist, rev-1-only name) reads the row that
  # was flipped; an absent name reads empty and dies.
  now="$(checklist_step_state_by_name "$file" "$target" || true)"
  [[ "$now" == "$glyph" ]] \
    || die "checklist_mark_by_name: no step named '$target' carries glyph '$glyph' in '$file' after the write (reads '[$now]'; empty means no row has that name) - do NOT treat the step as marked"
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

# #595: the ONE reader of a checklist's `Template:` header. revise.sh held the
# only parse (an inline sed); this change adds two more consumers (the oneshot
# boundary checker and cleanup.sh's guard clause), and two spellings of one
# question is the defect (register Issue-565: grep for the QUESTION a probe
# decides, not the name you would give it).
# Echoes the template name, or nothing when the file is unreadable or has no
# header. ALWAYS returns 0 — callers branch on emptiness, so this is safe inside
# `$(...)` (the Issue-120 non-fatal-resolve shape). The capture-then-print form
# is deliberate: a bare `sed | head -1` as the tail would export the pipeline's
# status to an errexit caller (register Issue-314).
checklist_template_name() {
  local checklist="$1" out
  [ -r "$checklist" ] || return 0
  out="$(sed -n 's/^Template: //p' "$checklist" | head -1)" || out=""
  printf '%s\n' "$out"
  return 0
}
