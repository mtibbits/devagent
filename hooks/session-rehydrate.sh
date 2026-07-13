#!/usr/bin/env bash
# hooks/session-rehydrate.sh — #456 SessionStart rehydration. Prints where.sh's
# one-screen "active issue + last/next step" as session context so a resumed session
# rehydrates automatically (no need to remember /devagent:catchup). Registered for
# SessionStart matchers `startup|resume|clear` (NOT `compact` — compaction already
# carries a summary). SessionStart fires for EVERY session in every repo, so the
# NO-OP path is load-bearing: no resolvable project, or a where.sh error, prints
# NOTHING and exits 0 — never injects noise into a non-devAgent session.
#
# CONTRACT (hook-common.sh): OPT-IN default-off via `session_rehydrate`; fail-silent
# (any error / no project → exit 0, no output). NO `set -e`.

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/hook-common.sh" 2>/dev/null || exit 0

hook_enabled session_rehydrate || exit 0

# Resolve the project: env pin → pointer (hook_active_project), else the
# single-configured-project fallback (exactly one [project.X]; 0 or >=2 → no resolve).
proj="$(hook_active_project)"
if [ -z "$proj" ]; then
  cfg="$(hook_home)/config.toml"
  if [ -f "$cfg" ]; then
    mapfile -t _projs < <(grep -oE '^\[project\.[^].]+\]' "$cfg" 2>/dev/null \
      | sed -E 's/^\[project\.(.*)\]$/\1/')
    [ "${#_projs[@]}" -eq 1 ] && proj="${_projs[0]}"
  fi
fi
[ -n "$proj" ] || exit 0   # nothing resolves → silent

# Wrap where.sh (unchanged). Any error (it dies without a project / on bad state) or
# empty output → silent exit 0; never leak stderr into the session.
where="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/where.sh"
[ -x "$where" ] || [ -f "$where" ] || exit 0
out="$(bash "$where" "$proj" 2>/dev/null)" || exit 0
[ -n "$out" ] || exit 0

printf 'devAgent — session rehydration (/devagent:catchup for the deep view):\n%s\n' "$out"
exit 0
