#!/usr/bin/env bash
# scripts/cleanup.sh — step 20. Switch source tree back to default_baseline,
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

source_dir="$(config_get_project_field "$project" source_dir)"
devdoc_dir="$(config_get_project_field "$project" devdoc_dir)"
baseline="$(config_get_project_field "$project" default_baseline)"
base_branch="${baseline##*/}"

# Restore source tree to base branch.
( cd "$source_dir" && "$DEVAGENT_GIT" checkout "$base_branch" )

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
if [ -z "${DEVAGENT_ACTIVE_ISSUE:-}" ] || [ "$shared_active" = "$gc_issue" ]; then
    state_context_clear "$project"
    state_set_many "$project" \
      str last_step      "20" \
      str last_step_name "cleanup" \
      str active_issue   ""
else
    info "cleanup: session is issue-pinned (${gc_issue}) — shared active_issue (${shared_active}) untouched"
fi

checklist_mark "$issue_dir/checklist.md" 20 x
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
    if [ -n "$("$DEVAGENT_GIT" status --porcelain)" ]; then
        "$DEVAGENT_GIT" add -A
        "$DEVAGENT_GIT" -c user.email=devagent@local -c user.name=devagent \
            commit -m "devdoc: $issue_arg cleanup"
        if "$DEVAGENT_GIT" remote get-url origin >/dev/null 2>&1; then
            "$DEVAGENT_GIT" push origin HEAD 2>/dev/null || \
                echo "warning: devdoc push failed; commit retained locally" >&2
        fi
    fi
fi
