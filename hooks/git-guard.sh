#!/usr/bin/env bash
# hooks/git-guard.sh — devAgent opt-in git-reflex guard (#352). A PreToolUse Bash
# hook that DENIES reflexive destructive git on a DIRTY working tree, so an agentic
# run can't silently wipe uncommitted work (6+ recorded near-losses: #85/#116/#125/
# #76/#151/#240). OPT-IN via `[defaults] git_guard = true`; default off. Override a
# single call by prefixing `DEVAGENT_GIT_GUARD_OVERRIDE=1`.
#
# CONTRACT — fail-OPEN. exit 0 = allow; exit 2 = deny (stderr shown to the user). A
# guard BUG must NEVER brick Bash, so every error/uncertain path exits 0 and ONLY a
# confirmed deny exits 2. Deliberately NO `set -e`.
#
# KNOWN GAPS (heuristic backstop, not a sandbox — all fail OPEN): it matches the raw
# command STRING, so `git -C <dir> …`, shell aliases, `bash -c '…'`, variable
# indirection, and compound `a && git stash` can evade (or, rarely, over-match) the
# match. The opt-in gate + the override are the intended escapes.

# 1. Gate — read [defaults] git_guard (matches doctor's config_get_default). OFF
#    (the default) or unreadable → allow fast, before any parsing work.
cfg="${DA_HOME:-$HOME/.claude/devagent}/config.toml"
[ -f "$cfg" ] || exit 0
awk '
  /^\[/ { in_def = ($0 == "[defaults]") }
  in_def && /^[[:space:]]*git_guard[[:space:]]*=[[:space:]]*true[[:space:]]*$/ { found = 1 }
  END   { exit(found ? 0 : 1) }
' "$cfg" 2>/dev/null || exit 0

# 2. Parse the tool call. Any parse failure → allow (fail-open; jq exits nonzero on
#    empty/garbage, and nonzero-but-not-2 must not deny).
input="$(cat 2>/dev/null)" || exit 0
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[ -n "$cmd" ] || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)" || cwd=""
[ -n "$cwd" ] || cwd="$PWD"

# Per-call override — allow regardless of tree state.
case "$cmd" in
  *DEVAGENT_GIT_GUARD_OVERRIDE=1*) exit 0 ;;
esac

# 3. Dirty gate — only guard a DIRTY tree; a clean tree (or a git error) → allow,
#    since the reflexive commands can't lose work when there's nothing uncommitted.
status="$(git -C "$cwd" status --porcelain 2>/dev/null)" || exit 0
[ -n "$status" ] || exit 0

# 4. Deny shapes (verb-gated; each requires its git verb so `git diff -- f` etc. are
#    never caught). `(^|[^[:alnum:]_])git` = `git` as a word, not `mygit`.
deny=""
if printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])git[[:space:]]+checkout([[:space:]].*)?[[:space:]]--([[:space:]]|$)'; then
  deny="\`git checkout … -- <pathspec>\` discards working-tree changes to those paths"
elif printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])git[[:space:]]+restore([[:space:]]|$)'; then
  # restore is safe ONLY as index-only --staged (and not also --worktree).
  if printf '%s' "$cmd" | grep -qE '[[:space:]]--staged([[:space:]]|=|$)' \
     && ! printf '%s' "$cmd" | grep -qE '[[:space:]]--worktree([[:space:]]|=|$)'; then
    :   # `git restore --staged` only touches the index — allow.
  else
    deny="\`git restore\` discards working-tree changes"
  fi
elif printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])git[[:space:]]+stash([[:space:]]|$)' \
   && ! printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])git[[:space:]]+stash[[:space:]]+(pop|apply|list|show|drop|clear|branch|create|store)([[:space:]]|$)'; then
  deny="\`git stash\` hides uncommitted work (recover with \`git stash pop\`)"
elif printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])git[[:space:]]+clean([[:space:]]|$)' \
   && printf '%s' "$cmd" | grep -qE '([[:space:]]-[a-z]*f|[[:space:]]--force)'; then
  deny="\`git clean -f\` removes untracked files"
fi

[ -n "$deny" ] || exit 0

# 5. Confirmed deny.
{
  printf 'devagent git-guard: BLOCKED — %s, and the working tree is dirty.\n' "$deny"
  printf '  House rule: commit first — do not discard uncommitted work reflexively.\n'
  printf '  Override this one call:  DEVAGENT_GIT_GUARD_OVERRIDE=1 %s\n' "$cmd"
  printf '  Disable the guard:       set [defaults] git_guard = false (or unset it).\n'
} >&2
exit 2
