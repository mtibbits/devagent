#!/usr/bin/env bash
# scripts/lib/io.sh — small io helpers. Safe to source multiple times.

_io_progname() {
  # #320: name the ENTRY script ($0), not BASH_SOURCE[1] — which from inside
  # die/warn/info is io.sh's own frame, so every diagnostic was prefixed "io.sh:".
  basename "$0"
}

die() {
  echo "$(_io_progname): $*" >&2
  exit 1
}

info() {
  echo "$(_io_progname): $*" >&2
}

warn() {
  echo "$(_io_progname): WARNING: $*" >&2
}

is_tty() {
  [[ -t 0 ]]
}

confirm() {
  local prompt="${1:-Proceed?}"
  if [[ "${DA_YES:-}" == "1" ]]; then
    return 0
  fi
  if ! is_tty; then
    return 1
  fi
  local reply
  read -r -p "$prompt [Y/n] " reply
  case "$reply" in
    ""|y|Y|yes|YES) return 0 ;;
    *)              return 1 ;;
  esac
}

# date_tag — YYYY-MM-DD, honoring DEVAGENT_DATE_OVERRIDE for test determinism
# (#338). Mirrors capture/lib/slug.sh so the analyze family and the capture
# family agree. Falls back to the real date when the override is unset.
date_tag() {
  if [[ -n "${DEVAGENT_DATE_OVERRIDE:-}" ]]; then
    printf '%s\n' "$DEVAGENT_DATE_OVERRIDE"
  else
    date +%Y-%m-%d
  fi
}

# #410: the born-red staleness fingerprint — the single source of truth for the
# tests/ delta that born-red judged, so commit.sh can detect drift ("run born-red,
# add a vacuous test, commit rides the stale PASS"). born-red.sh writes it into the
# artifact; commit.sh recomputes and dies on mismatch. Both call THIS function so
# the two can never drift apart.
#
# It hashes, for the UNION of (tracked files under tests/ that differ from
# baseline, via rename-aware `git diff --name-only -M`) and (untracked files under
# tests/, via `ls-files --others`), a sorted list of "<path> <content-hash>". This
# is a conservative SUPERSET of born-red's judged test set: it covers every path
# under tests/, not just `_is_test_file` matches, so a change to a shared helper /
# fixture / conftest that could flip a judged test's baseline result also drifts —
# the correct, fail-closed direction. Keying on path + `git hash-object` content makes
# it invariant to a file's tracked/untracked status, so merely `git add`-ing a test
# between the born-red run and the commit (same content) does NOT false-drift; only
# an added / edited / removed test does.
#   born_red_tests_fingerprint <dir> <baseline>
born_red_tests_fingerprint() {
  local dir="$1" baseline="$2" git="${DEVAGENT_GIT:-git}" f
  {
    {
      "$git" -C "$dir" diff --name-only -M "$baseline" -- tests/ 2>/dev/null
      "$git" -C "$dir" ls-files --others --exclude-standard -- tests/ 2>/dev/null
    } | LC_ALL=C sort -u | while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ -e "$dir/$f" ]; then
        printf '%s %s\n' "$f" "$("$git" -C "$dir" hash-object -- "$f" 2>/dev/null || echo ERR)"
      else
        printf '%s DELETED\n' "$f"
      fi
    done
  } | sha256sum | cut -d' ' -f1
}
