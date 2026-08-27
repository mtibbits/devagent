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
#       the project's repos, devdoc commits not permitted). Callers treat 3 as
#       a warn, 1 as a die.
#
# The --check CLAIM predicate, in one sentence: a `lessonslearned:` log entry
# whose machine field says `register: N staged`, or whose text (the free-form
# `note:` tail excluded) says patterns were promoted to the register/potholes
# and is not worded as a deferral/skip — unless this issue's staging file is
# still pending (the staging file IS the promise; --apply honours it).
#
# Working trees are LF on every platform (.gitattributes: `* text=auto eol=lf`),
# so no line-ending handling here — the same invariant every sibling script
# that edits markdown relies on.
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
# project_devdoc_dir, not a raw field read: it honours DEVAGENT_TEST_DEVDOC, the
# same leg template_resolve walks — a raw read would put the register and the
# containment rail in different trees.
devdoc_dir="$(expand_tilde "$(project_devdoc_dir "$project")")"

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
# so every comparison goes through ONE canonical form. An empty or missing dir
# yields "" (never the caller's cwd — `cd ""` succeeds in place, Issue-571).
_canon() { [ -n "${1:-}" ] && ( cd "$1" 2>/dev/null && pwd -P ); }

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
    grep -qxF "## $section" "$reg" \
        || die "--add: no section '## $section' in $reg — use a heading that already exists (grep '^## ' \"$reg\")"
    case "$line" in "- "*) ;; *) die "--add: the line must start with '- '" ;; esac
    printf '%s' "$line" | grep -qiE "\((${project} )?${issue_id}\)\.$" \
        || die "--add: the line must end with its own citation '(${issue_id}).'"
    # Weak, project-DERIVED neutrality rail on the BODY (citation stripped —
    # the citation token may legitimately carry the project name). The
    # shipped-token canary (tests/generic-templates.bats) remains the sole owner
    # of the project-specific token list; this only catches the commonest leak.
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
    # Plain append, in staging order; --apply tracks the current heading as it
    # streams the file, so a repeated heading is harmless.
    { echo; echo "## $section"; echo "$line"; } >> "$stage"
    info "staged for $issue_id: $line"
    ;;

