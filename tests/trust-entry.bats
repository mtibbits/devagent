#!/usr/bin/env bats
# #713 task 6: every entry point calls trust_entry_check (or
# trust_entry_check_devdoc) once, and under an in-scope policy refuses before
# any backend call, devdoc write or state write. The census case holds
# TRUST_ENTRY_POINTS equal to the scripts that carry the column-0 call; the
# refusal case runs each real script against the gh-stub with whoami
# answering github:1001, an id the policy lists as a trusted approver.

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'lib/bats-helpers'
load 'helpers/common'
load 'lib/trust-fixture'

SCOPE='scopes = ["github:github.com/acme/widgets"]'
# the gh-stub logs each call's argv, then its GH_HOST
WHOAMI_RE='^\[api\] \[-i\] \[--hostname\] \[github\.com\] \[user\]( GH_HOST=.*)?$'

setup() {
  trust_fixture_home
  unset GH_HOST DEVAGENT_ACTIVE_ISSUE DEVAGENT_ACTIVE_PROJECT DEVAGENT_PROJECT
  POL="$HOME/.config/devagent/trust"
}

teardown() {
  teardown_tmp_devagent_home
  devagent_test_teardown
}

# _wid: project `wid` (origin acme/widgets) with transition_issue = true, the
# gh-stub on PATH (whoami = github:1001), an active Issue-7 with a checklist
# and a STUCK file, a parked Issue-8, and a capture draft under the devdoc.
_wid() {
  setup_tmp_devagent_home
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_CASE=standard GH_STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv"
  export GH_STUB_EVENTS_DIR="$BATS_TEST_TMPDIR/ev"
  mkdir -p "$GH_STUB_EVENTS_DIR"
  echo '{"login":"worker","id":1001,"type":"User"}' > "$GH_STUB_EVENTS_DIR/user.json"
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/wid"
  mkdir -p "$DEVDOC/Issue-7" "$DEVDOC/Issue-8" "$DEVDOC/Captures/idea" "$BATS_TEST_TMPDIR/wid"
  cat > "$DA_HOME/config.toml" <<EOF
[project.wid]
source_dir = "$BATS_TEST_TMPDIR/wid"
devdoc_dir = "$DEVDOC"

[project.wid.permissions]
transition_issue = true

[project.wid.issue_source]
backend = "github"
repo = "acme/widgets"
dir_prefix = "Issue-"
EOF
  cat > "$DA_HOME/state/wid.toml" <<EOF
active_issue = "Issue-7"
issue_dir = "$DEVDOC/Issue-7"
mr_url = "https://github.com/acme/widgets/pull/9"
branch = "feat/7-widgets"

[parked]
Issue-8 = true
EOF
  local i
  for i in 7 8; do
    cat > "$DEVDOC/Issue-$i/checklist.md" <<EOF
# Checklist — Issue-$i

Template: standard

## Revision 1

- [x] 0. pull
- [x] 1. research
- [!] 2. draft
- [ ] 3. spike
- [ ] 8. branch
- [ ] 12. commit
- [ ] 18. ship
- [ ] 19. mergetoall
- [ ] 20. mergemr
- [ ] 24. cleanup

## Log
EOF
  done
  printf 'Step:        2 draft\nReason:      fixture\n' > "$DEVDOC/Issue-7/STUCK"
  printf '# A captured idea\n\nBody.\n' > "$DEVDOC/Captures/idea/draft.md"
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:2002"]' \
    'trusted_approvers = ["github:1001"]'
}

# _snap: every path under the devdoc and the state dir, then each file's
# checksum — the "nothing was written" witness.
_snap() {
  find "$DEVDOC" "$DA_HOME/state" | sort
  find "$DEVDOC" "$DA_HOME/state" -type f -exec sha256sum {} + | sort
}

# _argv_for <entry-point>: the minimal arguments that carry <entry-point> to
# its trust check.
_argv_for() {
  case "$1" in
    pull)                        ARGS=(wid origin 7) ;;
    next|ship|cleanup|mergetoall|mergemr|comments|sync|transition-draft-start|park|unstuck|commit|branch|wbs-update|statusreport)
                                 ARGS=(wid) ;;
    capture/file)                ARGS=(--slug idea --target origin) ;;
    resume|switch)               ARGS=(wid Issue-8) ;;
    stuck)                       ARGS=(wid "a reason") ;;
    revise)                      ARGS=(wid --no-chain) ;;
    spike)                       ARGS=(create wid) ;;
    promote-potholes)            ARGS=(wid "$DEVDOC/Issue-7" --check) ;;
    checklist-advance|migrate-checklist-numbering)
                                 ARGS=("$DEVDOC/Issue-7") ;;
    checklist-init)              ARGS=(--project wid "$DEVDOC/Issue-7") ;;
    checklist-log)               ARGS=("$DEVDOC/Issue-7" draft "a message") ;;
    checklist-mark)              ARGS=("$DEVDOC/Issue-7" 2 x) ;;
    checklist-stuck)             ARGS=("$DEVDOC/Issue-7" "a reason") ;;
    checklist-unstuck)           ARGS=(--pending "$DEVDOC/Issue-7") ;;
    *) return 1 ;;
  esac
}

