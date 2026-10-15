#!/usr/bin/env bash
# /devagent:wbs dispatcher. Routes subcommand to wbs-<sub>.sh.
#
# Project resolution: each subcommand resolves the project via
# active_resolve_project (arg -> env -> global pointer -> single-config).
# The dispatcher itself doesn't resolve; it just routes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
usage: /devagent:wbs <init|update|show> [project] [args]

  init [--force]                        scaffold <devdoc>/WBS.md from the template
  init --from-tracker [--all | --since <date|issue-id> | --open-only | --epic <issue-id>]
                                        build <devdoc>/WBS.md from the tracker's issue history; with
                                        no range flag and a closed share at or above
                                        auto_import_below_pct, print the survey JSON and
                                        WBS-INIT: choose-range and exit 10, writing nothing
  init [--from-tracker] --survey        print the survey JSON only
  update [--offline]                    set issue-leaf glyphs from the tracker, linked MRs, else checklists; add the active issue
  show [--depth N] [--milestone X]      print WBS.md as written (--depth/--milestone: matching nodes)
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage
sub="$1"; shift

case "$sub" in
  init)   exec bash "$SCRIPT_DIR/wbs-init.sh"   "$@" ;;
  update) exec bash "$SCRIPT_DIR/wbs-update.sh" "$@" ;;
  show)   exec bash "$SCRIPT_DIR/wbs-show.sh"   "$@" ;;
  *)      usage ;;
esac
