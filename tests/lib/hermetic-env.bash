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
# #731: cleanup runs the transcript archiver, which reads ${CLAUDE_CONFIG_DIR:-~/.claude}
# and ${DA_HOME}/config.toml. An inherited DA_HOME would archive fixture transcripts
# into the operator's real archive, an inherited CLAUDE_CONFIG_DIR the operator's
# real transcripts. Cleared ONCE per test shell (the file-scope source, before setup):
# a test body that loads a harness re-sources this guard after setup exported its own
# tmp DA_HOME / CLAUDE_CONFIG_DIR, and those must survive (next.bats #782 leg).
if [ -z "${_DEVAGENT_HERMETIC_HOMES:-}" ]; then
  unset CLAUDE_CONFIG_DIR DA_HOME
  _DEVAGENT_HERMETIC_HOMES=1   # not exported: each test shell clears its own inherited values
fi
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
# #713: a trust policy on the suite host turns trust on for any fixture whose
# repo it covers, and its identity checks would call the real forge. The
# candidates are scripts/lib/trust.sh's TRUST_SYSTEM_DIRS plus the user
# location; keep the two lists in step.
for _trust_loc in /etc/devagent/trust /c/ProgramData/devagent/trust "$HOME/.config/devagent/trust"; do
  if [ -e "$_trust_loc/policy.toml" ] || [ -L "$_trust_loc/policy.toml" ]; then
    echo "suite host carries a trust policy at $_trust_loc/policy.toml; run the suite where none exists" >&2
    unset _trust_loc
    return 1
  fi
done
unset _trust_loc
