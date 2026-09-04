#!/usr/bin/env bash
# scripts/promote-potholes.sh — #586/#611. Durable [pattern] → pothole-register
# promotion across the register's LAYERS. Step 22 STAGES lines into
# <issue-dir>/potholes-promotion.md (a devdoc file, immune to the shared source
# tree's stash/revert/gate churn), each line routed to a layer by the skill's
# judgment; step 23 (cleanup, right after its tree restore) DRAINS that file into
# each devdoc-resident layer file and commits EACH ONE ITSELF with a pathspec-
# scoped commit in the repo that holds the file. The plugin seed is never written.
#
# Layers (scripts/lib/potholes.sh): seed (plugin, read-only) · workflow (shared,
# [paths].potholes_workflow, cites "(<project> Issue-N)") · project (this
# project's devdoc, cites "(Issue-N)"). Reads — --check and the post-apply
# citation postcondition — are over the UNION of every present layer.
#
# Modes:
#   <project> <issue-dir> --add --layer project|workflow "<section>" "<line>"
#   <project> <issue-dir> --apply                              drain + commit
#   <project> <issue-dir> --check                              claim vs union
#   <project> --list-pending                                   undrained backlog
#
# Exit: 0 ok | 1 refused/failed (loud) | 2 usage | 3 apply DEFERRED, staging
#       file retained pending (commit_devdoc not true, target dirty/untracked,
#       repo mid-merge, layer path outside the repo holding devdoc_dir, lock
#       held). Callers treat 3 as a warn, 1 as a die.
#
# The --check CLAIM predicate, in one sentence: a `lessonslearned:` log entry
# whose machine field says `register: N staged`, or whose text (the free-form
# `note:` tail excluded) says patterns were promoted to the register/potholes
# and is not worded as a deferral/skip — unless this issue's staging file is
# still pending (the staging file IS the promise; --apply honours it).
#
# Working trees are LF on every platform (plugin .gitattributes `* text=auto
# eol=lf`; devDoc .gitattributes scoped to the register files, #611), so no
# line-ending handling here.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/template_resolve.sh"   # pulls paths/io/config + potholes.sh
. "$DEVAGENT_ROOT/scripts/lib/permission.sh"

: "${DEVAGENT_GIT:=git}"

usage() {
    echo "usage: promote-potholes.sh <project> <issue-dir> --add --layer project|workflow <section> <line> | --apply | --check
       promote-potholes.sh <project> --list-pending" >&2
    exit 2
}

project="${1:-}"; [ -n "$project" ] || usage
config_is_project "$project" || die "unknown project '$project'"
shift
# project_devdoc_dir, not a raw field read: it honours DEVAGENT_TEST_DEVDOC, the
# same leg template_resolve walks.
devdoc_dir="$(project_devdoc_dir "$project")"   # already tilde-expanded (config.sh whitelist)

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
issue_id="$(basename "$issue_dir")"          # e.g. Issue-586; Issue-Fork-132 stays whole
issue_n="${issue_id#Issue-}"                 # Fork-132 stays Fork-132, never #132
stage="$issue_dir/potholes-promotion.md"

# Layer paths, resolved ONCE. seed always exists (plugin file); wf may be empty
# (unconfigured) and either layer file may not exist yet (bootstrapped by --apply).
seed="$(potholes_seed_path)"
[ -f "$seed" ] || die "promote-potholes: plugin seed missing at $seed"
_potholes_memo "$project"          # in THIS shell: one lookup for the whole run, and a failure dies here
wf="$_POTHOLES_MEMO_WF"
pr="$_POTHOLES_MEMO_PR"
[ -n "$pr" ] || die "promote-potholes: project register path unresolvable (devdoc_dir unset?) for '$project'"

# Path forms diverge on this platform (MSYS `/c/…`, config `c:/…`, git `C:/…`),
# so every comparison goes through ONE canonical form. An empty or missing dir
# yields "" (never the caller's cwd — `cd ""` succeeds in place, Issue-571).
_canon() { [ -n "${1:-}" ] && ( cd "$1" 2>/dev/null && pwd -P ); }

