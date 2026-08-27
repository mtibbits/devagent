#!/usr/bin/env bats
# #585: the launcher that runs a devAgent session with superpowers ABSENT, without
# touching global plugin state. Mechanism verified in
# analysis/2026-08-27-draft-probes.md P1: `--settings` with an `enabledPlugins` map
# removed exactly the 14 superpowers:* slash commands (120 -> 106) and left devagent's
# 58 loaded, code-review and frontend-design untouched.
#
# SCOPE, stated so the green is not over-read: these are OFFLINE shape assertions.
# They pin what the launcher EMITS and how it dispatches; they do not re-run the live
# claude invocation, because a network call does not belong in the default suite path.
# The live half is evidenced once, by hand, in the traversal artifact — using the same
# stream-json init-event discriminator as the draft probe, never a model's prose about
# its own skill list (probe P1a: that answer was identical with and without the flag).
REPO="${BATS_TEST_DIRNAME}/.."
TOOL="$REPO/tests/tools/no-superpowers-session.sh"

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

@test "the launcher exists and is executable (#585)" {
  [ -x "$TOOL" ]
}

@test "emitted settings disable superpowers and say nothing else about plugins (#585)" {
  local out="$BATS_TEST_TMPDIR/st.json"
  run bash "$TOOL" --emit-settings "$out"
  [ "$status" -eq 0 ]
  [ -s "$out" ]
  run python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
ep=d['enabledPlugins']
assert ep['superpowers@claude-plugins-official'] is False, ep
# Merge semantics (probe P1): other plugins are absent from the map on purpose —
# naming them would freeze a snapshot of the operator's plugin set into the tool.
assert list(ep) == ['superpowers@claude-plugins-official'], ep
assert list(d) == ['enabledPlugins'], d
print('OK')
" "$out"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "the launcher execs claude with --settings and forwards its tail verbatim (#585)" {
  # Shim `claude` and capture argv, so this asserts the DISPATCH, not prose.
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/argv.txt"\n' "$BATS_TEST_TMPDIR" > "$bin/claude"
  chmod +x "$bin/claude"
  PATH="$bin:$PATH" run bash "$TOOL" -p 'hello --not-a-flag-of-ours'
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/argv.txt"
  [[ "${lines[0]}" == "--settings" ]]
  [ -f "${lines[1]}" ]
  [[ "${lines[2]}" == "-p" ]]
  [[ "${lines[3]}" == "hello --not-a-flag-of-ours" ]]   # one argv element, not resplit
  [ "${#lines[@]}" -eq 4 ]
}

@test "ZERO arguments LAUNCHES a session — it does not emit and exit (#585)" {
  # The emit-only predicate must key on `--emit-settings` being the WHOLE invocation.
  # Keying on `$# -eq 0` after the shift instead makes a bare invocation — the exact
  # command that runs the traversal — print a temp path and exit 0 without ever
  # starting claude. No other test here passes zero arguments, so that defect would
  # ship green.
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/argv0.txt"\necho LAUNCHED\n' \
    "$BATS_TEST_TMPDIR" > "$bin/claude"
  chmod +x "$bin/claude"
  PATH="$bin:$PATH" run bash "$TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *LAUNCHED* ]]
  [ -f "$BATS_TEST_TMPDIR/argv0.txt" ]
  run cat "$BATS_TEST_TMPDIR/argv0.txt"
  [[ "${lines[0]}" == "--settings" ]]
  [ "${#lines[@]}" -eq 2 ]              # exactly --settings <path>, nothing invented
}

@test "--emit-settings ALONE emits and exits without launching (#585)" {
  local bin="$BATS_TEST_TMPDIR/bin2"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\ntouch "%s/LAUNCHED_WRONGLY"\n' "$BATS_TEST_TMPDIR" > "$bin/claude"
  chmod +x "$bin/claude"
  PATH="$bin:$PATH" run bash "$TOOL" --emit-settings "$BATS_TEST_TMPDIR/emit.json"
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/emit.json" ]
  [ ! -e "$BATS_TEST_TMPDIR/LAUNCHED_WRONGLY" ]
}

@test "--emit-settings PLUS args emits to the named path AND launches (#585)" {
  # The third documented usage form, and the one the emit_only predicate exists to
  # distinguish from emit-alone. Tests 4 and 5 pin the other two; without this one the
  # branch that the launcher's longest comment defends has no test.
  local bin="$BATS_TEST_TMPDIR/bin3"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/argv3.txt"\necho LAUNCHED\n' \
    "$BATS_TEST_TMPDIR" > "$bin/claude"
  chmod +x "$bin/claude"
  local out="$BATS_TEST_TMPDIR/both.json"
  PATH="$bin:$PATH" run bash "$TOOL" --emit-settings "$out" -p hi
  [ "$status" -eq 0 ]
  [[ "$output" == *LAUNCHED* ]]
  [ -s "$out" ]                                  # emitted to the NAMED path
  run cat "$BATS_TEST_TMPDIR/argv3.txt"
  [[ "${lines[0]}" == "--settings" ]]
  [[ "${lines[1]}" == "$out" ]]                  # and launched with that same file
  [[ "${lines[2]}" == "-p" ]]
  [[ "${lines[3]}" == "hi" ]]
}

@test "the launcher refuses to run if claude is not on PATH (#585)" {
  # A missing binary must be a loud refusal, not a 127 the caller reads as a traversal
  # that found nothing (#316/#572).
  #
  # `PATH=<empty> run bash "$TOOL"` does NOT test this: the script would die at its own
  # mktemp, and bats could not even resolve `bash` — rc 127 with no mention of claude,
  # red before AND after the fix for a reason unrelated to the guard. Keep a working
  # toolchain and remove ONLY claude, then pin the MESSAGE rather than the bare code
  # (#Fork-132: two failure paths sharing one exit code fake a born-red assert).
  . "${BATS_TEST_DIRNAME}/lib/doctor-harness.bash"
  curated_path_without_claude
  run command -v claude
  [ "$status" -ne 0 ]                            # precondition, asserted not assumed

  run bash "$TOOL" -p hi
  [ "$status" -eq 127 ]
  [[ "$output" == *"no \`claude\` on PATH"* ]]   # the guard's own words, not any 127
}
