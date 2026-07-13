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

# --- Bash: deny only a raw write whose TARGET is the pointer, EXCEPT the deliberate
# writer. The write must actually target `_active.toml` (basename-exact, end-anchored
# so `_active.toml.bak`/`.tmp` sidecars are exempt) — a READ that merely mentions the
# pointer, or writes ELSEWHERE (`cat PTR 2>/dev/null`, `grep x PTR > out.txt`), passes.
cmd="$(hook_json_field "$input" 'tool_input.command')"
if [ -n "$cmd" ]; then
  case "$cmd" in
    # The deliberate, documented writer is allowed through. Substring match — an
    # accidental agent edit is the threat model, not an adversary crafting a
    # `# use.sh` comment to evade (the accepted #352 KNOWN-GAPS class).
    *use.sh*|*"devagent use "*|*"devagent:use"*) : ;;
    *)
      # (a) a redirection (`>`/`>>`) whose target token's basename is exactly
      #     `_active.toml`; (b) an in-place/copy writer (sed -i / tee / cp / mv / dd /
      #     truncate) naming the pointer (basename-exact, end-anchored). `2>/dev/null`
      #     and `> some_other_file` never match (a); a plain read never matches (b).
      # PTR = pointer basename, end-anchored (next char ∈ space/EOL/;|&/redir or none).
      PTR='(^|/)_active\.toml($|[[:space:]]|[;|&<>])'
      if printf '%s' "$cmd" | grep -qE '>>?[[:space:]]*([^[:space:]<>|&;]*/)?_active\.toml($|[[:space:]]|[;|&])'; then
        _deny                                   # (a) redirect TO the pointer
      fi
      if printf '%s' "$cmd" | grep -qE "$PTR" \
         && printf '%s' "$cmd" | grep -qE '(sed[[:space:]]+[^|;&]*-[a-zA-Z]*i|(^|[[:space:]])(tee|cp|mv|dd|truncate)[[:space:]])'; then
        _deny                                   # (b) writer command naming the pointer
      fi
      ;;
  esac
fi

exit 0
