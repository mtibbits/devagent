#!/usr/bin/env bash
# scripts/promote-potholes.sh — #586/#611/#612. Durable [pattern] → pothole-register
# promotion across the register's LAYERS. Step 22 STAGES ops (add, retire, amend) into
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
#   <project> <issue-dir> --add    --layer project|workflow "<section>" "<line>"
#   <project> <issue-dir> --retire --layer project|workflow "<old-line>" "<mechanism>"
#   <project> <issue-dir> --amend  --layer project|workflow "<old-line>" "<new-line>"
#   <project> <issue-dir> --drop <op>                          remove a stale op block
#   <project> <issue-dir> --apply                              drain + commit
#   <project> <issue-dir> --check                              claim vs union
#   <project> --list-pending                                   undrained backlog
#
# Grammar (#612, scripts/lib/potholes.sh): every line ends `(<tok>[; <tok>]*).`,
# each token in its layer's form; retire rewrites a line as `- [<section>] <text>
# — mechanised by <mechanism> (<tokens>).` under `## Retired (mechanised)` (kept
# for --check, hidden from the READ union).
# --apply validates EVERY op sequentially against temp copies of EVERY target
# (locks held throughout), then writes + commits per file; re-runs converge.
#
# Exit: 0 ok | 1 refused/failed (loud; also staging-file PARSE errors) | 2 usage
#       | 3 apply DEFERRED, staging file retained pending (commit_devdoc not
#       true, target dirty/untracked, repo mid-merge, layer path outside the repo
#       holding devdoc_dir, lock held, or any failed op VALIDATION — stale,
#       multi-hit, old+new both present, a rail — with the op and line quoted).
#       Callers treat 3 as a warn, 1 as a die.
#
# The --check CLAIM predicate, in one sentence: a `lessonslearned:` log entry
# whose machine field says `register: N staged`, or whose text (the free-form
# `note:` tail excluded) says patterns were promoted to the register/potholes
# and is not worded as a deferral/skip — unless this issue's staging file is
# still pending (the staging file IS the promise; --apply honours it).
#
# Working trees are LF on every platform (plugin .gitattributes `* text=auto
# eol=lf`; devDoc .gitattributes scoped to the register files, #611);
# potholes_file_check (#613) REFUSES a CR byte rather than handling it.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/template_resolve.sh"   # pulls paths/io/config + potholes.sh
. "$DEVAGENT_ROOT/scripts/lib/permission.sh"

: "${DEVAGENT_GIT:=git}"

usage() {
    echo "usage: promote-potholes.sh <project> <issue-dir> --add    --layer project|workflow <section> <line>
       promote-potholes.sh <project> <issue-dir> --retire --layer project|workflow <old-line> <mechanism>
       promote-potholes.sh <project> <issue-dir> --amend  --layer project|workflow <old-line> <new-line>
       promote-potholes.sh <project> <issue-dir> --drop <op-number>   |  --apply  |  --check
       promote-potholes.sh <project> --list-pending" >&2
    exit 2
}

project="${1:-}"; [ -n "$project" ] || usage
config_is_project "$project" || die "unknown project '$project'"
shift
# project_devdoc_dir, not a raw field read: it honours DEVAGENT_TEST_DEVDOC, the
# same leg template_resolve walks.
devdoc_dir="$(project_devdoc_dir "$project")"   # already tilde-expanded (config.sh whitelist)

# _op_count <staging-file> — its op blocks (one op per '## ' block; _parse_stage
# enforces it). grep -c: rc 0 hits, rc 1 none (prints 0), rc >= 2 could not read —
# which must never read as "0 ops" (Issue-316); rc 2 to the caller.
_op_count() {
    local c grc=0
    c="$(grep -c '^## ' "$1")" || grc=$?
    [ "$grc" -le 1 ] || { warn "promote-potholes: cannot read $1 (grep rc $grc)"; return 2; }
    printf '%s\n' "${c:-0}"
}

