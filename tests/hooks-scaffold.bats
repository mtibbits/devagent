#!/usr/bin/env bats
# #453: the hooks scaffold — shared conventions in hooks/lib/hook-common.sh that the
# guard children (#454/#455/#457) and the SessionStart child (#456) inherit. Pins the
# #352 contract at the SCAFFOLD level: opt-in default-off gate, per-call override,
# fail-open reads, and drift-parity of the generalized gate with git-guard.sh's
# reference gate.

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

REPO="${BATS_TEST_DIRNAME}/.."
LIB="$REPO/hooks/lib/hook-common.sh"

setup() {
  DA="$BATS_TEST_TMPDIR/da"
  mkdir -p "$DA/state"
  export DA_HOME="$DA"
  unset DEVAGENT_ACTIVE_PROJECT
  # shellcheck source=/dev/null
  source "$LIB"
}

_cfg() { printf '%s\n' "$1" > "$DA/config.toml"; }
_active() { printf 'active_project = "%s"\n' "$1" > "$DA/state/_active.toml"; }

@test "hook_enabled: default-off — no config key ⇒ disabled (#453)" {
  _cfg "[defaults]"
  run hook_enabled myguard
  [ "$status" -ne 0 ]
}

@test "hook_enabled: opt-in via [defaults] key = true (#453)" {
  _cfg $'[defaults]\nmyguard = true'
  run hook_enabled myguard
  [ "$status" -eq 0 ]
}

@test "hook_enabled: a non-bare line (trailing comment) does NOT enable (#432 strictness) (#453)" {
  _cfg $'[defaults]\nmyguard = true  # note'
  run hook_enabled myguard
  [ "$status" -ne 0 ]
}

@test "hook_enabled: [project.<active>] override wins over [defaults] (#453)" {
  _cfg $'[defaults]\nmyguard = true\n[project.volk]\nmyguard = false'
  _active volk
  run hook_enabled myguard
  [ "$status" -ne 0 ]   # project false beats defaults true
  _cfg $'[defaults]\n[project.volk]\nmyguard = true'
  run hook_enabled myguard
  [ "$status" -eq 0 ]   # project true, defaults absent
}

@test "hook_enabled: env pin resolves the active project over the pointer (#433) (#453)" {
  _cfg $'[defaults]\n[project.acme]\nmyguard = true'
  _active someoneelse
  export DEVAGENT_ACTIVE_PROJECT=acme
  run hook_enabled myguard
  [ "$status" -eq 0 ]
}

@test "hook_enabled: fail-open — unreadable/missing config ⇒ disabled (#453)" {
  export DA_HOME="$BATS_TEST_TMPDIR/nope"
  run hook_enabled myguard
  [ "$status" -ne 0 ]
}

@test "hook_overridden: 0 iff the named override env is non-empty (#453)" {
  unset MY_OVERRIDE
  run hook_overridden MY_OVERRIDE
  [ "$status" -ne 0 ]
  export MY_OVERRIDE=1
  run hook_overridden MY_OVERRIDE
  [ "$status" -eq 0 ]
}

@test "hook_read_input: echoes stdin and fails open on empty (#453)" {
  run bash -c "source '$LIB'; printf '%s' 'hello' | hook_read_input"
  [ "$status" -eq 0 ] && [ "$output" = "hello" ]
  run bash -c "source '$LIB'; hook_read_input < /dev/null"
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "hook_json_field: extracts a tool_input field, empty on garbage (#453)" {
  run bash -c "source '$LIB'; hook_json_field '{\"tool_input\":{\"command\":\"git status\"}}' 'tool_input.command'"
  [ "$output" = "git status" ]
  run bash -c "source '$LIB'; hook_json_field 'not json' 'tool_input.command'"
  [ -z "$output" ]
}

@test "hook_enabled: a regex-metachar key matches LITERALLY, not as a pattern (#453 redmr)" {
  # Guard against the dynamic-regex divergence: key `my.guard` must NOT match a
  # config line `myXguard = true` (the `.` must be literal, not any-char).
  _cfg $'[defaults]\nmyXguard = true'
  run hook_enabled 'my.guard'
  [ "$status" -ne 0 ] || { echo "hook_enabled over-matched a metachar key against a different line" >&2; return 1; }
  # And the exact key still enables.
  _cfg $'[defaults]\nmy.guard = true'
  run hook_enabled 'my.guard'
  [ "$status" -eq 0 ]
}

@test "hook_json_field: null/non-string extracts to EMPTY (mirrors jq // empty) (#453 redmr)" {
  run bash -c "source '$LIB'; hook_json_field '{\"tool_input\":{\"command\":null}}' 'tool_input.command'"
  [ -z "$output" ] || { echo "null command should extract empty, got: $output" >&2; return 1; }
  run bash -c "source '$LIB'; hook_json_field '{\"tool_input\":{\"command\":42}}' 'tool_input.command'"
  [ -z "$output" ]
  run bash -c "source '$LIB'; hook_json_field '{\"tool_input\":{}}' 'tool_input.command'"
  [ -z "$output" ]
}

@test "gate parity (DIFFERENTIAL): hook_enabled agrees with git-guard.sh's real gate (#453/#432)" {
  # The real behavioral-equivalence test: git-guard.sh DENIES a deny-shape on a dirty
  # tree iff its git_guard gate is ON, so its exit(2) is an observable of the gate.
  # Assert hook_enabled git_guard tracks git-guard's actual gate decision across
  # fixtures (not a grep for a shared token).
  local repo="$BATS_TEST_TMPDIR/gg"; mkdir -p "$repo"
  git -C "$repo" init -q >/dev/null
  ( cd "$repo" && echo base > f && git add f \
      && git -c user.email=t@t -c user.name=t commit -q -m base && echo dirty >> f )
  local GG="$REPO/hooks/git-guard.sh"
  # returns 0 iff git-guard denies (exit 2) a deny-shape on the dirty repo
  _gg_deny() {
    printf '{"tool_input":{"command":"git stash"},"cwd":"%s"}' "$repo" | bash "$GG"
    [ "$?" -eq 2 ]
  }
  local he gg fixture
  for fixture in \
    '[defaults]' \
    $'[defaults]\ngit_guard = true' \
    $'[defaults]\ngit_guard = true  # note'; do
    printf '%s\n' "$fixture" > "$DA/config.toml"
    if hook_enabled git_guard; then he=1; else he=0; fi
    if _gg_deny;            then gg=1; else gg=0; fi
    [ "$he" -eq "$gg" ] || { echo "gate divergence for fixture <<<$fixture>>>: hook_enabled=$he git-guard=$gg" >&2; return 1; }
  done
}
