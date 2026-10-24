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

unset DEVAGENT_ACTIVE_PROJECT DEVAGENT_ACTIVE_ISSUE DEVAGENT_SUITE_JOBS DEVAGENT_FETCH_TIMEOUT DEVAGENT_BC_MAX_PAGES BC_MAX_PAGES   # #240 session pins; #593 one-run jobs override; #660 one-run fetch bound; #774 paging cap
# #710: the per-stage tracker overrides are process-global (every project's
# transition writes them), so an operator shell must not leak one into a test;
# the three retired names too, and the ambient DEVAGENT_PROJECT the backends no
# longer read on the transition path. A test that needs one sets it itself.
unset DEVAGENT_PROJECT \
  DEVAGENT_GITHUB_LABEL_ON_DRAFT_START DEVAGENT_GITHUB_LABEL_ON_SHIP DEVAGENT_GITHUB_LABEL_ON_MERGE \
  DEVAGENT_GITLAB_LABELS_ON_DRAFT_START DEVAGENT_GITLAB_LABELS_ON_SHIP DEVAGENT_GITLAB_LABELS_ON_MERGE \
  DEVAGENT_JIRA_STAGE_ON_DRAFT_START DEVAGENT_JIRA_STAGE_ON_SHIP DEVAGENT_JIRA_STAGE_ON_MERGE \
  DEVAGENT_GITLAB_LABEL_NAMESPACE DEVAGENT_GITHUB_LABEL_IN_PROGRESS DEVAGENT_GITLAB_LABELS_IN_PROGRESS
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null # hostile ~/.gitconfig (e.g. commit.gpgsign)
export TZ=UTC LC_ALL=C.UTF-8                                   # TZ / locale drift (C.UTF-8: deterministic + UTF-8-safe)
