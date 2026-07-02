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
