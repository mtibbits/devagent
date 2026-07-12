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

# #433 flips the pre-#433 contract (a [project.*] git_guard was IGNORED). Now a
# [project.<active>] override enables the guard for THAT project only. active_project
# comes from state/_active.toml.
_set_active() { mkdir -p "$HOME/.claude/devagent/state"
  printf 'active_project = "%s"\n' "$1" > "$HOME/.claude/devagent/state/_active.toml"; }

@test "guard: [project.<active>] git_guard=true enables it for that project only (#433)" {
  printf '\n[project.risky]\ngit_guard = true\n' >> "$HOME/.claude/devagent/config.toml"
  _dirty
  _set_active risky
  _run "git stash"
  [ "$status" -eq 2 ]                         # ON for the active project
  # A DIFFERENT active project (no override, no [defaults]) → the override does NOT apply.
  _set_active other
  _run "git stash"
  [ "$status" -eq 0 ]                         # off — scoped to 'risky' only
}

@test "guard: [defaults] fallback applies when the active project has no override (#433)" {
  devagent_config_set_bool "$HOME/.claude/devagent/config.toml" defaults.git_guard true
  printf '\n[project.risky]\nx = 1\n' >> "$HOME/.claude/devagent/config.toml"
  _dirty
  _set_active risky                          # no [project.risky] git_guard → defaults wins
  _run "git stash"
  [ "$status" -eq 2 ]                         # ON via [defaults]
}

@test "guard: [project.<active>] git_guard=false overrides [defaults]=true (#433)" {
  devagent_config_set_bool "$HOME/.claude/devagent/config.toml" defaults.git_guard true
  printf '\n[project.safe]\ngit_guard = false\n' >> "$HOME/.claude/devagent/config.toml"
  _dirty
  _set_active safe
  _run "git stash"
  [ "$status" -eq 0 ]                         # off — project override beats defaults
}

@test "guard: no active_project (unset) falls back to [defaults] (#433 backwards compat)" {
  devagent_config_set_bool "$HOME/.claude/devagent/config.toml" defaults.git_guard true
  # no state/_active.toml written → proj empty → defaults-only, pre-#433 behavior
  _dirty
  _run "git stash"
  [ "$status" -eq 2 ]                         # ON via [defaults], as before #433
}

@test "guard: DEVAGENT_ACTIVE_PROJECT env pin wins over the _active.toml pointer (#433)" {
  # The box may env-pin the active project; the hook must honor the env FIRST or an
  # env-pinned [project.<X>] git_guard is silently ignored (security guard fails open).
  printf '\n[project.risky]\ngit_guard = true\n' >> "$HOME/.claude/devagent/config.toml"
  _set_active other                          # pointer says 'other' (no override)
  _dirty
  # PreToolUse hooks inherit the session env; pin it to 'risky' → guard ON.
  run bash -c 'DEVAGENT_ACTIVE_PROJECT=risky printf "%s" "$1" | DEVAGENT_ACTIVE_PROJECT=risky bash "$2"' \
    _ "$(_json 'git stash')" "$(HOOK)"
  [ "$status" -eq 2 ]                         # env pin resolved [project.risky] → ON
}

@test "guard ON + DIRTY: git reset --hard is DENIED in any arg position (#430)" {
  _on; _dirty
  for c in "git reset --hard" "git reset --hard HEAD~1" "git reset HEAD~1 --hard"; do
    _run "$c"
    [ "$status" -eq 2 ] || { echo "expected DENY(2) for: $c (got $status)"; false; }
  done
}

@test "guard ON + DIRTY: unprotected-pathspec checkout (>=2 positionals, no --) is DENIED (#430)" {
  _on; _dirty
  for c in "git checkout main guarded.txt" "git checkout HEAD guarded.txt" "git checkout -f main guarded.txt"; do
    _run "$c"
    [ "$status" -eq 2 ] || { echo "expected DENY(2) for: $c (got $status)"; false; }
  done
}

@test "guard ON + DIRTY: reset --soft/--mixed and single-positional checkout stay ALLOWED (#430 false-positive guard)" {
  _on; _dirty
  for c in "git checkout main" "git checkout -b feature" "git checkout -b feature main" "git checkout -B feature origin/main" "git reset --soft HEAD~1" "git reset --mixed" "git stash create" "git checkout guarded.txt" "git reset guarded.txt"; do
    _run "$c"
    [ "$status" -eq 0 ] || { echo "expected ALLOW(0) for: $c (got $status)"; false; }
  done
}

@test "guard ON + CLEAN: the new #430 shapes are ALLOWED (nothing to lose)" {
  _on; _clean
  for c in "git reset --hard" "git checkout main guarded.txt"; do
    _run "$c"
    [ "$status" -eq 0 ] || { echo "expected ALLOW(0) on clean for: $c (got $status)"; false; }
  done
}

@test "non-deny Bash calls skip the git status subprocess; deny shapes still run it (#431)" {
  _on; _dirty
  # A git shim that records each invocation, then delegates to the REAL git
  # (resolved to an absolute path NOW, before the shim shadows it on PATH).
  local real_git shimdir log
  real_git="$(command -v git)"
  shimdir="$(mktemp -d)"; log="$shimdir/gitcalls.log"
  cat > "$shimdir/git" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
exec "$real_git" "\$@"
SHIM
  chmod +x "$shimdir/git"

  # Non-git command → the fast-reject (3a) short-circuits → NO git status.
  : > "$log"
  PATH="$shimdir:$PATH" _run "echo hello"
  [ "$status" -eq 0 ]
  run grep -c status "$log"
  [ "$output" -eq 0 ] || { echo "expected 0 git-status calls for a non-git command; log:"; cat "$log"; false; }

  # git-but-non-deny command → the reorder short-circuits after shape-match, still
  # BEFORE the dirty gate → NO git status subprocess (the #431 hot-path win).
  : > "$log"
  PATH="$shimdir:$PATH" _run "git log --oneline -1"
  [ "$status" -eq 0 ]
  run grep -c status "$log"
  [ "$output" -eq 0 ] || { echo "expected 0 git-status calls for a git-but-non-deny command; log:"; cat "$log"; false; }

  # Deny-shaped command on a dirty tree → MUST run git status to confirm dirty.
  : > "$log"
  PATH="$shimdir:$PATH" _run "git stash"
  [ "$status" -eq 2 ]
  run grep -c status "$log"
  [ "$output" -ge 1 ] || { echo "expected >=1 git-status call for a deny shape; log:"; cat "$log"; false; }

  rm -rf "$shimdir"
}
