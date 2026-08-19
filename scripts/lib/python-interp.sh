# scripts/lib/python-interp.sh — resolve the interpreter that can run a project's
# pytest suite (#466).
#
# WHY this exists: a Python project conventionally keeps its interpreter inside the
# tree, at `<tree>/.venv/bin/python`, and the AMBIENT `python3` there cannot import
# pytest. Two scripts invoke pytest and both got this wrong in the same way:
#   run-suite.sh recorded "0 passed" for a 51-test suite (factor-ai Issue-9), and
#   born-red.sh read the resulting non-zero exit as "this test is RED at baseline",
#   so every new test classified baseline=RED and the gate passed VACUOUSLY.
# One fact, two homes — so it is resolved once, here (register Issue-82: a pattern with
# N consumers is fixed at the SOURCE, with all N enumerated up front).
#
# The FALLBACK tree argument is what makes this correct under `use_worktree = true`: a
# virtualenv is untracked, so `git worktree add` never reproduces it, and the measured
# tree legitimately has none while source_dir does. Pinning to a single path spelling
# was wrong in exactly the mode #571 built.
#
# SETTER-GLOBAL, never `$( … )` — the same convention as utf8_locale_resolve and
# active_tree_resolve (register Issue-282/Issue-120). Call it bare.
#
# shellcheck shell=bash

# python_interp_resolve <primary_tree> [<fallback_tree>]
#
# Sets PYTHON_INTERP (setter-global). Resolution order, first hit wins:
#   1. $DEVAGENT_PYTEST_PYTHON — the DEVAGENT_<TOOL> seam every other external tool in
#      this repo has (DEVAGENT_GIT, DEVAGENT_GH, DEVAGENT_CMAKE, analyze-static's
#      DEVAGENT_PYTHON). Without it an unsupported layout (`venv/`, `.venv/Scripts/`,
#      conda, uv, pyenv) would be UNSHIPPABLE rather than merely unsupported, because
#      run-suite's `(error)` verdict has no bypass by design. The seam names a WORKING
#      interpreter; it cannot silence that verdict, so fail-closed is unweakened.
#   2. <primary_tree>/.venv/bin/python   — the measured tree's own venv.
#   3. <fallback_tree>/.venv/bin/python  — for an ephemeral/linked worktree (above).
#   4. python3                           — ambient; the pre-#466 behaviour.
#
# Deliberately only the `.venv/` spelling is probed. Broadening the search list is a
# follow-up; the seam above already covers every other layout, and an unfound
# interpreter is no longer silent — run-suite records `pytest: (error)` and born-red
# dies, rather than either recording a false zero.
python_interp_resolve() {
  local primary="${1:-}" fallback="${2:-}"
  if [ -n "${DEVAGENT_PYTEST_PYTHON:-}" ]; then
    # shellcheck disable=SC2034  # PYTHON_INTERP is the return channel, not a local
    PYTHON_INTERP="$DEVAGENT_PYTEST_PYTHON"
    return 0
  fi
  if [ -n "$primary" ] && [ -x "$primary/.venv/bin/python" ]; then
    # shellcheck disable=SC2034  # return channel (see CONTRACT above)
    PYTHON_INTERP="$primary/.venv/bin/python"
    return 0
  fi
  if [ -n "$fallback" ] && [ -x "$fallback/.venv/bin/python" ]; then
    # shellcheck disable=SC2034  # return channel (see CONTRACT above)
    PYTHON_INTERP="$fallback/.venv/bin/python"
    return 0
  fi
  # shellcheck disable=SC2034  # return channel (see CONTRACT above)
  PYTHON_INTERP=python3
}
