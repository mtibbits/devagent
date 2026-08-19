#!/usr/bin/env bats
# #466 scripts/lib/python-interp.sh — the resolver both run-suite.sh and born-red.sh
# use. Each arm gets its own test: the review mutation-tested the shipped code by
# SWAPPING the primary and fallback arms and the whole suite stayed green, because no
# fixture had a primary tree without .venv and a fallback tree with one. The mode the
# fallback exists for (use_worktree = true) is latent and unused, and an untested arm
# is how it stays wrong.
load 'helpers/common'

setup() {
    devagent_test_setup
    PRIMARY="$DEVAGENT_TMP/primary"; FALLBACK="$DEVAGENT_TMP/fallback"
    mkdir -p "$PRIMARY" "$FALLBACK"
    unset DEVAGENT_PYTEST_PYTHON
}
teardown() { devagent_test_teardown; }

_mkvenv() { mkdir -p "$1/.venv/bin"; printf '#!/usr/bin/env bash\n' > "$1/.venv/bin/python"; chmod +x "$1/.venv/bin/python"; }
_resolve() {
    PYTHON_INTERP=""
    # shellcheck source=/dev/null
    . "$DEVAGENT_ROOT/scripts/lib/python-interp.sh"
    python_interp_resolve "$@"
}

@test "python_interp_resolve: DEVAGENT_PYTEST_PYTHON wins over both trees (#466)" {
    _mkvenv "$PRIMARY"; _mkvenv "$FALLBACK"
    DEVAGENT_PYTEST_PYTHON=/custom/python
    _resolve "$PRIMARY" "$FALLBACK"
    [ "$PYTHON_INTERP" = "/custom/python" ]
}

@test "python_interp_resolve: the PRIMARY tree's venv wins over the fallback's (#466)" {
    _mkvenv "$PRIMARY"; _mkvenv "$FALLBACK"
    _resolve "$PRIMARY" "$FALLBACK"
    [ "$PYTHON_INTERP" = "$PRIMARY/.venv/bin/python" ]
}

@test "python_interp_resolve: falls back to the second tree's venv — the use_worktree case (#466)" {
    # THE load-bearing arm: a virtualenv is untracked, so `git worktree add` never
    # reproduces it. The measured tree legitimately has none while source_dir does.
    _mkvenv "$FALLBACK"          # primary deliberately has no .venv
    _resolve "$PRIMARY" "$FALLBACK"
    [ "$PYTHON_INTERP" = "$FALLBACK/.venv/bin/python" ]
}

@test "python_interp_resolve: neither tree has a venv → ambient python3 (#466)" {
    _resolve "$PRIMARY" "$FALLBACK"
    [ "$PYTHON_INTERP" = "python3" ]
}

@test "python_interp_resolve: a one-argument call never consults a fallback (#466)" {
    _mkvenv "$FALLBACK"
    _resolve "$PRIMARY"
    [ "$PYTHON_INTERP" = "python3" ]
}

@test "python_interp_resolve: a NON-EXECUTABLE .venv/bin/python is not selected (#466)" {
    mkdir -p "$PRIMARY/.venv/bin"; printf '#!/usr/bin/env bash\n' > "$PRIMARY/.venv/bin/python"
    chmod -x "$PRIMARY/.venv/bin/python"
    _mkvenv "$FALLBACK"
    _resolve "$PRIMARY" "$FALLBACK"
    [ "$PYTHON_INTERP" = "$FALLBACK/.venv/bin/python" ]
}

@test "python_interp_resolve: an EMPTY DEVAGENT_PYTEST_PYTHON falls through, not to an empty command (#466)" {
    _mkvenv "$PRIMARY"
    DEVAGENT_PYTEST_PYTHON=""
    _resolve "$PRIMARY" "$FALLBACK"
    [ "$PYTHON_INTERP" = "$PRIMARY/.venv/bin/python" ]
}
