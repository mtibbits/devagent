#!/usr/bin/env bash
# scripts/lib/selfcert.sh — #1097: the self-certification scan. A change can alter
# what a project's required CI checks measure: it edits a workflow file, a path the
# project lists in required_checks_paths, or a Git Bash tag line the base already
# had. mergemr.sh (rule 21) stops on such a diff until the operator acknowledges it
# for one head; preship-deferred.sh warns about it. Both ask here, so they cannot
# disagree about which paths count.
#
# Functions only: sourcing it runs nothing. Requires DEVAGENT_GIT set; it sources
# nothing. Every function is a SETTER-GLOBAL: call it bare, never as $(...).
# Nothing here talks to a remote: an object the repository lacks is a failed read
# (_selfcert_git), never something git fetches for itself.

# A tag line, matched case-insensitively against a CR-stripped line: the regex of the
# malformed-line detector in scripts/ci/gitbash-tagged.sh, byte for byte (pinned by
# tests/mergemr.bats). It is wider than that script's selection regex on purpose: a
# line the detector would call malformed is a tag line someone edited.
SELFCERT_TAG_RE='^[[:space:]]*#.*file_tags.*gitbash'

# The paths selfcert_paths names in SELFCERT_LIST before it counts the rest.
SELFCERT_LIST_MAX=10

# _selfcert_git <git argument>...: git for a read that must stay in this repository.
# In a partial clone git fetches a missing object from its promisor remote on any
# read that touches it, with no bound, and this scan runs in a step where every read
# is bounded. So the read fails instead, and the caller says it could not tell:
#   GIT_NO_LAZY_FETCH=1        git does not try. git 2.45 documents it and builds
#                              with the 2024 security fixes honour it (probed:
#                              Ubuntu's 2.43.0); a git without them ignores it
#   GIT_ALLOW_PROTOCOL=none    no transport is allowed (`none` names no protocol; it
#                              overrides protocol.*.allow), so on a git that does try,
#                              the fetch is refused before it connects
# Probed in a blobless clone with its remote reachable: either alone makes
# `cat-file blob` exit 128 and leaves the blob missing.
_selfcert_git() {
  GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL=none "$DEVAGENT_GIT" "$@"
}

# _selfcert_names <top> <rev> <entry>: rc 0 iff <entry> names a path in <rev>'s tree: a
# file, a directory or a submodule. An entry with a trailing / must not name a file:
# as a pathspec it then matches nothing (probed, git 2.43). ls-tree, not cat-file: a
# submodule's commit is not an object of this repository. --literal-pathspecs: the
# diff reads the entry as :(literal), so this must too. Without it ls-tree honours
# pathspec magic, and an entry such as `:/scripts/ci/` would name a path here and
# match nothing there.
_selfcert_names() {
  local out
  out="$(_selfcert_git --literal-pathspecs -C "$1" ls-tree "$2" -- "${3%/}" 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  [[ "$3" != */ || "${out%%$'\t'*}" != *" blob "* ]]
}

# _selfcert_tags <top> <rev> <path>: sets _SELFCERT_TAGS to <path>'s tag lines at
# <rev>, in file order, one per line. rc 0 with it empty when <rev>'s tree has no file
# at <path>, or the file has no tag line. Whether the file is there is read from the
# tree (ls-tree), so a file that is there and cannot be read is never taken for one
# with no tag line, the answer that lets a diff through: rc 1, and _SELFCERT_ERR is
# `git ls-tree exited <rc>` or `git cat-file exited <rc>`. The C locale keeps a line
# with a stray lead byte from dropping out; pipefail carries cat-file's status past
# tr, and grep finding nothing is not a failure.
_selfcert_tags() {
  local out rc=0
  _SELFCERT_TAGS="" _SELFCERT_ERR=""
  out="$(_selfcert_git --literal-pathspecs -C "$1" ls-tree "$2" -- "$3" 2>/dev/null)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    _SELFCERT_ERR="git ls-tree exited $rc"
    return 1
  fi
  out="${out%%$'\t'*}"                   # <mode> <type> <object id>
  [[ "$out" == *" blob "* ]] || return 0
  _SELFCERT_TAGS="$(set -o pipefail
    _selfcert_git -C "$1" cat-file blob "${out##* }" 2>/dev/null | tr -d '\r\000' \
      | { LC_ALL=C grep -aiE -- "$SELFCERT_TAG_RE" || true; })" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    _SELFCERT_TAGS="" _SELFCERT_ERR="git cat-file exited $rc"
    return 1
  fi
  return 0
}

