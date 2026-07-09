# Shared bats helpers for devAgent Phase 6 tests.
#
# Usage in a .bats file:
#   load 'helpers/fixtures'
#   setup() { fixture_init volk Issue-676; }

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# #322: hermetic env (pins / git config / TZ / locale)
. "$(dirname "${BASH_SOURCE[0]}")/../lib/hermetic-env.bash"

# fixture_init <project> <issue-dir-name>
fixture_init() {
  local project="$1"
  local issue="$2"

  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude/devagent/state"
  mkdir -p "$HOME/.claude/devagent/secrets"

  local devdoc="$BATS_TEST_TMPDIR/devdoc/$project"
  mkdir -p "$devdoc/$issue/revisions"

  FIX_PROJECT="$project"
  FIX_ISSUE="$issue"
  FIX_ISSUE_DIR="$devdoc/$issue"
  FIX_STATE_FILE="$HOME/.claude/devagent/state/${project}.toml"
  FIX_CONFIG_FILE="$HOME/.claude/devagent/config.toml"

  cat >"$FIX_CONFIG_FILE" <<EOF
[defaults]
checklist_template = "standard"

[project.${project}]
source_dir   = "$BATS_TEST_TMPDIR/src/${project}"
devdoc_dir   = "$devdoc"

[project.${project}.code_source]
backend  = "github"
upstream = "example/${project}"
fork     = "fork/${project}"
EOF

  cat >"$FIX_STATE_FILE" <<EOF
active_issue   = "$issue"
issue_dir      = "$FIX_ISSUE_DIR"
branch         = "fix/0-stub"
last_step      = 15
last_step_name = "ship"
mr_url         = "https://github.com/example/${project}/pull/842"
revision       = 1
updated_at     = "2026-05-19T14:32:00-04:00"
EOF

  cat >"$FIX_ISSUE_DIR/checklist.md" <<'EOF'
# Issue — Workflow checklist

State key: [ ] pending  [x] done  [-] skipped  [!] stuck  [~] in-progress  [?] blocked-external  [P] parked

Template: standard
Created: 2026-05-19 14:01
Active revision: 1

## Revision 1

- [x]  0. pull
- [x]  1. draft
- [x]  2. scope
- [x]  3. improve
- [x]  4. prune
- [x]  5. tighten
- [x]  6. branch
- [x]  7. implement
- [x]  8. quality
- [x]  9. document
- [x] 10. commit
- [x] 11. analyze
- [x] 12. draftmr
- [x] 13. review
- [x] 14. redmr
- [x] 15. ship
- [ ] 16. mergetoall
- [ ] 17. updatewbs
- [ ] 18. impact
- [ ] 19. lessonslearned
- [ ] 20. cleanup

## Log
- 2026-05-19 14:01  pull: fetched example/stub#0, scaffold created
- 2026-05-19 17:10  ship: MR #842 opened
EOF

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# stub_mr_comments <text>
stub_mr_comments() {
  local text="$1"
  local stub="$BATS_TEST_TMPDIR/bin/devagent-code-github"
  cat >"$stub" <<EOF
#!/usr/bin/env bash
# Stub for code/github.sh used by tests.
if [[ "\$1" == "mr-comments" ]]; then
  cat <<'PAYLOAD'
$text
PAYLOAD
  exit 0
fi
echo "stub: unknown verb \$1" >&2
exit 2
EOF
  chmod +x "$stub"
  export DEVAGENT_CODE_BACKEND_CMD="$stub"
}

# stub_chain_recorder
stub_chain_recorder() {
  local stub="$BATS_TEST_TMPDIR/bin/devagent-chain"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/chain.log"
EOF
  chmod +x "$stub"
  export DEVAGENT_CHAIN_CMD="$stub"
}