# _repo_of <path> — canonical git toplevel of the nearest EXISTING ancestor of
# <path> (the path itself may not exist yet). rc 1 / "" when not in a repo.
_repo_of() {
    local d="$1"
    while [ -n "$d" ] && [ ! -d "$d" ] && [ "$d" != / ]; do d="$(dirname "$d")"; done
    [ -d "$d" ] || return 1
    _canon "$("$DEVAGENT_GIT" -C "$d" rev-parse --show-toplevel 2>/dev/null || true)"
}

# _commit_devdoc_raw — the operator's flag, read RAW (no gate; DA_YES cannot
# stand in for it).
_commit_devdoc_raw() { config_get_project_field "$project" permissions.commit_devdoc 2>/dev/null || echo false; }

# Citation-STRIPPED body of a line (the token may legitimately carry the project).
_body() { printf '%s' "$1" | sed -E "s/${POTHOLES_CITE_TAIL_RE}//"; }

# _skeleton <layer> — a NEW layer file: header comment + title. The staged
# sections are appended by the drain (a union-valid heading absent from the
# file is added the same way), so a bootstrapped file carries only what landed.
_skeleton() {
    local who
    case "$1" in
        workflow) who="WORKFLOW layer — shared by every project; cites (<project> Issue-N)" ;;
        project)  who="PROJECT layer for $project — private; cites (Issue-N)" ;;
    esac
    printf '%s\n' \
        "<!-- POTHOLE REGISTER, $who (#611). Bootstrapped by" \
        "     scripts/promote-potholes.sh --apply and read as a UNION with the plugin seed by" \
        "     \`template.sh show potholes\`. One line per entry, keyed by a DOMAIN TRIGGER," \
        "     ending in its citation; section headings mirror the seed's. -->" \
        "" \
        "# Pothole register ($1)"
}

