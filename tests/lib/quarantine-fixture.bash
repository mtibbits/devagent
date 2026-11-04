# tests/lib/quarantine-fixture.bash — shared #714 quarantine fixtures. Load
# after lib/bats-helpers and lib/trust-fixture.

. "$(dirname "${BASH_SOURCE[0]}")/hermetic-env.bash"   # idempotent (#322)

QF_LABEL="devagent:quarantine"

# qf_policy <separate|single|hardened>: the user-level policy for project wid
# (scope acme/widgets): worker 1001, approver 2002, quarantine = QF_LABEL.
#   separate  single_identity = false (the default)
#   single    1001 is also an approver; single_identity = true
#   hardened  single plus required_hardening = ["signatures"] (refuses at
#             entry: unit cases only)
# Extra toml lines after the shape are appended; QF_WORKERS replaces the
# worker_identities members.
qf_policy() {
  local shape="$1" lines
  shift
  lines=('scopes = ["github:github.com/acme/widgets"]' "worker_identities = [${QF_WORKERS:-\"github:1001\"}]"
         "quarantine = \"$QF_LABEL\"")
  case "$shape" in
    separate) lines+=('trusted_approvers = ["github:2002"]') ;;
    single)   lines+=('trusted_approvers = ["github:2002", "github:1001"]' 'single_identity = true') ;;
    hardened) lines+=('trusted_approvers = ["github:2002", "github:1001"]' 'single_identity = true'
                      'required_hardening = ["signatures"]') ;;
    *) echo "qf_policy: unknown shape $shape" >&2; return 1 ;;
  esac
  trust_fixture_policy "$HOME/.config/devagent/trust" "${lines[@]}" "$@"
}

# qf_project: project wid (origin acme/widgets, dir_prefix Issue-,
# transition_issue = true) on a tmp DA_HOME; an active Issue-7 and a parked
# Issue-8, each with a checklist; the quarantine backend stub through
# DEVAGENT_ISSUE_BACKEND_DIR with its state in QB_DIR, and the gh-stub on PATH
# logging into the same calls file (pull's fetch goes to gh directly).
qf_project() {
  trust_fixture_home
  unset GH_HOST DEVAGENT_ACTIVE_ISSUE DEVAGENT_ACTIVE_PROJECT DEVAGENT_PROJECT
  setup_tmp_devagent_home
  QB_DIR="$BATS_TEST_TMPDIR/qb"
  mkdir -p "$QB_DIR"
  : > "$QB_DIR/calls"
  export QB_DIR
  export DEVAGENT_ISSUE_BACKEND_DIR="$PLUGIN_ROOT/tests/fixtures/quarantine-backend"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_CASE=standard GH_STUB_ARGV_LOG="$QB_DIR/calls"
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/wid"
  mkdir -p "$DEVDOC/Issue-7" "$DEVDOC/Issue-8" "$BATS_TEST_TMPDIR/wid"
  cat > "$DA_HOME/config.toml" <<CFG
[project.wid]
source_dir = "$BATS_TEST_TMPDIR/wid"
devdoc_dir = "$DEVDOC"

[project.wid.permissions]
transition_issue = true

[project.wid.issue_source]
backend = "github"
repo = "acme/widgets"
dir_prefix = "Issue-"
CFG
  cat > "$DA_HOME/state/wid.toml" <<STATE
active_issue = "Issue-7"
issue_dir = "$DEVDOC/Issue-7"
branch = "feat/7-widgets"

[parked]
Issue-8 = true
STATE
  local i
  for i in 7 8; do
    cat > "$DEVDOC/Issue-$i/checklist.md" <<CL
# Checklist — Issue-$i

Template: standard

## Revision 1

- [x] 0. pull
- [x] 2. draft
- [ ] 4. scope
- [ ] 8. branch
- [ ] 12. commit
- [ ] 18. ship
- [ ] 24. cleanup

## Log
CL
  done
}

# qf_ev <time> <seq> <actor> <atype> <kind> [<label>]: append one bc_rec line
# to the stub's events (label defaults to QF_LABEL).
qf_ev() {
  printf '%s\t%s\t%s\t%s\t%s\tLA_x %s\n' "$1" "$2" "$3" "$4" "$5" "${6:-$QF_LABEL}" >> "$QB_DIR/events.tsv"
}

# qf_calls: the stub's call log, verbs only (gh-stub lines keep their argv).
qf_calls() { cut -d' ' -f1 "$QB_DIR/calls"; }
