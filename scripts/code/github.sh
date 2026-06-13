#!/usr/bin/env bash
# scripts/code/github.sh — github code backend.
# Backend contract: the five §9.2 code verbs (push-branch, create-mr, mr-state,
# mr-comments, merge-mr) plus two OPTIONAL verbs used by ship.sh's stacked-base
# pre-validation — branch-exists (#41) and merged-pr-head (#154). Backends may omit
# either; ship.sh treats a non-1 exit as "can't determine" and leaves the parent
# base unchanged. These two verbs are header-comment-only (not in spec §9.2).
# All gh/git calls go through $DEVAGENT_GH / $DEVAGENT_GIT so tests can stub.
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
  branch-exists <repo> <branch>
  merged-pr-head <repo> <branch>
EOF
    exit 2
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
        # §9.3 shape via gh's built-in jq (no external jq dependency here).
        # Same filter as issue/github.sh cmd_comment_list. The old
        # `pr view --comments` human view fails on gh 2.45.0 and has no
        # `### @` lines for comments.sh to count (#84).
        "$DEVAGENT_GH" pr view "$1" --json comments --jq '
          def comment_block:
            .comments | map(
              "### @" + (.author.login // "unknown")
              + " · " + ((.createdAt // "") | split("T")[0])
              + "\n\n" + (.body // "")
            ) | join("\n\n");
          "## Comments (" + ((.comments | length) | tostring) + ")\n"
          + (if (.comments | length) > 0 then "\n" + comment_block + "\n" else "" end)
        '
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
    branch-exists)
        [ $# -eq 2 ] || usage
        # #85: 0 = exists (HTTP 200); 1 = CONFIRMED absent (a real HTTP 404);
        # 2 = can't determine (network / 403 rate-limit / any other gh error).
        # `gh api` exits 1 for all of those, so map only a "HTTP 404" in the
        # captured stderr to absent — everything else is exit 2 so ship.sh's
        # stacked logic (rc 1 = drop the parent base) does NOT discard a live
        # parent on a transient failure. Mirrors merged-pr-head's three-state
        # contract below. Slashed names (feat/parent) are valid in the path.
        # The `if err=$(...)` form is load-bearing under `set -euo pipefail`:
        # a bare assignment would propagate gh's non-zero status and abort
        # before we could inspect the error text.
        if err="$("$DEVAGENT_GH" api "repos/$1/branches/$2" 2>&1 >/dev/null)"; then
            exit 0
        fi
        case "$err" in
            *"HTTP 404"*) exit 1 ;;
            *)            exit 2 ;;
        esac
        ;;
    merged-pr-head)
        [ $# -eq 2 ] || usage
        # #154: 0 = a MERGED PR has <branch> as head (a DEAD parent base — basing a
        # child PR on it strands the child; live PR #152/#153); 1 = none (live
        # parent). A gh error (auth/network/bad repo) is NOT "none" — propagate it
        # as exit 2 so ship.sh's "can't determine" path leaves the base unchanged.
        # Same-repo head match: `--head <branch>` matches heads in <repo>; a
        # fork-first head is `owner:branch` and a bare name can miss → counted as
        # none (fail-open, no worse than pre-#154). devagent — where this fired — is
        # same-repo. (Header-comment contract only; not in spec §9.2.)
        count="$("$DEVAGENT_GH" pr list --repo "$1" --head "$2" --state merged \
                    --json number --jq 'length')" || exit 2
        # A successful gh with empty/non-numeric stdout is NOT "no merged PR" (rc 1) —
        # it is "can't determine" (exit 2), so ship leaves the base unchanged rather
        # than trusting an unprovable parent as live (#154: rc 1 = none, rc >= 2 = unknown).
        [[ "$count" =~ ^[0-9]+$ ]] || exit 2
        [ "$count" -gt 0 ]
        ;;
    *) usage ;;
esac
