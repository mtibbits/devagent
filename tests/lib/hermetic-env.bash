# tests/lib/hermetic-env.bash — central test-hermeticity guard (#322).
#
# A single developer-shell export (or a hostile global gitconfig / TZ / locale)
# must not fail the suite. This runs on SOURCE (top-level, not a function) and is
# sourced by every setup layer + bare-setup bats file, so it fires per-test (bats
# sources `load` files in each @test's subprocess) before setup and the body —
# whatever setup path a test uses. Idempotent: safe to source from multiple
# layers (defense-in-depth).
#
# Boundary (#322): this is only the shared guard. Merging the setup layers is
# child #335 — which will collapse the per-layer source lines to one.

unset DEVAGENT_ACTIVE_PROJECT DEVAGENT_ACTIVE_ISSUE DEVAGENT_SUITE_JOBS   # #240 session pins; #593 one-run jobs override
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null # hostile ~/.gitconfig (e.g. commit.gpgsign)
export TZ=UTC LC_ALL=C.UTF-8                                   # TZ / locale drift (C.UTF-8: deterministic + UTF-8-safe)
