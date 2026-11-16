#!/usr/bin/env bash
# scripts/lib/merge-forward.sh — #1125: [project.<name>.merge_forward], the opt-in for
# accepting a merge-forward that only re-applies git's own merge of the base.
#
#   [project.<name>.merge_forward]
#   verify      = "ci"               # absent or "preship": today's behaviour
#   append_only = ["CHANGELOG.md"]   # exact repo-relative file paths
#
# One home each for the config reader, the merge-driver predicate, list membership and
# the merge-gate predicate (preship-verified-head.sh forward, mergemr.sh rule 14,
# doctor.sh). Requires io.sh (die) and config.sh sourced first; it sources nothing.

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
