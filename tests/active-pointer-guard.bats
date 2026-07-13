#!/usr/bin/env bats
# #454: the PreToolUse active-pointer backstop. Drives hooks/active-pointer-guard.sh
# with PreToolUse JSON on stdin (exit 2 = deny, exit 0 = allow). Opt-in default-off,
# fires ONLY under a DEVAGENT_ACTIVE_PROJECT env pin; defense-in-depth over the #282
# script-layer gate.

REPO="${BATS_TEST_DIRNAME}/.."
HOOK="$REPO/hooks/active-pointer-guard.sh"

setup() {
  DA="$BATS_TEST_TMPDIR/da"; mkdir -p "$DA/state"
  export DA_HOME="$DA"
  printf '[defaults]\nactive_pointer_guard = true\n' > "$DA/config.toml"   # opt-in ON
  export DEVAGENT_ACTIVE_PROJECT=volk                                        # pinned
  unset DEVAGENT_ACTIVE_POINTER_GUARD_OVERRIDE
  PTR="$DA/state/_active.toml"
}

_write_json() { printf '{"tool_input":{"file_path":"%s","content":"x"}}' "$1"; }
_bash_json()  { printf '{"tool_input":{"command":%s}}' \
                 "$(printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"; }
_feed() { run bash -c 'printf "%s" "$1" | bash "$2"' _ "$1" "$HOOK"; }

@test "pinned: Write to _active.toml is DENIED, message names devagent use (#454)" {
  _feed "$(_write_json "$PTR")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"devagent use"* ]]
}

@test "pinned: Edit-shaped write (file_path) to _active.toml is DENIED (#454)" {
  _feed '{"tool_input":{"file_path":"/home/u/.claude/devagent/state/_active.toml","old_string":"a","new_string":"b"}}'
  [ "$status" -eq 2 ]
}

@test "pinned: raw-bash writes to the pointer are DENIED (#454)" {
  local c
  for c in "echo 'active_project = \"x\"' > $PTR" \
           "sed -i s/a/b/ $PTR" \
           "printf 'x' >> $PTR" \
           "tee $PTR <<<x"; do
    _feed "$(_bash_json "$c")"
    [ "$status" -eq 2 ] || { echo "expected DENY(2) for: $c (got $status)" >&2; false; }
  done
}

@test "pinned: the deliberate writer 'devagent use <other>' PASSES (#454)" {
  _feed "$(_bash_json "bash $REPO/scripts/use.sh someproj")"
  [ "$status" -eq 0 ]
  _feed "$(_bash_json "devagent use someproj")"
  [ "$status" -eq 0 ]
}

@test "pinned: a READ of the pointer PASSES, even with a redirection elsewhere (#454 redmr)" {
  # The write must TARGET the pointer; a read that mentions it — including one with a
  # stderr redirect (2>/dev/null) or one that writes RESULTS to a different file —
  # must pass (the redmr fail-closed BLOCKING).
  local c
  for c in "cat $PTR" \
           "grep active_project $PTR" \
           "cat $PTR 2>/dev/null" \
           "grep active_project $PTR > /tmp/matches.txt" \
           "diff $PTR /tmp/other 2>/dev/null" \
           "python3 -c 'print(open(\"$PTR\").read())'"; do
    _feed "$(_bash_json "$c")"
    [ "$status" -eq 0 ] || { echo "expected ALLOW(0) for read: $c (got $status)" >&2; false; }
  done
}

@test "pinned: precision — raw-bash writes to pointer SIDECARS are NOT denied (#454 review)" {
  # _active.toml.bak / .tmp / .swp are different files — end-anchored match exempts them.
  local c
  for c in "echo x > $PTR.bak" "sed -i s/a/b/ $PTR.tmp" "tee $PTR.swp <<<x"; do
    _feed "$(_bash_json "$c")"
    [ "$status" -eq 0 ] || { echo "expected ALLOW(0) for sidecar: $c (got $status)" >&2; false; }
  done
}

@test "pinned: precision — a DIFFERENT file 'foo_active.toml' is NOT denied (#454)" {
  _feed "$(_write_json "$DA/state/foo_active.toml")"
  [ "$status" -eq 0 ]
  _feed "$(_bash_json "echo x > $DA/state/foo_active.toml")"
  [ "$status" -eq 0 ]
}

@test "UNPINNED: with the env pin unset, all pointer writes are ALLOWED (guard silent) (#454)" {
  unset DEVAGENT_ACTIVE_PROJECT
  _feed "$(_write_json "$PTR")"
  [ "$status" -eq 0 ]
  _feed "$(_bash_json "sed -i s/a/b/ $PTR")"
  [ "$status" -eq 0 ]
}

@test "opt-in default-off: gate off ⇒ ALLOWED even when pinned (#454)" {
  printf '[defaults]\n' > "$DA/config.toml"   # active_pointer_guard absent
  _feed "$(_write_json "$PTR")"
  [ "$status" -eq 0 ]
}

@test "per-call override: DEVAGENT_ACTIVE_POINTER_GUARD_OVERRIDE bypasses the deny (#454)" {
  export DEVAGENT_ACTIVE_POINTER_GUARD_OVERRIDE=1
  _feed "$(_write_json "$PTR")"
  [ "$status" -eq 0 ]
}

@test "fail-open: malformed hook input is ALLOWED (#454)" {
  _feed 'not json at all'
  [ "$status" -eq 0 ]
}
