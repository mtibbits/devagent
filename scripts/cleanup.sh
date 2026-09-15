#!/usr/bin/env bash
# scripts/cleanup.sh — step 23. Switch source tree back to default_baseline,
# commit/push devdoc if permissions.commit_devdoc=true, clear active_issue.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
. "$DEVAGENT_ROOT/scripts/lib/log.sh"
. "$DEVAGENT_ROOT/scripts/lib/permission.sh"
. "$DEVAGENT_ROOT/scripts/lib/template_resolve.sh"   # #611: potholes.sh layer paths (the exclude pathspecs below)

: "${DEVAGENT_GIT:=git}"

project="${1:-}"
[ -n "$project" ] || die "project required"
config_is_project "$project" || die "unknown project '$project'"

# #240: a pinned session cleans up ITS issue — derive the dir instead of
# trusting the shared slot (which belongs to the other session). The pin is
# VALIDATED first (review MED: a traversal pin like Issue-2/../Issue-1 would
# otherwise run the full cleanup against another issue's dir).
# #331: resolve the target issue ONCE (arg → pin → shared state) and let
# issue_arg follow it — previously issue_arg was arg → SHARED state (skipping the
# pin), so a pinned session's devdoc commit + permission plan named the OTHER
# session's issue. gc_issue (below) already uses the arg→pin→state chain.
cleanup_target="${2:-}"; cleanup_target="${cleanup_target##*/}"
[ "$cleanup_target" != "--" ] || cleanup_target=""
[ -n "$cleanup_target" ] || cleanup_target="${DEVAGENT_ACTIVE_ISSUE:-}"
if [ -n "$cleanup_target" ]; then
    _state_issue_id_ok "$cleanup_target" \
        || die "invalid issue id '$cleanup_target' (allowed: A-Za-z0-9 _ -)"
    issue_dir="$(issue_dir_for "$project" "$cleanup_target")"
else
    cleanup_target="$(state_get "$project" active_issue 2>/dev/null || true)"
    issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"
fi
issue_arg="$cleanup_target"
[ -d "$issue_dir" ] || die "issue_dir not set or missing"

# #242 (generalizes #231): refuse to close while ANY prior closeout step is
# non-terminal — updatewbs/impact/lessonslearned are exactly the steps skipped
# when "the code is merged, I'm done" (Issue-78/79/80), and lessonslearned is
# the [actionable]->reap producer whose loss is silent and unrecoverable.
# Design A1+B1+C2 per the issue: block (die) on all three, naming every
# offender at once; the per-step escape is marking [-] (skip), auditable in
# the checklist. BY NAME (numbers vary by template), absent step => no gate.
# Runs before any side effect (the tree restore below).
offenders="$(checklist_nonterminal_by_names "$issue_dir/checklist.md" updatewbs impact lessonslearned)"
if [ -n "$offenders" ]; then
    # Derive the remediation commands from the offender list itself — one
    # authoritative name list (the helper args above).
    fix_cmds="$(printf '%s\n' "$offenders" | sed 's/:.*$//; s|^|/devagent:|' | tr '\n' ' ')"
    die "closeout steps not terminal: ${offenders//$'\n'/ } — run ${fix_cmds}first, or mark a genuinely-empty step [-] via /devagent:checklist-mark, then re-run (#242)"
fi

