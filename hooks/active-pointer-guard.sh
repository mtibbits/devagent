#!/usr/bin/env bash
# hooks/active-pointer-guard.sh — #454 PreToolUse backstop. When the session carries
# a DEVAGENT_ACTIVE_PROJECT env pin, DENY out-of-band writes to the active-pointer
# file `_active.toml` — the model editing it directly via Write/Edit or raw bash,
# bypassing the resolver-gated scripts (next.sh/use.sh). Defense-in-depth, NOT a race
# fix: the script-layer write gate already shipped in #282. The deliberate writer
# `devagent use` (use.sh) is allowed through.
#
# CONTRACT (hook-common.sh): fail-OPEN (exit 0 allow / exit 2 deny); OPT-IN
# default-off via `active_pointer_guard`; per-call override
# DEVAGENT_ACTIVE_POINTER_GUARD_OVERRIDE; STRING-MATCH only (in-script pointer writes
# and obfuscated bash are invisible — the #352 KNOWN GAPS class). NO `set -e`.

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/hook-common.sh" 2>/dev/null || exit 0

hook_enabled active_pointer_guard || exit 0          # opt-in default-off
[ -n "${DEVAGENT_ACTIVE_PROJECT:-}" ] || exit 0       # ONLY under an env pin
hook_overridden DEVAGENT_ACTIVE_POINTER_GUARD_OVERRIDE && exit 0

input="$(hook_read_input)"

_deny() {
  printf 'devAgent active-pointer-guard: refusing an out-of-band write to _active.toml under the DEVAGENT_ACTIVE_PROJECT="%s" env pin.\n' "${DEVAGENT_ACTIVE_PROJECT}" >&2
  printf 'Switch projects with `devagent use <project>` (use.sh is the deliberate, resolver-gated writer).\n' >&2
  printf 'Override this single call: DEVAGENT_ACTIVE_POINTER_GUARD_OVERRIDE=1\n' >&2
  exit 2
}

# --- Write/Edit: the target file_path IS the pointer (basename exactly _active.toml).
fp="$(hook_json_field "$input" 'tool_input.file_path')"
case "$fp" in
  */_active.toml|_active.toml) _deny ;;
esac

# --- Bash: a raw write pattern targeting the pointer, EXCEPT the deliberate writer.
cmd="$(hook_json_field "$input" 'tool_input.command')"
if [ -n "$cmd" ]; then
  case "$cmd" in
    # the deliberate, documented writer is allowed through (use.sh / devagent use)
    *use.sh*|*"devagent use "*|*"devagent:use"*) : ;;
    *)
      # deny only when the command BOTH references the pointer file (basename
      # _active.toml, preceded by `/` or line-start so `foo_active.toml` is exempt)
      # AND carries a write verb — a read like `cat .../_active.toml` or
      # `grep x .../_active.toml` (no verb) passes. `>`/`>>` redirection, `sed -i`,
      # `tee`, `cp`/`mv`/`dd`/`truncate` cover the raw-write class; obfuscation is an
      # accepted KNOWN GAP (#352).
      if printf '%s' "$cmd" | grep -qE '(^|/)_active\.toml' \
         && printf '%s' "$cmd" | grep -qE '(>|sed[[:space:]]+-[a-zA-Z]*i|\b(tee|cp|mv|dd|truncate)[[:space:]])'; then
        _deny
      fi
      ;;
  esac
fi

exit 0
