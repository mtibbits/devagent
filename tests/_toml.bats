#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  install_fixture_config config-onproject.toml
  TOML="$PLUGIN_ROOT/scripts/lib/_toml.py"
}

teardown() { teardown_tmp_devagent_home; }

@test "get reads a top-level scalar" {
  run python3 "$TOML" get "$DA_HOME/config.toml" defaults.checklist_template
  [ "$status" -eq 0 ]
  [ "$output" = "standard" ]
}

@test "get reads a nested scalar" {
  run python3 "$TOML" get "$DA_HOME/config.toml" project.volk.devdoc_dir
  [ "$status" -eq 0 ]
  [ "$output" = "~/src/devDoc/volk" ]
}

@test "get returns nonzero on missing key" {
  run python3 "$TOML" get "$DA_HOME/config.toml" project.volk.nope
  [ "$status" -ne 0 ]
}

# --- #99: control-char escaping, legal-type emit, parse-error exit code ---

@test "set of a value with a newline keeps the file valid TOML (#99)" {
  local f="$DA_HOME/st.toml"; printf 'a = "x"\n' > "$f"
  run python3 "$TOML" set "$f" msg "$(printf 'line1\nline2')"
  [ "$status" -eq 0 ]
  run python3 "$TOML" validate "$f"
  [ "$status" -eq 0 ]                       # file is still parseable
  run python3 "$TOML" get "$f" msg
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'line1\nline2')" ] # newline round-trips
}

@test "mutating a file that contains a float and an array does not crash (#99)" {
  local f="$DA_HOME/ff.toml"
  printf 'ratio = 1.5\narr = [1, 2, 3]\n' > "$f"
  run python3 "$TOML" set "$f" added "ok"
  [ "$status" -eq 0 ]
  run python3 "$TOML" get "$f" ratio
  [ "$output" = "1.5" ]
  run python3 "$TOML" get "$f" added
  [ "$output" = "ok" ]
  run python3 "$TOML" validate "$f"
  [ "$status" -eq 0 ]
}

@test "get on an unparseable file exits 2, distinct from key-absent (#99)" {
  local f="$DA_HOME/bad.toml"; printf 'this is = not valid = toml\n' > "$f"
  run python3 "$TOML" get "$f" some.key
  [ "$status" -eq 2 ]                        # parse error, not 1 (absent)
}

@test "list-tables enumerates project subtable names" {
  run python3 "$TOML" list-tables "$DA_HOME/config.toml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project.volk"* ]]
  [[ "$output" == *"project.volk.issue_source"* ]]
}

@test "set then get round-trips a string" {
  python3 "$TOML" set "$DA_HOME/config.toml" project.volk.new_key '"hello world"'
  run python3 "$TOML" get "$DA_HOME/config.toml" project.volk.new_key
  [ "$status" -eq 0 ]
  [ "$output" = "hello world" ]
}

