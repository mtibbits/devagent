#!/usr/bin/env bats
# #453: the hooks scaffold — shared conventions in hooks/lib/hook-common.sh that the
# guard children (#454/#455/#457) and the SessionStart child (#456) inherit. Pins the
# #352 contract at the SCAFFOLD level: opt-in default-off gate, per-call override,
# fail-open reads, and drift-parity of the generalized gate with git-guard.sh's
# reference gate.

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

@test "gate drift parity: hook-common and git-guard.sh share the anchored-strict gate (#453/#432)" {
  # Behavioral-equivalence-by-construction: both resolve a bool config gate with the
  # SAME anchored strictness (`= true` must be a literally bare line, trailing $).
  # git-guard hardcodes git_guard; hook_enabled generalizes the key — so pin that
  # BOTH carry the anchored `= true[[:space:]]*$` pattern (a bare-line requirement),
  # never a loose match a `# note` suffix would satisfy.
  run grep -cE 'true\[\[:space:\]\]\*\$' "$REPO/hooks/git-guard.sh"
  [ "$output" -ge 1 ] || { echo "git-guard.sh lost its anchored-strict gate" >&2; return 1; }
  run grep -cE 'true\[\[:space:\]\]\*\$' "$LIB"
  [ "$output" -ge 1 ] || { echo "hook-common.sh lost its anchored-strict gate — drift from the #352 reference" >&2; return 1; }
}