# #595: enforce the ONESHOT no-repo-diff boundary mechanically, BEFORE any side
# effect — the same placement the #242 and #586 gates use, and load-bearing
# here: the tree restore below is a `git checkout`, which would carry a dirty
# oneshot footprint onto the base branch.
# The TIER READ LIVES HERE, not only in the checker, so a non-oneshot close
# spawns no subprocess and its output is byte-identical to today (the checker
# pays a bash spawn, seven lib sources and a python3 config read before its own
# tier gate). cleanup.sh already sources lib/checklist.sh (line 11), and this
# read goes through the same single-source helper the checker uses, and the
# checker resolves its TARGET through the same arg -> pin -> shared-slot chain
# as above (redmr M1), so both read the one checklist this close is about
# ("omits step 12" was never a oneshot key — research omits 12 too).
# The checker owns the whole predicate; this site owns only verdict->action.
# --auto CHAIN TRACE (register Issue-242 — "a die mid-chain is a different
# product than one on direct invocation, and warnings can't gate autonomous
# flows"): cleanup is the chain's through-target (next.sh:64), so a die here
# ends the chain non-zero with this message last, and nothing downstream is
# stranded because cleanup is the last step. A warn would scroll past unread in
# exactly the autonomous flow that most needs the gate.
if [ "$(checklist_template_name "$issue_dir/checklist.md")" = oneshot ]; then
    os_rc=0
    "$DEVAGENT_ROOT/scripts/oneshot-zerodiff.sh" "$project" "$issue_arg" || os_rc=$?
    case "$os_rc" in
        0) : ;;   # clean — the invariant holds
        5) : ;;   # operator-acknowledged; the checker already warned loudly
        3) die "oneshot boundary VIOLATED — see above. A one-shot is an operational action, not a repo change. If this issue produced the listed changes, escalate with 'bash $DEVAGENT_ROOT/scripts/revise.sh $project $issue_arg --retier standard' (restarts the issue at draft, step 2) and re-run the chain; if it did not, land or clear them first. This check cannot attribute them — the tree is shared (#595)." ;;
        4) die "oneshot boundary INDETERMINATE — see above. An invariant that cannot be proven must not authorize completion. Apply the remedy the checker named (the routine one: check out the base branch in the shared tree), then re-run. Reviewed de-scoping only: 'echo \"<reason>\" > $issue_dir/.devagent-oneshot-ack' records an acknowledgement and skips the check for this issue (#595)." ;;
        *) die "oneshot boundary check could not RUN (rc=$os_rc) — a usage or tooling fault, not a boundary verdict; see above (#595)." ;;
    esac
fi

source_dir="$(config_get_project_field "$project" source_dir)"
devdoc_dir="$(config_get_project_field "$project" devdoc_dir)"
baseline="$(config_get_project_field "$project" default_baseline)"
base_branch="${baseline##*/}"

# #586: refuse a promotion CLAIM the register does not carry, BEFORE any side
# effect (the #242 placement). A claim can only come from a lessonslearned: log
# line or a staging file, so the common case skips the process entirely.
if [ -f "$issue_dir/potholes-promotion.md" ] || grep -q 'lessonslearned:' "$issue_dir/checklist.md" 2>/dev/null; then
    "$DEVAGENT_ROOT/scripts/promote-potholes.sh" "$project" "$issue_dir" --check \
        || die "pothole-promotion check failed (#586) — see above"
fi

# Restore source tree to base branch.
( cd "$source_dir" && "$DEVAGENT_GIT" checkout "$base_branch" )

# #586/#611: drain the pending register promotion NOW, after the source-tree
# restore. The drain commits each devdoc-resident layer file ITSELF (one
# path-scoped commit per layer, operator identity) — the devdoc commit below
# never carries them. rc 3 = deferred (stays pending, stays loud). Re-running
# cleanup after a die here is safe (--apply is idempotent).
if [ -f "$issue_dir/potholes-promotion.md" ]; then
    pp_rc=0
    "$DEVAGENT_ROOT/scripts/promote-potholes.sh" "$project" "$issue_dir" --apply || pp_rc=$?
    if [ "$pp_rc" -eq 3 ]; then
        warn "cleanup: pothole promotion DEFERRED — $issue_dir/potholes-promotion.md stays pending; see the reason above. Environment causes (commit_devdoc flag, dirty/untracked register, mid-merge, containment, held lock): fix and re-run promote-potholes.sh $project $issue_dir --apply. A pre-existing register-contract violation in the layer file (#613: '<file>:<line>: <reason>' is quoted — fix that line by hand, then re-run --apply). An op-validation cause (#612: STALE, multi-hit, old+new both present, a failed rail — the op and line are quoted): close the op with promote-potholes.sh $project $issue_dir --drop <op> (then reword the lessonslearned: log line if it counted that op), or land it by hand and set 'status: applied by-hand <sha>'; re-running --apply alone re-DEFERs"
    elif [ "$pp_rc" -ne 0 ]; then
        die "cleanup: pothole promotion FAILED (rc=$pp_rc) — the failing layer was restored; any layer commit reported above is already in devdoc history and the staging file stays pending (#586/#611)"
    fi
