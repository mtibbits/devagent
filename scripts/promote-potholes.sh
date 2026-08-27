#!/usr/bin/env bash
# scripts/promote-potholes.sh — #586. Durable [pattern] → pothole-register
# promotion. Step 22 STAGES lines into <issue-dir>/potholes-promotion.md (a
# devdoc file, immune to the shared source tree's stash/revert/gate churn);
# step 23 (cleanup, right after its tree restore) DRAINS that file into the
# resolved register and commits it, scoped to that one path. A promotion CLAIM
# the register does not carry FAILS --check.
#
# Modes:
#   <project> <issue-dir> --add "<section heading>" "<line>"   stage one line
#   <project> <issue-dir> --apply                              drain + commit
#   <project> <issue-dir> --check                              claim vs register
#   <project> --list-pending                                   undrained backlog
#
# Exit: 0 ok | 1 refused/failed (loud) | 2 usage | 3 apply DEFERRED, staging
#       file retained pending (register dirty, wrong branch, register outside
#       the project's repos). Callers treat 3 as a warn, 1 as a die.
#
# The --check CLAIM predicate, in one sentence: a `lessonslearned:` log entry
# that says patterns were promoted to the register/potholes — unless it is
# worded as a deferral/skip, or this issue's staging file is still pending
# (the staging file IS the promise; --apply honours it).
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/template_resolve.sh"   # pulls paths/io/config

: "${DEVAGENT_GIT:=git}"

usage() {
    echo "usage: promote-potholes.sh <project> <issue-dir> --add <section> <line> | --apply | --check
       promote-potholes.sh <project> --list-pending" >&2
    exit 2
}

project="${1:-}"; [ -n "$project" ] || usage
config_is_project "$project" || die "unknown project '$project'"
shift
devdoc_dir="$(config_get_project_field "$project" devdoc_dir)"
source_dir="$(config_get_project_field "$project" source_dir)"