# --list-pending needs no issue.
if [ "${1:-}" = "--list-pending" ]; then
    found=0
    for f in "$devdoc_dir"/*/potholes-promotion.md; do
        [ -e "$f" ] || continue
        grep -q '^status: pending' "$f" || continue
        found=1
        n="$(_op_count "$f")" || die "--list-pending: unreadable staging file $f"
        printf 'pending: %s (%s ops)\n' "$f" "$n"
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

# Citation-STRIPPED body of a line — the WHOLE multi-token suffix (a token may
# legitimately carry the project; the body may not).
_body() { printf '%s' "$1" | sed -E "s/${POTHOLES_CITE_TAIL_RE}//"; }

MODE=""
TARGET=""
# _layer_target <layer> — SETTER: fills $TARGET with the ONE devdoc-resident file
# that layer names. A setter, never `$(…)`-captured: it die-exits, and a
# die-exiting resolver inside a command substitution is the Issue-120 shape
# (the apply engine below is this file's first `set -e`-off context).
_layer_target() {
    case "$1" in
        project)  TARGET="$pr" ;;
        workflow) [ -n "$wf" ] || die "$MODE: --layer workflow, but no workflow register is configured ([paths] potholes_workflow, or [project.$project.paths] potholes_workflow) — configure it, or route this line to --layer project"
                  TARGET="$wf" ;;
        "")       die "$MODE: --layer project|workflow is REQUIRED (no default) — domain content → project; would fire on another project's issue → workflow" ;;
        *)        die "$MODE: unknown layer '$1' (project|workflow)" ;;
    esac
}
# _normalise_own_token <layer> <line> — the own token in the config spelling:
# split → map the case-insensitive match → join (no separator regex here).
_normalise_own_token() {
    local want toks t out=""
    want="$(potholes_own_token "$project" "$issue_id" "$1")"
    toks="$(potholes_cite_tokens "$2")" || { printf '%s\n' "$2"; return; }   # a bad tail is _rails' finding, not ours
    while IFS= read -r t; do
        [ "${t,,}" = "${want,,}" ] && t="$want"
        out="${out}${t}"$'\n'
    done <<< "$toks"
    printf '%s (%s).\n' "$(_body "$2")" "$(printf '%s' "$out" | potholes_cite_join)"
}
# _bullet_shape <line> — single line, '- ' prefix. Owned here, called by every
# rail and every old-line check (one predicate, Issue-585). Reason on stderr, rc 1.
_bullet_shape() {
    case "$1" in *$'\n'*) warn "$MODE: the line must be a SINGLE line"; return 1 ;; esac
    case "$1" in "- "*) ;; *) warn "$MODE: the line must be a bullet starting with '- ' — a heading is not a legal target: $1"; return 1 ;; esac
}
# Optional operator noun list, read ONCE per process (a python3 spawn per read).
_NOUNS_LOADED=0; _NOUNS=""; _NOUNS_RC=0
_nouns() {
    [ "$_NOUNS_LOADED" -eq 1 ] && return 0
    _NOUNS="$(config_get_project_list "$project" paths.potholes_domain_nouns 2>/dev/null)" || _NOUNS_RC=$?
    _NOUNS_LOADED=1
}
# _rails <layer> <line> — every per-line rail, shared by --add, the retire result
# and the amend replacement, at staging AND at --apply. Reason on stderr, rc 1 —
# the caller decides die (staging) vs DEFER (--apply).
_rails() {
    local layer="$1" line="$2" body hit
    _bullet_shape "$line" || return 1
    potholes_line_cite_ok "$project" "$issue_id" "$layer" "$line" || { warn "$MODE: citation rail failed for the $layer layer"; return 1; }
    [ "$layer" = workflow ] || return 0                   # the rest are the SHARED file's leak rails
    body="$(_body "$line")"
    if printf '%s' "$body" | grep -qiF -- "$project"; then
        warn "$MODE: the line names the project ('$project') in its body — the workflow register is shared; strip the noun or use --layer project"; return 1
    fi
    _nouns   # rc 3 (wrong type) refuses; rc 1 (absent) is the common case
    [ "$_NOUNS_RC" -ne 3 ] || { warn "$MODE: [project.$project.paths] potholes_domain_nouns must be an array of strings"; return 1; }
    if [ "$_NOUNS_RC" -eq 0 ] && [ -n "$_NOUNS" ]; then
        hit="$(printf '%s\n' "$body" | grep -iowF -f <(printf '%s\n' "$_NOUNS") | head -1 || true)"
        [ -z "$hit" ] || { warn "$MODE: the body matches paths.potholes_domain_nouns ('$hit') — domain content belongs in --layer project"; return 1; }
    fi
}
# _op_shape_ok <kind> <old> <arg2> — the per-op argument rules, shared by the
# staging modes and _validate_op so a hand-edited block obeys what --retire /
# --amend enforced: the old line is a bullet; a retire mechanism carries neither
# ')' nor 'Issue-' (DEFENSIVE — the strippers anchor on the line end and are
# exercised against a body carrying '(' ')' '[' '*' '$' '\\'; the ban keeps a
# retired line to exactly one citation-shaped tail for ad-hoc audits); an amend
# keeps every old token (an amend is a citation). Reason on stderr, rc 1.
_op_shape_ok() {
    local kind="$1" old="$2" b="$3" ot nt t
    _bullet_shape "$old" || return 1
    case "$kind" in
    retire)
        case "$b" in *")"*) warn "$MODE: <mechanism> may not contain ')' — a retired line must carry exactly one citation-shaped tail: $b"; return 1 ;; esac
        case "$b" in *Issue-*) warn "$MODE: <mechanism> may not contain the substring 'Issue-': $b"; return 1 ;; esac ;;
    amend)
        ot="$(potholes_cite_tokens "$old")" || { warn "$MODE: <old-line> has no well-formed citation: $old"; return 1; }
        nt="$(potholes_cite_tokens "$b")"   || { warn "$MODE: <new-line> has no well-formed citation: $b"; return 1; }
        while IFS= read -r t; do
            potholes_tokens_has "$nt" "$t" || { warn "$MODE: <new-line> drops the old line's token '$t' — an amend is a citation, keep every member's token"; return 1; }
        done <<< "$ot" ;;
    esac
}
# Exact whole-line operations over the ACTIVE region — under a '## ' heading
# that is not the Retired heading; a bullet ABOVE the first heading (a
# bootstrapped skeleton's preamble, a hand edit) belongs to no section and is
# neither a hit nor a legal target. ONE awk program, mode-switched, so the
# region predicate is spelled once. Values travel via ENVIRON — never -v, never
# a regex (a line may carry '(' '[' '*' '$' '\\').
#   count | section | in_retired            → stdout / rc, file untouched
#   delete | replace <new>                  → rewrite the file in place
_region_awk() {   # <mode> <file> <line> [<new>]
    local mode="$1" f="$2" prog
    case "$mode" in
        count)      [ -f "$f" ] || { echo 0; return; } ;;
        in_retired) [ -f "$f" ] || return 1 ;;
    esac
    # shellcheck disable=SC2016  # an awk program, not shell
    prog='
      BEGIN { sec = ""; m = ENVIRON["MODE_"]; c = 0; f = 0 }
      /^## / { sec = $0 }
      { active = (sec != "" && sec != ENVIRON["RH"]); hit = (active && $0 == ENVIRON["L"]) }
      m == "count"      { if (hit) c++; next }
      m == "section"    { if (hit) { print sec; exit }; next }
      m == "in_retired" { if (sec == ENVIRON["RH"] && $0 == ENVIRON["L"]) f = 1; next }
      m == "delete"     { if (!hit) print; next }
      m == "replace"    { if (hit) print ENVIRON["N"]; else print; next }
      END { if (m == "count") print c; if (m == "in_retired") exit !f }'
    case "$mode" in
        delete|replace)   # rewrite in place; the read modes never touch the tree beside a real register
            if MODE_="$mode" RH="$POTHOLES_RETIRED_HEADING" L="$3" N="${4:-}" awk "$prog" "$f" > "$f.2"
            then mv "$f.2" "$f"; else rm -f "$f.2"; return 1; fi ;;
        *)  MODE_="$mode" RH="$POTHOLES_RETIRED_HEADING" L="$3" awk "$prog" "$f" ;;
    esac
}
_hits()         { _region_awk count      "$1" "$2"; }
_section_of()   { _region_awk section    "$1" "$2"; }
_in_retired()   { _region_awk in_retired "$1" "$2" >/dev/null; }
_delete_line()  { _region_awk delete     "$1" "$2"; }
_replace_line() { _region_awk replace    "$1" "$2" "$3"; }
_retire_result() {   # <section-heading> <old> <mechanism> <layer> → the Retired line
    local sec="${1#\#\# }" body toks own
    body="$(_body "$2")"; body="${body#- }"
    own="$(potholes_own_token "$project" "$issue_id" "$4")"
    toks="$(potholes_cite_tokens "$2")" || { warn "$MODE: <old-line> has no well-formed citation: $2"; return 1; }
    potholes_tokens_has "$toks" "$own" || toks="${toks}"$'\n'"$own"
    printf -- '- [%s] %s — mechanised by %s (%s).' "$sec" "$body" "$3" "$(printf '%s\n' "$toks" | potholes_cite_join)"
}
# Say NOW what --apply will DEFER on later — cheap, so the operator hears it at
# step 22 where the op can still be re-routed, not at cleanup.
_warn_commit_devdoc() {
    [ "$(_commit_devdoc_raw)" = true ] \
        || warn "$MODE: permissions.commit_devdoc is not true for $project — cleanup will DEFER the drain (rc 3) until the flag is flipped; the staged op is kept"
}
# _stage_open — _stage_init, then refuse to queue onto a DRAINED file: a drained
# file is a record, not a queue (the --drop rule). `dropped (all ops)` holds no
# op and drained nothing, so a new op re-opens it as pending; an op appended to
# an `applied` file would be accepted and never drained (review #612).
_stage_open() {
    local st
    _stage_init
    st="$(sed -n 's/^status: *//p' "$stage" | head -1)"
    case "$st" in
        pending*) ;;
        dropped*) sed -i 's/^status: dropped.*$/status: pending/' "$stage"
                  info "$MODE: re-opened $stage (was: $st) — pending again" ;;
        applied*) die "$MODE: $stage is already drained ($st) — a drained file is a record, not a queue; move it aside (mv $stage $stage.drained) and stage again, or land the line by hand and say so in the lessonslearned: log line" ;;
        *)        die "$MODE: $stage has an unrecognised status line ('$st') — fix it by hand: pending | applied <sha> | applied by-hand <sha> | dropped (all ops)" ;;
    esac
}
# _staged_block <needle-line> — the op number, then the first staged block (its
# non-blank lines from the '## ' heading on) carrying <needle-line> exactly; or
# nothing. Idempotency is keyed on the WHOLE block: a byte-identical re-run is
# a no-op, a DIFFERENT op on the same line is refused — keyed on the line
# alone, a 7a retire followed by a 7b amend of the same line was swallowed as
# "already staged" (red-team #612). The two needle namespaces — an add's
# '- <line>' and a retire/amend's 'old: <line>' — are disjoint by construction:
# an added line carries THIS issue's token, a register line being retired or
# amended cannot (it would mean a drained file, which _stage_open refuses).
_staged_block() {
    [ -f "$stage" ] || return 0
    L="$1" awk '
      /^## / { if (hit && !found) { fidx = k; fblk = blk; found = 1 } k++; blk = $0; hit = 0; next }
      blk != "" && !/^[[:space:]]*$/ { blk = blk "\n" $0; if ($0 == ENVIRON["L"]) hit = 1 }
      END { if (hit && !found) { fidx = k; fblk = blk; found = 1 } if (found) { print fidx; print fblk } }' "$stage"
}
# _stage_put <block> <needle-line> — append <block> unless the SAME block is
# staged (rc 0, no-op); die when a different op already names <needle-line>,
# printing the `--drop <n>` that clears it (a remedy must be executable as
# printed — the _stale message sets the precedent).
_stage_put() {
    local have idx
    have="$(_staged_block "$2")"
    if [ -n "$have" ]; then
        idx="${have%%$'\n'*}"; have="${have#*$'\n'}"
        [ "$have" = "$1" ] && { info "$MODE: already staged (idempotent): ${2#old: }"; exit 0; }
        die "$MODE: a DIFFERENT op (op $idx) is already staged for this line in $stage — one op per line; keep it, or clear it with 'promote-potholes.sh $project $issue_dir --drop $idx' and re-stage:"$'\n'"$have"
    fi
    printf '\n%s\n' "$1" >> "$stage"
}
_stage_init() {
    [ -f "$stage" ] && return 0
    {
        echo "# Pothole promotion — $issue_id"
        echo
        echo "<!-- #586/#611/#612: written by step 22 (core-lessons-learned item 7) via"
        echo "     scripts/promote-potholes.sh --add | --retire | --amend. One op per '## '"
        echo "     block: 'layer:' then 'op: add|retire|amend' and its keyed lines"
        echo "     ('- <line>' for add; 'old:' + 'mechanism:' for retire; 'old:' + 'new:'"
        echo "     for amend). A block without 'op:' is an add. Drained by --apply, which"
        echo "     cleanup.sh (step 23) runs after its tree restore: every op is validated"
        echo "     against a temp copy of every target file, then each file is written and"
        echo "     committed path-scoped. Sanctioned hand-edits: 'status: applied by-hand"
        echo "     <sha>' after landing lines by hand, and '--drop <op>' for a stale op. -->"
        echo
        echo "status: pending"
    } > "$stage"
}

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

