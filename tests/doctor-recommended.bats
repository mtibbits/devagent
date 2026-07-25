#!/usr/bin/env bats
# #541: doctor's recommended-plugin check — WARN when superpowers is absent
# or disabled, silent when enabled, silent (no false WARN) when the CLI
# errors or is missing. Never flips doctor's exit code (recommend, not
# require — Issue-242: no new die in a chain).

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  # Real dirs the doctor must find (harness copied from doctor.bats:5-35 —
  # a seeded, well-formed [project.volk] block so doctor exits 0 for
  # reasons unrelated to the check under test).
  mkdir -p "$DA_HOME/fake-src" "$DA_HOME/fake-devdoc"
  cat > "$DA_HOME/config.toml" <<TOML
[defaults]
checklist_template = "standard"

[project.volk]
source_dir = "$DA_HOME/fake-src"
devdoc_dir = "$DA_HOME/fake-devdoc"
default_baseline = "origin/main"

[project.volk.issue_source]
backend    = "github"
repo       = "gnuradio/volk"
dir_prefix = "Issue-"

[project.volk.code_source]
backend  = "github"
upstream = "gnuradio/volk"
fork     = "mtibbits/volk"
TOML
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/state.sh"
  source "$PLUGIN_ROOT/scripts/lib/secrets.sh"
  state_init volk
  secrets_bootstrap
  SCRIPTS="$PLUGIN_ROOT/scripts"
  STUBBIN="$DA_HOME/stubbin"
  mkdir -p "$STUBBIN"
}
teardown() { teardown_tmp_devagent_home; }

# PATH-shim a `claude` stub whose `plugin list` output copies the REAL
# measured shapes (analysis/2026-07-25-probe-dependency-semantics.md /
# live capture at 2.1.211). The `absent` stub carries OTHER plugins so a
# name-blind grep can't pass vacuously (Issue-Fork-149 poison control).
make_claude_stub() {
  local state="$1" fixture="$STUBBIN/list-output.txt"
  if [ "$state" = failing ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBBIN/claude"
  else
    # Shared header + a non-superpowers block in EVERY fixture, so the
    # absent case stays poison-controlled (other plugins present,
    # superpowers nowhere — Issue-Fork-149) and only the state-bearing
    # tail varies per case.
    cat > "$fixture" <<'EOF'
Installed plugins:

  ❯ devagent@devagent
    Version: a143b22419c4
    Scope: user
    Status: ✔ enabled
EOF
    case "$state" in
      absent) cat >> "$fixture" <<'EOF'

  ❯ code-review@claude-plugins-official
    Version: unknown
    Scope: user
    Status: ✔ enabled
EOF
        ;;
      disabled) cat >> "$fixture" <<'EOF'

  ❯ superpowers@claude-plugins-official
    Version: 6.2.0
    Scope: user
    Status: ✘ disabled
EOF
        ;;
      enabled) cat >> "$fixture" <<'EOF'

  ❯ superpowers@claude-plugins-official
    Version: 6.2.0
    Scope: user
    Status: ✔ enabled
EOF
        ;;
    esac
    printf '#!/usr/bin/env bash\ncat "%s"\n' "$fixture" > "$STUBBIN/claude"
  fi
  chmod +x "$STUBBIN/claude"
  export PATH="$STUBBIN:$PATH"
}

# Strip every PATH dir that carries a `claude` executable (the CI case:
# no claude CLI at all).
remove_claude_from_path() {
  local newpath="" d
  local IFS=:
  for d in $PATH; do
    [ -x "$d/claude" ] && continue
    newpath="${newpath:+$newpath:}$d"
  done
  export PATH="$newpath"
}

@test "doctor WARNs when superpowers is not installed (recommend, never die)" {
  make_claude_stub absent      # list carries OTHER plugins but no superpowers (poison control)
  run bash "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]          # WARN must not flip doctor's exit
  [[ "$output" == *"recommended: claude plugin install superpowers@claude-plugins-official"* ]]
}

@test "doctor WARNs when superpowers is installed but DISABLED" {
  make_claude_stub disabled    # superpowers block present, Status: disabled (Cell C's state)
  run bash "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]
  # redmr finding: the disabled state's copy-pasteable fix is ENABLE (with the
  # stanza's own marketplace-qualified name), not a second install
  [[ "$output" == *"recommended: claude plugin enable superpowers@claude-plugins-official"* ]]
}

@test "doctor stays silent about superpowers when installed+enabled" {
  make_claude_stub enabled
  run bash "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"recommended: claude plugin install"* ]]
}

@test "doctor stays silent (no false WARN) when the claude CLI itself errors" {
  make_claude_stub failing     # stub exits 1 with no output — the Issue-314/243 case
  run bash "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"recommended: claude plugin install"* ]]
}

@test "doctor skips the check silently when no claude CLI on PATH (CI)" {
  remove_claude_from_path
  run bash "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"recommended: claude plugin install"* ]]
}
