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
  # shellcheck disable=SC2034  # both are the return channel: the .bats files that
  # load this harness read $SCRIPTS and $STUBBIN from their own test bodies.
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
  # Default STUBBIN rather than demanding it. seed_doctor_project sets it, but a
  # caller that only needs the stub (revise.bats loads helpers/fixtures, not
  # bats-helpers) should not have to hand-build the directory first — that is a
  # special case layered on shared infrastructure, and the next such caller would
  # copy it.
  : "${STUBBIN:=${BATS_TEST_TMPDIR:?stub_claude_cli: no STUBBIN and no BATS_TEST_TMPDIR}/stubbin}"
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

# Install the quiet stub at SOURCE time (#585). The enrollment canary in
# tests/doctor-hermetic.bats asserts a file LOADS this harness; without this line that
# is not the same as asserting the stub is installed, so a file could load the harness,
# forget to call stub_claude_cli, and take a live `claude plugin list` dependency while
# the canary stayed green. Loading now IS the guarantee.
#
# `enabled` is the silent state, so it cannot perturb any caller's assertions. Callers
# that exercise another state just call stub_claude_cli again — it is idempotent about
# PATH. Guarded on BATS_TEST_TMPDIR so sourcing this file outside bats is inert.
[ -n "${BATS_TEST_TMPDIR:-}" ] && stub_claude_cli enabled

# Make `claude` unresolvable WITHOUT losing the rest of its directory (#585, from
# Issue-541 review minor 9). The predecessor stripped every PATH DIRECTORY holding a
# `claude`; on the author's machine ~/.local/bin also holds pytest, py.test, uv, uvx
# and git-filter-repo, so a one-executable intent carried a directory-wide blast
# radius. For each claude-bearing dir, substitute a shadow dir symlinking every OTHER
# entry; leave claude-free dirs exactly as they are.
#
# NOT an error when there is no claude to hide: that is the CI shape, and the first
# consumer is the test named for it. A hard failure there would make that test's
# verdict a function of the machine — precisely what this issue removes.
curated_path_without_claude() {
  local newpath="" d shadow entry n=0 dropped=0
  local IFS=:
  for d in $PATH; do
    [ -n "$d" ] || continue                       # an empty PATH element means CWD
    if [ -x "$d/claude" ]; then
      # Under BATS_TEST_TMPDIR so bats reaps the shadow dirs with the test; a bare
      # `mktemp -d` left one behind per call, and this helper cannot trap (callers
      # keep running).
      shadow="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/nopath-XXXXXX")"
      # Cost is proportional to the claude-bearing dir's SIZE, which is a property of
      # where claude was installed, not of this repo (#123 — a cost measurement is
      # machine-bound). Measured: ~7 symlinks and instant for a private bin dir;
      # 1.19 s for a 2215-entry /usr/bin.
      #
      # An earlier version REFUSED above 200 entries. That was worse: it made four
      # tests fail outright on any machine with a system-wide claude install — a test
      # verdict that is a function of the machine, which is the defect class this
      # whole issue removes. Paying ~1.2 s in that case is the lesser evil, and it is
      # the same order as the ~5 s this issue saves elsewhere.
      #
      # Per-entry rather than one `ln -s "$d"/* "$shadow"/`, so a single failing link
      # does not abort the rest. Known limit, stated rather than implied by a comment
      # that claimed otherwise: `"$d"/*` does not match dotfiles, so a dot-prefixed
      # executable in a claude-bearing dir is dropped from the curated PATH. No PATH
      # dir on any supported setup has one; if that changes, add `dotglob`.
      #
      # A link that fails is COUNTED, not swallowed: a silently-missing binary makes
      # the consuming test fail for a reason unrelated to claude, which is the kind of
      # misdirection this issue exists to remove.
      for entry in "$d"/*; do
        [ -e "$entry" ] || continue               # unmatched glob
        [ "${entry##*/}" = claude ] && continue
        ln -s "$entry" "$shadow/${entry##*/}" 2>/dev/null || dropped=$((dropped + 1))
      done
      [ "$dropped" -eq 0 ] || echo "curated_path_without_claude: $dropped entry(ies) of $d could not be linked into the curated PATH" >&2
      newpath="${newpath:+$newpath:}$shadow"
      n=$((n + 1))
    else
      newpath="${newpath:+$newpath:}$d"
    fi
  done
  export PATH="$newpath"
  [ "$n" -gt 0 ] || echo "curated_path_without_claude: no claude on PATH (already absent — no-op)"
  return 0
}