# --- staging-file parser (#612): one op per '## ' block --------------------------
# Parallel arrays, one entry per op. add: A=line, B="" · retire: A=old,
# B=mechanism · amend: A=old, B=new. Block index == op index == the --drop
# number == the "op N" the DEFER messages quote (one op per block, enforced).
OP_SEC=(); OP_LAYER=(); OP_KIND=(); OP_A=(); OP_B=()
_b_reset() { b_sec=""; b_layer=""; b_op=""; b_lines=(); b_old=""; b_new=""; b_mech=""; }
_b_flush() {   # close the current block into the OP_* arrays; malformed → die (rc 1, a parse error)
    [ -n "$b_sec" ] || return 0
    [ -n "$b_layer" ] || die "--apply: staged block '$b_sec' has no 'layer:' line in $stage — re-stage it with --layer project|workflow"
    case "$b_layer" in project|workflow) ;; *) die "--apply: unknown layer '$b_layer' in $stage" ;; esac
    case "${b_op:-add}" in
        add)
            [ "${#b_lines[@]}" -gt 0 ] || die "--apply: add block '$b_sec' has no '- ' line in $stage"
            [ "${#b_lines[@]}" -eq 1 ] || die "--apply: add block '$b_sec' holds ${#b_lines[@]} '- ' lines in $stage — one op per block (a hand-edit; --add never writes this); re-stage one line per block"
            [ -z "$b_old$b_new$b_mech" ] || die "--apply: add block '$b_sec' carries old:/new:/mechanism: keys in $stage"
            OP_SEC+=("$b_sec"); OP_LAYER+=("$b_layer"); OP_KIND+=(add); OP_A+=("${b_lines[0]}"); OP_B+=("") ;;
        retire)
            [ -n "$b_old" ] && [ -n "$b_mech" ] || die "--apply: retire block '$b_sec' needs 'old:' and 'mechanism:' in $stage"
            [ "${#b_lines[@]}" -eq 0 ] && [ -z "$b_new" ] || die "--apply: retire block '$b_sec' has a stray '- ' or 'new:' line in $stage: ${b_lines[*]:-$b_new}"
            OP_SEC+=("$b_sec"); OP_LAYER+=("$b_layer"); OP_KIND+=(retire); OP_A+=("$b_old"); OP_B+=("$b_mech") ;;
        amend)
            [ -n "$b_old" ] && [ -n "$b_new" ] || die "--apply: amend block '$b_sec' needs 'old:' and 'new:' in $stage"
            [ "${#b_lines[@]}" -eq 0 ] && [ -z "$b_mech" ] || die "--apply: amend block '$b_sec' has a stray '- ' or 'mechanism:' line in $stage: ${b_lines[*]:-$b_mech}"
            OP_SEC+=("$b_sec"); OP_LAYER+=("$b_layer"); OP_KIND+=(amend); OP_A+=("$b_old"); OP_B+=("$b_new") ;;
        *)  die "--apply: unknown op '$b_op' in block '$b_sec' of $stage (add|retire|amend)" ;;
    esac
    _b_reset
}
_parse_stage() {
    local l; _b_reset
    while IFS= read -r l; do
        case "$l" in
            "## "*)         _b_flush; b_sec="$l" ;;
            "layer: "*)     b_layer="${l#layer: }" ;;
            "op: "*)        b_op="${l#op: }" ;;
            "old: "*)       b_old="${l#old: }" ;;
            "new: "*)       b_new="${l#new: }" ;;
            "mechanism: "*) b_mech="${l#mechanism: }" ;;
            "- "*)          [ -n "$b_sec" ] || die "--apply: staged line before any '## ' section in $stage"
                            b_lines+=("$l") ;;
        esac
    done < <(grep -E '^(## |layer: |op: |old: |new: |mechanism: |- )' "$stage")
    _b_flush
}