case "${1:-}" in
--add)
    shift
    layer=""
    if [ "${1:-}" = "--layer" ]; then layer="${2:-}"; shift 2 || usage; fi
    section="${1:-}"; line="${2:-}"
    [ -n "$section" ] && [ -n "$line" ] || usage
    # Routing is the SKILL's judgment (core-lessons-learned item 7); the script
    # enforces only what is decidable: the layer is named, and its citation form.
    case "$layer" in
        project|workflow) ;;
        "") die "--add: --layer project|workflow is REQUIRED (no default) — domain content → project; would fire on another project's issue → workflow" ;;
        *)  die "--add: unknown layer '$layer' (project|workflow)" ;;
    esac
    case "$line" in *$'\n'*) die "--add: the line must be a SINGLE line" ;; esac
    case "$line" in "- "*) ;; *) die "--add: the line must start with '- '" ;; esac
    body="$(_body "$line")"
    case "$layer" in
    project)
        printf '%s' "$line" | grep -qE "\(${issue_id}\)\.$" \
            || die "--add: a project-layer line must end with its own citation '(${issue_id}).'"
        ;;
    workflow)
        [ -n "$wf" ] || die "--add: --layer workflow, but no workflow register is configured ([paths] potholes_workflow, or [project.$project.paths] potholes_workflow) — configure it, or route this line to --layer project"
        printf '%s' "$line" | grep -qiE "\(${project} ${issue_id}\)\.$" \
            || die "--add: a workflow-layer line must end with '(${project} ${issue_id}).' — the shared register cites the project"
        line="${body} (${project} ${issue_id})."      # normalise to the config spelling
        ! printf '%s' "$body" | grep -qiF -- "$project" \
            || die "--add: the line names the project ('$project') in its body — the workflow register is shared; strip the noun or use --layer project"
        # Optional operator noun list: fixed-string, word-bounded, case-insensitive.
        # rc 3 (wrong type) dies; rc 1 (absent) is the common case.
        nouns_rc=0; nouns="$(config_get_project_list "$project" paths.potholes_domain_nouns 2>/dev/null)" || nouns_rc=$?
        [ "$nouns_rc" -ne 3 ] || die "--add: [project.$project.paths] potholes_domain_nouns must be an array of strings"
        if [ "$nouns_rc" -eq 0 ] && [ -n "$nouns" ]; then
            hit="$(printf '%s\n' "$body" | grep -iowF -f <(printf '%s\n' "$nouns") | head -1 || true)"
            [ -z "$hit" ] || die "--add: the body matches paths.potholes_domain_nouns ('$hit') — domain content belongs in --layer project"
        fi
        ;;
    esac
    potholes_union_headings "$project" | grep -qxF -- "## $section" \
        || die "--add: no section '## $section' in any register layer — use a heading that already exists (template.sh --project $project show potholes | grep '^## ')"
    if [ ! -f "$stage" ]; then
        {
            echo "# Pothole promotion — $issue_id"
            echo
            echo "<!-- #586/#611: written by step 22 (core-lessons-learned item 7) via"
            echo "     scripts/promote-potholes.sh --add --layer project|workflow. Drained by"
            echo "     --apply, which cleanup.sh (step 23) runs after its tree restore: each"
            echo "     block's lines are appended VERBATIM at the END of the named section of"
            echo "     that layer's file (bootstrapped if absent) and committed there, one"
            echo "     path-scoped commit per layer file. The status line is machine-written;"
            echo "     the ONE sanctioned hand-edit is closing a DEFERRED entry after landing"
            echo "     its lines by hand: status: applied by-hand <sha>. -->"
            echo
            echo "status: pending"
        } > "$stage"
    fi
    grep -qxF -- "$line" "$stage" && { info "--add: already staged (idempotent): $line"; exit 0; }
    # Say NOW what --apply will do later — cheap, so the operator hears it at
    # step 22 where the line can still be re-routed, not at cleanup.
    [ "$(_commit_devdoc_raw)" = true ] \
        || warn "--add: permissions.commit_devdoc is not true for $project — cleanup will DEFER the drain (rc 3) until the flag is flipped; the staged line is kept"
    if [ "$layer" = workflow ]; then
        _wr="$(_repo_of "$wf" || true)"; _dr="$(_repo_of "$devdoc_dir" || true)"
        [ -n "$_wr" ] && [ "$_wr" = "$_dr" ] \
            || warn "--add: the workflow register $wf is not inside the git repo holding devdoc_dir ($devdoc_dir) — the containment rail will DEFER (rc 3) at cleanup"
    fi
    { echo; echo "## $section"; echo "layer: $layer"; echo "$line"; } >> "$stage"
    info "staged for $issue_id ($layer layer): $line"
    ;;

