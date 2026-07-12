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
# DENY SHAPES (on a dirty tree): `git checkout … -- <pathspec>`; `git restore`
# (except index-only `--staged`); bare `git stash` / `git stash push`; `git clean
# -f`; `git reset --hard` (any arg position — #430); and the unprotected-pathspec
# checkout — `git checkout` with >=2 non-flag positional args and no `--` separator
# (#430, conservative: multi-ref false positives use the override; `-b`/`-B`/
# `--orphan` branch creation and single-arg forms always pass — a single positional
# cannot be distinguished from a branch switch, so `git checkout <file>` is an
# accepted work-wipe gap, not a git-protected safe pass).
#
# KNOWN GAPS (heuristic backstop, not a sandbox — all fail OPEN): it matches the raw
# command STRING, so `git -C <dir> …`, shell aliases, `bash -c '…'`, variable
# indirection, and compound `a && git stash` can evade (or, rarely, over-match) the
# match. The #430 no-`--` checkout shape widens the over-match surface slightly — a
# STRING merely containing `git checkout <w1> <w2>` (e.g. a commit message or echo
# referencing it) over-matches. The opt-in gate + the override are the intended escapes.

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

# 3. Shape-match FIRST (#431) — pure-bash string tests, no subprocess. The git
#    status subprocess (step 4) is the hot-path cost, so we confine it to the rare
#    deny-shaped command: match the shape here, and only THEN pay for a git status.
#    Every non-deny Bash call in a guarded session now skips git entirely.
#    (verb-gated; each requires its git verb so `git diff -- f` etc. are never
#    caught. `(^|[^[:alnum:]_])git` = `git` as a word, not `mygit`.)
#
# 3a. Fast reject — no `git` substring at all → no deny shape is possible (every
#     shape below requires a git verb). A pure case-glob (no subprocess), so the
#     overwhelming majority of Bash calls (which never mention git) exit here,
#     skipping BOTH the grep chain and the git status subprocess.
case "$cmd" in
  *git*) ;;
  *) exit 0 ;;
esac

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
elif printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])git[[:space:]]+reset([[:space:]]|$)' \
   && printf '%s' "$cmd" | grep -qE '[[:space:]]--hard([[:space:]]|$)'; then
  # #430: `git reset --hard` (any arg position) discards ALL uncommitted work.
  # `--soft`/`--mixed` (and default `git reset <path>` unstaging) touch no
  # worktree content, so they are NOT denied.
  deny="\`git reset --hard\` discards all uncommitted changes"
elif printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])git[[:space:]]+checkout([[:space:]]|$)'; then
  # #430: unprotected-pathspec checkout. `git checkout <ref> <pathspec>` with no
  # `--` separator overwrites <pathspec> in the worktree (the `--` form is caught
  # by the first branch above). ref-vs-path is undecidable from the string, so the
  # conservative rule: deny when there are >=2 non-flag positional args and no
  # `--` — accepting rare false positives on multi-ref forms (the override handles
  # them). A single positional (plain branch switch, which git itself refuses to
  # let clobber dirty files) always passes.
  co_args="$(printf '%s' "$cmd" | sed -E 's/^.*git[[:space:]]+checkout[[:space:]]*//')"
  co_args="${co_args%%;*}"; co_args="${co_args%%&&*}"; co_args="${co_args%%|*}"
  set -f                                    # no globbing while word-splitting args
  co_pos=0; co_ddash=0; co_newbranch=0
  for tok in $co_args; do
    case "$tok" in
      --) co_ddash=1; break ;;
      -b|-B|--orphan) co_newbranch=1 ;;     # branch CREATION — never a pathspec overwrite
      -*) : ;;                              # any other flag — not a positional
      *)  co_pos=$((co_pos + 1)) ;;
    esac
  done
  set +f
  # -b/-B/--orphan create a branch (carrying dirty changes forward), so the extra
  # positional is a start-point ref, not a pathspec — don't deny (#430 false-positive fix).
  if [ "$co_ddash" -eq 0 ] && [ "$co_newbranch" -eq 0 ] && [ "$co_pos" -ge 2 ]; then
    deny="\`git checkout <ref> <pathspec>\` (no \`--\`) overwrites those paths in the worktree"
  fi
fi

# No deny shape matched → allow WITHOUT touching git (the common hot path, #431).
[ -n "$deny" ] || exit 0

# 4. Dirty gate — a matched deny shape only loses work on a DIRTY tree; a clean
#    tree (or a git error) → allow. This `git status` subprocess now runs ONLY for
#    a deny-shaped command, not on every guarded Bash call (#431).
status="$(git -C "$cwd" status --porcelain 2>/dev/null)" || exit 0
[ -n "$status" ] || exit 0

# 5. Confirmed deny.
{
  printf 'devagent git-guard: BLOCKED — %s, and the working tree is dirty.\n' "$deny"
  printf '  House rule: commit first — do not discard uncommitted work reflexively.\n'
  printf '  Override this one call:  DEVAGENT_GIT_GUARD_OVERRIDE=1 %s\n' "$cmd"
  printf '  Disable the guard:       set [defaults] git_guard = false (or unset it).\n'
} >&2
exit 2
