#!/usr/bin/env bash
# scripts/lib/merge-forward.sh — #1125: [project.<name>.merge_forward], the opt-in for
# accepting a merge-forward that only re-applies git's own merge of the base.
#
#   [project.<name>.merge_forward]
#   verify      = "ci"               # absent or "preship": today's behaviour
#   append_only = ["CHANGELOG.md"]   # exact repo-relative file paths
#
# One home each for the config reader, the merge-driver scan, git's merge and its
# conflicted paths, list membership and the merge-gate predicate
# (preship-verified-head.sh forward, mergemr.sh rule 14, doctor.sh). Requires io.sh
# (die) and config.sh sourced first, and DEVAGENT_GIT set; it sources nothing.

# merge_forward_entry_valid <e>: rc 0 iff <e> is an exact repo-relative file path —
# non-empty, no leading /, no drive letter, none of * ? [, and no empty, . or ..
# component.
merge_forward_entry_valid() {
  local e="$1"
  [[ -n "$e" ]] || return 1
  [[ "$e" != /* ]] || return 1
  [[ ! "$e" =~ ^[A-Za-z]: ]] || return 1
  [[ "$e" != *[\*\?\[]* ]] || return 1
  case "/$e/" in */./*|*/../*|*//*) return 1 ;; esac
  return 0
}

# merge_forward_resolve <project>: SETTER-GLOBALS, call bare (never in $(...)):
#   MF_VERIFY       ci | preship (an absent table or key: preship)
#   MF_APPEND_ONLY  ( entry ... ), in config order (absent: empty)
# Dies naming the key on a bad value, whatever else is configured (Issue-780). No
# [defaults] fallback: the table is per project.
# shellcheck disable=SC2034  # both are the return channel
merge_forward_resolve() {
  local p="$1" v="" out="" rc=0 e
  MF_VERIFY=preship; MF_APPEND_ONLY=()
  if v="$(config_get_project_field "$p" merge_forward.verify 2>/dev/null)"; then
    v="${v//$'\r'/}"
    case "$v" in
      ci|preship) MF_VERIFY="$v" ;;
      *) die "merge_forward.verify must be \"ci\" or \"preship\" (got '$v'); fix [project.$p.merge_forward] verify" ;;
    esac
  fi
  # `&& printf .` is a sentinel: $( ... ) strips trailing newlines (platform.sh).
  out="$(config_get_project_list "$p" merge_forward.append_only 2>/dev/null && printf .)" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    3) die "merge_forward.append_only must be an array of strings, e.g. append_only = [\"CHANGELOG.md\"]; fix [project.$p.merge_forward] append_only" ;;
    *) die "could not read [project.$p.merge_forward] append_only (exit $rc)" ;;
  esac
  out="${out%.}"
  [[ -n "$out" ]] || return 0
  mapfile -t MF_APPEND_ONLY <<<"${out%$'\n'}"
  for e in "${MF_APPEND_ONLY[@]}"; do
    merge_forward_entry_valid "$e" \
      || die "merge_forward.append_only entry '$e' is not an exact repo-relative file path (no leading /, drive letter, empty, . or .. component, or * ? [); fix [project.$p.merge_forward] append_only"
  done
}

# merge_forward_driver <value>: rc 0 iff a `git check-attr merge` value names a driver
# that can hide a conflict from git's merge. unspecified/set/unset/text/binary do not
# (the `binary` macro's -merge reads `unset`).
merge_forward_driver() {
  case "$1" in
    unspecified|set|unset|text|binary) return 1 ;;
    *) return 0 ;;
  esac
}

# merge_forward_drivers <tree> <treeish>: rc 0 when no path of <treeish> has a merge
# driver, asked with `git check-attr merge` at <tree>'s top level (merge-tree reads the
# WORKTREE's attributes, U2; a subdirectory tree would see only its own paths).
# rc 1: MF_DRIVER_PATH has merge=MF_DRIVER_VALUE (the first such path). rc 2: a git
# command failed; rc 3: check-attr's record count is wrong; rc 4: a configured driver
# named text or binary replaces git's built-in merge, which check-attr cannot see
# (MF_DRIVER_WHY).
# shellcheck disable=SC2034  # the MF_DRIVER_* globals are the return channel
merge_forward_drivers() {
  local tree="$1" treeish="$2" top tmp rc=0 i out
  local -a names=() attrs=()
  MF_DRIVER_PATH="" MF_DRIVER_VALUE="" MF_DRIVER_WHY=""
  if ! top="$("$DEVAGENT_GIT" -C "$tree" rev-parse --show-toplevel 2>/dev/null)" || [[ -z "$top" ]]; then
    MF_DRIVER_WHY="git rev-parse --show-toplevel failed"
    return 2
  fi
  out="$("$DEVAGENT_GIT" -C "$top" config --name-only --get-regexp '^merge\.(text|binary)\.driver$' 2>/dev/null)" || rc=$?
  case "$rc" in
    0) MF_DRIVER_WHY="${out%%$'\n'*} is configured; a driver named text or binary replaces git's built-in merge"
       return 4 ;;
    1) rc=0 ;;
    *) MF_DRIVER_WHY="git config exited $rc"; return 2 ;;
  esac
  tmp="$(mktemp -d)"
  "$DEVAGENT_GIT" -C "$top" ls-tree -r -z --full-tree --name-only "$treeish" >"$tmp/names" 2>/dev/null || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    MF_DRIVER_WHY="git ls-tree exited $rc"
  else
    "$DEVAGENT_GIT" -C "$top" check-attr -z --stdin merge <"$tmp/names" >"$tmp/attrs" 2>/dev/null || rc=$?
    [[ "$rc" -eq 0 ]] || MF_DRIVER_WHY="git check-attr exited $rc"
  fi
  if [[ "$rc" -eq 0 ]]; then
    mapfile -d '' names <"$tmp/names"
    mapfile -d '' attrs <"$tmp/attrs"
  fi
  rm -rf "$tmp"
  [[ "$rc" -eq 0 ]] || return 2
  if [[ "${#attrs[@]}" -ne $(( 3 * ${#names[@]} )) ]]; then
    MF_DRIVER_WHY="git check-attr returned $(( ${#attrs[@]} / 3 )) records for ${#names[@]} paths"
    return 3
  fi
  for (( i = 0; i < ${#attrs[@]}; i += 3 )); do
    if merge_forward_driver "${attrs[i+2]}"; then
      MF_DRIVER_PATH="${attrs[i]}" MF_DRIVER_VALUE="${attrs[i+2]}"
      return 1
    fi
  done
  return 0
}

# merge_forward_merge <tree> <ours> <theirs>: git's own merge, as forward compares it and
# rule 14 names it. merge.default=text: a configured merge.default driver would apply
# to every path whose merge attribute is unspecified, which check-attr cannot see.
# diff3: the hunk checker reads the base section. Sets MF_MTREE (the merged tree),
# MF_CONFLICTED (the conflicted paths, sorted, unique) and MF_CONFLICT[<path>] = text
# (stages 2 and 3, a 100644/100755 mode: git merged it as text) or other.
# rc 0 clean, 1 conflicted, 2 merge-tree failed (MF_MERGE_RC), 3 a conflicted path
# contains a newline, 4 git reports a conflict but names no conflicted path (a
# directory rename split, for one). MF_OURS and MF_THEIRS keep the two arguments: the
# conflict markers carry them (merge_forward_insertions).
# shellcheck disable=SC2034  # the MF_* globals are the return channel
merge_forward_merge() {
  local tree="$1" ours="$2" theirs="$3" tmp rc=0 i rec info cpath cm cs
  local -a mt=()
  local -A stages=() badmode=()
  MF_MTREE="" MF_MERGE_RC=0 MF_CONFLICTED=() MF_OURS="$ours" MF_THEIRS="$theirs"
  declare -gA MF_CONFLICT=()
  tmp="$(mktemp)"
  "$DEVAGENT_GIT" -C "$tree" -c merge.conflictStyle=diff3 -c merge.default=text \
    merge-tree --write-tree -z "$ours" "$theirs" >"$tmp" 2>/dev/null || rc=$?
  mapfile -d '' mt <"$tmp"
  rm -f "$tmp"
  MF_MERGE_RC="$rc"
  [[ "$rc" -le 1 ]] || return 2
  MF_MTREE="${mt[0]:-}"
  [[ "$rc" -eq 1 ]] || return 0
  # `<mode> <oid> <stage>\t<path>` records up to the first empty field.
  for (( i = 1; i < ${#mt[@]}; i++ )); do
    rec="${mt[i]}"
    [[ -n "$rec" ]] || break
    info="${rec%%$'\t'*}" cpath="${rec#*$'\t'}"
    [[ "$cpath" != *$'\n'* ]] || return 3
    read -r cm _ cs <<<"$info"
    [[ -n "${stages[$cpath]+x}" ]] || MF_CONFLICTED+=("$cpath")
    stages[$cpath]+="$cs"
    case "$cm" in 100644|100755) : ;; *) badmode[$cpath]=1 ;; esac
  done
  [[ "${#MF_CONFLICTED[@]}" -gt 0 ]] || return 4
  mapfile -t MF_CONFLICTED < <(printf '%s\n' "${MF_CONFLICTED[@]}" | LC_ALL=C sort)
  for cpath in "${MF_CONFLICTED[@]}"; do
    if [[ "${stages[$cpath]}" == *2* && "${stages[$cpath]}" == *3* && -z "${badmode[$cpath]+x}" ]]; then
      MF_CONFLICT[$cpath]=text
    else
      MF_CONFLICT[$cpath]=other
    fi
  done
  return 1
}

# merge_forward_insertions <tree> <path>: after merge_forward_merge, rc 0 when <path>'s
# conflicted blob in MF_MTREE parses as pure insertions on both sides (the hunk
# checker's --parse-only): the precondition of forward's append-only check, whatever
# the resolution. rc 1: it does not (MF_HUNKS_WHY); rc 2: cannot tell.
# shellcheck disable=SC2034  # MF_HUNKS_WHY is the return channel
merge_forward_insertions() {
  local tree="$1" path="$2" tmp rc=0
  local hunks="${DEVAGENT_MF_HUNKS:-$DEVAGENT_ROOT/scripts/lib/merge-forward-hunks.py}"
  MF_HUNKS_WHY=""
  tmp="$(mktemp -d)"
  if "$DEVAGENT_GIT" -C "$tree" cat-file blob "$MF_MTREE:$path" >"$tmp/merged" 2>/dev/null; then
    python3 -I "$hunks" --parse-only "$tmp/merged" "$MF_OURS" "$MF_THEIRS" >"$tmp/reason" 2>/dev/null || rc=$?
    IFS= read -r MF_HUNKS_WHY <"$tmp/reason" || true
  else
    rc=2
  fi
  rm -rf "$tmp"
  case "$rc" in
    0) return 0 ;;
    3) return 1 ;;
    *) return 2 ;;
  esac
}

# merge_forward_listed <path>: rc 0 iff <path> byte-equals an MF_APPEND_ONLY entry.
merge_forward_listed() {
  local e
  for e in "${MF_APPEND_ONLY[@]}"; do
    [[ "$e" == "$1" ]] && return 0
  done
  return 1
}

# merge_forward_gate <issue_dir>: sets MF_GATE_LINE (the 1-based line number). rc 0 when
# a line of <issue_dir>/mr.md mentions a merge gate, 1 when none does, 2 when it cannot
# tell (mr.md missing, or grep exited >= 2). This is the one home #911 replaces.
# shellcheck disable=SC2034  # MF_GATE_LINE is the return channel
merge_forward_gate() {
  local f="$1/mr.md" out="" rc=0
  MF_GATE_LINE=""
  [[ -f "$f" ]] || return 2
  out="$(LC_ALL=C grep -n -i -m1 -F 'merge gate' "$f")" || rc=$?
  case "$rc" in
    0) MF_GATE_LINE="${out%%:*}"; return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}
