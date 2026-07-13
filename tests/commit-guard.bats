#!/usr/bin/env bats
# #455: the commit-discipline PreToolUse guard. Drives hooks/commit-guard.sh with
# PreToolUse JSON on stdin (exit 2 = deny, exit 0 = allow). Opt-in default-off; fires
# only for a `git commit` missing -s when an issue is active for the resolved project
# AND cwd is inside that project's source_dir.

REPO="${BATS_TEST_DIRNAME}/.."
HOOK="$REPO/hooks/commit-guard.sh"

setup() {
  DA="$BATS_TEST_TMPDIR/da"; mkdir -p "$DA/state"
  export DA_HOME="$DA"
  SRC="$BATS_TEST_TMPDIR/proj"; mkdir -p "$SRC"
  printf '[defaults]\ncommit_guard = true\n[project.acme]\nsource_dir = "%s"\n' "$SRC" > "$DA/config.toml"
  printf 'active_issue = "Issue-7"\n' > "$DA/state/acme.toml"
  export DEVAGENT_ACTIVE_PROJECT=acme
  unset DEVAGENT_COMMIT_GUARD_OVERRIDE
}
_j() { printf '{"tool_input":{"command":%s},"cwd":"%s"}' \
         "$(printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" "${2:-$SRC}"; }
_feed() { run bash -c 'printf "%s" "$1" | bash "$2"' _ "$1" "$HOOK"; }

@test "active tree: signed 'git commit -s' PASSES (#455)" {
  _feed "$(_j 'git commit -s -m fix')"; [ "$status" -eq 0 ]
  _feed "$(_j 'git commit -sm fix')";   [ "$status" -eq 0 ]
  _feed "$(_j 'git commit --signoff -m fix')"; [ "$status" -eq 0 ]
}

@test "active tree: unsigned 'git commit' is DENIED, message names -s (#455)" {
  _feed "$(_j 'git commit -m fix')"
  [ "$status" -eq 2 ]
  [[ "$output" == *"-s"* ]]
}

@test "active tree: 'git commit --amend' without -s is DENIED (sign-off drop) (#455)" {
  _feed "$(_j 'git commit --amend --no-edit')"; [ "$status" -eq 2 ]
  _feed "$(_j 'git commit --amend -s')";        [ "$status" -eq 0 ]
}

@test "'-S' (gpg-sign) is NOT a DCO sign-off → unsigned commit DENIED (#455)" {
  _feed "$(_j 'git commit -S -m fix')"; [ "$status" -eq 2 ]
}

@test "fused DCO+gpg cluster '-sS'/'-Ss' IS signed → PASSES (#455 redmr)" {
  # -s (DCO sign-off) + -S (gpg-sign) in one cluster is a genuinely SIGNED commit;
  # the mandatory lowercase `s` is present, so it must not be wrongly denied.
  _feed "$(_j 'git commit -sS -m fix')"; [ "$status" -eq 0 ]
  _feed "$(_j 'git commit -Ss -m fix')"; [ "$status" -eq 0 ]
  # but -S alone (no lowercase s) is still UNSIGNED → denied (guard against widening).
  _feed "$(_j 'git commit -Sm fix')"; [ "$status" -eq 2 ]
}

@test "'commit' as a ref/other subcommand is NOT a git commit (#455)" {
  for c in 'git log commit' 'git commit-tree abc' 'echo commit' 'git show commit'; do
    _feed "$(_j "$c")"
    [ "$status" -eq 0 ] || { echo "false-positive on: $c (status $status)" >&2; false; }
  done
}

@test "out of scope: commit in a repo OUTSIDE the active source_dir PASSES (#455)" {
  _feed "$(_j 'git commit -m fix' '/some/other/repo')"; [ "$status" -eq 0 ]
}

@test "out of scope: no active_issue ⇒ unsigned commit PASSES (#455)" {
  printf 'active_issue = ""\n' > "$DA/state/acme.toml"
  _feed "$(_j 'git commit -m fix')"; [ "$status" -eq 0 ]
}

@test "opt-in default-off: gate off ⇒ unsigned commit PASSES (#455)" {
  printf '[project.acme]\nsource_dir = "%s"\n' "$SRC" > "$DA/config.toml"   # commit_guard absent
  _feed "$(_j 'git commit -m fix')"; [ "$status" -eq 0 ]
}

@test "per-call override + fail-open: override / malformed input PASS (#455)" {
  export DEVAGENT_COMMIT_GUARD_OVERRIDE=1
  _feed "$(_j 'git commit -m fix')"; [ "$status" -eq 0 ]
  unset DEVAGENT_COMMIT_GUARD_OVERRIDE
  _feed 'not json'; [ "$status" -eq 0 ]
}

@test "-C global option: 'git -C <dir> commit' unsigned is DENIED (#455)" {
  _feed "$(_j "git -C $SRC commit -m fix")"; [ "$status" -eq 2 ]
}
