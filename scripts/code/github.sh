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
    create-mr)
        [ $# -ge 5 ] || usage
        repo="$1"; title="$2"; body="$3"; head="$4"; base="$5"; shift 5
        draft=()
        while [ $# -gt 0 ]; do
            case "$1" in
                --draft) draft=(--draft); shift ;;
                *) usage ;;
            esac
        done
        "$DEVAGENT_GH" pr create --repo "$repo" --title "$title" \
            --body-file "$body" --head "$head" --base "$base" "${draft[@]}"
        ;;
    mr-state)
        [ $# -eq 1 ] || usage
        "$DEVAGENT_GH" pr view "$1" --json state --jq .state
        ;;
    mr-comments)
        [ $# -eq 1 ] || usage
        "$DEVAGENT_GH" pr view "$1" --comments
        ;;
    merge-mr)
        [ $# -ge 1 ] || usage
        url="$1"; shift
        method="squash"
        while [ $# -gt 0 ]; do
            case "$1" in
                --method)
                    case "${2:-}" in
                        squash|merge|rebase) method="$2"; shift 2 ;;
                        *) echo "code/github.sh: --method must be squash|merge|rebase" >&2; exit 2 ;;
                    esac
                    ;;
                *) usage ;;
            esac
        done
        "$DEVAGENT_GH" pr merge "$url" --"$method"
        ;;
    *) usage ;;
esac
