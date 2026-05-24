# Phase 9 → Phase 3 Coordination

Phase 9 introduces `depends_ship_preflight`, called by `ship.sh` before
opening an MR. Plan 3's executor should add the following block to
`scripts/ship.sh` immediately after argument parsing, before the call
to `code/<backend>.sh create-mr`:

```bash
# Phase 9: warn (or block under --strict-deps) when shipping an issue
# whose recorded dependencies have not yet been merged.
. "${DEVAGENT_LIB:-$(dirname "${BASH_SOURCE[0]}")/lib}/depends.sh"
STRICT_DEPS="${STRICT_DEPS:-0}"
if ! depends_ship_preflight "${PROJECT}" "${ACTIVE_ISSUE}" "${STRICT_DEPS}"; then
  exit 2
fi
```

Plan 3 must also:
- Accept a `--strict-deps` CLI flag and export `STRICT_DEPS=1` when set.
- Document the flag in `commands/ship.md`.

If Plan 9 lands after Plan 3: Plan 3's `. depends.sh` line will fail
until Plan 9 lands. Workaround during the gap: Plan 3 can wrap the
source in `[ -f ... ] && . ... || true` to keep ship.sh functional.

If Plan 9 lands before Plan 3: nothing to do — `scripts/lib/depends.sh`
is harmless on its own.

`/devagent:where` (Plan 2) should also call `depends_ship_preflight`
in warn-only mode when the active issue's next step is `ship`, so the
operator sees the warning at the planning stage. The exact insertion
point is up to Plan 2's executor; the function signature is stable.
