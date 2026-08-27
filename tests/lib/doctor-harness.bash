# tests/lib/doctor-harness.bash
# Shared setup for the bats files that invoke scripts/doctor.sh (#585).
#
# Two jobs, and they are one job: doctor.bats and doctor-recommended.bats carried
# byte-identical seeded-volk setup() blocks (Issue-541 review minor 8), and the
# extraction is what gives the `claude` stub a single home. Without the stub,
# doctor.sh runs `timeout 5 claude plugin list` for real on every invocation —
# measured 19 live calls across the three files, 0.28 s each, ~5.0 s per suite run —
# and the tests' inputs become a function of the developer's plugin state rather than
# of the tree. A HUNG CLI would cost `timeout 5` x19 = 95 s.
#
# Load AFTER lib/bats-helpers where that is used (needs PLUGIN_ROOT and, for
# seed_doctor_project, setup_tmp_devagent_home). tests/revise.bats loads
# helpers/fixtures instead and uses only stub_claude_cli, which needs just STUBBIN.

. "$(dirname "${BASH_SOURCE[0]}")/hermetic-env.bash"   # idempotent (#322)

# Seed the well-formed [project.volk] fixture doctor expects, so doctor exits 0 for
# reasons unrelated to whatever check a caller is exercising.
seed_doctor_project() {
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

# PATH-shim a `claude` whose `plugin list` output copies the REAL measured shapes
# (Issue-541 analysis/2026-07-25-probe-dependency-semantics.md; live capture at CLI
# 2.1.211, re-confirmed byte-for-byte inside that issue's toggle window).
# state: absent | disabled | enabled | failing
# Idempotent — re-calling replaces the fixture without re-prepending PATH.
stub_claude_cli() {
  local state="$1" fixture
  : "${STUBBIN:?stub_claude_cli: STUBBIN is unset — call seed_doctor_project first, or set it}"
  mkdir -p "$STUBBIN"
  fixture="$STUBBIN/list-output.txt"
  if [ "$state" = failing ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBBIN/claude"
  else
    # Shared header + a non-superpowers block in EVERY fixture, so the `absent` case
    # stays poison-controlled — other plugins present, superpowers nowhere — and a
    # name-blind grep cannot pass vacuously (Issue-Fork-149).
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
      *) echo "stub_claude_cli: unknown state '$state' (absent|disabled|enabled|failing)" >&2
         return 2 ;;
    esac
    printf '#!/usr/bin/env bash\ncat "%s"\n' "$fixture" > "$STUBBIN/claude"
  fi
  chmod +x "$STUBBIN/claude"
  case ":$PATH:" in
    *":$STUBBIN:"*) ;;                    # already present — do not re-prepend
    *) export PATH="$STUBBIN:$PATH" ;;
  esac
}
