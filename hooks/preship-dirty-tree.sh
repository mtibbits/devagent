#!/usr/bin/env bash
# hooks/preship-dirty-tree.sh — #457 PostToolUse (command-type, NOT Stop, NOT
# prompt-type) hook. After a ship invocation, surfaces UNTRACKED files in the issue
# worktree — the mechanized "git-add NEW files or an empty PR ships" catch. ship.sh's
# #148 gate hard-blocks dirty TRACKED state but EXCLUDES untracked (`grep -cv '^??'`);
# this hook adds exactly that excluded class and NOTHING else (#148 stays the
# authority for tracked state). The ship already ran — this never blocks it, it makes
# a stranded untracked file visible.
#
# CONTRACT (hook-common.sh): OPT-IN default-off via `preship_dirty_tree`; per-call
# override DEVAGENT_PRESHIP_DIRTY_TREE_OVERRIDE; fail-OPEN (any error / no worktree /
# nothing untracked → exit 0). SURFACE = exit 2 with the file list on stderr (the
# PostToolUse feedback channel). Fires at most once per identical untracked state.
# STRING-MATCH only (#352 KNOWN GAPS). NO `set -e`.

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/hook-common.sh" 2>/dev/null || exit 0

hook_enabled preship_dirty_tree || exit 0
hook_overridden DEVAGENT_PRESHIP_DIRTY_TREE_OVERRIDE && exit 0

input="$(hook_read_input)"
cmd="$(hook_json_field "$input" 'tool_input.command')"
[ -n "$cmd" ] || exit 0
# Only when ship.sh is the PROGRAM being run (a Bash-TOOL ship: `bash .../ship.sh`,
# `sh …ship.sh`, or a direct `…/ship.sh`) — NOT when it is merely an argument
# (`cat/vim/git diff …/ship.sh`), which would over-fire the advisory. NOTE: until
# #452, `/devagent:ship` bang-EXECUTED ship.sh (`!\`bash …ship.sh\``) — command
# expansion, not a Bash tool call — so PostToolUse could not see it. ship is now a
# skill whose body has no `!` line, so the operator-typed path runs through the Bash
# TOOL and IS seen. Still unseen: the `--auto` chain, which execs scripts/ship.sh
# in-process via next.sh rather than through the tool.
_is_ship() {
  # ship.sh at a command-segment start (optional path prefix), OR right after an
  # interpreter (bash/sh/exec/source) preceded by start/space/separator.
  printf '%s' "$1" | grep -qE '(^|[;&|][[:space:]]*)([^[:space:];&|]*/)?ship\.sh([[:space:]]|$)' && return 0
  printf '%s' "$1" | grep -qE '(^|[[:space:]]|[;&|])(bash|sh|exec|source)[[:space:]]+([^[:space:];&|]*/)?ship\.sh([[:space:]]|$)'
}
_is_ship "$cmd" || exit 0

# Worktree: the ship's cwd if it is a git repo, else the active project's source_dir
# (mirrors ship.sh's work_dir scoping). Files outside the worktree are never reported
# by `git status --porcelain`.
cwd="$(hook_json_field "$input" 'cwd')"
wt=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  wt="$cwd"
else
  proj="$(hook_active_project)"
  if [ -n "$proj" ]; then
    cfg="$(hook_home)/config.toml"
    wt="$(awk -F'"' -v p="$proj" '
      /^\[/ { inp = ($0 == "[project." p "]") }
      inp && $0 ~ /^[[:space:]]*source_dir[[:space:]]*=/ { print $2; exit }
    ' "$cfg" 2>/dev/null || true)"
  fi
fi
[ -n "$wt" ] && git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Untracked ONLY (`^??`). NEVER `--ignored`, so .gitignore'd build/scratch paths are
# never listed. Empty → nothing to surface.
untracked="$(git -C "$wt" status --porcelain 2>/dev/null | grep '^??' || true)"
[ -n "$untracked" ] || exit 0

# Fire at most once per identical (state × worktree). The marker lives in THIS
# worktree's .git dir (so two worktrees never collide — the #457-review $wt bug), and
# the fingerprint is HEAD-sha + untracked-set (so a NEW commit or a changed untracked
# set re-surfaces — an actual state change is never permanently suppressed; only an
# exact-identical repeat within the same state is quiet, per the "at most once" AC).
head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo '?')"
fp="${head}:$(printf '%s' "$untracked" | md5sum 2>/dev/null | awk '{print $1}')"
gitdir="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null || true)"
[ -n "$gitdir" ] || exit 0
marker="${gitdir}/devagent-preship-nag"
[ "$(cat "$marker" 2>/dev/null || true)" = "$fp" ] && exit 0
printf '%s' "$fp" > "$marker" 2>/dev/null || true

n="$(printf '%s\n' "$untracked" | grep -c . )"
{
  printf 'devAgent preship-dirty-tree: %d UNTRACKED file(s) in the issue worktree at ship — ship.sh (#148) gates TRACKED state only, not untracked, so a new file may have shipped un-added / an empty PR may have gone out:\n' "$n"
  printf '%s\n' "$untracked"
  printf 'If any is a real source file, `git add` + `git commit -s` it and re-ship; else ignore (or add to .gitignore). Silence one attempt: DEVAGENT_PRESHIP_DIRTY_TREE_OVERRIDE=1\n'
} >&2
exit 2
