#!/usr/bin/env bash
# issue/custom.sh — template/stub for a custom issue backend.
#
# To implement your own backend:
#   1. Copy this file to scripts/issue/<yourname>.sh
#   2. Set `backend = "<yourname>"` under [project.<name>.issue_source]
#      in ~/.claude/devagent/config.toml
#   3. Replace each cmd_* function with your implementation.
#   4. Run `bats tests/backend-contract.bats` against your backend
#      to confirm contract compliance (see README "Custom backends").
#
# The verbs fetch, create, transition, state and comment-list MUST be
# implemented for the dispatcher to function; state-list MAY be (an absent
# one makes `wbs update` use local checklists, #703), and so MAY issue-list
# (an absent one makes `wbs init --from-tracker` refuse, #706) and
# state-exists <repo> <state> (exit 0 present, 4 absent; an absent verb makes
# doctor skip its tracker check, #710), and so MAY the read-only events
# <repo> <num>, events --kinds <repo>, comment-records <repo> <num> and whoami
# <repo> (exit 78 or 2 means unsupported, #712). Until a verb is implemented
# it exits 78 (EX_CONFIG) with a documented message so callers can report
# "backend not implemented" cleanly.
#
# #710: the callers always append `--project <name>` to transition, naming
# the project they resolved. Accept it; a backend that keeps its own stage
# mapping may ignore it. The built-in backends read the project's
# [project.<name>.issue_workflow] mapping through scripts/lib/transition.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/backend-common.sh
source "${SCRIPT_DIR}/../lib/backend-common.sh"

usage() {
  cat <<EOF >&2
Usage: custom.sh <verb> [args…]
  fetch <repo> <num>
  create <repo> <title> <body-file> [--label X]…
  transition <repo> <num> <semantic-stage> [--project <name>]
  state <repo> <num>
  comment-list <repo> <num>
  state-list <repo>
  issue-list <repo>
  state-exists <repo> <state>
  events <repo> <num>
  events --kinds <repo>
  comment-records <repo> <num>
  whoami <repo>
EOF
  exit 2
}

verb="${1:-}"; shift || true
case "$verb" in
  fetch|create|transition|state|comment-list|state-list|issue-list|state-exists|events|comment-records|whoami)
    bc_die_not_implemented custom "$verb" ;;
  ""|-h|--help) usage ;;
  *) usage ;;
esac