fi

# Bookkeeping first — updates checklist.md so devdoc has something to commit.
# Clear the per-issue context and GC any leftover snapshot for this issue
# (#98), then record cleanup as the last step.
# #240: GC the ISSUE BEING CLEANED, and touch the shared slot only when that
# issue owns it. A pinned session finishing Issue-2 while the shared pointer
# says Issue-1 must GC context.Issue-2 — not Issue-1's live table — and must
# not wipe the other session's top-level keys or pointer.
# Precedence: explicit arg (the arg IS the issue) → pin → shared state.
gc_issue="${2:-}"
gc_issue="${gc_issue##*/}"
[ "$gc_issue" != "--" ] || gc_issue=""
[ -n "$gc_issue" ] || gc_issue="${DEVAGENT_ACTIVE_ISSUE:-}"
if [ -z "$gc_issue" ]; then
    gc_issue="$(state_get "$project" active_issue 2>/dev/null || true)"
fi
if [ -z "$gc_issue" ] || [ "$gc_issue" = "null" ]; then
    gc_issue="${issue_arg##*/}"
fi
shared_active="$(state_get "$project" active_issue 2>/dev/null || true)"
if [ -n "$gc_issue" ] && [ "$gc_issue" != "--" ]; then
    state_unset "$project" "context.${gc_issue}"
    state_remove_displaced "$project" "$gc_issue"   # #415: don't leak the marker
    # #351: remove this issue's keyed analyze build dirs from the shared source
    # tree. Per-issue keying isolates concurrent chains but would grow unbounded
    # otherwise; cleanup bounds it to in-flight issues. The `-*` requires a dash
    # after the key, so cleaning Issue-1 cannot wipe Issue-10's dirs (prefix).
    _bk="$(printf '%s-%s' "$project" "$gc_issue" | tr -c 'A-Za-z0-9' '-')"
    rm -rf -- "$source_dir/build-$_bk" 2>/dev/null || true
    for _d in "$source_dir/build-$_bk"-*; do
        [ -e "$_d" ] && rm -rf -- "$_d"
    done
    unset _bk _d
fi
# #417: touch the shared slot ONLY when the issue being cleaned actually OWNS it
# (shared_active == gc_issue). The old guard keyed on pin-ABSENCE (a session
# property), so an unpinned `cleanup <proj> Issue-B` while active_issue=Issue-A
# ran state_context_clear + active_issue="" and wiped Issue-A's live top-level
# mirror. Ownership is a property of the SLOT, not of DEVAGENT_ACTIVE_ISSUE: this
# still clears on the normal unpinned cleanup of the active issue (shared==gc) and
# on a pinned session cleaning its own issue, and still skips a pinned session
# whose slot names another issue — but never clobbers a different active issue.
if [ "$shared_active" = "$gc_issue" ]; then
    # #536 redmr MAJOR: state_cleanup_finish resets spike_worktree_path along with the
    # other issue keys. If a spike worktree SURVIVED (a crashed create/teardown), that
    # reset erases the only pointer to it — turning a passive gap into active
    # pointer-erasure. Warn with the path BEFORE it is discarded.
    _spike_orphan="$(state_ctx_get "$project" spike_worktree_path "$issue_arg" 2>/dev/null || true)"
    if [ -n "${_spike_orphan:-}" ] && [ -e "$_spike_orphan" ]; then
        warn "spike worktree still present at '$_spike_orphan' — cleanup is about to clear the recorded path. Remove it by hand (git worktree remove --force '$_spike_orphan') or it becomes an untracked orphan."
    fi
    state_cleanup_finish "$project"   # #418: clear+stamp+pointer in ONE transaction