--check)
    claim=""
    if [ -f "$issue_dir/checklist.md" ]; then
        # The free-form `note:` tail is stripped BEFORE matching, so an operator
        # note can neither make nor unmake a claim.
        ll="$(awk '/^## Log/{p=1;next} /^## /{p=0} p' "$issue_dir/checklist.md" \
              | grep -E '^- .*[[:space:]]lessonslearned:' | sed 's/; *note:.*$//' || true)"
        # The machine field is unconditional; only free text is subject to the
        # deferral deny-list (else "3 promoted, 1 candidate skipped" un-claims itself).
        claim="$(printf '%s\n' "$ll" | grep -iE 'register: [1-9][0-9]* staged' || true)"   # "0 staged" is not a claim
        free="$(printf '%s\n' "$ll" | grep -ivE 'register: [0-9]+ staged' \
                 | grep -iE 'promot.*(register|pothole)' \
                 | grep -ivE 'defer|refus|skip|not promoted|no promotion|not committed|none staged|candidate' || true)"
        claim="${claim}${claim:+${free:+$'\n'}}${free}"
    fi
    st=""; [ -f "$stage" ] && st="$(sed -n 's/^status: *//p' "$stage" | head -1)"
    case "$st" in
        pending*) info "promote-potholes: $issue_id has a PENDING register promotion ($stage) — cleanup will drain it"
                  claim="" ;;    # the staging file IS the promise; honoured at --apply
        applied*) claim="${claim}${claim:+$'\n'}staging file: $stage says applied" ;;
    esac
    if [ -n "$claim" ] && ! potholes_cited_union "$project" "$issue_id"; then
        printf 'promote-potholes: %s CLAIMS a register promotion no register layer carries.\n' "$issue_id" >&2
        printf '  layers searched (no "%s)" citation):\n' "$issue_id" >&2
        potholes_layer_files "$project" | sed 's/^/    /' >&2
        printf '  claim(s):\n%s\n' "$claim" | sed 's/^/    /' >&2
        printf '  fix: stage the lines (promote-potholes.sh %s %s --add --layer project|workflow ...) and let cleanup drain them,\n' "$project" "$issue_dir" >&2
        printf '       or correct the log line to say the promotion is deferred/skipped and why.\n' >&2
        exit 1
    fi
    ;;

