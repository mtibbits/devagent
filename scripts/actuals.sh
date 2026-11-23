#!/usr/bin/env bash
# scripts/actuals.sh — #735. Build <devagent_home>/actuals.json: per (project,
# issue), the tokens, time and sessions cost-report charges, and the dated
# milestones milestones.sh reports, in one versioned, deterministic document the
# portfolio reads (commands/actuals.md; the slot shapes are
# docs/portfolio-schema.md, "Actuals").
#
# Usage: actuals.sh [--archive DIR] [--project P] [--out PATH | --stdout] [--if-stale]
#
#   --archive DIR  read only that transcript archive; without it, every live
#                  transcript dir plus [archive].transcripts_dir when configured
#   --project P    one project's rows (needs --out or --stdout: the default
#                  file stays the all-projects document the portfolio reads)
#   --out PATH     write there instead of <devagent_home>/actuals.json
#   --stdout       print the document instead of writing it
#   --if-stale     cleanup's call: do nothing when the default file is usable
#                  and younger than [archive].actuals_max_age_hours (default 24)
#
# Runs `milestones.sh <p> --all --json` once per project (P alone with
# --project); each run's exit, stdout and stderr reach scripts/lib/actuals.py
# in an ACTUALS_* manifest, which does everything else. A failed source is a
# `sources` row in the document and, for a failed milestones run, one
# `actuals: WARNING:` line here; never a failure.
#
# Exit: 0 written, printed, or skipped as fresh; 1 config missing or invalid,
# or an unknown project; 2 a usage error, --archive not a directory, a
# refused or unwritable output, or a refused actuals_max_age_hours.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/paths.sh
source "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/io.sh
source "$SCRIPT_DIR/lib/io.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

USAGE="usage: actuals.sh [--archive DIR] [--project P] [--out PATH | --stdout] [--if-stale]"

usage_error() {
  [[ -n "${1:-}" ]] && echo "actuals: $1" >&2
  echo "$USAGE" >&2
  exit 2
}

archive="" project="" out="" have_archive=0 have_project=0 have_out=0 to_stdout=0 if_stale=0
# _take <flag> <value>: store a flag's value, refusing an empty one. No $(…):
# usage_error must exit this shell, not a subshell.
_take() {
  [[ -n "$2" ]] || usage_error "$1 needs a value"
  case "$1" in
    --archive) archive="$2" have_archive=1 ;;
    --project) project="$2" have_project=1 ;;
    --out)     out="$2" have_out=1 ;;
  esac
}
while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      echo "$USAGE"
      exit 0
      ;;
    --archive|--project|--out)
      _take "$1" "${2:-}"
      shift 2
      ;;
    --archive=*|--project=*|--out=*)
      _take "${1%%=*}" "${1#*=}"
      shift
      ;;
    --stdout)   to_stdout=1; shift ;;
    --if-stale) if_stale=1; shift ;;
    -?*)        usage_error "unknown flag '$1'" ;;
    *)          usage_error "unexpected argument '$1'" ;;
  esac
done
(( have_out && to_stdout )) && usage_error "--out and --stdout cannot be combined"
if (( if_stale )); then
  (( have_out || to_stdout || have_project )) \
    && usage_error "--if-stale rebuilds the default file only; it takes no --out, --stdout or --project"
fi
if (( have_project && ! have_out && ! to_stdout )); then
  echo "actuals: --project builds a one-project document; pass --out PATH or --stdout" >&2
  echo "$USAGE" >&2
  exit 2
fi

config_load
if (( have_project )) && ! config_is_project "$project"; then
  echo "actuals: unknown project '$project'" >&2
  exit 1
fi

args=()
(( have_archive )) && args+=(--archive "$archive")
(( have_project )) && args+=(--project "$project")
(( have_out )) && args+=(--out "$out")
(( to_stdout )) && args+=(--stdout)
lib="$PLUGIN_ROOT/scripts/lib/actuals.py"

# The manifest belongs to this script: nothing inherited reaches the library.
unset "${!ACTUALS_@}"
pre=("${args[@]}")
(( if_stale )) && pre+=(--if-stale)
rc=0
python3 "$lib" preflight "${pre[@]}" || rc=$?
case "$rc" in
  0) ;;
  3) exit 0 ;;   # fresh: nothing to do
  *) exit "$rc" ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if (( have_project )); then
  projects=("$project")
else
  mapfile -t projects < <(config_list_projects)
fi
i=0
for p in "${projects[@]}"; do
  rc=0
  bash "$SCRIPT_DIR/milestones.sh" "$p" --all --json >"$tmp/$i.out" 2>"$tmp/$i.err" || rc=$?
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "${line//[[:space:]]/}" ]] && echo "actuals: milestones $p: ${line%$'\r'}" >&2
  done < "$tmp/$i.err"
  if (( rc != 0 )); then
    last="$(grep -v '^[[:space:]]*$' "$tmp/$i.err" | tail -n 1 | tr -d '\r' || true)"
    echo "actuals: WARNING: milestones $p: exit $rc: $last; other sources still reported" >&2
  fi
  export "ACTUALS_MS_${i}_PROJECT=$p" "ACTUALS_MS_${i}_RC=$rc" \
    "ACTUALS_MS_${i}_OUT=$tmp/$i.out" "ACTUALS_MS_${i}_ERR=$tmp/$i.err"
  i=$((i + 1))
done
export ACTUALS_MS_COUNT="$i"

rc=0
python3 "$lib" build "${args[@]}" || rc=$?
exit "$rc"
