#!/usr/bin/env bash
# scripts/code/github.sh — github code backend.
# Backend contract: the five §9.2 code verbs (push-branch, create-mr, mr-state,
# mr-comments, merge-mr) plus two OPTIONAL verbs used by ship.sh's stacked-base
# pre-validation — branch-exists (#41) and merged-pr-head (#154). Backends may omit
# either; ship.sh treats a non-1 exit as "can't determine" and leaves the parent
# base unchanged. These two verbs are header-comment-only (not in spec §9.2).
# Plus the optional §9.2 verbs issue-mrs (#704), read by `wbs update`, and
# mr-checks (#782), read by lib/ci.sh (next and mergetoall).
# All gh/git calls go through $DEVAGENT_GH / $DEVAGENT_GIT so tests can stub.
set -euo pipefail

: "${DEVAGENT_GH:=gh}"
: "${DEVAGENT_GIT:=git}"

# #269: classify the rc-2 "can't determine" cause (auth vs network vs rate-limit).
# shellcheck source=../lib/conn-diag.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/conn-diag.sh"
# shellcheck source=../lib/backend-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/backend-common.sh"

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
  issue-mrs    <owner/name> <num>...
  mr-checks    <mr-url>
EOF
    exit 2
}

# --- issue-mrs (#704) --------------------------------------------------------
# Optional §9.2 verb: per issue number, the PRs whose title or body closes it
# (scripts/lib/mr-link.py applies the rule and prints the grammar). Candidates
# come from the issue side, its timeline's CrossReferencedEvents, so fork and
# cross-repo PRs are seen whatever their base. One GraphQL call per batch of
# GH_ISSUE_MRS_BATCH issues (a 100-issue batch measured 6.7-9.6 s against
# GitHub's ~10 s GraphQL timeout), plus one call per further page of a
# truncated timeline. Repo and numbers travel as query variables; the query
# text depends only on the batch length.
# Exit: 0 ok (a per-issue NOT_FOUND is `missing` in-band); 1 bad args, gh or
# transport failure, a GraphQL error; 3 auth (HTTP 401/403); 5 an
# unrecognised record, non-JSON, a repeated cursor or > 50 pages.
GH_ISSUE_MRS_BATCH=50
GH_ISSUE_MRS_MAX_PAGES=50
# shellcheck disable=SC2016  # GraphQL, not shell
GH_TL_FRAGMENT='fragment P on IssueTimelineItemsConnection { totalCount pageInfo{hasNextPage endCursor} nodes{ ... on CrossReferencedEvent { source { __typename ... on PullRequest { number title body state isDraft createdAt mergedAt repository{nameWithOwner} } } } } }'

# _im_fail <errfile> <what>: report gh's last stderr line; exit 3 for auth, else 1.
_im_fail() {
    local last msg
    last="$(grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | tr -d '\r' || true)"
    echo "code/github.sh: issue-mrs: $2 failed${last:+: $last}" >&2
    if msg="$(conn_diag_message "$(cat "$1" 2>/dev/null)")" && [[ "$msg" == authentication* ]]; then
        exit 3
    fi
    exit 1
}

# _im_call <out> <err> <gh args...>: run gh; set IM_RC (never trips set -e).
_im_call() {
    local out="$1" err="$2"; shift 2
    if "$DEVAGENT_GH" api graphql "$@" >"$out" 2>"$err"; then IM_RC=0; else IM_RC=$?; fi
}