--check)
    claim=""
    if [ -f "$issue_dir/checklist.md" ]; then
        # The free-form `note:` tail is stripped BEFORE matching, so an operator
        # note can neither make nor unmake a claim.
        claim="$(awk '/^## Log/{p=1;next} /^## /{p=0} p' "$issue_dir/checklist.md" \
                 | grep -E '^- .*[[:space:]]lessonslearned:' | sed 's/; *note:.*$//' \
                 | grep -iE 'register: [0-9]+ staged|promot.*(register|pothole)' \
                 | grep -ivE 'defer|refus|skip|not promoted|no promotion|not committed|none staged|candidate' || true)"
    fi
    st=""; [ -f "$stage" ] && st="$(sed -n 's/^status: *//p' "$stage" | head -1)"
    case "$st" in
        pending*) info "promote-potholes: $issue_id has a PENDING register promotion ($stage) — cleanup will drain it"
                  claim="" ;;    # the staging file IS the promise; honoured at --apply
        applied*) claim="${claim}${claim:+$'\n'}staging file: $stage says applied" ;;
    esac
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
    source_dir="$(expand_tilde "$(config_get_project_field "$project" source_dir)")"
    src_c="$(_canon "$source_dir" || true)"; doc_c="$(_canon "$devdoc_dir" || true)"
    [ -n "$src_c" ] && [ -n "$doc_c" ] \
        || die "--apply: source_dir ('$source_dir') or devdoc_dir ('$devdoc_dir') does not exist — cannot bound the register"
    reg_c="$(_canon "$(dirname "$reg")")/$(basename "$reg")"
    # Commit OWNER, decided once from the facts that decide it:
    #   self   — the register is in the source repo: this script commits it
    #   caller — the register is in devdoc: cleanup's own devdoc commit carries it
    #   (none) — anywhere else: DEFERRED, never written (a foreign project's
    #            plugin-default register, or a test that forgot its override)
    case "$reg_c" in
        "$src_c"/*) owner=self ;;
        "$doc_c"/*) owner=caller ;;
        *) warn "promote-potholes: register $reg is outside $source_dir and $devdoc_dir — not writing it; $issue_id stays pending"; exit 3 ;;
    esac
    if [ "$owner" = caller ] && [ "$(config_get_project_field "$project" permissions.commit_devdoc 2>/dev/null || echo false)" != true ]; then
        warn "promote-potholes: register is in devdoc but permissions.commit_devdoc is not true — nobody would commit the edit; $issue_id stays pending"
        exit 3
    fi
    repo=""; rel=""
    if [ "$owner" = self ]; then
        repo="$(_canon "$("$DEVAGENT_GIT" -C "$(dirname "$reg")" rev-parse --show-toplevel 2>/dev/null || true)" || true)"
        [ -n "$repo" ] || { warn "promote-potholes: $reg is not inside a git repo — staying pending"; exit 3; }
        rel="${reg_c#"$repo"/}"
        # Rail 2: never append to a register another session is mid-edit on (the
        # #541/#553 shape) — committing the path would sweep their line into our
        # chore commit.
        if [ -n "$("$DEVAGENT_GIT" -C "$repo" status --porcelain -- "$rel")" ]; then
            warn "promote-potholes: $rel is dirty in $repo (another session's in-flight edit) — $issue_id stays pending; re-run --apply once it lands"
            exit 3
        fi
        # Rail 3: only commit on the project's base branch (the same
        # `${baseline##*/}` cleanup.sh checks out). On a merged issue branch the
        # commit would be stranded — the #586 defect itself.
        baseline="$(config_get_project_field "$project" default_baseline)"; base_branch="${baseline##*/}"
        cur="$("$DEVAGENT_GIT" -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
        if [ "$cur" != "$base_branch" ]; then
            warn "promote-potholes: $repo is on '$cur', not '$base_branch' — a promotion commit there would be stranded; $issue_id stays pending"
            exit 3
        fi
    fi
    # Apply into a TEMP copy (under TMPDIR, never beside the register in the
    # shared tree), validate, then overwrite. Never restore by checkout — the
    # shared tree may hold uncommitted work.
    tmp="$(mktemp "${TMPDIR:-/tmp}/potholes.XXXXXX")"
    trap 'rm -f "$tmp" "$tmp.2"' EXIT
    cp "$reg" "$tmp"
    section=""; applied=0
    while IFS= read -r l; do
        case "$l" in
            "## "*) section="$l" ;;
            "- "*)
                [ -n "$section" ] || die "--apply: staged line before any '## ' section in $stage"
                grep -qxF -- "$l" "$tmp" && continue          # dedupe by exact line
                # Append at the END of the section: buffer the blank run before
                # the next heading so the line lands after the last bullet and
                # the blank run survives (the #570 hazard). ENVIRON, not -v: -v
                # processes C escapes and would corrupt a `\(`.
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
    done < <(grep -E '^(## |- )' "$stage")
    if [ "$applied" -gt 0 ]; then
        # Postconditions BEFORE the file is replaced: format contract + citation.
        v="$(awk 'prev ~ /^- / && /^## / {c++} {prev=$0} END{print c+0}' "$tmp")"
        [ "$v" = "0" ] || die "--apply: append produced $v 'bullet immediately before a ## heading' violations — register NOT modified"
        _cited "$tmp" || die "--apply: post-apply register carries no ${issue_id} citation — register NOT modified"
        cat "$tmp" > "$reg"      # preserve the target's mode/inode
        # Commit scoped to the ONE path (U1: a pathspec commit leaves the index alone).
        [ "$owner" = self ] && { "$DEVAGENT_GIT" -C "$repo" commit -s -q \
            -m "chore: promote pothole-register entries from #${issue_n}" -- "$rel" \
            || die "--apply: commit failed in $repo (register edit left in the tree — commit it by hand)"; }
    fi
    rm -f "$tmp"; trap - EXIT
    # Nothing to write (lines already carried) is success, not a die.
    sha=devdoc; [ "$owner" = self ] && sha="$("$DEVAGENT_GIT" -C "$repo" rev-parse --short HEAD)"
    sed -i "s/^status: pending$/status: applied ${sha}/" "$stage"
    info "promote-potholes: $applied line(s) promoted for $issue_id into $reg — applied at $sha (NOT pushed; a later 'git push' from that repo carries it)"
    ;;

*) usage ;;
esac