@test "set-bool writes a boolean" {
  python3 "$TOML" set-bool "$DA_HOME/config.toml" project.volk.fork_first false
  run python3 "$TOML" get "$DA_HOME/config.toml" project.volk.fork_first
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "unset removes a key" {
  python3 "$TOML" unset "$DA_HOME/config.toml" defaults.checklist_template
  run python3 "$TOML" get "$DA_HOME/config.toml" defaults.checklist_template
  [ "$status" -ne 0 ]
}

@test "validate exits 0 on good file, nonzero on malformed" {
  run python3 "$TOML" validate "$DA_HOME/config.toml"
  [ "$status" -eq 0 ]
  cp "$(fixtures_dir)/config-malformed.toml" "$DA_HOME/bad.toml"
  run python3 "$TOML" validate "$DA_HOME/bad.toml"
  [ "$status" -ne 0 ]
}

@test "concurrent writes do not lose updates" {
  # Launch 20 concurrent writers each setting a distinct key.
  # Without flock, lost-update races would drop some keys.
  local i pids=()
  for i in $(seq 1 20); do
    python3 "$TOML" set "$DA_HOME/config.toml" \
      "project.volk.race_$i" "\"v$i\"" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done

  # All 20 keys must be readable.
  local missing=0
  for i in $(seq 1 20); do
    run python3 "$TOML" get "$DA_HOME/config.toml" "project.volk.race_$i"
    [ "$status" -eq 0 ] || { missing=$((missing+1)); continue; }
    [ "$output" = "v$i" ] || missing=$((missing+1))
  done
  [ "$missing" -eq 0 ]
}

@test "lock file is released on exception" {
  # Force a malformed write (a bad value type) and verify the lock
  # does not stick around blocking subsequent writers.
  run python3 "$TOML" set-bool "$DA_HOME/config.toml" \
      project.volk.fork_first not-a-bool
  [ "$status" -ne 0 ]
  # Now a normal write must still succeed.
  run python3 "$TOML" set "$DA_HOME/config.toml" \
      project.volk.after_error '"ok"'
  [ "$status" -eq 0 ]
}

@test "mutation refuses a comment-bearing file, leaving it intact (#100)" {
  local f="$BATS_TEST_TMPDIR/commented.toml"
  printf '# hand-written rationale\nkey = "v"  # inline note\n' > "$f"
  run python3 "$TOML" set "$f" key '"new"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to mutate"* ]]
  grep -q '# hand-written rationale' "$f"   # comment preserved
  grep -q 'key = "v"' "$f"                  # value untouched
}

@test "mutation proceeds on a comment-free file (#100)" {
  local f="$BATS_TEST_TMPDIR/plain.toml"
  printf 'key = "v"\n' > "$f"
  run python3 "$TOML" set "$f" key '"new"'
  [ "$status" -eq 0 ]
  run python3 "$TOML" get "$f" key
  [ "$output" = "new" ]
}

@test "a # inside a quoted string is not treated as a comment (#100)" {
  local f="$BATS_TEST_TMPDIR/hashval.toml"
  printf 'url = "http://x/y#frag"\n' > "$f"
  run python3 "$TOML" set "$f" k '"v"'
  [ "$status" -eq 0 ]   # the # is in a string, not a comment → mutation allowed
}

# --- #96: set-many / set-if / --print-old -----------------------------------

_seed96() {
  F="$BATS_TEST_TMPDIR/s.toml"
  printf 'a = "1"\nb = 2\nactive_issue = "Issue-1"\n' > "$F"
}

@test "set-many writes typed keys + exactly one updated_at-free transaction (#96)" {
  _seed96
  run python3 "$TOML" set-many "$F" str a "x" int b 7 bool c true
  [ "$status" -eq 0 ]
  [ "$(python3 "$TOML" get "$F" a)" = "x" ]
  grep -qE '^b = 7$' "$F"
  grep -qE '^c = true$' "$F"
}

@test "set-many is all-or-nothing on a bad triplet (#96)" {
  _seed96
  before="$(stat -c '%Y %s' "$F"; cat "$F")"
  run python3 "$TOML" set-many "$F" str a "x" int b notanint
  [ "$status" -eq 2 ]
  after="$(stat -c '%Y %s' "$F"; cat "$F")"
  [ "$before" = "$after" ]
}

@test "set-if swaps on match, exit 0 (#96)" {
  _seed96
  run python3 "$TOML" set-if "$F" a "1" "2"
  [ "$status" -eq 0 ]
  [ "$(python3 "$TOML" get "$F" a)" = "2" ]
}

@test "set-if refuses on mismatch: exit 3, actual on stdout, file untouched (#96)" {
  _seed96
  before="$(stat -c '%Y %s' "$F"; cat "$F")"
  run python3 "$TOML" set-if "$F" a "999" "2"
  [ "$status" -eq 3 ]
  [ "$output" = "1" ]
  after="$(stat -c '%Y %s' "$F"; cat "$F")"
  [ "$before" = "$after" ]
}

@test "set-if --absent matches only a missing key (#96)" {
  _seed96
  run python3 "$TOML" set-if "$F" newkey --absent "v"
  [ "$status" -eq 0 ]
  [ "$(python3 "$TOML" get "$F" newkey)" = "v" ]
  run python3 "$TOML" set-if "$F" a --absent "v"
  [ "$status" -eq 3 ]
}

@test "set --print-old prints prior value; nothing when absent (#96)" {
  _seed96
  run python3 "$TOML" set --print-old "$F" a "9"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run python3 "$TOML" set --print-old "$F" ghostkey "9"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "set-if exit 2 on unparseable file (#96/#99)" {
  F="$BATS_TEST_TMPDIR/bad.toml"
  printf 'a = "1\nb == 2\n' > "$F"
  run python3 "$TOML" set-if "$F" a "1" "2"
  [ "$status" -eq 2 ]
}

@test "set-if on a table key: clean exit 2, no traceback (#96 review L1)" {
  _seed96
  printf '[tbl]\nx = "1"\n' >> "$F"
  run python3 "$TOML" set-if "$F" tbl "1" "2"
  [ "$status" -eq 2 ]
  [[ "$output" != *Traceback* ]]
}

# --- #288: _toml.py must run on a no-fcntl interpreter (Windows) ---
#
# Simulate a fcntl-less CPython on ANY platform: a sitecustomize.py on
# PYTHONPATH sets sys.modules['fcntl']=None at interpreter startup (before
# _toml.py loads), so `import fcntl` raises ImportError even on Linux, forcing
# the msvcrt branch. A stub msvcrt.py satisfies that branch's lazy `import
# msvcrt` on Linux; on Windows the builtin msvcrt shadows the stub (real
# locking there — the concurrency test above attests actual exclusion). These
# tests therefore assert on exit code / output value ONLY, never on stub
# side-effects, so they mean the same thing on both platforms. The stub proves
# the branch is *wired*, not that it mutually excludes.
_nofcntl_shim() {   # create shim dir, echo its path for PYTHONPATH
  local d="$BATS_TEST_TMPDIR/nofcntl"
  mkdir -p "$d"
  printf "import sys\nsys.modules['fcntl'] = None\n" > "$d/sitecustomize.py"
  printf "LK_LOCK = 1\nLK_UNLCK = 0\ndef locking(fd, mode, nbytes):\n    pass\n" \
    > "$d/msvcrt.py"
  printf '%s' "$d"
}

@test "no-fcntl shim actually forces fcntl absent (#288 canary)" {
  # If the shim ever stops applying (exotic site config, -S launch), the
  # sibling fcntl-absent tests would silently pass against the REAL fcntl
  # path — a false green of the exact regression they guard. This canary
  # fails loudly in that case: under the shim, `import fcntl` MUST raise.
  local shim; shim="$(_nofcntl_shim)"
  run env PYTHONPATH="$shim" python3 -c "import fcntl"
  [ "$status" -ne 0 ]
}

@test "read-only verb works when fcntl is absent (#288)" {
  local shim; shim="$(_nofcntl_shim)"
  printf 'k = "v"\n' > "$BATS_TEST_TMPDIR/n.toml"
  # The literal #288 symptom: import no longer dies before the verb runs.
  run env PYTHONPATH="$shim" python3 "$TOML" get "$BATS_TEST_TMPDIR/n.toml" k
  [ "$status" -eq 0 ]
  [ "$output" = "v" ]
}

@test "mutation verb works when fcntl is absent (#288 msvcrt lock path)" {
  local shim; shim="$(_nofcntl_shim)"
  printf 'k = "v"\n' > "$BATS_TEST_TMPDIR/n.toml"
  # Exercises the msvcrt lock+unlock branch: LK_LOCK/LK_UNLCK resolve,
  # fileno()/seek(0) work, value round-trips.
  run env PYTHONPATH="$shim" python3 "$TOML" set "$BATS_TEST_TMPDIR/n.toml" k2 '"w"'
  [ "$status" -eq 0 ]
  run env PYTHONPATH="$shim" python3 "$TOML" get "$BATS_TEST_TMPDIR/n.toml" k2
  [ "$status" -eq 0 ]
  [ "$output" = "w" ]
}

@test "unlock runs after an exception inside the lock, fcntl absent (#288)" {
  local shim; shim="$(_nofcntl_shim)"
  printf 'k = "v"\n' > "$BATS_TEST_TMPDIR/n.toml"
  # `set k.sub` treats scalar k as a table → _set_path raises ValueError
  # INSIDE the with-block (after the lock is held), exercising the finally/
  # unlock path. (The "lock released on exception" test, and set-int/set-bool
  # bad values which #96 validates PRE-lock, all reject before locking — so
  # none of them cover this branch.)
  run env PYTHONPATH="$shim" python3 "$TOML" set "$BATS_TEST_TMPDIR/n.toml" k.sub "x"
  [ "$status" -ne 0 ]
  # A subsequent write still succeeds. Process exit alone would drop the lock,
  # so this asserts the finally/unlock branch EXECUTES cleanly (no hang, no
  # wiring break) after an in-lock exception — not cross-process release.
  run env PYTHONPATH="$shim" python3 "$TOML" set "$BATS_TEST_TMPDIR/n.toml" k4 '"ok"'
  [ "$status" -eq 0 ]
}

@test "acquire retries on EDEADLOCK contention, fcntl absent (#288)" {
  # The retry-on-EDEADLOCK loop is the only novel control flow in the fix, and
  # neither the no-op stub (Linux) nor a fast uncontended real lock (Windows)
  # forces it to iterate. A stateful stub whose LK_LOCK raises EDEADLOCK twice
  # then succeeds proves the loop retries the contention error and completes.
  # (On Windows the builtin msvcrt shadows this stub, so the mutation just
  # takes the real lock uncontended — still exit 0; the coverage is on Linux.)
  local d="$BATS_TEST_TMPDIR/retry"
  mkdir -p "$d"
  printf "import sys\nsys.modules['fcntl'] = None\n" > "$d/sitecustomize.py"
  cat > "$d/msvcrt.py" <<'PY'
import errno
LK_LOCK = 1
LK_UNLCK = 0
_n = [0]
def locking(fd, mode, nbytes):
    if mode == LK_LOCK:
        _n[0] += 1
        if _n[0] <= 2:                       # first two acquires "contend"
            raise OSError(errno.EDEADLOCK, "simulated contention")
    # third LK_LOCK and every LK_UNLCK succeed
PY
  printf 'k = "v"\n' > "$BATS_TEST_TMPDIR/r.toml"
  run env PYTHONPATH="$d" python3 "$TOML" set "$BATS_TEST_TMPDIR/r.toml" k2 '"w"'
  [ "$status" -eq 0 ]
  run env PYTHONPATH="$d" python3 "$TOML" get "$BATS_TEST_TMPDIR/r.toml" k2
  [ "$status" -eq 0 ]
  [ "$output" = "w" ]
}
