#!/usr/bin/env bats
# #320: io.sh diagnostics must prefix the ENTRY script's name, not io.sh's own
# frame. _io_progname read BASH_SOURCE[1] — from inside die/warn that IS io.sh —
# so every message plugin-wide was prefixed "io.sh:", hiding which of ~50 entry
# scripts failed. Fix: basename "$0" (the entry script, robust to call depth — a
# die deep in a sourced lib still names the entry, unlike BASH_SOURCE[2]).

load 'helpers'

@test "io.sh die prefixes the entry script name, not io.sh (#320)" {
  cat > "$BATS_TEST_TMPDIR/myentry.sh" <<EOF
#!/usr/bin/env bash
. "$REPO_ROOT/scripts/lib/io.sh"
die "boom"
EOF
  run bash "$BATS_TEST_TMPDIR/myentry.sh"
  [ "$status" -eq 1 ]
  [ "$output" = "myentry.sh: boom" ]
}

@test "io.sh warn prefixes the entry script name, not io.sh (#320)" {
  cat > "$BATS_TEST_TMPDIR/other-cmd.sh" <<EOF
#!/usr/bin/env bash
. "$REPO_ROOT/scripts/lib/io.sh"
warn "heads up"
EOF
  run bash "$BATS_TEST_TMPDIR/other-cmd.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "other-cmd.sh: WARNING: heads up" ]
}

@test "io.sh die deep in a sourced lib still names the entry script, not the lib (#320)" {
  cat > "$BATS_TEST_TMPDIR/mylib.sh" <<'LIB'
inner() { die "inner boom"; }
LIB
  cat > "$BATS_TEST_TMPDIR/deep.sh" <<EOF
#!/usr/bin/env bash
. "$REPO_ROOT/scripts/lib/io.sh"
. "$BATS_TEST_TMPDIR/mylib.sh"
inner
EOF
  run bash "$BATS_TEST_TMPDIR/deep.sh"
  [ "$status" -eq 1 ]
  [ "$output" = "deep.sh: inner boom" ]
}

@test "no executed script die/warn/info redundantly prefixes its own name (#320 harmonization)" {
  # io.sh now auto-prefixes $0 (the entry script); a literal "<script>.sh:" prefix
  # in an executed script (scripts/*.sh, not lib/) would double it. This canary
  # keeps the harmonized state — grep must find NO such prefix outside lib/.
  local offenders
  offenders="$(grep -rEn '(die|info|warn) "[a-z_-]+\.sh: ' "$REPO_ROOT/scripts" --include='*.sh' | grep -v '/lib/' || true)"
  [ -z "$offenders" ] || { printf 'redundant self-prefixes (io.sh already adds the script name):\n%s\n' "$offenders" >&2; false; }
}
