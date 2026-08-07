#!/usr/bin/env bats
# #572: active_resolve_project_try / active_context_project / active_guard_scope
load 'helpers/common'

setup() {
  devagent_test_setup
  # second project + pointer on B; no git repo — nothing in this file runs
  # git against projB (born-red no-ops at its born_red gate first)
  devagent_fixture_projB
  LIB="$BATS_TEST_DIRNAME/../scripts/lib"
}
teardown() { devagent_test_teardown; }

_src() { echo ". '$LIB/paths.sh'; . '$LIB/io.sh'; . '$LIB/config.sh'; . '$LIB/state.sh'; . '$LIB/active.sh'"; }

@test "try: sets BOTH project and source in the CALLING shell (#572)" {
  run bash -c "$(_src); active_resolve_project_try ''; echo \"\$ACTIVE_RESOLVED_PROJECT/\$ACTIVE_RESOLVED_FROM\""
  [ "$status" -eq 0 ]
  [ "$output" = "projB/pointer" ]
}

@test "try: an arg resolves as FROM=arg (#572)" {
  run bash -c "$(_src); active_resolve_project_try '$TEST_PROJECT'; echo \"\$ACTIVE_RESOLVED_FROM\""
  [ "$output" = "arg" ]
}

@test "try: a 2+-project fallback does NOT kill the caller (#572 U3)" {
  rm -f "$HOME/.claude/devagent/state/_active.toml"
  # `type` preamble: a missing function must redden this test, not vacuously
  # green it via a swallowed 127 (register: Issue-316)
  run bash -c "$(_src); type active_resolve_project_try >/dev/null 2>&1 || exit 99; set -e; active_resolve_project_try '' 2>/dev/null || true; echo AFTER=\$ACTIVE_RESOLVED_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AFTER="* ]]
}

@test "try: failure RE-EMITS the engine's stderr for unsuppressed sites (#572 U3 amendment)" {
  rm -f "$HOME/.claude/devagent/state/_active.toml"
  run bash -c "$(_src); active_resolve_project_try '' || true; :"
  [[ "$output" == *"projects configured"* ]]
}

@test "context: \$PWD inside a configured source_dir names that project (#572 U1/U2)" {
  run bash -c "cd '$SOURCE_DIR'; $(_src); active_context_project"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_PROJECT" ]
}

@test "context: a SUBDIRECTORY of source_dir still names the project (#572)" {
  mkdir -p "$SOURCE_DIR/a/b"
  run bash -c "cd '$SOURCE_DIR/a/b'; $(_src); active_context_project"
  [ "$output" = "$TEST_PROJECT" ]
}