# _lib: source trust.sh as an entry point would.
_lib() {
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
  source "$PLUGIN_ROOT/scripts/lib/trust.sh"
}

@test "entry-points: TRUST_ENTRY_POINTS equals the scripts calling trust_entry_check" {
  _lib
  local f found=() want missing extra
  while IFS= read -r f; do
    f="${f#"$PLUGIN_ROOT/scripts/"}"
    found+=("${f%.sh}")
  done < <(grep -rlE --include='*.sh' '^trust_entry_check(_devdoc)? "' "$PLUGIN_ROOT/scripts" | sort)
  want="$(printf '%s\n' "${TRUST_ENTRY_POINTS[@]}" | sort)"
  missing="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "${found[@]}" | sort))"
  extra="$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "${found[@]}" | sort))"
  [ -z "$missing" ] || { echo "in TRUST_ENTRY_POINTS but no call: $missing" >&2; return 1; }
  [ -z "$extra" ] || { echo "calls trust_entry_check but not in TRUST_ENTRY_POINTS: $extra" >&2; return 1; }
  [ "${#found[@]}" -ge 29 ] || { echo "only ${#found[@]} callers" >&2; return 1; }
}

@test "entry-points: each refuses with 9 when whoami is a trusted id" {
  _wid
  _lib
  export DEVAGENT_DEVDOC_DIR="$DEVDOC" DEVAGENT_ISSUE_BACKEND_DIR="$PLUGIN_ROOT/scripts/issue"
  export DEVAGENT_REPO_ORIGIN=acme/widgets
  local ep before after fails=0 calls
  for ep in "${TRUST_ENTRY_POINTS[@]}"; do
    _argv_for "$ep" || { echo "no argv for $ep" >&2; fails=$((fails + 1)); continue; }
    rm -f "$GH_STUB_ARGV_LOG"
    before="$(_snap)"
    run --separate-stderr "$PLUGIN_ROOT/scripts/$ep.sh" "${ARGS[@]}"
    after="$(_snap)"
    if [ "$status" -ne 9 ] || [[ "$stderr" != *"trust: account github:1001 is in trusted_approvers"* ]]; then
      echo "$ep: rc=$status stderr=$stderr" >&2
      fails=$((fails + 1))
      continue
    fi
    calls=""
    [ ! -f "$GH_STUB_ARGV_LOG" ] || calls="$(grep -vE -- "$WHOAMI_RE" "$GH_STUB_ARGV_LOG" || true)"
    if [ -n "$calls" ]; then
      echo "$ep: calls beyond whoami: $calls" >&2
      fails=$((fails + 1))
    fi
    if [ "$before" != "$after" ]; then
      echo "$ep: wrote before refusing:" >&2
      diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
      fails=$((fails + 1))
    fi
  done
  [ "$fails" -eq 0 ]
}

@test "file: project derived from devdoc_dir; zero or two matches refuse 9" {
  _wid
  export DEVAGENT_ISSUE_BACKEND_DIR="$PLUGIN_ROOT/scripts/issue" DEVAGENT_REPO_ORIGIN=acme/widgets
  local f="$PLUGIN_ROOT/scripts/capture/file.sh"

  DEVAGENT_DEVDOC_DIR="$DEVDOC" run --separate-stderr "$f" --slug idea --target origin
  [ "$status" -eq 9 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [[ "$stderr" == *"trust: account github:1001 is in trusted_approvers"* ]]
  [ ! -e "$DEVDOC/Captures/idea/.pending" ]

  # No project owns this devdoc dir; an ambient DEVAGENT_PROJECT is never read.
  local other="$BATS_TEST_TMPDIR/devDoc/nobody"
  mkdir -p "$other/Captures/idea"
  cp "$DEVDOC/Captures/idea/draft.md" "$other/Captures/idea/"
  DEVAGENT_PROJECT=wid DEVAGENT_DEVDOC_DIR="$other" run --separate-stderr "$f" --slug idea --target origin
  [ "$status" -eq 9 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [[ "$stderr" == *"trust: capture/file could not resolve a project"* ]]

  # Two projects share wid's devdoc dir.
  cat >> "$DA_HOME/config.toml" <<EOF

[project.twin]
source_dir = "$BATS_TEST_TMPDIR/twin"
devdoc_dir = "$DEVDOC"
EOF
  rm -f "$GH_STUB_ARGV_LOG"
  DEVAGENT_DEVDOC_DIR="$DEVDOC" run --separate-stderr "$f" --slug idea --target origin
  [ "$status" -eq 9 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [[ "$stderr" == *"trust: capture/file could not resolve a project"* ]]
  [ ! -s "$GH_STUB_ARGV_LOG" ]
  [ ! -e "$DEVDOC/Captures/idea/.pending" ]
}