# --list-pending needs no issue.
if [ "${1:-}" = "--list-pending" ]; then
    found=0
    for f in "$devdoc_dir"/*/potholes-promotion.md; do
        [ -e "$f" ] || continue
        grep -q '^status: pending' "$f" || continue
        found=1
        printf 'pending: %s (%s lines)\n' "$f" "$(grep -c '^- ' "$f")"
    done
    [ "$found" -eq 1 ] || echo "no pending pothole promotions for $project"
    exit 0
fi

issue_dir="${1:-}"; [ -n "$issue_dir" ] || usage
shift
[ -d "$issue_dir" ] || die "no such issue dir: $issue_dir"
issue_id="$(basename "$issue_dir")"          # e.g. Issue-586
issue_n="${issue_id##*-}"
stage="$issue_dir/potholes-promotion.md"

# Resolve the register ONCE, via the §12 walk.
reg="$(template_resolve "$project" potholes | sed -n 's/^path=//p')"
[ -n "$reg" ] && [ -f "$reg" ] || die "promote-potholes: potholes register unresolvable for '$project'"

# Path forms diverge on this platform (MSYS `/c/…`, config `c:/…`, git `C:/…`),
# so every comparison goes through ONE canonical form (cd + pwd -P). Comparing
# the raw strings made the drain defer forever in production (improve finding 1).
_canon() { ( cd "$1" 2>/dev/null && pwd -P ); }

# _cited <file> — does <file> carry a citation naming THIS issue? The closing
# paren is load-bearing: a bare "Issue-1" prefix-matches "Issue-10)" and
# "Issue-Fork-1)". The optional token accepts the cross-project spelling
# "(lawFirm Issue-21)" ONLY when it names this project (case-insensitive).
_cited() { grep -qiE "\((${project} )?${issue_id}\)" "$1"; }

case "${1:-}" in
--add)
    section="${2:-}"; line="${3:-}"
    [ -n "$section" ] && [ -n "$line" ] || usage
    case "$line" in *$'\n'*) die "--add: the line must be a SINGLE line" ;; esac
    tr -d '\r' < "$reg" | grep -qxF "## $section" \
        || die "--add: no section '## $section' in $reg — use a heading that already exists (grep '^## ' \"$reg\")"
    case "$line" in "- "*) ;; *) die "--add: the line must start with '- '" ;; esac
    printf '%s' "$line" | grep -qiE "\((${project} )?${issue_id}\)\.$" \
        || die "--add: the line must end with its own citation '(${issue_id}).'"
    # Weak, project-DERIVED neutrality rail on the BODY (citation stripped —
    # the citation token may legitimately carry the project name). The
    # shipped-token canary (tests/generic-templates.bats) remains the sole owner
    # of the project-specific token list; this check does NOT own that
    # constraint — it only catches the commonest leak, the project's own name.
    body="$(printf '%s' "$line" | sed -E 's/ *\(([A-Za-z]+ )?Issue-[A-Za-z0-9-]+\)\.$//')"
    ! printf '%s' "$body" | grep -qiF -- "$project" \
        || die "--add: the line names the project ('$project') — the register is a shipped, project-neutral template"
    if [ ! -f "$stage" ]; then
        {
            echo "# Pothole promotion — $issue_id"
            echo
            echo "<!-- #586: written by step 22 (core-lessons-learned item 7) via"
            echo "     scripts/promote-potholes.sh --add. Applied to the resolved potholes"
            echo "     register by --apply, which cleanup.sh (step 23) runs after its tree"
            echo "     restore. Lines are appended VERBATIM at the END of the named section."
            echo "     Do not hand-edit the status line. -->"
            echo
            echo "status: pending"
        } > "$stage"
    fi
    grep -qxF -- "$line" "$stage" && { info "--add: already staged (idempotent): $line"; exit 0; }
    if grep -qxF "## $section" "$stage"; then
        # ENVIRON, not -v: -v processes C escapes and would corrupt a `\(`.
        S="## $section" L="$line" awk '
            $0==ENVIRON["S"] {print; print ENVIRON["L"]; done=1; next} {print}
            END{ if(!done) exit 9 }' "$stage" > "$stage.tmp" && mv "$stage.tmp" "$stage"
    else
        { echo; echo "## $section"; echo "$line"; } >> "$stage"
    fi
    info "staged for $issue_id: $line"
    ;;

--check)
    claim=""
    if [ -f "$issue_dir/checklist.md" ]; then
        claim="$(awk '/^## Log/{p=1;next} /^## /{p=0} p' "$issue_dir/checklist.md" \
                 | grep -E '^- .*[[:space:]]lessonslearned:' \
                 | grep -iE 'promot.*(register|pothole)' \
                 | grep -ivE 'defer|refus|skip|not promoted|no promotion|not committed|none staged|candidate' || true)"
    fi
    if [ -f "$stage" ] && grep -q '^status: applied' "$stage"; then
        claim="${claim}${claim:+$'\n'}staging file: $stage says applied"
    fi
    if [ -f "$stage" ] && grep -q '^status: pending' "$stage"; then
        info "promote-potholes: $issue_id has a PENDING register promotion ($stage) — cleanup will drain it"
        claim=""     # the staging file IS the promise; honoured at --apply
    fi
    if [ -n "$claim" ] && ! _cited "$reg"; then
        printf 'promote-potholes: %s CLAIMS a register promotion the register does not carry.\n' "$issue_id" >&2
        printf '  register: %s (no "%s)" citation)\n' "$reg" "$issue_id" >&2
        printf '  claim(s):\n%s\n' "$claim" | sed 's/^/    /' >&2
        printf '  fix: stage the lines (promote-potholes.sh %s %s --add ...) and let cleanup drain them,\n' "$project" "$issue_dir" >&2
        printf '       or correct the log line to say the promotion is deferred/skipped and why.\n' >&2
        exit 1
    fi
    ;;

--apply)
    [ -f "$stage" ] || exit 0
    grep -q '^status: pending' "$stage" || exit 0
    src_c="$(_canon "$source_dir" || true)"; doc_c="$(_canon "$devdoc_dir" || true)"
    reg_c="$(_canon "$(dirname "$reg")")/$(basename "$reg")"
    # Rail 1: the register must live inside this project's own repos. A foreign
    # project's plugin-default register (and any test that forgot its override)
    # is DEFERRED, never written.
    case "$reg_c" in
        "$src_c"/*|"$doc_c"/*) [ -n "$src_c$doc_c" ] ;;
        *) warn "promote-potholes: register $reg is outside $source_dir and $devdoc_dir — not writing it; $issue_id stays pending"; exit 3 ;;
    esac
    # A devdoc-resident register (a project/devdoc override) rides cleanup's own
    # devdoc commit: no branch rule, no commit here, and no git repo required.
    in_devdoc=0
    case "$reg_c" in "$doc_c"/*) [ -n "$doc_c" ] && in_devdoc=1 ;; esac
    repo="$("$DEVAGENT_GIT" -C "$(dirname "$reg")" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$repo" ] && [ "$in_devdoc" -eq 0 ]; then
        warn "promote-potholes: $reg is not inside a git repo — staying pending"; exit 3
    fi
    rel=""
    if [ -n "$repo" ]; then
        repo="$(_canon "$repo")"
        rel="${reg_c#"$repo"/}"
        # Rail 2: never append to a register another session is mid-edit on (the
        # #541/#553 shape) — committing the path would sweep their line into our
        # chore commit.
        if ! { "$DEVAGENT_GIT" -C "$repo" diff --quiet -- "$rel" && "$DEVAGENT_GIT" -C "$repo" diff --cached --quiet -- "$rel"; }; then
            warn "promote-potholes: $rel is dirty in $repo (another session's in-flight edit) — $issue_id stays pending; re-run --apply once it lands"
            exit 3
        fi
    fi
    # Rail 3: only commit on the project's base branch. On a merged issue branch
    # the commit would be stranded — the #586 defect itself. Checked BEFORE any
    # edit so there is nothing to roll back.
    baseline="$(config_get_project_field "$project" default_baseline)"; base_branch="${baseline##*/}"
    cur=""; [ -n "$repo" ] && cur="$("$DEVAGENT_GIT" -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
    if [ "$in_devdoc" -eq 0 ] && [ "$cur" != "$base_branch" ]; then
        warn "promote-potholes: $repo is on '$cur', not '$base_branch' — a promotion commit there would be stranded; $issue_id stays pending"
        exit 3
    fi
    # Apply into a TEMP copy (under TMPDIR, never beside the register in the
    # shared tree), validate, then overwrite. Never restore by checkout — the
    # shared tree may hold uncommitted work. CRLF working trees are normalised
    # for the edit and restored on write.
    crlf=0; grep -q $'\r' "$reg" && crlf=1
    tmp="$(mktemp "${TMPDIR:-/tmp}/potholes.XXXXXX")"
    trap 'rm -f "$tmp" "$tmp.2"' EXIT
    tr -d '\r' < "$reg" > "$tmp"
    section=""; applied=0
    while IFS= read -r l; do
        case "$l" in
            "## "*) section="$l" ;;
            "- "*)
                [ -n "$section" ] || die "--apply: staged line before any '## ' section in $stage"
                grep -qxF -- "$l" "$tmp" && continue          # dedupe by exact line
                # Append at the END of the section: buffer the blank run before
                # the next heading so the line lands after the last bullet and
                # the blank run survives (the #570 hazard).
                S="$section" L="$l" awk '
                  BEGIN{ins=0; nb=0}
                  /^## /{
                    if (ins==1) { print ENVIRON["L"]; ins=2 }
                    for(i=1;i<=nb;i++) print b[i]; nb=0
                    print; if ($0==ENVIRON["S"]) ins=1; next
                  }
                  {
                    if (ins==1 && $0 ~ /^[[:space:]]*$/) { b[++nb]=$0; next }
                    for(i=1;i<=nb;i++) print b[i]; nb=0; print
                  }
                  END{
                    if (ins==1) { print ENVIRON["L"]; ins=2 }
                    for(i=1;i<=nb;i++) print b[i]
                    if (ins!=2) exit 9
                  }' "$tmp" > "$tmp.2" || die "--apply: section '${section#\#\# }' not found in $reg"
                mv "$tmp.2" "$tmp"; applied=$((applied+1)) ;;
        esac
    done < <(tr -d '\r' < "$stage" | grep -E '^(## |- )')
    if [ "$applied" -eq 0 ]; then
        # Nothing to write and nothing to commit is SUCCESS, not a die: the
        # lines are already carried (hand-landed, or a re-run after a partial).
        sha="$( [ -n "$repo" ] && "$DEVAGENT_GIT" -C "$repo" rev-parse --short HEAD || echo devdoc )"
        sed -i "s/^status: pending$/status: applied ${sha}/" "$stage"
        info "promote-potholes: every staged line is already in $reg — $issue_id marked applied at $sha"
        exit 0
    fi
    # Postconditions BEFORE the file is replaced: format contract + citation.
    v="$(awk 'prev ~ /^- / && /^## / {c++} {prev=$0} END{print c+0}' "$tmp")"
    [ "$v" = "0" ] || die "--apply: append produced $v 'bullet immediately before a ## heading' violations — register NOT modified"
    _cited "$tmp" || die "--apply: post-apply register carries no ${issue_id} citation — register NOT modified"
    if [ "$crlf" -eq 1 ]; then sed 's/$/\r/' "$tmp" > "$reg"; else cat "$tmp" > "$reg"; fi   # preserve mode/inode
    rm -f "$tmp"; trap - EXIT
    # Commit scoped to the ONE path (U1: pathspec commit leaves the index alone).
    if [ "$in_devdoc" -eq 1 ]; then
        info "promote-potholes: register lives in the devdoc repo — cleanup's devdoc commit carries it"
    else
        "$DEVAGENT_GIT" -C "$repo" commit -s -q \
            -m "chore: promote pothole-register entries from #${issue_n}" -- "$rel" \
            || die "--apply: commit failed in $repo (register edit left in the tree — commit it by hand)"
    fi
    sha="$( [ -n "$repo" ] && "$DEVAGENT_GIT" -C "$repo" rev-parse --short HEAD || echo devdoc )"
    sed -i "s/^status: pending$/status: applied ${sha}/" "$stage"
    info "promote-potholes: $applied line(s) promoted for $issue_id — ${repo:-$reg} $sha (NOT pushed; a later 'git push' from that repo carries it)"
    ;;

*) usage ;;
esac
