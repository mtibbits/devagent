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

# #269: classify the rc-2 "can't determine" cause (auth vs network vs rate-limit).
# shellcheck source=../lib/conn-diag.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/conn-diag.sh"

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
        # #85/#243: 0 = exists (HTTP 200); 1 = CONFIRMED absent (a real HTTP 404
        # on a repo the token CAN read); 2 = can't determine (network / 403
        # rate-limit / any other gh error, OR a 404 that masks an unreadable
        # private repo). #269: rc 2 is unchanged for callers (ship.sh keys on rc),
        # but now also carries a classified diagnostic on stderr (auth vs network
        # vs rate-limit) when the captured error is recognizable. `gh api` exits 1
        # for all error cases, so map only a
        # "HTTP 404" in the captured stderr toward absent — but rc 1 is emitted
        # ONLY once repo-readability is established (#243). GitHub returns HTTP
        # 404 for an authorization failure on a private repo (it hides existence
        # rather than 403), so a branch-endpoint 404 is indistinguishable from an
        # absent branch until we confirm the repo itself reads. If it does not,
        # fail closed to rc 2 so ship.sh's stacked logic (rc 1 = drop the parent
        # base) does NOT discard a live parent on a broken-auth or transient
        # failure. merged-pr-head below is unaffected by this 404-masks-403 case:
        # it fails closed via `|| exit 2` when `gh pr list` errors on an
        # unreadable repo. Slashed names (feat/parent) are valid in the path.
        # The `if err=$(...)` form is load-bearing under `set -euo pipefail`:
        # a bare assignment would propagate gh's non-zero status and abort
        # before we could inspect the error text.
        if err="$("$DEVAGENT_GH" api "repos/$1/branches/$2" 2>&1 >/dev/null)"; then
            exit 0
        fi
        case "$err" in
            *"HTTP 404"*)
                # A 404 here means "branch absent" only if the repo is readable.
                # Probe the repo root: readable → genuinely absent (rc 1);
                # otherwise the 404 masks an unreadable private repo → rc 2 (#243).
                # #269: capture the repo-probe error (it carries the auth-vs-network
                # signal, unlike the branch-endpoint 404) and surface a classified
                # cause on stderr; rc 2 unchanged. `if assign` keeps set -e happy.
                if repoerr="$("$DEVAGENT_GH" api "repos/$1" 2>&1 >/dev/null)"; then
                    exit 1
                fi
                if msg="$(conn_diag_message "$repoerr")"; then
                    echo "code/github.sh: branch-exists can't determine '$2' on '$1' — $msg" >&2
                fi
                exit 2
                ;;
            *)
                # #269: any other gh error (network/403/etc). Classify $err; rc 2.
                if msg="$(conn_diag_message "$err")"; then
                    echo "code/github.sh: branch-exists can't determine '$2' on '$1' — $msg" >&2
                fi
                exit 2 ;;
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
        # #243: unaffected by the 404-masks-403 private-repo case — an unreadable
        # repo makes `gh pr list` exit non-zero, so `|| exit 2` already fails
        # closed (rc 2 = can't determine); rc 1 is never reached on an auth failure.
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
