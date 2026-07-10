#!/usr/bin/env bats
# #352: the opt-in git-reflex guard PreToolUse hook. Drive hooks/git-guard.sh
# directly with the tool-use JSON on stdin (exit 2 = deny, exit 0 = allow).
load 'helpers/common'

HOOK() { echo "$DEVAGENT_ROOT/hooks/git-guard.sh"; }

# Emit the PreToolUse JSON for a command, cwd = the (dirty/clean) test repo.
_json() {
  printf '{"tool_input":{"command":%s},"cwd":"%s"}' \
    "$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$SOURCE_DIR"
}
setup() {
  devagent_test_setup
  export DA_HOME="$HOME/.claude/devagent"          # the hook reads $DA_HOME/config.toml
  # a committed base so the tree can be made dirty/clean deterministically
  ( cd "$SOURCE_DIR" && git checkout -q -b work 2>/dev/null || true
    echo base > guarded.txt && git add guarded.txt \
    && git -c user.email=t@t -c user.name=t commit -q -m base )
}
teardown() { devagent_test_teardown; }

_on()    { devagent_config_set_bool "$HOME/.claude/devagent/config.toml" defaults.git_guard true; }
_dirty() { ( cd "$SOURCE_DIR" && echo change >> guarded.txt ); }
_clean() { ( cd "$SOURCE_DIR" && git checkout -q -- . && git clean -qfd ); }
# feed JSON to the hook, capture exit code into $status ($1 = the git command)
_run() { run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(_json "$1")" "$(HOOK)"; }

@test "guard ON + DIRTY: denies the five reflexive shapes (#352 AC)" {
  _on; _dirty
  for c in "git checkout HEAD -- guarded.txt" "git stash" "git stash push" "git restore guarded.txt" "git clean -fd"; do
    _run "$c"
    [ "$status" -eq 2 ] || { echo "expected DENY(2) for: $c (got $status)"; false; }
  done
}

@test "guard ON + DIRTY: the deny message names the house rule + the override" {
  _on; _dirty
  run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(_json 'git stash')" "$(HOOK)"
  [ "$status" -eq 2 ]
  [[ "$output" == *"commit first"* ]]
  [[ "$output" == *"DEVAGENT_GIT_GUARD_OVERRIDE=1"* ]]
}

@test "guard ON + CLEAN tree: the same shapes are ALLOWED (nothing to lose)" {
  _on; _clean
  for c in "git checkout HEAD -- guarded.txt" "git stash" "git restore guarded.txt" "git clean -fd"; do
    _run "$c"
    [ "$status" -eq 0 ] || { echo "expected ALLOW(0) on clean for: $c (got $status)"; false; }
  done
}

@test "guard ON + DIRTY: recovery + safe forms ALLOWED (stash pop, --staged, checkout branch, clean -n)" {
  _on; _dirty
  for c in "git stash pop" "git stash show" "git restore --staged guarded.txt" "git checkout main" "git clean -n" "git diff -- guarded.txt"; do
    _run "$c"
    [ "$status" -eq 0 ] || { echo "expected ALLOW(0) for: $c (got $status)"; false; }
  done
}

@test "guard ON + DIRTY: the override prefix ALLOWS the call" {
  _on; _dirty
  _run "DEVAGENT_GIT_GUARD_OVERRIDE=1 git stash"
  [ "$status" -eq 0 ]
}

@test "guard OFF (default): no behavior change — every shape allowed" {
  _dirty                                            # guard NOT enabled
  for c in "git stash" "git checkout HEAD -- guarded.txt" "git clean -fd" "git restore guarded.txt"; do
    _run "$c"
    [ "$status" -eq 0 ] || { echo "expected ALLOW(0) when OFF for: $c (got $status)"; false; }
  done
}

@test "guard ON: an injected hook error (garbage/empty stdin) FAILS OPEN (exit 0)" {
  _on; _dirty
  run bash -c 'printf "not json" | bash "$1"' _ "$(HOOK)"
  [ "$status" -eq 0 ]
  run bash -c 'printf "" | bash "$1"' _ "$(HOOK)"
  [ "$status" -eq 0 ]
}

@test "guard: git_guard=true in a PROJECT section (not [defaults]) does NOT enable it" {
  # section-scoped read must match doctor's config_get_default (defaults only)
  printf '\n[project.other]\ngit_guard = true\n' >> "$HOME/.claude/devagent/config.toml"
  _dirty
  _run "git stash"
  [ "$status" -eq 0 ]
}
