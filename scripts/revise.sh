#!/usr/bin/env bash
#
# /devagent:revise — start a new revision pass after MR feedback.
#
# Usage:  revise.sh [project] [issue] [--no-chain]

set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/paths.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/io.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/state.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/active.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/revision.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/flags.sh"
# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/checklist.sh"

# Private die() preserves the "revise:" message prefix; defined after the sources so
# it shadows io.sh's die (state.sh's internal die calls then carry this prefix too).
die() {
  printf 'revise: %s\n' "$*" >&2
  exit 1
}

# #97: state read/write now goes through lib/state.sh (state_get / state_set /
# state_set_int). The private section-ignorant helpers that appended a not-found key
# at EOF — corrupting the [parked] table — have been removed.

# Parse argv
PROJECT=""
ISSUE=""
NO_CHAIN=0
RETIER=""
expect_retier=0
for arg in "$@"; do
  if [[ "$expect_retier" -eq 1 ]]; then
    # An explicit empty value must not silently degrade to a genuine revise.
    [[ -n "$arg" ]] || die "--retier requires a tier name"
    RETIER="$arg"
    expect_retier=0
    continue
  fi
  case "$arg" in
    --retier)   expect_retier=1 ;;
    --no-chain) NO_CHAIN=1 ;;
    *)
      if [[ -z "$PROJECT" ]]; then
        PROJECT="$arg"
      elif [[ -z "$ISSUE" ]]; then
        ISSUE="$arg"
      fi
      ;;
  esac
done
[[ "$expect_retier" -eq 0 ]] || die "--retier requires a tier name"
# #124: route the bare-invocation default through the active-project chain
# (arg → DEVAGENT_ACTIVE_PROJECT → global _active.toml → single configured project)
# instead of the literal string 'default', matching next.sh / statusreport.sh / wbs.
# #572: _try form; a resolution failure still exits under set -e with the
# engine's own message (re-emitted), byte-compatible with the old $() die-through.
active_resolve_project_try "$PROJECT"
PROJECT="$ACTIVE_RESOLVED_PROJECT"
active_guard_scope revise

# #240: the session's issue (arg → env pin → shared state); reads/writes are
# keyed to it. (Supersedes the #70 arg-vs-state crosscheck: an explicit arg
# IS the issue.)
ISSUE="$(active_resolve_issue "$PROJECT" "$ISSUE" 2>/dev/null || true)"
issue_dir=$(issue_context_dir "$PROJECT" "$ISSUE") \
  || die "no active_issue for project '$PROJECT'"
[[ -n "$issue_dir" ]] || die "issue_dir empty in state for project '$PROJECT'"
[[ -d "$issue_dir" ]] || die "issue dir not found: $issue_dir"

n_cur=$(revision_current "$PROJECT" "$ISSUE")
n_new=$((n_cur + 1))

if [[ -n "$RETIER" ]]; then
  # #537 escalation valve: tier promotion is a REVISION (this script owns
  # both halves — the block append AND the issue-keyed state transaction).
  # No comments.md required: this is a tier change, not MR feedback.
  tier_require_legal "$RETIER"
  old_tier="$(sed -n 's/^Template: //p' "$issue_dir/checklist.md" | head -1)"
  tpl="$(_checklist_template_path "$RETIER" "$PROJECT")"
  [[ -f "$tpl" ]] || die "checklist template not found: $tpl"
  {
    printf '\n## Revision %s\n\n' "$n_new"
    # the new tier's Revision-1 rows, excluding the PRE-DRAFT / flag-driven steps.
    # Keyed by NAME, not number, so a future renumber leaves this untouched (#558).
    # A pending `pull` would re-point next.sh at pull; research (#535) and spike
    # (#536) are flag-driven — their flip lives ONLY in pull.sh's scaffold branch,
    # so copying them would re-point next.sh or silently reset a flagged row to
    # `[-]` on every revision. Re-flag via the documented manual escape hatch.
    awk '/^## Revision 1$/{inrev=1; next} inrev && /^## /{exit}
         inrev && /^- \[/ && $0 !~ /^- \[.\] +[0-9]+\. (pull|research|spike)$/ {print}' "$tpl" \
      | checklist_filter_mergetoall "$PROJECT"
  } >> "$issue_dir/checklist.md"
  sed -i "s/^Template: .*/Template: ${RETIER}/" "$issue_dir/checklist.md"
  # #414 shape: revision bump + step-pointer reset in ONE issue-keyed
  # transaction; pending_comments_file deliberately untouched (no comments).
  state_ctx_set_many "$PROJECT" "$ISSUE" int revision "$n_new" int last_step 0 str last_step_name ""
  log_append "$issue_dir" revise "retier: ${old_tier:-unknown} → ${RETIER} (revision $n_new)"
  printf 'revise: retier %s → %s (revision %s)\n' "${old_tier:-unknown}" "$RETIER" "$n_new"
else
  prev_rdir=$(revision_dir "$issue_dir" "$n_cur")
  prev_comments="$prev_rdir/comments.md"

  if [[ ! -f "$prev_comments" ]]; then
    die "missing $prev_comments — run /devagent:comments first"
  fi

  new_rdir=$(revision_dir "$issue_dir" "$n_new")
  mkdir -p "$new_rdir"

  revision_block_text "$n_new" "$PROJECT" >>"$issue_dir/checklist.md"

  # #96: int + str in one transaction (#240: issue-keyed, mirror inside the lock).
  # #414: also RESET last_step/last_step_name — the new '## Revision N' block has
  # every step [ ], so a step pointer inherited from the prior revision (e.g.
  # last_step_name=ship) makes doctor's #329 step-coherence check false-FAIL (state
  # names a step the active block shows unmarked). Empty name ⇒ doctor skips the
  # check; the checklist is authoritative for resumption (next reads the glyphs).
  state_ctx_set_many "$PROJECT" "$ISSUE" int revision "$n_new" str pending_comments_file "$prev_comments" int last_step 0 str last_step_name ""

  k=$(grep -c '^### @' "$prev_comments" || true)
  # #75: route through log_append so the entry lands inside the `## Log` section,
  # not at EOF after the just-appended `## Revision N` block.
  log_append "$issue_dir" revise "revision $n_new started, $k comments to address"

  printf 'revise: advanced to revision %s (%s comments pending)\n' "$n_new" "$k"
fi

# Shared chain tail — both paths dispatch identically (#537 quality: the
# retier branch initially forked this block and dropped the exec branch).
if [[ "$NO_CHAIN" -eq 0 ]]; then
  chain_cmd="${DEVAGENT_CHAIN_CMD:-/devagent:next}"
  if [[ -x "$chain_cmd" ]]; then
    "$chain_cmd" /devagent:next
  else
    printf 'CHAIN: %s\n' "$chain_cmd"
  fi
fi
