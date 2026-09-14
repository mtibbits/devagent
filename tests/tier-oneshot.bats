#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_CASE="standard"

  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC" "$BATS_TEST_TMPDIR/volk"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$DEVDOC"

[project.volk.issue_source]
backend = "github"
repo = "gnuradio/volk"
dir_prefix = "Issue-"
EOF
}

teardown() { teardown_tmp_devagent_home; }

# --- Task 1: template fixture + §12 resolution -------------------------------

@test "checklist-oneshot carries exactly rows 0/7/9/19/20 (#537)" {
  tpl="$PLUGIN_ROOT/templates/checklist-oneshot.md"
  [ -f "$tpl" ]
  [ "$(grep -cE '^\- \[ \] +[0-9]+\.' "$tpl")" -eq 5 ]
  grep -qE '^\- \[ \] +0\. pull' "$tpl"
  grep -qE '^\- \[ \] +9\. implement' "$tpl"
  grep -qE '^\- \[ \] +11\. document' "$tpl"
  grep -qE '^\- \[ \] 22\. lessonslearned' "$tpl"
  grep -qE '^\- \[ \] 23\. cleanup' "$tpl"
}

@test "checklist-oneshot carries the evidence note and the no-repo-change boundary (#537)" {
  tpl="$PLUGIN_ROOT/templates/checklist-oneshot.md"
  grep -q "execution evidence" "$tpl"
  grep -q "not a repo change" "$tpl"
}

@test "oneshot is §12-resolvable through checklist_init (#537)" {
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
  d="$BATS_TEST_TMPDIR/issue"
  mkdir -p "$d"
  ISSUE_ID="Issue-999" checklist_init "$d" oneshot
  grep -q '^Template: oneshot$' "$d/checklist.md"
}

# --- Task 4: executor carve-out fixture-greps --------------------------------

@test "implement.md carries both absent-producing-step carve-outs (#537)" {
  f="$PLUGIN_ROOT/commands/implement.md"
  grep -q "producing step is absent from the issue's checklist is N/A" "$f"
  grep -q "branch produces the branch" "$f"
  grep -q "draft produces imPlan.md" "$f"
  grep -q "execute directly against the issue body" "$f"
}

@test "document.md carries the absent-draft-step carve-out (#537)" {
  f="$PLUGIN_ROOT/commands/document.md"
  grep -q "producing step is absent from the issue's checklist is N/A" "$f"
  grep -qE "checklist omits draft" "$f"
}

# --- Task 5: end-to-end oneshot chain ----------------------------------------

@test "scaffolded oneshot issue chains through next.sh to 7 then 9 without an executor halt (#537)" {
  export GH_STUB_BODY_JSON='"## Workflow flags\ntier: oneshot\n\nDo the thing."'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 710
  [ "$status" -eq 0 ]
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run /devagent:implement"* ]]
  run "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$DEVDOC/Issue-710" 9 x
  [ "$status" -eq 0 ]
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run /devagent:document"* ]]
}

# --- Task 7: spec-lag tripwire + allowlist sweep -----------------------------

@test "spec carries the tier table with oneshot defined and simple/ultra reserved (#537, #435 tripwire)" {
  spec="$PLUGIN_ROOT/docs/specs/2026-05-19-devagent-plugin-design.md"
  grep -q "Workflow tier profiles" "$spec"
  grep -q 'checklist-oneshot' "$spec"
  grep -qE '\| *oneshot *\|' "$spec"
  grep -qE '\| *simple *\| *RESERVED' "$spec"
  grep -qE '\| *ultra *\| *RESERVED' "$spec"
}

@test "spec tier table stays in sweep with tier_allowlist (#537, Issue-458 sweep)" {
  spec="$PLUGIN_ROOT/docs/specs/2026-05-19-devagent-plugin-design.md"
  source "$PLUGIN_ROOT/scripts/lib/flags.sh"
  for t in $(tier_allowlist); do
    grep -qE "^\| *${t} *\|" "$spec"
  done
  # the config sample/skel comments are POINTERS, not a second list —
  # a pipe-delimited tier enumeration outside the table is drift surface
  run grep -E 'standard \| docs-only \| research \| perf' "$spec" "$PLUGIN_ROOT/templates/config.toml.skel"
  [ "$status" -ne 0 ]
}

# --- #595: the mechanical boundary check is named in every prose home ---------

@test "checklist-oneshot boundary paragraph names the check and stays true after a retier (#595 AC4)" {
  tpl="$PLUGIN_ROOT/templates/checklist-oneshot.md"
  grep -q 'oneshot-zerodiff.sh' "$tpl"
  grep -q 'default_baseline' "$tpl"
  # retier leaves this prose on a standard checklist (revise.md:39-42): the
  # enforcement claim must be scoped to the header, not stated flat
  grep -qE 'While this checklist.s .Template:. reads .oneshot.' "$tpl"
  # the pre-existing #537 pins must survive the rewrite
  grep -q "execution evidence" "$tpl"
  grep -q "not a repo change" "$tpl"
}

@test "implement.md:27 — the issue's second prose home — carries the reframed invariant (#595 r2 SE2)" {
  f="$PLUGIN_ROOT/commands/implement.md"
  grep -q 'oneshot-zerodiff.sh' "$f"
  grep -q 'no unpublished change' "$f"
  # the #537 carve-out pins survive
  grep -q "branch produces the branch" "$f"
  grep -q "producing step is absent from the issue's checklist is N/A" "$f"
}

@test "document.md keys the verify beat on the TIER and carves the straggler commit out (#595)" {
  f="$PLUGIN_ROOT/commands/document.md"
  grep -q 'oneshot-zerodiff.sh' "$f"
  grep -q 'Not on a oneshot issue' "$f"
  # the permitted shape: the beat's trigger sentence names the Template: header
  grep -qE 'Template:. header is .oneshot.' "$f"
}

@test "cleanup.md documents the oneshot boundary precondition, canary-safe (#595 AC4)" {
  f="$PLUGIN_ROOT/commands/cleanup.md"
  grep -q 'CLAUDE_PLUGIN_ROOT}/scripts/oneshot-zerodiff.sh' "$f"
  grep -q -- '--retier standard' "$f"
  grep -q 'restarts the issue at draft' "$f"
  grep -q '.devagent-oneshot-ack' "$f"
}

@test "spec's oneshot tier row names the mechanical enforcement (#595 AC4)" {
  spec="$PLUGIN_ROOT/docs/specs/2026-05-19-devagent-plugin-design.md"
  run grep -cE '^\| oneshot \|.*oneshot-zerodiff' "$spec"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}