# selfcert_paths <tree> <base> <head> [<extra path>...]: the self-certifying paths of
# the diff <base>..<head> (the two commits' trees compared), read in <tree>'s
# repository. Callers pass REQUIRED_CHECKS_PATHS as the extra paths.
#   rc 0  SELFCERT_PATHS=( path ... ), sorted, unique, possibly empty;
#         SELFCERT_LIST is their display form: joined `, `, the first
#         SELFCERT_LIST_MAX of them and then ` (+N more)`, each control character
#         shown as `?` so the text stays on one line
#   rc 2  could not tell; SELFCERT_WHY says why:
#           <sha7> is not a commit in <tree>
#           required_checks_paths entry '<e>' names no path at <base7> or <head7>
#             (SELFCERT_BAD_ENTRY is <e>, else empty)
#           git diff exited <rc>
#           <path> at <sha7> cannot be read in <tree> (git cat-file exited <rc>)
#             (or `git ls-tree exited <rc>`): a changed *.bats file that <sha7>'s
#             tree holds, whose tag lines could therefore not be compared
# A path is self-certifying when it is
#   - under .github/workflows/, or equal to or under an extra path, and changed; or
#   - a changed *.bats file, at any depth, that has a tag line at <base> and whose
#     tag lines at <head> are not the same lines: one was removed or edited, or the
#     file was deleted or renamed (renames are not followed, so it is named by its
#     old path). A file with no tag line at <base> never counts: adding a tag line,
#     or a tagged file, is not a way to weaken the check.
# An extra path that names nothing at either commit would match nothing, silently
# (probed), so it fails closed. git runs at the repository's top level: a pathspec
# is read relative to the directory git runs in, and diff.relative would hide paths
# outside it. `-z` output goes to a file and is read with mapfile, never $( ).
# shellcheck disable=SC2034  # the SELFCERT_* globals are the return channel
selfcert_paths() {
  local tree="$1" base="$2" head="$3" top b h e p tmp rc=0 n bt shown
  local -a specs=(':(literal).github/workflows/') found=() bats=()
  shift 3
  SELFCERT_PATHS=() SELFCERT_LIST="" SELFCERT_WHY="" SELFCERT_BAD_ENTRY=""
  # git reads an empty -C argument as the current directory: never ask there.
  if [[ -z "$tree" || ! -d "$tree" ]]; then
    SELFCERT_WHY="${base:0:7} is not a commit in ${tree:-(no tree)}"
    return 2
  fi
  top="$(_selfcert_git -C "$tree" rev-parse --show-toplevel 2>/dev/null)" || top=""
  [[ -n "$top" ]] || top="$tree"      # a bare repository has no top level: ask in place
  if ! b="$(_selfcert_git -C "$top" rev-parse --verify --quiet "${base}^{commit}" 2>/dev/null)"; then
    SELFCERT_WHY="${base:0:7} is not a commit in $tree"
    return 2
  fi
  if ! h="$(_selfcert_git -C "$top" rev-parse --verify --quiet "${head}^{commit}" 2>/dev/null)"; then
    SELFCERT_WHY="${head:0:7} is not a commit in $tree"
    return 2
  fi
  for e in "$@"; do
    if ! _selfcert_names "$top" "$b" "$e" && ! _selfcert_names "$top" "$h" "$e"; then
      SELFCERT_BAD_ENTRY="$e"
      SELFCERT_WHY="required_checks_paths entry '$e' names no path at ${b:0:7} or ${h:0:7}"
      return 2
    fi
    specs+=(":(literal)$e")
  done
  tmp="$(mktemp -d)"
  _selfcert_git -C "$top" diff --name-only -z --no-renames --ignore-submodules=none \
    "$b" "$h" -- "${specs[@]}" >"$tmp/listed" 2>/dev/null || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    _selfcert_git -C "$top" diff --name-only -z --no-renames --ignore-submodules=none \
      "$b" "$h" -- ':(glob)**/*.bats' >"$tmp/bats" 2>/dev/null || rc=$?
  fi
  if [[ "$rc" -eq 0 ]]; then
    mapfile -d '' found <"$tmp/listed"
    mapfile -d '' bats <"$tmp/bats"
  fi
  rm -rf "$tmp"
  if [[ "$rc" -ne 0 ]]; then
    SELFCERT_WHY="git diff exited $rc"
    return 2
  fi
  for p in "${bats[@]+"${bats[@]}"}"; do
    if ! _selfcert_tags "$top" "$b" "$p"; then
      SELFCERT_WHY="${p//[[:cntrl:]]/?} at ${b:0:7} cannot be read in $tree ($_SELFCERT_ERR)"
      return 2
    fi
    bt="$_SELFCERT_TAGS"
    [[ -n "$bt" ]] || continue
    if ! _selfcert_tags "$top" "$h" "$p"; then
      SELFCERT_WHY="${p//[[:cntrl:]]/?} at ${h:0:7} cannot be read in $tree ($_SELFCERT_ERR)"
      return 2
    fi
    [[ "$bt" == "$_SELFCERT_TAGS" ]] || found+=("$p")
  done
  [[ "${#found[@]}" -gt 0 ]] || return 0
  mapfile -d '' SELFCERT_PATHS < <(printf '%s\0' "${found[@]}" | LC_ALL=C sort -z -u)
  n=0 shown=""
  for p in "${SELFCERT_PATHS[@]}"; do
    n=$((n + 1))
    [[ "$n" -le "$SELFCERT_LIST_MAX" ]] || break
    shown+=", ${p//[[:cntrl:]]/?}"
  done
  SELFCERT_LIST="${shown#, }"
  n=$(( ${#SELFCERT_PATHS[@]} - SELFCERT_LIST_MAX ))
  [[ "$n" -le 0 ]] || SELFCERT_LIST+=" (+$n more)"
  return 0
}

# selfcert_ack <issue_dir> <head40>: rc 0 when the operator acknowledged the
# self-certifying diff at this head: line 1 of <issue_dir>/.devagent-selfcert-ack,
# CR-stripped, is `<40 hex digits> <reason>`, the digits equal <head40> and the
# reason holds a non-blank character. SELFCERT_ACK_REASON is the reason, without
# trailing blanks. Anything else (no file, another head, a short or upper-case id, no
# reason, the line not first) is rc 1 with SELFCERT_ACK_REASON empty: an ack covers
# one head and says why.
# shellcheck disable=SC2034  # SELFCERT_ACK_REASON is the return channel
selfcert_ack() {
  local f="$1/.devagent-selfcert-ack" line=""
  local re='^([0-9a-f]{40})[[:space:]]+(.*[^[:space:]].*)$'
  SELFCERT_ACK_REASON=""
  [[ -f "$f" ]] || return 1
  IFS= read -r line <"$f" || true      # a last line without its newline still reads
  line="${line//$'\r'/}"
  [[ "$line" =~ $re ]] || return 1
  [[ "${BASH_REMATCH[1]}" == "$2" ]] || return 1
  SELFCERT_ACK_REASON="${BASH_REMATCH[2]}"
  SELFCERT_ACK_REASON="${SELFCERT_ACK_REASON%"${SELFCERT_ACK_REASON##*[![:space:]]}"}"
  return 0
}