--apply)
    [ -f "$stage" ] || exit 0
    grep -q '^status: pending' "$stage" || exit 0
    # Rail 0 — the operator's RAW flag, before any gate: DA_YES=1 must not stand
    # in for it. false → DEFER, a one-flag fix, said so.
    if [ "$(_commit_devdoc_raw)" != true ]; then
        warn "promote-potholes: permissions.commit_devdoc is not true for $project — the devdoc-resident register(s) would go uncommitted; $issue_id stays pending (one-flag fix: [project.$project.permissions] commit_devdoc = true, then re-run --apply)"
        exit 3
    fi
    doc_repo="$(_repo_of "$devdoc_dir" || true)"
    [ -n "$doc_repo" ] || { warn "promote-potholes: devdoc_dir $devdoc_dir is not inside a git repo — $issue_id stays pending"; exit 3; }

    # Parse the staging file into per-layer (section, line) lists. A block with
    # no `layer:` line is an ERROR — #586 landed 2026-08-27 and none exist.
    section=""; layer=""
    W_SEC=(); W_LINE=(); P_SEC=(); P_LINE=()
    while IFS= read -r l; do
        case "$l" in
            "## "*)     section="$l"; layer="" ;;
            "layer: "*) layer="${l#layer: }" ;;
            "- "*)
                [ -n "$section" ] || die "--apply: staged line before any '## ' section in $stage"
                [ -n "$layer" ] || die "--apply: staged block '$section' has no 'layer:' line in $stage — re-stage it with --add --layer project|workflow"
                case "$layer" in
                    workflow) W_SEC+=("$section"); W_LINE+=("$l") ;;
                    project)  P_SEC+=("$section"); P_LINE+=("$l") ;;
                    *) die "--apply: unknown layer '$layer' in $stage" ;;
                esac ;;
        esac
    done < <(grep -E '^(## |layer: |- )' "$stage")

    # Every rail for EVERY staged layer BEFORE any write, so a DEFER on the
    # second layer never strands a half-drained run. Locks are taken here and
    # released by the EXIT trap — a die can never leak one.
    LOCKS=()
    tmp="$(mktemp "${TMPDIR:-/tmp}/potholes.XXXXXX")"
    _release() { local L; for L in "${LOCKS[@]}"; do rmdir "$L" 2>/dev/null || true; done; rm -f "$tmp" "$tmp.2" "$tmp.orig"; }
    trap _release EXIT
    L_NAME=(); L_TARGET=(); L_REPO=(); L_REL=()
    for ly in workflow project; do
        if [ "$ly" = workflow ]; then n=${#W_LINE[@]}; target="$wf"; else n=${#P_LINE[@]}; target="$pr"; fi
        [ "$n" -gt 0 ] || continue
        [ -n "$target" ] || { warn "promote-potholes: $ly-layer lines are staged but no $ly register path is configured — $issue_id stays pending"; exit 3; }
        repo="$(_repo_of "$target" || true)"
        # Containment: the repo holding the layer path MUST be the repo holding
        # devdoc_dir — a mistyped absolute path can never make us commit elsewhere.
        if [ -z "$repo" ] || [ "$repo" != "$doc_repo" ]; then
            warn "promote-potholes: $ly register $target is not inside the git repo holding devdoc_dir ($doc_repo) — containment bound; $issue_id stays pending"
            exit 3
        fi
        if "$DEVAGENT_GIT" -C "$repo" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
            warn "promote-potholes: $repo is mid-merge (MERGE_HEAD present) — $issue_id stays pending; finish the merge and re-run --apply"
            exit 3
        fi
        if [ -L "$target" ]; then                             # a link would write THROUGH the containment bound
            warn "promote-potholes: $ly register $target is a symlink — refusing to write through it; $issue_id stays pending"
            exit 3
        fi
        mkdir -p "$(dirname "$target")"                     # empty dir: invisible to git
        rel="$(_canon "$(dirname "$target")")/$(basename "$target")"; rel="${rel#"$repo"/}"
        st="$("$DEVAGENT_GIT" -C "$repo" status --porcelain -- "$rel")"
        if [ -n "$st" ]; then
            case "$st" in
                '??'*) warn "promote-potholes: $rel is untracked in $repo (a stray skeleton?) — commit or remove it; $issue_id stays pending" ;;
                *)     warn "promote-potholes: $rel is dirty in $repo (another session's in-flight edit) — $issue_id stays pending; re-run --apply once it lands" ;;
            esac
            exit 3
        fi
        lock="$target.lock"
        if ! mkdir "$lock" 2>/dev/null; then
            warn "promote-potholes: lock $lock is held — a concurrent closeout is writing this register, or a killed run left it; if no other --apply is running, rmdir it and re-run. $issue_id stays pending"
            exit 3
        fi
        LOCKS+=("$lock")
        L_NAME+=("$ly"); L_TARGET+=("$target"); L_REPO+=("$repo"); L_REL+=("$rel")
    done
    cur="$("$DEVAGENT_GIT" -C "$doc_repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    # The gate, only after the raw flag said true (it returns 0 silently then;
    # kept so the commit stays inside the §8 permission contract).
    if [ "${#L_NAME[@]}" -gt 0 ]; then
        permission_gate "$project" commit_devdoc "promote-potholes plan: commit ${L_REL[*]} in $doc_repo (branch $cur) for $issue_id"
    fi

    shas=""
    for i in "${!L_NAME[@]}"; do
        ly="${L_NAME[i]}"; target="${L_TARGET[i]}"; repo="${L_REPO[i]}"; rel="${L_REL[i]}"
        if [ "$ly" = workflow ]; then SECS=("${W_SEC[@]}"); LINES=("${W_LINE[@]}"); else SECS=("${P_SEC[@]}"); LINES=("${P_LINE[@]}"); fi
        bootstrapped=0
        if [ -f "$target" ]; then
            cp "$target" "$tmp"; cp "$target" "$tmp.orig"
        else
            bootstrapped=1
            _skeleton "$ly" > "$tmp"
        fi
        applied=0
        for j in "${!LINES[@]}"; do
            l="${LINES[j]}"; section="${SECS[j]}"
            grep -qxF -- "$l" "$tmp" && continue              # dedupe by exact line
            # A heading valid in the UNION but absent from THIS layer file is added
            # at the end (blank line first: never a bullet directly before a heading).
            grep -qxF -- "$section" "$tmp" || printf '\n%s\n' "$section" >> "$tmp"
            # Append at the END of the section: buffer the blank run before the
            # next heading so the line lands after the last bullet and the blank
            # run survives (the #570 hazard). ENVIRON, not -v: -v processes C
            # escapes and would corrupt a `\(`.
            S="$section" L="$l" awk '
              BEGIN{ins=0; nb=0}
              /^## /{
                if (ins==1) { print ENVIRON["L"]; ins=2 }
                for(k=1;k<=nb;k++) print b[k]; nb=0
                print; if (ins==0 && $0==ENVIRON["S"]) ins=1; next
              }
              {
                if (ins==1 && $0 ~ /^[[:space:]]*$/) { b[++nb]=$0; next }
                for(k=1;k<=nb;k++) print b[k]; nb=0; print
              }
              END{
                if (ins==1) { print ENVIRON["L"]; ins=2 }
                for(k=1;k<=nb;k++) print b[k]
                if (ins!=2) exit 9
              }' "$tmp" > "$tmp.2" || die "--apply: section '${section#\#\# }' not found in $target"
            mv "$tmp.2" "$tmp"; applied=$((applied+1))
        done
        [ "$applied" -gt 0 ] || continue                       # this layer already carries every line
        # Postconditions BEFORE the file is replaced: format contract + citation.
        # Citation check scoped to THIS file (the pre-#611 shape): the union would
        # be satisfied by another layer's earlier promotion and prove nothing.
        v="$(awk 'prev ~ /^- / && /^## / {c++} {prev=$0} END{print c+0}' "$tmp")"
        [ "$v" = "0" ] || die "--apply: append produced $v 'bullet immediately before a ## heading' violations — $ly register NOT modified"
        grep -qiE -- "$(potholes_cite_re "$project" "$issue_id" "$ly")" "$tmp" \
            || die "--apply: post-apply $ly register carries no ${issue_id} citation — NOT modified"
        cat "$tmp" > "$target"                                 # preserve mode/inode of an existing file
        if [ "$bootstrapped" -eq 1 ]; then
            "$DEVAGENT_GIT" -C "$repo" add -- "$rel"           # an untracked path needs it before a pathspec commit
        fi
        # Commit scoped to the ONE path, with the operator's identity (-s), like a
        # source-tree chore; cleanup's own devdoc commit (devagent@local) never
        # carries these files. On failure put things back: a bootstrapped file is
        # REMOVED (rm --cached + rm -f + the empty dir) so cleanup's `git add -A`
        # cannot sweep the skeleton; an existing one gets its original bytes.
        if ! "$DEVAGENT_GIT" -C "$repo" commit -s -q \
            -m "chore: promote pothole-register entries from #${issue_n}" \
            -m "layer: $ly; register: $rel; branch: $cur" -- "$rel"; then
            if [ "$bootstrapped" -eq 1 ]; then
                "$DEVAGENT_GIT" -C "$repo" rm --cached -q -- "$rel" 2>/dev/null || true
                rm -f "$target"
                rmdir "$target.lock" 2>/dev/null || true       # release first, so an empty templates/ can go too
                rmdir "$(dirname "$target")" 2>/dev/null || true
            else
                cat "$tmp.orig" > "$target"
            fi
            die "--apply: commit failed in $repo — $ly register restored, $issue_id stays pending (git identity/hooks; fix, then re-run --apply)${shas:+; earlier layer commit(s) $shas already landed}"
        fi
        sha="$("$DEVAGENT_GIT" -C "$repo" rev-parse --short HEAD)"
        shas="${shas:+$shas,}$sha"
        info "promote-potholes: $applied line(s) promoted for $issue_id into $target ($ly layer) — committed $sha on $cur (NOT pushed)"
    done
    # Nothing new to write anywhere is success: the registers already carry every
    # line at the devdoc HEAD, which is what the stamp then records.
    [ -n "$shas" ] || shas="$("$DEVAGENT_GIT" -C "$doc_repo" rev-parse --short HEAD)"
    sed -i "s/^status: pending$/status: applied ${shas}/" "$stage"
    ;;

*) usage ;;
esac
