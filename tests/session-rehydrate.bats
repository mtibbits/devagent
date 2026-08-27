#!/usr/bin/env bats
# #456: the SessionStart rehydration hook. Drives hooks/session-rehydrate.sh with
# SessionStart JSON on stdin; it prints where.sh's one-screen output when a project
# resolves, and is SILENT (zero output, exit 0) otherwise. The no-op path is
# load-bearing — SessionStart fires for every session in every repo.

REPO="${BATS_TEST_DIRNAME}/.."
HOOK="$REPO/hooks/session-rehydrate.sh"
# #585: bare-setup file (no `load`), so the #322 guard is sourced directly. Without it
# an ambient DEVAGENT_ACTIVE_ISSUE from the developer's shell reaches where.sh and
# silences the hook, reddening the two "PRINTS where.sh output" tests below.
. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

setup() {
  DA="$BATS_TEST_TMPDIR/da"; mkdir -p "$DA/state"
  export DA_HOME="$DA"
  # Deliberately redundant with the guard above: this file's third and fourth tests
  # assert the no-pointer branch, and the local statement of intent belongs here
  # rather than only in a distant shared file.
  unset DEVAGENT_ACTIVE_PROJECT
}
# one configured project 'acme' with the dirs where.sh needs; no active issue is fine
# (where.sh prints a valid "(none)" one-screen).
_one_project() {
  printf '[defaults]\nsession_rehydrate = true\n[project.acme]\nsource_dir = "%s"\ndevdoc_dir = "%s"\n' \
    "$BATS_TEST_TMPDIR/src" "$BATS_TEST_TMPDIR/dd" > "$DA/config.toml"
}
_feed() { run bash -c 'printf "%s" "$1" | bash "$2"' _ "${1:-\{\}}" "$HOOK"; }

@test "resolvable project (single configured) PRINTS where.sh output (#456)" {
  _one_project
  _feed '{}'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" == *"acme"* ]]
}

@test "resolvable project via env pin PRINTS where.sh output (#456)" {
  _one_project
  export DEVAGENT_ACTIVE_PROJECT=acme
  _feed '{}'
  [ "$status" -eq 0 ] && [ -n "$output" ]
}

@test "NO-OP: no project resolvable (zero configured, no pin/pointer) ⇒ ZERO output, exit 0 (#456)" {
  printf '[defaults]\nsession_rehydrate = true\n' > "$DA/config.toml"
  _feed '{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "NO-OP: multiple configured + no pin/pointer ⇒ ZERO output, exit 0 (#456)" {
  printf '[defaults]\nsession_rehydrate = true\n[project.a]\nsource_dir="/a"\n[project.b]\nsource_dir="/b"\n' > "$DA/config.toml"
  _feed '{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "where.sh error (project resolves but is unconfigured) ⇒ SILENT exit 0 (#456)" {
  printf '[defaults]\nsession_rehydrate = true\n[project.acme]\nsource_dir="/x"\n' > "$DA/config.toml"
  export DEVAGENT_ACTIVE_PROJECT=badproj   # pinned but not in config → where.sh dies
  _feed '{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "opt-in default-off: gate off ⇒ ZERO output, exit 0 (#456)" {
  printf '[project.acme]\nsource_dir="%s"\ndevdoc_dir="%s"\n' \
    "$BATS_TEST_TMPDIR/src" "$BATS_TEST_TMPDIR/dd" > "$DA/config.toml"   # session_rehydrate absent
  _feed '{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
