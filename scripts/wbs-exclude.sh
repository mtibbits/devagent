#!/usr/bin/env bash
# wbs-exclude: add one `<!-- wbs-exclude: <id>, ... -->` line to WBS.md (#761),
# the supported way to keep deliberately deleted issues out of
# `wbs init --merge` and `wbs update`.
#
# Usage: wbs-exclude.sh [project] <issue-id>...  There are no flags: any
# `--` argument is refused. The first argument is the project only when it
# names a configured project; every other argument is an issue id.
#
# Every id is checked before anything is read or written: it must match the
# exclusion grammar (letters, digits, `_`, `.` and `-`; so no whitespace,
# newline, comma or `>`), and the shared resolver (wbs-tracker.py
# `parse_leaf`) must read it as an issue of a configured source (a source
# needs backend, repo and dir_prefix). No tracker is called. One bad id
# refuses the whole run. Ids that name one issue are folded, and ids an
# existing exclusion line already lists, by `wbs update`'s rule
# (wbs-tracker.py `same_issue`), are skipped. The new line goes directly after
# the last exclusion line outside a fence, with its indentation, else at the
# end at column 0, in the file's line-ending style. It is written only when
# the file gains whole lines and a re-parse lists exactly the new ids; the
# write is wbs-parser.py `write_document`. It never removes or re-glyphs a
# leaf, and never reports existing malformed exclusion lines
# (`wbs init --merge` does). The work is scripts/lib/wbs-exclude.py.
#
# Output (stderr): `wbs exclude: excluded <ids> in <dest>`, with
# `; <ids> already listed` when some were; `wbs exclude: nothing to exclude;
# <ids> already listed`; or one line per refused id, then `wbs exclude:
# nothing written`.
#
# Exit: 0 written, or nothing to do; 1 a missing, unreadable or non-UTF-8
# WBS.md, a failed postcondition, or a failed write (nothing written), or
# the devDoc lock not taken (held past DEVAGENT_DEVDOC_LOCK_TIMEOUT, or its
# location undeterminable; spec §3.3); 2 a refused id, no id, an unknown
# flag, an unknown project, or an unset devdoc_dir.
#
# Lock (#749): the ids are checked before the devDoc repository lock; the
# read and the write run under it, released by the EXIT trap.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
source "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/io.sh
source "$SCRIPT_DIR/lib/io.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/active.sh
source "$SCRIPT_DIR/lib/active.sh"
# shellcheck source=lib/devdoc-repo.sh
source "$SCRIPT_DIR/lib/devdoc-repo.sh"   # #749: the devDoc repository lock

usage() {
  echo "usage: /devagent:wbs exclude [project] <issue-id>..." >&2
}

project_arg=""
ids=()
first=1
for arg in "$@"; do
  case "$arg" in
    --*) printf 'wbs exclude: unknown flag %s\n' "'$arg'" >&2; usage; exit 2 ;;
    *)
      if (( first )) && config_is_project "$arg"; then
        project_arg="$arg"
      else
        ids+=("$arg")
      fi
      first=0
      ;;
  esac
done
if (( ${#ids[@]} == 0 )); then
  echo "wbs exclude: no issue id given" >&2
  usage
  exit 2
fi

active_resolve_project_try "$project_arg" || exit 2
project="$ACTIVE_RESOLVED_PROJECT"
if ! config_is_project "$project"; then
  printf "wbs exclude: unknown project '%s'\n" "$project" >&2
  exit 2
fi
active_guard_scope "wbs exclude"
devdoc_dir="$(config_get_project_field "$project" devdoc_dir 2>/dev/null || true)"
if [[ -z "$devdoc_dir" ]]; then
  printf 'wbs exclude: devdoc_dir not configured for %s\n' "$project" >&2
  exit 2
fi

src_env=("WBS_EXCL_PROJECT=$project")
for pair in ORIGIN:issue_source FORK:issue_source_fork; do
  S="${pair%%:*}" table="${pair#*:}"
  for key in BACKEND:backend REPO:repo PREFIX:dir_prefix; do
    src_env+=("WBS_EXCL_${S}_${key%%:*}=$(config_get_project_field "$project" "$table.${key#*:}" 2>/dev/null || true)")
  done
done

entry="$SCRIPT_DIR/lib/wbs-exclude.py"
# Ids travel NUL-terminated on stdin: a command line splits an id holding a
# newline, and stdin keeps every byte.
printf '%s\0' "${ids[@]}" | env "${src_env[@]}" python3 "$entry" validate

wbs="$devdoc_dir/WBS.md"
[[ -f "$wbs" ]] || die "wbs exclude: $wbs missing; run /devagent:wbs init first"

trap devdoc_lock_release EXIT
devdoc_lock_acquire "$devdoc_dir" - "/devagent:wbs exclude $project ${ids[*]}" || exit 1

printf '%s\0' "${ids[@]}" | env "${src_env[@]}" WBS_PATH="$wbs" python3 "$entry" write