@test "context: \$PWD under no configured source_dir returns 1, prints nothing (#572)" {
  run bash -c "cd '$DEVAGENT_TMP'; $(_src); active_context_project"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "guard: MISMATCH dies naming BOTH projects and BOTH issues (#572 AC2)" {
  run bash -c "cd '$SOURCE_DIR'; $(_src); active_resolve_project_try ''; active_guard_scope demo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"projB"*    ]]   # the resolved project
  [[ "$output" == *"Issue-9"*  ]]   # its issue
  [[ "$output" == *"$TEST_PROJECT"* ]]   # the project under work
  [[ "$output" == *"Issue-1"*  ]]   # the issue under work
  [[ "$output" == *"pointer"*  ]]   # where the resolution came from
  [[ "$output" == *"SCOPE MISMATCH"* ]]
}

@test "guard: an explicit arg is never guarded (#572 — FROM=arg)" {
  run bash -c "cd '$SOURCE_DIR'; $(_src); active_resolve_project_try 'projB'; active_guard_scope demo"
  [ "$status" -eq 0 ]
}

@test "guard: an ENV pin is guarded exactly like the pointer (#572 — env is not trusted)" {
  run bash -c "cd '$SOURCE_DIR'; export DEVAGENT_ACTIVE_PROJECT=projB; $(_src); active_resolve_project_try ''; active_guard_scope demo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"env"* ]]
}

@test "guard: agreeing context allows silently (#572)" {
  run bash -c "cd '$SOURCE_DIR'; export DEVAGENT_ACTIVE_PROJECT=$TEST_PROJECT; $(_src); active_resolve_project_try ''; active_guard_scope demo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guard: UNDETERMINED context allows but WARNS naming project AND source (#572 Q2 contract)" {
  run bash -c "cd '$DEVAGENT_TMP'; $(_src); active_resolve_project_try ''; active_guard_scope demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"projB"*   ]]   # the resolved project — REQUIRED
  [[ "$output" == *"pointer"* ]]   # its resolution source — REQUIRED
  [[ "$output" == *"Issue-9"* ]]   # its issue, when state names one
}

@test "guard: the UNDETERMINED warning names the ENV source when the pin resolved it (#572 Q2)" {
  run bash -c "cd '$DEVAGENT_TMP'; export DEVAGENT_ACTIVE_PROJECT=projB; $(_src); active_resolve_project_try ''; active_guard_scope demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"env"*   ]]
  [[ "$output" == *"projB"* ]]
}

@test "guard: an undecidable run is never SILENT — stderr is non-empty (#572 Q2)" {
  run bash -c "cd '$DEVAGENT_TMP'; $(_src); type active_guard_scope >/dev/null 2>&1 || exit 99; active_resolve_project_try ''; active_guard_scope demo 2>&1 1>/dev/null"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "guard: a FAILED config enumeration is loud, never a silent allow (#572 register Issue-314)" {
  printf '[[[ this is not toml' > "$HOME/.claude/devagent/config.toml"
  run bash -c "cd '$SOURCE_DIR'; export DEVAGENT_ACTIVE_PROJECT=projB; $(_src); active_resolve_project_try ''; active_guard_scope demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"enumeration"* ]]   # names the cause, not just "no project"
  [[ "$output" == *"projB"* ]]
  [[ "$output" == *"env"* ]]
}

@test "convention parity: --project flag and positional scope both resolve FROM=arg, neither guarded (#572 Task 6)" {
  # control: the BARE invocation from projA's tree with the pointer on projB
  # IS guarded — without this, the two allow-legs below prove nothing
  run bash -c "cd '$SOURCE_DIR'; bash '$LIB/../depends.sh' list"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCOPE MISMATCH"* ]]
  # flag convention: an explicit --project is FROM=arg -> never guarded
  run bash -c "cd '$SOURCE_DIR'; bash '$LIB/../depends.sh' --project projB list"
  [[ "$output" != *"SCOPE MISMATCH"* ]]
  # positional convention: same conditions, same bypass (born-red is an
  # opt-in no-op for a project without born_red=true, so rc 0 and quiet)
  run bash -c "cd '$SOURCE_DIR'; bash '$LIB/../born-red.sh' projB"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SCOPE MISMATCH"* ]]
}

@test "guard: DEVAGENT_SCOPE_GUARD_OVERRIDE=1 restores today's behavior (#572 opt-out)" {
  run bash -c "cd '$SOURCE_DIR'; export DEVAGENT_SCOPE_GUARD_OVERRIDE=1; $(_src); active_resolve_project_try ''; active_guard_scope demo"
  [ "$status" -eq 0 ]
}

@test "guard: an EMPTY or 0 override does NOT disable the guard (#572 — presence is not truth)" {
  # assert the TAG, not just rc != 0 — a missing function's 127 must not
  # vacuously green this at baseline (register: Issue-85 / born-red discipline)
  run bash -c "cd '$SOURCE_DIR'; export DEVAGENT_SCOPE_GUARD_OVERRIDE=; $(_src); active_resolve_project_try ''; active_guard_scope demo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCOPE MISMATCH"* ]]
  run bash -c "cd '$SOURCE_DIR'; export DEVAGENT_SCOPE_GUARD_OVERRIDE=0; $(_src); active_resolve_project_try ''; active_guard_scope demo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCOPE MISMATCH"* ]]
}
