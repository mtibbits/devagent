#!/usr/bin/env bash
# scripts/capacity.sh — #743: resolve and validate the operator capacity declared in
# config.toml ([capacity] and [project.<name>.capacity]) into the capacity document.
#
#   usage: capacity.sh            (no arguments; -h | --help prints the usage line)
#
# stdout: the document (JSON) on exit 0, nothing otherwise. stderr: every line starts
# `capacity: ` — violations, then warnings.
# Exits: 0 resolved; 2 any argument; 3 invalid values; 4 config missing, unreadable or
# not valid TOML. Exit 1 is never chosen: it is what a crash looks like, so this script
# calls neither die nor config_load (both exit 1), and every fallible command below is
# guarded with an explicit exit.
#
# Every rule, the document and the message text live in scripts/lib/capacity.py; this
# entry point only checks the config the way doctor does (_toml.py validate) and passes
# the project list from config_list_projects, so both answer from the same source.
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 4
# shellcheck source=lib/paths.sh
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
# shellcheck source=lib/io.sh
source "$PLUGIN_ROOT/scripts/lib/io.sh"
# shellcheck source=lib/config.sh
source "$PLUGIN_ROOT/scripts/lib/config.sh"

help=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) help=1 ;;
    *) printf "capacity: unexpected argument '%s' (usage: capacity.sh)\n" "$arg" >&2; exit 2 ;;
  esac
done
if (( help == 1 )); then
  echo "usage: capacity.sh"
  exit 0
fi

cfg="$(config_path)" || exit 4
[[ -f "$cfg" && -r "$cfg" ]] || { echo "capacity: config not readable: $cfg" >&2; exit 4; }
_config_toml validate "$cfg" >/dev/null 2>&1 || { echo "capacity: config is not valid TOML: $cfg" >&2; exit 4; }
list="$(config_list_projects)" || { echo "capacity: cannot list projects: $cfg" >&2; exit 4; }

names=()
while IFS= read -r p; do
  if [[ -n "$p" ]]; then names+=("$p"); fi
done <<<"$list"

exec python3 "$PLUGIN_ROOT/scripts/lib/capacity.py" resolve "$cfg" ${names[@]+"${names[@]}"}
