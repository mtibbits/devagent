#!/usr/bin/env bats
# #327: the context choreography (save / clear / restore / pull-displacement)
# must each be ONE locked transaction. Pins observe the _toml.py traffic via a
# PATH python3 shim (the #317 pattern) — deterministic, no window-racing — plus
# a crash injection proving displacement has a single point of change.

load 'lib/bats-helpers'

setup() {
  unset DEVAGENT_ACTIVE_PROJECT DEVAGENT_ACTIVE_ISSUE
  setup_tmp_devagent_home
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/state.sh"
  state_init volk
  # Shim python3: log every _toml.py argv, then exec the real interpreter.
  REAL_PY="$(command -v python3)"
  export REAL_PY
  SHIM="$BATS_TEST_TMPDIR/shim"; mkdir -p "$SHIM"
  cat > "$SHIM/python3" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/toml-calls.log"
exec "$REAL_PY" "\$@"
SH
  chmod +x "$SHIM/python3"
  LOG="$BATS_TEST_TMPDIR/toml-calls.log"
}
teardown() { teardown_tmp_devagent_home; }

_muts() {  # count mutation-verb invocations in the log
  awk '{print $2}' "$LOG" 2>/dev/null \
    | grep -cE '^(set|set-int|set-bool|set-many|set-many-if|set-if|unset|transact)$'
}

@test "state_context_save is ONE transaction (#327)" {
  state_set volk branch "fix/9-x"
  state_set volk mr_url "https://x/1"
  : > "$LOG"
  PATH="$SHIM:$PATH" state_context_save volk Issue-9
  [ "$(_muts)" -eq 1 ]
  # behavior: snapshot present with the values
  [ "$(state_issue_get volk Issue-9 branch)" = "fix/9-x" ]
}

@test "state_context_clear is ONE transaction (#327)" {
  state_set volk branch "fix/9-x"
  : > "$LOG"
  PATH="$SHIM:$PATH" state_context_clear volk
  [ "$(_muts)" -eq 1 ]
  grep -qE '^branch = ""$' "$DA_HOME/state/volk.toml"
  grep -qE '^revision = 1$' "$DA_HOME/state/volk.toml"    # int form preserved (#97)
}

@test "state_context_restore is ONE transaction and deletes the snapshot in it (#327)" {
  state_set volk branch "fix/old"
  state_context_save volk Issue-9
  state_set volk branch "fix/other"
  : > "$LOG"
  PATH="$SHIM:$PATH" state_context_restore volk Issue-9
  [ "$(_muts)" -eq 1 ]
  grep -qE '^branch = "fix/old"$' "$DA_HOME/state/volk.toml"
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" context.Issue-9.branch
  [ "$status" -ne 0 ]                                      # table gone, same txn
}

@test "pull displacement (state_pull_promote) is ONE transaction carrying snapshot AND promote (#327)" {
  state_set volk active_issue Issue-1
  state_set volk branch "fix/prev"
  state_set volk issue_dir "$DA_HOME/prev-dir"
  : > "$LOG"
  PATH="$SHIM:$PATH" state_pull_promote volk Issue-2 "$DA_HOME/new-dir" Issue-1
  [ "$(_muts)" -eq 1 ]
  fused="$(grep ' transact ' "$LOG")"
  [[ "$fused" == *"--snapshot context.Issue-1"* ]]
  [[ "$fused" == *" active_issue Issue-2"* ]]
  # behavior: prev snapshotted, top level cleared+promoted
  [ "$(state_issue_get volk Issue-1 branch)" = "fix/prev" ]
  grep -qE '^active_issue = "Issue-2"$' "$DA_HOME/state/volk.toml"
  grep -qE '^branch = ""$' "$DA_HOME/state/volk.toml"
}

@test "a crash at displacement's single mutation leaves the OLD state complete (#327)" {
  state_set volk active_issue Issue-1
  state_set volk branch "fix/prev"
  # Kill shim: abort the FIRST mutation attempt before it executes.
  KILL="$BATS_TEST_TMPDIR/kill"; mkdir -p "$KILL"
  cat > "$KILL/python3" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" transact "*|*" set-many "*|*" set "*|*" unset "*|*" set-int "*)
    exit 137 ;;
esac
exec "$REAL_PY" "\$@"
SH
  chmod +x "$KILL/python3"
  # set -e mirrors production (every step script runs set -euo pipefail), so
  # the killed mutation's 137 propagates out of the command substitution.
  run bash -c "set -euo pipefail; PATH='$KILL':\$PATH; source '$PLUGIN_ROOT/scripts/lib/paths.sh'; source '$PLUGIN_ROOT/scripts/lib/io.sh'; source '$PLUGIN_ROOT/scripts/lib/state.sh'; state_pull_promote volk Issue-2 '$DA_HOME/new-dir' Issue-1"
  # Exactly the kill-shim's 137 (review NIT: a broken re-source would also be
  # nonzero and pass vacuously — the old state trivially intact).
  [ "$status" -eq 137 ]
  # Old state fully intact: active still Issue-1 with its branch; NO snapshot,
  # NO half-clear. (On the HEAD choreography a crash mid-sequence left
  # active_issue=prev with branch="" — the torn #316 shape.)
  grep -qE '^active_issue = "Issue-1"$' "$DA_HOME/state/volk.toml"
  grep -qE '^branch = "fix/prev"$' "$DA_HOME/state/volk.toml"
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" context.Issue-1.branch
  [ "$status" -ne 0 ]
}