case "${1:-}" in
--add)
    MODE=--add; shift
    layer=""
    if [ "${1:-}" = "--layer" ]; then layer="${2:-}"; shift 2 || usage; fi
    section="${1:-}"; line="${2:-}"
    [ -n "$section" ] && [ -n "$line" ] || usage
    case "$section" in *$'\n'*) die "--add: <section> must be a SINGLE line" ;; esac
    # Routing is the SKILL's judgment (core-lessons-learned item 7); the script
    # enforces only what is decidable: the layer is named, and its citation form.
    _layer_target "$layer"; target="$TARGET"
    [ "## $section" != "$POTHOLES_RETIRED_HEADING" ] || die "--add: '$POTHOLES_RETIRED_HEADING' is not a legal target — it is written only by --retire"
    line="$(_normalise_own_token "$layer" "$line")"
    _rails "$layer" "$line" || die "--add: refused (see above)"
    potholes_union_headings "$project" | grep -qxF -- "## $section" \
        || die "--add: no section '## $section' in any register layer — use a heading that already exists (template.sh --project $project show potholes | grep '^## ')"
    _stage_open
    blk="$(printf '%s\n' "## $section" "layer: $layer" "op: add" "$line")"
    _warn_commit_devdoc
    if [ "$layer" = workflow ]; then
        _wr="$(_repo_of "$wf" || true)"; _dr="$(_repo_of "$devdoc_dir" || true)"
        [ -n "$_wr" ] && [ "$_wr" = "$_dr" ] \
            || warn "--add: the workflow register $wf is not inside the git repo holding devdoc_dir ($devdoc_dir) — the containment rail will DEFER (rc 3) at cleanup"
    fi
    cnt="$(potholes_section_count "$target" "## $section")"
    [ "$cnt" -lt "$POTHOLES_SECTION_CAP" ] \
        || warn "--add: section '## $section' of the $layer layer file $target already holds $cnt bullets (cap $POTHOLES_SECTION_CAP) — consolidate before adding (core-lessons-learned 7b); staging anyway, --apply never refuses a full section"
    _stage_put "$blk" "$line"
    info "staged for $issue_id ($layer layer): $line"
    ;;