else
    info "cleanup: ${gc_issue} does not own the shared active_issue (${shared_active:-<none>}) — shared slot left untouched"
fi

checklist_mark "$issue_dir/checklist.md" 23 x cleanup
log_append "$issue_dir" cleanup "tree restored, active_issue cleared${NOTE:+ — $NOTE}"

# Reconcile the WBS against the now-completed checklist so the leaf for
# this issue flips to [x]. --if-exists silently no-ops if the project
# has no WBS.md (it's an optional artifact). We pass project explicitly
# because active_issue was just cleared above.
"$DEVAGENT_ROOT/scripts/wbs-update.sh" --if-exists "$project" || \
    warn "cleanup: wbs reconcile failed (non-fatal)"

# Commit + push devdoc if permitted.
commit_devdoc="$(config_get_project_field "$project" "permissions.commit_devdoc" 2>/dev/null || echo false)"
if [ "$commit_devdoc" = "true" ]; then
    plan="cleanup plan: commit + push devdoc updates for $issue_arg"
    permission_gate "$project" commit_devdoc "$plan"
    cd "$devdoc_dir"
    # #140: --porcelain reports untracked files too. A fresh Issue-NNN/ dir from
    # pull.sh this cycle is entirely untracked; the old `git diff` guard saw only
    # tracked modifications and silently skipped the commit.
    # #611: scoped to devdoc_dir (`-- .`): from a subdirectory of the devDoc
    # repo an unscoped -A stages the WHOLE worktree, including a workflow
    # register at the repo root left dirty by a concurrent session. The
    # register LAYER FILES are the drain's to commit, never this commit's: a
    # layer the drain DEFERred on (dirty/untracked — another session's edit)
    # must not be swept here under devagent@local (#611 review). Exclude
    # every layer path that lives under devdoc_dir.
    # FAIL CLOSED: a lookup that dies inside $( ) would leave excl empty and
    # re-arm the sweep, so each rc is read in THIS shell and a failure refuses
    # the whole devdoc commit (red-team #611).
    _dc="$(pwd -P)"; excl=(); _lk=1
    _lp_pr="$(potholes_project_path "$project")"  || _lk=0
    _lp_wf="$(potholes_workflow_path "$project")" || _lk=0
    if [ "$_lk" -ne 1 ]; then
        warn "cleanup: register layer lookup failed (see above) — devdoc commit REFUSED so no layer file can be swept; fix [paths] potholes_workflow / the config and commit devdoc by hand"
    fi
    for _lp in "$_lp_pr" "$_lp_wf"; do
        [ -n "$_lp" ] && [ -d "$(dirname "$_lp")" ] || continue
        _lpc="$(cd "$(dirname "$_lp")" && pwd -P)/$(basename "$_lp")"
        case "$_lpc" in "$_dc"/*) excl+=(":(exclude)${_lpc#"$_dc"/}") ;; esac
    done
    unset _dc _lp _lpc _lp_pr _lp_wf
    if [ "$_lk" -eq 1 ] && [ -n "$("$DEVAGENT_GIT" status --porcelain -- . "${excl[@]}")" ]; then
        "$DEVAGENT_GIT" add -A -- . "${excl[@]}"
        "$DEVAGENT_GIT" -c user.email=devagent@local -c user.name=devagent \
            commit -m "devdoc: $issue_arg cleanup"
        if "$DEVAGENT_GIT" remote get-url origin >/dev/null 2>&1; then
            "$DEVAGENT_GIT" push origin HEAD 2>/dev/null || \
                echo "warning: devdoc push failed; commit retained locally" >&2
        fi
    fi
fi
