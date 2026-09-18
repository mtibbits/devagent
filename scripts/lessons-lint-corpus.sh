#!/usr/bin/env bash
# scripts/lessons-lint-corpus.sh — run lessons-lint.sh over a SET of files (#594).
# The one implementation of "is this set of lessons files clean?": cleanup.sh's
# step-23 gate passes it one file, an evidence run passes it a devdoc root, and
# tests/lessons-lint-corpus.bats passes it a hermetic fixture corpus.
#
# usage: lessons-lint-corpus.sh <root-dir | file>...
#   <root-dir>  walked for every lessonsLearned.md beneath it; any path with a
#               .git/ COMPONENT is pruned (a gitlab-notes/ sibling is not).
#   <file>      linted as given, whatever its basename.
#   LESSONS_LINT=<path> overrides the per-file lint (default: lessons-lint.sh
#               beside this script) — a test seam for the could-not-run class.
#
# Exit 0: every subject lint-clean. Exit 1: one or more subjects RED (offenders
# listed). Exit 2: the question could not be answered — usage, a nonexistent
# argument, an EMPTY subject set (zero subjects is never a pass), or a per-file
# lint that exited neither 0 nor 1 (COULD-NOT-RUN: named, counted apart, never
# folded into the red count). Summary line, always last on stdout:
#   lessons-lint-corpus: scanned N files, R red, C could-not-run
# Pure bash — no awk here (the recognizer is the one awk program in this path).
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=lib/io.sh
. "$DEVAGENT_ROOT/scripts/lib/io.sh"

# io.sh's die hard-codes exit 1 (the offenders verdict); the rc-2 class is
# emitted here.
cannot() { printf '%s\n' "lessons-lint-corpus: $*" >&2; exit 2; }

[ "$#" -ge 1 ] || cannot "usage: lessons-lint-corpus.sh <root-dir | file>..."
lint="${LESSONS_LINT:-$DEVAGENT_ROOT/scripts/lessons-lint.sh}"
[ -f "$lint" ] || cannot "lint script not found: $lint"

subjects=()
for arg in "$@"; do
  if [ -d "$arg" ]; then
    while IFS= read -r -d '' f; do
      subjects+=("$f")
    done < <(find "$arg" -name lessonsLearned.md -not -path '*/.git/*' -print0 | sort -z)
  elif [ -f "$arg" ]; then
    subjects+=("$arg")
  else
    cannot "no such file or directory: $arg"
  fi
done
[ "${#subjects[@]}" -gt 0 ] || cannot "no lessonsLearned.md files found under: $*"

red=0
cnr=0
for f in "${subjects[@]}"; do
  rc=0
  out="$(bash "$lint" "$f" 2>&1)" || rc=$?
  case "$rc" in
    0) ;;
    1) red=$((red + 1)); printf 'RED %s\n%s\n' "$f" "$out" ;;
    *) cnr=$((cnr + 1)); printf 'COULD-NOT-RUN %s\n%s\n' "$f" "$out"
       printf '%s\n' "lessons-lint-corpus: could not lint (rc $rc): $f" >&2 ;;
  esac
done

printf '%s\n' "lessons-lint-corpus: scanned ${#subjects[@]} files, $red red, $cnr could-not-run"
[ "$cnr" -eq 0 ] || exit 2
[ "$red" -eq 0 ] || die "$red of ${#subjects[@]} lessons files are red (offenders above)"