--retire|--amend)
    MODE="$1"; shift
    layer=""
    if [ "${1:-}" = "--layer" ]; then layer="${2:-}"; shift 2 || usage; fi
    old="${1:-}"; arg2="${2:-}"
    [ -n "$old" ] && [ -n "$arg2" ] || usage
    _layer_target "$layer"; target="$TARGET"
    case "$arg2" in *$'\n'*) die "$MODE: the second argument must be a SINGLE line" ;; esac
    _bullet_shape "$old" || die "$MODE: <old-line> refused (see above)"
    n="$(_hits "$target" "$old")"
    if [ "$n" -eq 0 ]; then
        grep -qxF -- "$old" "$seed" \
            && die "$MODE: seed line — the plugin seed is a curated excerpt edited only by a seed-curation PR (#613 ledger); it is never the target of an op: record the candidate as an [actionable] lesson: $old"
        die "$MODE: <old-line> not found outside '$POTHOLES_RETIRED_HEADING' in the $layer layer $target: $old"
    fi
    [ "$n" -eq 1 ] || die "$MODE: <old-line> occurs $n times in $target — it must occur exactly once: $old"
    section="$(_section_of "$target" "$old")"
    [ -n "$section" ] || die "$MODE: <old-line> sits above the first '## ' heading of $target — not in any section, not a legal target"
    if [ "$MODE" = --retire ]; then
        kind=retire; key=mechanism; val="$arg2"
        _op_shape_ok retire "$old" "$val" || die "--retire: refused (see above)"
        result="$(_retire_result "$section" "$old" "$val" "$layer")" || die "--retire: refused (see above)"
        _rails "$layer" "$result" || die "--retire: the retired line fails a rail (see above): $result"
    else
        kind=amend; key=new; val="$(_normalise_own_token "$layer" "$arg2")"
        [ "$val" != "$old" ] || die "--amend: <new-line> is identical to <old-line> (after own-token normalisation) — nothing to amend"
        _rails "$layer" "$val" || die "--amend: <new-line> refused (see above)"
        _op_shape_ok amend "$old" "$val" || die "--amend: refused (see above)"
        result="$val"
    fi
    _stage_open
    _stage_put "$(printf '%s\n' "$section" "layer: $layer" "op: $kind" "old: $old" "$key: $val")" "old: $old"
    info "staged $kind for $issue_id ($layer layer): $old → $result"
    _warn_commit_devdoc
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
        dropped*) info "promote-potholes: $issue_id staging file is dropped (all ops) — neither a promise nor a claim" ;;
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

    _parse_stage

    # Every rail for EVERY staged layer BEFORE any write, so a DEFER on the
    # second layer never strands a half-drained run. Locks are taken here and
    # released by the EXIT trap — a die can never leak one.
    LOCKS=()
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/potholes.XXXXXX")"    # one temp copy per layer lives here
    _release() { local L; for L in "${LOCKS[@]}"; do rmdir "$L" 2>/dev/null || true; done; rm -rf "$tmp"; }
    trap _release EXIT
    L_NAME=(); L_TARGET=(); L_REPO=(); L_REL=()
    for ly in workflow project; do
        case " ${OP_LAYER[*]} " in *" $ly "*) ;; *) continue ;; esac   # no op names this layer
        if [ "$ly" = workflow ]; then target="$wf"; else target="$pr"; fi
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


    # --- op engine (#612) ---------------------------------------------------------
    _defer() { warn "promote-potholes: $*"; warn "promote-potholes: $issue_id stays pending — nothing was written (rc 3)"; exit 3; }
    # _stale <q> <diagnosis> <what> <op-number> — the two closes, spelled once (tests pin them).
    _stale() { _defer "$1: STALE — $2 (another issue's consolidate consumed it first?): $3 — close it with '--drop $4' (then reword the lessonslearned: log line if it counted this op), or land a line carrying this issue's token by hand and set 'status: applied by-hand <sha>'"; }
    _one_hit() { [ "$2" -eq 1 ] || _defer "$1: old line occurs $2 times (must be exactly once): $3"; }   # <q> <n> <old>
    _append_in_section() {   # <file> <heading> <line> — at the END of the section; heading added at EOF if absent
        # A heading valid in the UNION but absent from THIS layer file is added at
        # the end (blank line first: never a bullet directly before a heading).
        grep -qxF -- "$2" "$1" || printf '\n%s\n' "$2" >> "$1"
        # Append at the END of the section: buffer the blank run before the next
        # heading so the line lands after the last bullet and the blank run
        # survives (the #570 hazard). ENVIRON, not -v: -v processes C escapes and
        # would corrupt a `\(`.
        S="$2" L="$3" awk '
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
          }' "$1" > "$1.2" || return 1
        mv "$1.2" "$1"
    }
    # _validate_op <index> <temp> — rc 0 changed | rc 4 already applied | exit 3 DEFER.
    # A zero-hit is ALREADY APPLIED only when the op's EXACT result line is present
    # (retire: the result under Retired; amend: new present, old absent; add: the
    # line) — never "some line carries this issue's token", which would mark a
    # stale sibling op applied.
    _validate_op() {
        local j="$1" t="$2" kind="${OP_KIND[$1]}" sec="${OP_SEC[$1]}" a="${OP_A[$1]}" b="${OP_B[$1]}" ly="${OP_LAYER[$1]}" n m res q
        q="op $((j+1)) ($kind, $ly layer, '$sec')"
        case "$kind" in
        add)
            [ "$sec" != "$POTHOLES_RETIRED_HEADING" ] || _defer "$q: the Retired section is not a legal add target: $a"
            [ "$(_hits "$t" "$a")" -eq 0 ] || return 4
            _rails "$ly" "$a" || _defer "$q: rail failed: $a"
            _append_in_section "$t" "$sec" "$a" || _defer "$q: section '$sec' could not be appended to: $a"
            ;;
        retire)
            _op_shape_ok retire "$a" "$b" || _defer "$q: refused (see above): $a"
            res="$(_retire_result "$sec" "$a" "$b" "$ly")" || _defer "$q: refused (see above): $a"
            n="$(_hits "$t" "$a")"
            if [ "$n" -eq 0 ]; then
                _in_retired "$t" "$res" && return 4
                _stale "$q" "old line absent and its retired form absent" "$a" "$((j+1))"
            fi
            _one_hit "$q" "$n" "$a"
            _rails "$ly" "$res" || _defer "$q: the retired line fails a rail: $res"
            _delete_line "$t" "$a" || _defer "$q: could not delete the old line from the temp copy: $a"
            _append_in_section "$t" "$POTHOLES_RETIRED_HEADING" "$res" || _defer "$q: could not append to '$POTHOLES_RETIRED_HEADING': $res"
            ;;
        amend)
            _op_shape_ok amend "$a" "$b" || _defer "$q: refused (see above): $a"
            n="$(_hits "$t" "$a")"; m="$(_hits "$t" "$b")"
            if [ "$n" -eq 0 ] && [ "$m" -ge 1 ]; then return 4; fi
            [ "$n" -ge 1 ] || _stale "$q" "neither the old nor the new line is present" "old: $a" "$((j+1))"
            [ "$m" -eq 0 ] || _defer "$q: REFUSED — old AND new both present (an add of the new line staged beside this amend, or a second amend onto the same merged line — one member is replaced per merged line): old: $a / new: $b"
            _one_hit "$q" "$n" "$a"
            _rails "$ly" "$b" || _defer "$q: the replacement fails a rail: $b"
            _replace_line "$t" "$a" "$b" || _defer "$q: could not replace the old line in the temp copy: $a"
            ;;
        esac
        return 0
    }

    # VALIDATION — every op of every layer, SEQUENTIALLY (op 2 sees op 1's result),
    # against temp copies; nothing is written until all pass. Locks are already
    # held (rail phase) and stay held through the last commit.
    declare -A CHANGED=() BOOT=()
    MODE=--apply
    for i in "${!L_NAME[@]}"; do
        ly="${L_NAME[i]}"; target="${L_TARGET[i]}"; t="$tmp/$ly"
        if [ -f "$target" ]; then cp "$target" "$t"; cp "$target" "$t.orig"; BOOT[$ly]=0
        else _skeleton "$ly" > "$t"; BOOT[$ly]=1; fi
        c=0
        for j in "${!OP_KIND[@]}"; do
            [ "${OP_LAYER[j]}" = "$ly" ] || continue
            vrc=0; _validate_op "$j" "$t" || vrc=$?
            case "$vrc" in 0) c=$((c+1)) ;; 4) ;; *) exit "$vrc" ;; esac
        done
        CHANGED[$ly]=$c
        [ "$c" -gt 0 ] || continue
        # Postconditions on the temp copy: the register FILE contract over the WHOLE
        # file (potholes_file_check, #613 — a pre-existing violation DEFERs too, each
        # line labelled with the real path), then the citation, scoped to THIS file
        # (the union would be satisfied by another layer's earlier promotion). rc 2
        # (unreadable copy) is a harness fault, never a register verdict (Issue-316).
        pc_rc=0; pc="$(potholes_file_check "$ly" "$t" "$target" 2>&1)" || pc_rc=$?
        [ "$pc_rc" -ne 2 ] || die "--apply: potholes_file_check could not read the $ly temp copy ($t): $pc"
        [ "$pc_rc" -eq 0 ] || _defer "$ly layer: the ops would leave the register violating its format contract — $target NOT modified; fix the quoted line by hand, then re-run --apply:"$'\n'"$pc"
        grep -qiE -- "$(potholes_cite_re "$project" "$issue_id" "$ly")" "$t" \
            || _defer "$ly layer: after the ops the register carries no ${issue_id} citation — $target NOT modified"
    done

    # WRITE + COMMIT — per file; a failure restores THAT file and dies, earlier
    # commits stand (the re-run converges: their ops read as already applied).
    # Commit scoped to the ONE path, with the operator's identity (-s), like a
    # source-tree chore; cleanup's own devdoc commit (devagent@local) never
    # carries these files. On failure a bootstrapped file is REMOVED (rm --cached
    # + rm -f + the empty dir) so cleanup's `git add -A` cannot sweep the
    # skeleton; an existing one gets its original bytes.
    shas=""
    for i in "${!L_NAME[@]}"; do
        ly="${L_NAME[i]}"; target="${L_TARGET[i]}"; repo="${L_REPO[i]}"; rel="${L_REL[i]}"; t="$tmp/$ly"
        [ "${CHANGED[$ly]}" -gt 0 ] || continue                # this layer already carries every op's result
        cat "$t" > "$target"                                   # preserve mode/inode of an existing file
        if [ "${BOOT[$ly]}" -eq 1 ]; then
            "$DEVAGENT_GIT" -C "$repo" add -- "$rel"           # an untracked path needs it before a pathspec commit
        fi
        if ! "$DEVAGENT_GIT" -C "$repo" commit -s -q \
            -m "chore: promote pothole-register entries from #${issue_n}" \
            -m "layer: $ly; register: $rel; branch: $cur" -- "$rel"; then
            if [ "${BOOT[$ly]}" -eq 1 ]; then
                "$DEVAGENT_GIT" -C "$repo" rm --cached -q -- "$rel" 2>/dev/null || true
                rm -f "$target"
                rmdir "$target.lock" 2>/dev/null || true       # release first, so an empty templates/ can go too
                rmdir "$(dirname "$target")" 2>/dev/null || true
            else
                cat "$t.orig" > "$target"
            fi
            die "--apply: commit failed in $repo — $ly register restored, $issue_id stays pending (git identity/hooks; fix, then re-run --apply)${shas:+; earlier layer commit(s) $shas already landed}"
        fi
        sha="$("$DEVAGENT_GIT" -C "$repo" rev-parse --short HEAD)"
        shas="${shas:+$shas,}$sha"
        info "promote-potholes: ${CHANGED[$ly]} op(s) applied for $issue_id to $target ($ly layer) — committed $sha on $cur (NOT pushed)"
    done
    # Nothing new to write anywhere is success: the registers already carry every
    # op's result at the devdoc HEAD, which is what the stamp then records.
    [ -n "$shas" ] || shas="$("$DEVAGENT_GIT" -C "$doc_repo" rev-parse --short HEAD)"
    sed -i "s/^status: pending$/status: applied ${shas}/" "$stage"
    ;;

--drop)
    n="${2:-}"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || usage
    [ -f "$stage" ] || die "--drop: no staging file at $stage"
    grep -q '^status: pending' "$stage" || die "--drop: $stage is not pending ($(sed -n 's/^status: *//p' "$stage" | head -1)) — a drained file is a record, not a queue"
    total="$(_op_count "$stage")" || die "--drop: unreadable staging file $stage"
    [ "$n" -le "$total" ] || die "--drop: op $n does not exist — $stage holds $total op block(s)"
    N="$n" awk '/^## /{k++} !(k==ENVIRON["N"]+0)' "$stage" > "$stage.2" && mv "$stage.2" "$stage"
    if [ "$total" -eq 1 ]; then
        sed -i 's/^status: pending$/status: dropped (all ops)/' "$stage"
        info "--drop: removed the last op from $stage — status: dropped (all ops); if the lessonslearned: log line still claims 'register: N staged', reword it (--check will say so)"
    else
        info "--drop: removed op $n of $total from $stage ($((total-1)) remain pending)"
    fi
    ;;

*) usage ;;
esac
