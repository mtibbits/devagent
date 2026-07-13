#!/usr/bin/env bash
# hooks/lib/hook-common.sh — shared conventions for devAgent PreToolUse /
# SessionStart hooks (#453 scaffold). New hook scripts under hooks/ source this to
# inherit the #352 git-guard contract; git-guard.sh itself stays standalone (the
# reference implementation) and does NOT source this file.
#
# CONTRACT (every hook honors it):
#   - FAIL-OPEN. A PreToolUse hook exits 0 = allow, exit 2 = deny (stderr shown to
#     the user). A PostToolUse hook (#457) exits 0 = nothing, exit 2 = SURFACE the
#     stderr as feedback to the model — the tool has ALREADY run, so exit 2 never
#     blocks it. A SessionStart hook (#456) exits 0 and prints its stdout as context.
#     Whichever event: a hook BUG must NEVER brick the tool — EVERY error / uncertain
#     / unreadable path returns the fail-SAFE (allow / nothing); ONLY a confirmed
#     match denies-or-surfaces. Deliberately NO `set -e` in hooks.
#   - OPT-IN, DEFAULT-OFF. Each hook is gated by a `[defaults].<key>` /
#     `[project.<active>].<key>` config bool (see hook_enabled); absent/unreadable
#     ⇒ disabled. Enabling a hook never changes behavior for a session that has not
#     opted in.
#   - PER-CALL OVERRIDE. A single tool call bypasses a hook by setting its override
#     env (see hook_overridden), e.g. DEVAGENT_GIT_GUARD_OVERRIDE=1.
#   - STRING-MATCH ONLY. Hooks match the raw command string; `git -C <dir> …`,
#     aliases, `bash -c '…'`, variable indirection, and compound `a && cmd` can
#     evade (or rarely over-match). This obfuscation gap is ACCEPTED and DOCUMENTED
#     (the #352 KNOWN GAPS class) — a hook is a reflex backstop, not a sandbox.
#   - TIMEOUT. hooks.json sets a 5s per-hook timeout; a timed-out hook fails OPEN.
#
# LATENCY/NOISE BUDGET: every registered PreToolUse Bash hook spawns one process on
# EVERY Bash tool call (bounded by the 5s timeout each). Keep the stack small and
# each hook's fast path allocation-free (config-miss / non-match should return
# before any subprocess). See the spec "Hooks surface" section.

# hook_home — the devAgent state/config home (mirrors git-guard.sh's DA_HOME).
hook_home() { printf '%s\n' "${DA_HOME:-$HOME/.claude/devagent}"; }

# hook_active_project — resolve the active project the #433 way: the
# DEVAGENT_ACTIVE_PROJECT env pin FIRST (the box may pin it via settings.local.json),
# then the state/_active.toml pointer. Empty (unset) ⇒ defaults-only.
hook_active_project() {
  if [ -n "${DEVAGENT_ACTIVE_PROJECT:-}" ]; then
    printf '%s\n' "${DEVAGENT_ACTIVE_PROJECT}"
    return 0
  fi
  awk -F'"' '/^active_project[[:space:]]*=/{print $2; exit}' \
    "$(hook_home)/state/_active.toml" 2>/dev/null || true
}

# hook_enabled <config-key> — 0 (enabled) iff the opt-in gate is ON for the active
# project. A LITERALLY BARE `[project.<active>].<key> = true|false` overrides a bare
# `[defaults].<key> = true`; absent/false/unreadable ⇒ 1 (disabled, the fail-safe).
# The awk mirrors git-guard.sh's gate structure with the key generalized (a bare
# `<key> = true  # note` does NOT enable — anchored `$`, the #432 strictness). A
# behavioral-equivalence canary (tests/hooks-scaffold.bats) pins hook_enabled
# git_guard == git-guard.sh's inline gate so the two never diverge.
hook_enabled() {
  local key="$1" cfg proj
  cfg="$(hook_home)/config.toml"
  [ -f "$cfg" ] || return 1
  proj="$(hook_active_project)"
  # LITERAL key match (not a dynamic regex): split each line on its first `=` and
  # string-compare the trimmed LHS to the key, so a key containing a regex
  # metacharacter (`.`/`*`/`?`) cannot over-match a different line (the divergence
  # from git-guard's literal gate a dynamic-regex build would introduce). Bare-line
  # strictness preserved: the trimmed RHS must equal exactly `true`/`false` (a
  # `= true  # note` yields RHS `true  # note` ≠ `true`, so it does not enable — the
  # #432 anchored-`$` semantics, keeping parity with git-guard's reference gate).
  awk -v proj="$proj" -v key="$key" '
    /^\[/ {
      in_def  = ($0 == "[defaults]")
      in_proj = (proj != "" && $0 == "[project." proj "]")
    }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      eq = index(line, "=")
      if (eq > 0) {
        k = substr(line, 1, eq - 1); v = substr(line, eq + 1)
        sub(/[[:space:]]+$/, "", k); sub(/^[[:space:]]+/, "", v)
        if (k == key) {
          if      (v == "true"  && in_proj) { pv = 1; ps = 1 }
          else if (v == "false" && in_proj) { pv = 0; ps = 1 }
          else if (v == "true"  && in_def)  { dv = 1 }
        }
      }
    }
    END { exit((ps ? pv : dv) ? 0 : 1) }
  ' "$cfg" 2>/dev/null || return 1
}

# hook_overridden <env-var-name> — 0 iff the named per-call override env is set to a
# non-empty value. Lets a single tool call bypass a hook.
hook_overridden() {
  local name="$1"
  [ -n "${!name:-}" ]
}

# hook_read_input — echo the hook's stdin (the PreToolUse/SessionStart JSON),
# fail-open: empty string on any read error (a downstream parse of "" also fails
# open). Never returns non-zero for an empty read.
hook_read_input() {
  cat 2>/dev/null || true
}

# hook_json_field <json> <python-key-path> — extract a STRING tool_input field
# fail-open via python3 (available; jq not assumed). Mirrors git-guard's reference
# extract `jq -r '.tool_input.command // empty'`: a string value prints as-is; a
# null / missing / non-string value (number, bool, object, array) prints EMPTY — so
# a child's natural presence test `[ -n "$cmd" ]` treats a null/absent command as
# absent, and a container value never leaks a serialized blob into a deny match.
hook_json_field() {
  local json="$1" path="$2"
  # Script via -c (so stdin is free for the JSON); path via argv[1]. Fail-open.
  printf '%s' "$json" | python3 -c '
import json, sys
try:
    cur = json.load(sys.stdin)
    for part in sys.argv[1].split("."):
        cur = cur[part]
    if isinstance(cur, str):
        sys.stdout.write(cur)
except Exception:
    pass
' "$path" 2>/dev/null || true
}
