#!/usr/bin/env bash
# scripts/lib/staging.sh — where pull keeps a fetched ticket under a trust
# policy until its floor passes (#715; spec §3.3, §9.3).
#
# Under a policy in scope, pull fetches into a staging dir under devAgent's
# state directory (outside git and outside every devdoc tree), renders the
# candidate issue.md there (staging_render.py, comments reduced to a count),
# runs the quarantine verdict on that candidate, and only on PASS installs it
# (staging_promote) — the pull's first devdoc write. Every other exit removes
# the dir: QUARANTINE discards it before the label write, and pull's
# `trap staging_discard EXIT` covers die, refuse, try_later, INT and TERM.
# A dir a KILL or power loss left behind is swept by the next staging_open
# (older than 60 minutes, judged by age: a recorded PID can be reused).
#
# Layout: $(devagent_home)/state/staging/<project>.<issue_id>.XXXXXX/ (0700),
# holding fetch.raw (deleted by staging_render, so comment text is on disk
# only while the render runs) and issue.md (the candidate).
#
# Source-only file: do not execute directly. Uses the caller's die().

_STAGING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
declare -F devagent_home >/dev/null || source "$_STAGING_LIB_DIR/paths.sh"

# _staging_canon <path>: <path> with its nearest existing ancestor resolved by
# `pwd -P` and the missing tail appended, so a path that does not exist yet
# (a first pull's devdoc dir, the staging root) is compared canonically
# without creating anything.
_staging_canon() {
  local p="$1" anc tail=""
  anc="$p"
  while [ ! -d "$anc" ]; do
    tail="/$(basename "$anc")$tail"
    anc="$(dirname "$anc")"
  done
  printf '%s%s\n' "$(cd "$anc" && pwd -P)" "$tail"
}

# staging_open <project> <issue_id> <devdoc_dir>: make this pull's staging dir.
# SETTER-GLOBAL STAGE_DIR STAGE_RAW STAGE_MD — call it bare. Dies when
# the staging root resolves inside <devdoc_dir> (checked before anything is
# created), so staged text can never sit under a devdoc tree.
staging_open() {
  local project="$1" id="$2" devdoc="$3" root croot cdev
  root="$(devagent_home)/state/staging"
  croot="$(_staging_canon "$root")"
  cdev="$(_staging_canon "$devdoc")"
  cdev="${cdev%/}"
  case "$croot/" in
    "$cdev"/*) die "the staging root $root is inside devdoc_dir $devdoc; move devagent_home or devdoc_dir apart" ;;
  esac
  mkdir -p "$root"
  chmod 700 "$root"
  root="$(cd "$root" && pwd -P)"
  find "$root" -mindepth 1 -maxdepth 1 -type d -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  STAGE_DIR="$(mktemp -d "$root/$project.$id.XXXXXX")"
  STAGE_RAW="$STAGE_DIR/fetch.raw"
  STAGE_MD="$STAGE_DIR/issue.md"
}

# staging_discard: remove this pull's staging dir. Idempotent; a no-op when
# STAGE_DIR is unset or empty; always returns 0 (it runs from an EXIT trap and
# as a statement under `set -e`).
staging_discard() {
  if [ -n "${STAGE_DIR:-}" ]; then rm -rf "$STAGE_DIR"; fi
  return 0
}

# staging_render <repo> <num>: render STAGE_RAW into STAGE_MD (staging_render.py),
# then delete STAGE_RAW. SETTER-GLOBAL STAGE_TRAILERS (the script's
# `trailers <k>`, accepted only as 1-9 digits) and STAGE_REASON (the script's
# stderr, kept only when it is exactly one of its six fixed layout reasons, else
# empty: anything else could carry ticket bytes). Returns the script's exit, or
# 3 when it exits 0 without a well-formed token.
# shellcheck disable=SC2034  # setter-globals
staging_render() {
  local repo="$1" num="$2" rc=0 out reason="" err="$STAGE_DIR/render.err"
  local reasons='^(line [12]|header line [0-9]{1,9}|header keys|no header rule|no comments heading)$'
  STAGE_TRAILERS="" STAGE_REASON=""
  out="$(python3 -I -X utf8 "$_STAGING_LIB_DIR/staging_render.py" "$STAGE_RAW" "$STAGE_MD" "$repo" "$num" \
    2> "$err")" || rc=$?
  [ "$rc" -eq 0 ] || reason="$(head -c 32 "$err")"
  rm -f "$STAGE_RAW" "$err"
  if [ "$rc" -ne 0 ]; then
    if [[ "$reason" =~ $reasons ]]; then STAGE_REASON="$reason"; fi
    return "$rc"
  fi
  [[ "$out" =~ ^trailers\ ([0-9]{1,9})$ ]] || return 3
  STAGE_TRAILERS="${BASH_REMATCH[1]}"
}

# staging_promote <issue_dir>: install the candidate as <issue_dir>/issue.md —
# the one place issue.md is written under trust — then discard the staging dir.
# A plain redirect, then mv: the file takes the umask's mode, not mktemp's 0600.
# A failed copy removes the tmp file, removes <issue_dir> when this call's own
# mkdir -p created it, leaves any old issue.md untouched, and returns non-zero.
staging_promote() {
  local dir="$1" made=0 rc=0
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" || return
    made=1
  fi
  { cat "$STAGE_MD" > "$dir/issue.md.tmp"; } || rc=$?
  if [ "$rc" -eq 0 ]; then mv -f "$dir/issue.md.tmp" "$dir/issue.md" || rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$dir/issue.md.tmp"
    if [ "$made" = 1 ]; then rmdir "$dir" 2>/dev/null || true; fi
    return "$rc"
  fi
  staging_discard
}
