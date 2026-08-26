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

# A venv whose python CAN run pytest (arms 2 and 3 probe capability, not existence).
_mkvenv() {
    mkdir -p "$1/.venv/bin"
    printf '#!/usr/bin/env bash\ncase "$*" in *--version*) echo "pytest 9.0.0"; exit 0;; esac\nexit 0\n' \
        > "$1/.venv/bin/python"
    chmod +x "$1/.venv/bin/python"
}
# A venv that exists and is executable but CANNOT run pytest — the routine
# "application venv, pytest installed system-wide" shape.
_mkvenv_nopytest() {
    mkdir -p "$1/.venv/bin"
    printf '#!/usr/bin/env bash\necho "No module named pytest" >&2\nexit 1\n' > "$1/.venv/bin/python"
    chmod +x "$1/.venv/bin/python"
}
_resolve() {
    PYTHON_INTERP=""
    # shellcheck source=/dev/null
    . "$DEVAGENT_ROOT/scripts/lib/io.sh"          # die, used by the seam validation
    # shellcheck source=/dev/null
    . "$DEVAGENT_ROOT/scripts/lib/python-interp.sh"
    python_interp_resolve "$@"
}
# A real executable to point DEVAGENT_PYTEST_PYTHON at (it is validated, not probed).
_mkcustom() { printf '#!/usr/bin/env bash\nexit 0\n' > "$DEVAGENT_TMP/custom"; chmod +x "$DEVAGENT_TMP/custom"; }

@test "python_interp_resolve: DEVAGENT_PYTEST_PYTHON wins over both trees (#466)" {
    _mkvenv "$PRIMARY"; _mkvenv "$FALLBACK"; _mkcustom
    # shellcheck disable=SC2034  # read by python_interp_resolve in the sourced lib
    DEVAGENT_PYTEST_PYTHON="$DEVAGENT_TMP/custom"
    _resolve "$PRIMARY" "$FALLBACK"
    [ "$PYTHON_INTERP" = "$DEVAGENT_TMP/custom" ]
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
    # shellcheck disable=SC2034  # read by python_interp_resolve in the sourced lib
    DEVAGENT_PYTEST_PYTHON=""
    _resolve "$PRIMARY" "$FALLBACK"
    [ "$PYTHON_INTERP" = "$PRIMARY/.venv/bin/python" ]
}

@test "python_interp_resolve: a .venv that CANNOT run pytest falls through, not (error) (#466 redmr)" {
    # Existence is not capability. Selecting the first -x path turned a routine shape —
    # an application venv with pytest only system-wide — into an unshippable (error)
    # with no override, on a tree that measured fine before this branch.
    _mkvenv_nopytest "$PRIMARY"
    _resolve "$PRIMARY" "$FALLBACK"
    [ "$PYTHON_INTERP" = "python3" ]
}

@test "python_interp_resolve: a pytest-less PRIMARY venv falls through to a working FALLBACK (#466 redmr)" {
    _mkvenv_nopytest "$PRIMARY"; _mkvenv "$FALLBACK"
    _resolve "$PRIMARY" "$FALLBACK"
    [ "$PYTHON_INTERP" = "$FALLBACK/.venv/bin/python" ]
}

@test "python_interp_resolve: a non-executable DEVAGENT_PYTEST_PYTHON DIES naming it (#466 redmr)" {
    # An operator's explicit choice must surface as a named error, never silently fall
    # through to an interpreter they did not ask for — and never as a generic (error)
    # whose remedy tells them to set the variable they just set.
    _mkvenv "$PRIMARY"
    run bash -c ". '$DEVAGENT_ROOT/scripts/lib/io.sh'; . '$DEVAGENT_ROOT/scripts/lib/python-interp.sh'; DEVAGENT_PYTEST_PYTHON=/nonexistent/python python_interp_resolve '$PRIMARY' '$FALLBACK'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"/nonexistent/python"* ]]
    [[ "$output" == *"DEVAGENT_PYTEST_PYTHON"* ]]
}

@test "python_interp_resolve: an EXECUTABLE DEVAGENT_PYTEST_PYTHON is honoured unprobed (#466)" {
    # Honoured without a pytest-capability probe, so a broken choice fails loudly at the
    # run rather than being silently replaced.
    _mkvenv "$PRIMARY"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$DEVAGENT_TMP/custompy"; chmod +x "$DEVAGENT_TMP/custompy"
    # shellcheck disable=SC2034  # read by python_interp_resolve in the sourced lib
    DEVAGENT_PYTEST_PYTHON="$DEVAGENT_TMP/custompy"
    _resolve "$PRIMARY" "$FALLBACK"
    [ "$PYTHON_INTERP" = "$DEVAGENT_TMP/custompy" ]
}
