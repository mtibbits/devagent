#!/usr/bin/env bash
# scripts/code/github.sh — github code backend (push-branch, create-mr, mr-state,
# mr-comments, merge-mr). All gh/git calls go through $DEVAGENT_GH / $DEVAGENT_GIT
# so tests can stub.
set -euo pipefail

: "${DEVAGENT_GH:=gh}"
: "${DEVAGENT_GIT:=git}"

usage() {
    cat >&2 <<'EOF'
usage: code/github.sh <verb> [args...]
verbs:
  push-branch  <remote> <branch>
  create-mr    <repo> <title> <body-file> <head> <base> [--draft]
  mr-state     <mr-url>
  mr-comments  <mr-url>
  merge-mr     <mr-url> [--method squash|merge|rebase]
EOF
    exit 64
}

verb="${1:-}"; shift || usage
case "$verb" in
    push-branch)
        [ $# -eq 2 ] || usage
        "$DEVAGENT_GIT" push --set-upstream "$1" "$2"
        ;;
    *) usage ;;
esac