issue_mrs() {
    local repo="$1"; shift
    local owner="${repo%%/*}" name="${repo#*/}" id
    if [[ ! "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
        echo "code/github.sh: issue-mrs: repo must be <owner/name>: '$repo'" >&2
        exit 1
    fi
    for id in "$@"; do
        [[ "$id" =~ ^[0-9]+$ ]] || { echo "code/github.sh: issue-mrs: not an issue number: '$id'" >&2; exit 1; }
    done
    [ $# -gt 0 ] || exit 0
    bc_have_cli jq || { echo "code/github.sh: issue-mrs: jq not on PATH" >&2; exit 1; }
    local tmp; tmp="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand $tmp now
    trap "rm -rf '$tmp'" EXIT
    local ids=("$@") recs="$tmp/records" start=0 canon="$repo"
    : > "$recs"
    while [ "$start" -lt "${#ids[@]}" ]; do
        local batch=("${ids[@]:start:GH_ISSUE_MRS_BATCH}") k decl="" aliases="" args=()
        for k in "${!batch[@]}"; do
            decl+=",\$n$k:Int!"
            aliases+=" i$k: issue(number:\$n$k){ timelineItems(itemTypes:[CROSS_REFERENCED_EVENT], first:100){...P} }"
            args+=(-F "n$k=${batch[$k]}")
        done
        local q="query(\$owner:String!,\$name:String!$decl){repository(owner:\$owner,name:\$name){ nameWithOwner$aliases }} $GH_TL_FRAGMENT"
        _im_call "$tmp/out" "$tmp/err" -f "query=$q" -f "owner=$owner" -f "name=$name" "${args[@]}"
        # Valid: JSON with .data.repository; every error a per-alias NOT_FOUND.
        if ! jq -e '.data.repository | type == "object"' "$tmp/out" >/dev/null 2>&1; then
            if [ "$IM_RC" -ne 0 ]; then _im_fail "$tmp/err" "gh api graphql (exit $IM_RC)"; fi
            if ! jq -e . "$tmp/out" >/dev/null 2>&1; then
                echo "code/github.sh: issue-mrs: gh returned non-JSON" >&2; exit 5
            fi
            _im_fail "$tmp/err" "gh api graphql (no data)"
        fi
        if ! jq -e '[.errors[]? | select(.type != "NOT_FOUND" or (.path | length) != 2
                     or .path[0] != "repository" or ((.path[1] | tostring) | test("^i[0-9]+$") | not))]
                    | length == 0' "$tmp/out" >/dev/null; then
            echo "code/github.sh: issue-mrs: GraphQL error: $(jq -r '[.errors[]? | (.type // "") + " " + (.message // "")] | first' "$tmp/out" | tr -d '\r')" >&2
            exit 1
        fi
        if [ "$IM_RC" -ne 0 ] && ! jq -e '(.errors // []) | length > 0' "$tmp/out" >/dev/null; then
            _im_fail "$tmp/err" "gh api graphql (exit $IM_RC)"
        fi
        # One line per alias: `M` (more pages) or `-`, TAB, {id, status, nodes,
        # more, cursor}. The flag spares a jq spawn per issue (slow on Windows).
        local ids_json
        ids_json="$(printf '"%s",' "${batch[@]}")"; ids_json="[${ids_json%,}]"
        # `#N` resolves against a PR's own repo, which GitHub names
        # canonically; a renamed or transferred repo still configured under
        # its old name must not read as "no MR" everywhere.
        canon="$(jq -r '.data.repository.nameWithOwner // empty' "$tmp/out" | tr -d '\r')"
        [ -n "$canon" ] || canon="$repo"
        # shellcheck disable=SC2016  # jq program
        if ! jq -r --argjson ids "$ids_json" '
              .data.repository as $r
              | ([.errors[]? | .path[1] | ltrimstr("i") | tonumber]) as $missing
              | range(0; $ids | length) as $k
              | if ($missing | any(. == $k)) then {id: $ids[$k], status: "missing", nodes: []}
                else ($r["i\($k)"].timelineItems // error("alias i\($k) has no timeline")) as $t
                | {id: $ids[$k], status: "ok", nodes: $t.nodes,
                   more: ($t.totalCount > ($t.nodes | length) and $t.pageInfo.hasNextPage),
                   cursor: $t.pageInfo.endCursor}
                end
              | (if .more then "M" else "-" end) + "\t" + tojson' "$tmp/out" > "$tmp/lines"; then
            echo "code/github.sh: issue-mrs: unrecognised GraphQL response" >&2
            exit 5
        fi
        local line n=0
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            [ -n "$line" ] || continue
            n=$((n + 1))
            if [ "${line%%$'\t'*}" != M ]; then
                printf '%s\n' "${line#*$'\t'}" >> "$recs"
                continue
            fi
            printf '%s\n' "${line#*$'\t'}" > "$tmp/rec"
            local pages=0 seen=" " more cursor iid
            while :; do
                # `|`, not TAB: whitespace IFS would collapse an empty cursor
                IFS='|' read -r more cursor iid < <(jq -r \
                    '[(.more == true | tostring), (.cursor // ""), (.id | tostring)] | join("|")' \
                    "$tmp/rec" | tr -d '\r')
                [ "$more" = true ] || break
                if [ -z "$cursor" ] || [[ "$seen" == *" $cursor "* ]]; then
                    echo "code/github.sh: issue-mrs: issue $iid: repeated or empty page cursor" >&2; exit 5
                fi
                pages=$((pages + 1))
                if [ "$pages" -gt "$GH_ISSUE_MRS_MAX_PAGES" ]; then
                    echo "code/github.sh: issue-mrs: issue $iid: more than $GH_ISSUE_MRS_MAX_PAGES pages" >&2; exit 5
                fi
                seen+="$cursor "
                _im_call "$tmp/page" "$tmp/err" \
                    -f "query=query(\$owner:String!,\$name:String!,\$n:Int!,\$after:String!){repository(owner:\$owner,name:\$name){issue(number:\$n){timelineItems(itemTypes:[CROSS_REFERENCED_EVENT],first:100,after:\$after){...P}}}} $GH_TL_FRAGMENT" \
                    -f "owner=$owner" -f "name=$name" -F "n=$iid" -f "after=$cursor"
                if [ "$IM_RC" -ne 0 ] || ! jq -e '(.errors // []) | length == 0' "$tmp/page" >/dev/null 2>&1; then
                    _im_fail "$tmp/err" "gh api graphql page (exit $IM_RC)"
                fi
                # shellcheck disable=SC2016  # jq program
                if ! jq -c --slurpfile p "$tmp/page" '
                      ($p[0].data.repository.issue.timelineItems // error("no timeline")) as $t
                      | .nodes += $t.nodes
                      | .more = ($t.totalCount > (.nodes | length) and $t.pageInfo.hasNextPage)
                      | .cursor = $t.pageInfo.endCursor' "$tmp/rec" > "$tmp/rec2"; then
                    echo "code/github.sh: issue-mrs: unrecognised page response" >&2; exit 5
                fi
                mv "$tmp/rec2" "$tmp/rec"
            done
            cat "$tmp/rec" >> "$recs"
        done < "$tmp/lines"
        [ "$n" -eq "${#batch[@]}" ] || { echo "code/github.sh: issue-mrs: batch answered $n of ${#batch[@]} issues" >&2; exit 5; }
        start=$((start + GH_ISSUE_MRS_BATCH))
    done
    # Normalise for mr-link.py: PR sources only, states mapped, bodies kept.
    # shellcheck disable=SC2016  # jq program
    if ! jq -c '{id, status, mrs: [.nodes[] | .source? // empty
            | select(.__typename == "PullRequest")
            | {repo: .repository.nameWithOwner,
               ref: "\(.repository.nameWithOwner)#\(.number)",
               state: (if .state == "OPEN" then "open" elif .state == "CLOSED" then "closed"
                       elif .state == "MERGED" then "merged"
                       else error("unrecognised PR state \(.state)") end),
               draft: (.isDraft == true), created: .createdAt, merged: .mergedAt,
               title: (.title // ""), body: (.body // "")}]}' "$recs" > "$tmp/norm"; then
        echo "code/github.sh: issue-mrs: unrecognised PR record" >&2
        exit 5
    fi
    # Never exit 2 (python's own code for an unopenable script): 2 means "no verb".
    python3 "$(dirname "${BASH_SOURCE[0]}")/../lib/mr-link.py" emit github "$canon" < "$tmp/norm" || exit 5
}

# --- mr-checks (#782) --------------------------------------------------------
# Optional §9.2 verb: the PR's state, its head SHA as the forge reports it, and
# one line per de-duplicated check, in rollup order (TAB-separated):
#   state  open|merged|closed
#   head   <40-hex>
#   pass|pending  <name>  <link>
#   fail          <name>  <link>  <CONCLUSION>
# One `gh pr view --json headRefOid,state,statusCheckRollup` call, one jq filter.
# Exit: 0 ok; 1 bad args, gh missing or failed, jq missing (never 2: 2 and 78
# mean "no verb"); 5 an unrecognised record or non-JSON. On a non-zero exit the
# LAST stderr line is a bare reason (no prefix): lib/ci.sh quotes it.
# The bucket table is the decision. STALE is deliberately unmapped: it fails
# closed (exit 5, CI UNKNOWN). Dedup key = workflowName + name/context, keeping a
# not-yet-COMPLETED run first, then the latest startedAt, then rollup order. Known
# limit: two non-Actions apps posting same-named checks (empty workflowName)
# collapse into one.
# shellcheck disable=SC2016  # jq, not shell
GH_MR_CHECKS_JQ='def clean: tostring | gsub("[\t\r\n]"; " ");
def bucket:
  if .__typename == "StatusContext" then
    {"SUCCESS":"pass","PENDING":"pending","EXPECTED":"pending",
     "FAILURE":"fail","ERROR":"fail"}[.state // ""]
  elif .__typename == "CheckRun" then
    if .status != "COMPLETED" then "pending"
    else {"SUCCESS":"pass","SKIPPED":"pass","NEUTRAL":"pass",
          "FAILURE":"fail","CANCELLED":"fail","TIMED_OUT":"fail",
          "ACTION_REQUIRED":"fail","STARTUP_FAILURE":"fail"}[.conclusion // ""]
    end
  else null end;
({"OPEN":"open","MERGED":"merged","CLOSED":"closed"}[.state // ""]
   // error("state \(.state)")) as $st
| ((.headRefOid // "") | if test("^[0-9a-f]{40}$") then . else error("head \(.)") end) as $head
| "state\t\($st)", "head\t\($head)",
  ( .statusCheckRollup // [] | to_entries
    | map(.value + {_i: .key,
                    _k: [(.value.workflowName // ""), (.value.name // .value.context // "")]})
    | group_by(._k)
    | map(max_by([(.__typename == "CheckRun" and .status != "COMPLETED"), (.startedAt // ""), ._i]))
    | sort_by(._i) | .[]
    | (bucket // error("unrecognised check \(.name // .context): \(.__typename) \(.status // .state) \(.conclusion // "")")) as $b
    | $b + "\t" + ((.name // .context) | clean) + "\t" + ((.detailsUrl // .targetUrl // "") | clean)
      + (if $b == "fail" then "\t" + ((.conclusion // .state // "") | clean) else "" end) )'

mr_checks() {
    local url="$1" rc=0
    bc_have_cli "$DEVAGENT_GH" || { echo "gh not on PATH" >&2; exit 1; }
    bc_have_cli jq || { echo "jq not on PATH" >&2; exit 1; }
    local tmp; tmp="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand $tmp now
    trap "rm -rf '$tmp'" EXIT
    GH_PROMPT_DISABLED=1 "$DEVAGENT_GH" pr view "$url" --json headRefOid,state,statusCheckRollup         </dev/null >"$tmp/out" 2>"$tmp/err" || rc=$?
    if [ "$rc" -ne 0 ]; then
        cat "$tmp/err" >&2
        echo "gh exited $rc" >&2      # gh's own 2 ("cancelled") must not read as "no verb"
        exit 1
    fi
    rc=0
    jq -r "$GH_MR_CHECKS_JQ" <"$tmp/out" >"$tmp/lines" 2>"$tmp/jqerr" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "unrecognised rollup: $(grep -v '^[[:space:]]*$' "$tmp/jqerr" | tail -n 1 | tr -d '\r')" >&2
        exit 5
    fi
    tr -d '\r' <"$tmp/lines"
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
        # §9.3 mr-comments shape (#592): conversation comments, then review
        # summaries (` · review: STATE`), then inline comments (` · path:line`),
        # under ONE `## Comments (N)` header counting all of them. Filters run
        # in gh's built-in jq (no external jq dependency here). `--paginate
        # --jq` filters PER PAGE and gh 2.45 has no --slurp, so each filter
        # emits one @base64 block per line and the count/join happen here.
        # Owner/repo/host come from the URL, never gh's {owner}/{repo}
        # placeholders (those resolve from the ambient cwd's remote).
        url="${1%%#*}"; url="${url%%\?*}"
        rest="${url#*://}"; host="${rest%%/*}"
        IFS=/ read -r owner repo kind num _ <<<"${rest#*/}"
        if [ "$kind" != pull ] || ! [[ "$num" =~ ^[0-9]+$ ]] || [ -z "$owner" ] || [ -z "$repo" ]; then
            echo "code/github.sh: mr-comments: cannot parse PR URL '$1'" >&2
            exit 2
        fi
        # gh reads a non-http(s) argument as a PR number or a branch of the
        # cwd's repo, so hand it the URL just parsed, never the raw input.
        scheme=https; [[ "$url" == *://* ]] && scheme="${url%%://*}"
        url="$scheme://$host/$owner/$repo/pull/$num"
        # One entry: `### @login · date[suffix]`, blank line, body. The
        # conversation form is the same filter as issue/github.sh
        # cmd_comment_list. An empty-body COMMENTED review is the container
        # GitHub creates for an inline-comment batch (its content arrives via
        # the inline call); a PENDING review is the viewer's own draft.
        # shellcheck disable=SC2016  # a jq program, not shell
        entry_def='def entry($who; $ts; $suffix):
            "### @" + ($who // "unknown") + " · " + (($ts // "") | split("T")[0])
            + $suffix + "\n\n" + (.body // "");'
        pr_blocks="$("$DEVAGENT_GH" pr view "$url" --json comments,reviews --jq "$entry_def"'
          ((.comments // [])[] | entry(.author.login; .createdAt; "")),
          ((.reviews // [])[]
            | select(.state != "PENDING")
            | select((.body // "") != "" or .state != "COMMENTED")
            | entry(.author.login; .submittedAt; " · review: " + (.state // "UNKNOWN")))
          | @base64
        ')"
        skip_inline=0
        [ "${DEVAGENT_MR_COMMENTS_SKIP_INLINE:-}" = 1 ] && skip_inline=1
        inline_blocks=""
        if [ "$skip_inline" = 0 ]; then
            # shellcheck disable=SC2016  # a jq program, not shell
            inline_blocks="$("$DEVAGENT_GH" api --hostname "$host" --paginate \
                "repos/$owner/$repo/pulls/$num/comments?per_page=100" --jq "$entry_def"'
              .[]
              | (.line // .original_line) as $ln
              | entry(.user.login; .created_at;
                  " · " + (.path // "") + (if $ln then ":" + ($ln | tostring) else "" end))
              | @base64
            ')" || {
                rc=$?
                echo "code/github.sh: mr-comments: inline review comments could not be fetched — re-run /devagent:comments; to fetch without them set DEVAGENT_MR_COMMENTS_SKIP_INLINE=1" >&2
                exit "$rc"
            }
        fi
        blocks=()
        while IFS= read -r enc; do
            [ -n "$enc" ] || continue
            # The trailing `x` keeps the body's own trailing newlines ($(...) strips them).
            block="$(printf '%s' "$enc" | base64 -d && printf x)"
            blocks+=("${block%x}")
        done <<<"$pr_blocks"$'\n'"$inline_blocks"
        # Same bytes as the #84 jq filter: header, blank line, each block
        # followed by a blank line.
        bc_emit_comments_header "${#blocks[@]}"
        for block in "${blocks[@]}"; do printf '%s\n\n' "$block"; done
        if [ "$skip_inline" = 1 ]; then
            printf '> inline review comments not fetched (DEVAGENT_MR_COMMENTS_SKIP_INLINE=1)\n\n'
        fi
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
    issue-mrs)
        # bad args exit 1, never 2: 2 means "no such verb" to wbs update (#704)
        [ $# -ge 1 ] || { echo "usage: code/github.sh issue-mrs <owner/name> <num>..." >&2; exit 1; }
        issue_mrs "$@"
        ;;
    mr-checks)
        [ $# -eq 1 ] || { echo "usage: code/github.sh mr-checks <mr-url>" >&2; exit 1; }
        mr_checks "$1"
        ;;
    *) usage ;;
esac
