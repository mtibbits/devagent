#!/usr/bin/env bash
# hooks/commit-guard.sh — #455 PreToolUse commit-discipline guard. Denies a
# `git commit` that lacks a DCO sign-off (`-s`/`--signoff`), INCLUDING
# `git commit --amend` without `-s` (the recorded sign-off-drop failure). Fires ONLY
# when a devAgent issue is active for the resolved project AND the command's cwd is
# inside that project's source_dir — DCO is this operator's PER-PROJECT policy, not
# universal, so commits in unrelated repos pass. A signed `git commit -s` outside
# scripts/commit.sh is ALLOWED (ship.sh's #148 review/redmr-fix recovery path).
#
# CONTRACT (hook-common.sh): fail-OPEN (exit 0 allow / exit 2 deny); OPT-IN default-
# off via `commit_guard`; per-call override DEVAGENT_COMMIT_GUARD_OVERRIDE; STRING-
# MATCH only (a `-s` inside a quoted message under-matches → falsely ALLOWS, the safe
# direction; obfuscation is the accepted #352 KNOWN GAPS class). NO `set -e`.

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/hook-common.sh" 2>/dev/null || exit 0

hook_enabled commit_guard || exit 0
hook_overridden DEVAGENT_COMMIT_GUARD_OVERRIDE && exit 0

input="$(hook_read_input)"
cmd="$(hook_json_field "$input" 'tool_input.command')"
[ -n "$cmd" ] || exit 0

# Is `commit` the git SUBCOMMAND? `commit` must follow `git` and (optionally) git's
# global options only — so `git commit`, `git -C <dir> commit`, `git -c k=v commit`
# match, but `git log commit` (a ref named commit), `git commit-tree`, and a bare
# `echo commit` do NOT. Exotic globals before `commit` under-match → allow (safe).
printf '%s' "$cmd" | grep -qE '(^|[[:space:]])git[[:space:]]+((-C[[:space:]]+[^[:space:]]+|-c[[:space:]]+[^[:space:]]+|--git-dir=[^[:space:]]+|--work-tree=[^[:space:]]+)[[:space:]]+)*commit([[:space:]]|$)' || exit 0

# Already signed? `--signoff`, or a single-dash short-flag cluster containing a
# lowercase `s` (`-s`/`-sm`/`-ms`) — NOT `-S` (gpg-sign) nor `--message`/`--signoff`'s
# double-dash forms other than --signoff itself.
if printf '%s' "$cmd" | grep -qE '(--signoff|(^|[[:space:]])-[a-rt-z]*s[a-z]*([[:space:]]|=|$))'; then
  exit 0
fi

# Firing scope (per-project): active project + non-empty active_issue + cwd ⊂ source_dir.
proj="$(hook_active_project)"
[ -n "$proj" ] || exit 0
cfg="$(hook_home)/config.toml"
[ -f "$cfg" ] || exit 0
src="$(awk -F'"' -v p="$proj" '
  /^\[/ { inp = ($0 == "[project." p "]") }
  inp && $0 ~ /^[[:space:]]*source_dir[[:space:]]*=/ { print $2; exit }
' "$cfg" 2>/dev/null || true)"
[ -n "$src" ] || exit 0

cwd="$(hook_json_field "$input" 'cwd')"
case "$cwd" in
  "$src"|"$src"/*) : ;;   # inside the active project's tree
  *) exit 0 ;;             # unrelated repo / no cwd → allow (per-project policy)
esac

active_issue="$(awk -F'"' '/^active_issue[[:space:]]*=/{print $2; exit}' \
  "$(hook_home)/state/${proj}.toml" 2>/dev/null || true)"
[ -n "$active_issue" ] || exit 0   # no active issue → not enforcing

# In scope, git commit, unsigned → deny.
printf 'devAgent commit-guard: this `git commit` in %s (active issue %s) has no DCO sign-off.\n' "$src" "$active_issue" >&2
printf 'Re-run with `-s` — devAgent requires `git commit -s` (a `--amend` must also carry -s; amending drops the trailer otherwise).\n' >&2
printf 'Override this single call: DEVAGENT_COMMIT_GUARD_OVERRIDE=1\n' >&2
exit 2
