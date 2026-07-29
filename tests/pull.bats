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

  # Config with both origin and fork issue sources
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$DEVDOC"

[project.volk.issue_source]
backend = "github"
repo = "gnuradio/volk"
dir_prefix = "Issue-"

[project.volk.issue_source_fork]
backend = "github"
repo = "mtibbits/volk"
dir_prefix = "Issue-Fork-"
EOF
}

teardown() { teardown_tmp_devagent_home; }

@test "pull origin scaffolds Issue-N dir and writes issue.md" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  [ -d "$DEVDOC/Issue-676" ]
  [ -f "$DEVDOC/Issue-676/issue.md" ]
  [ -f "$DEVDOC/Issue-676/checklist.md" ]
  grep -q "gnuradio/volk#676" "$DEVDOC/Issue-676/issue.md"
}

@test "pull fork uses dir_prefix Issue-Fork-" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk fork 42
  [ "$status" -eq 0 ]
  [ -d "$DEVDOC/Issue-Fork-42" ]
}

@test "pull marks step 0 done in checklist" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -E '^\- \[x\] +0\. pull' "$DEVDOC/Issue-676/checklist.md"
}

@test "pull appends a log entry naming the source and issue" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -E 'pull: fetched gnuradio/volk#676' "$DEVDOC/Issue-676/checklist.md"
}

@test "pull sets state.active_issue and state.issue_dir" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -q 'active_issue *= *"Issue-676"' "$DA_HOME/state/volk.toml"
  grep -q "issue_dir *= *\"$DEVDOC/Issue-676\"" "$DA_HOME/state/volk.toml"
}

@test "pull keeps mergetoall pre-skipped without all_prs_branch" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -qE '^- \[-\] 19\. mergetoall' "$DEVDOC/Issue-676/checklist.md"
}

@test "pull flips mergetoall to pending when the project sets all_prs_branch" {
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$DEVDOC"
all_prs_branch = "dev/all-prs"

[project.volk.issue_source]
backend = "github"
repo = "gnuradio/volk"
dir_prefix = "Issue-"
EOF
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -qE '^- \[ \] 19\. mergetoall' "$DEVDOC/Issue-676/checklist.md"
}

@test "pull is idempotent on issue.md (refetch overwrites, checklist preserved)" {
  "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  # Tamper with the checklist so we can prove it wasn't blown away
  printf '\nUSER-EDIT\n' >> "$DEVDOC/Issue-676/checklist.md"
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -q "USER-EDIT" "$DEVDOC/Issue-676/checklist.md"
}

@test "pull rejects missing origin|fork token" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk 676
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin|fork"* ]]
}

@test "pull rejects non-numeric issue number" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin notanumber
  [ "$status" -ne 0 ]
}

@test "pull rejects unknown project with recovery menu (no network)" {
  run "$PLUGIN_ROOT/scripts/pull.sh" nosuchproj origin 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found in config.toml"* ]]
  [[ "$output" == *"/devagent:init nosuchproj"* ]]
  # AC6: no scaffold dir created for the bogus project.
  [ ! -d "$BATS_TEST_TMPDIR/devDoc/nosuchproj" ]
}

@test "pull of a new issue clears the previous issue's per-issue keys (#98)" {
  mkdir -p "$DA_HOME/state"
  cat > "$DA_HOME/state/volk.toml" <<CTX
active_issue = "Issue-1"
issue_dir = "$DEVDOC/Issue-1"
branch = "fix/1-old"
mr_url = "https://example.com/pr/1"
CTX
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -qE '^branch = ""$' "$DA_HOME/state/volk.toml"
  grep -qE '^mr_url = ""$' "$DA_HOME/state/volk.toml"
}

@test "pull snapshots the displaced unparked issue's context (#98)" {
  mkdir -p "$DA_HOME/state"
  cat > "$DA_HOME/state/volk.toml" <<CTX
active_issue = "Issue-1"
issue_dir = "$DEVDOC/Issue-1"
branch = "fix/1-old"
CTX
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  v="$(python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" context.Issue-1.branch)"
  [ "$v" = "fix/1-old" ]
}

@test "re-pull of the active issue preserves its in-flight context (#98)" {
  "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/state/volk.toml" branch "fix/676-mid-flight"
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -qE '^branch = "fix/676-mid-flight"$' "$DA_HOME/state/volk.toml"
}

@test "pull of a parked issue drops the parked flag and GCs its stale snapshot (#98 redmr MAJ-1)" {
  mkdir -p "$DA_HOME/state"
  cat > "$DA_HOME/state/volk.toml" <<CTX
active_issue = ""

[context.Issue-676]
branch = "feat/676-OLD"

[parked]
Issue-676 = true
CTX
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" parked.Issue-676
  [ "$status" -ne 0 ]
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" context.Issue-676.branch
  [ "$status" -ne 0 ]
}

@test "park, re-pull, rebranch, resume cannot resurrect the pre-park context (#98 redmr MAJ-1 e2e)" {
  "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/state/volk.toml" branch "feat/676-OLD"
  "$PLUGIN_ROOT/scripts/park.sh" volk
  "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/state/volk.toml" branch "feat/676-NEW"
  run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-676
  # resume must NOT clobber the live branch with the stale snapshot,
  # whatever its exit status (pull dropped the parked flag → refusal is fine).
  grep -qE '^branch = "feat/676-NEW"$' "$DA_HOME/state/volk.toml"
}

@test "#247: pull displacing an in-flight unparked issue notifies that its context was preserved" {
  mkdir -p "$DA_HOME/state"
  cat > "$DA_HOME/state/volk.toml" <<CTX
active_issue = "Issue-1"
issue_dir = "$DEVDOC/Issue-1"
branch = "fix/1-old"
CTX
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  # Targeted notice: names the displaced issue, says preserved, points to resume.
  [[ "$output" == *"Issue-1"* ]]
  [[ "$output" == *"preserved"* ]]
  [[ "$output" == *"resume"* ]]
}

@test "#247: the displacement notice is distinct from the generic state_set concurrency warning" {
  mkdir -p "$DA_HOME/state"
  cat > "$DA_HOME/state/volk.toml" <<CTX
active_issue = "Issue-1"
issue_dir = "$DEVDOC/Issue-1"
branch = "fix/1-old"
CTX
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  # The #247 notice carries "preserved"; the generic warning does not.
  echo "$output" | grep -i 'preserved' | grep -qi 'Issue-1'
}

@test "#247: re-pull of the same active issue prints NO displacement notice" {
  "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/state/volk.toml" branch "fix/676-mid"
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  [[ "$output" != *"preserved"* ]]
}

@test "#247: pull with no prior active issue prints NO displacement notice" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  [[ "$output" != *"preserved"* ]]
}

@test "#247: pull displacing an issue with no in-flight context prints NO notice (nothing set aside)" {
  mkdir -p "$DA_HOME/state"
  # active_issue set, but NO in-flight keys (branch/baseline/etc all empty) →
  # state_context_save snapshots nothing → no notice.
  cat > "$DA_HOME/state/volk.toml" <<CTX
active_issue = "Issue-1"
issue_dir = "$DEVDOC/Issue-1"
CTX
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  [[ "$output" != *"preserved"* ]]
}

@test "pull.sh never writes the global pointer (#282)" {
  # pull's project is always an explicit positional; its old unconditional
  # active_set_project was the banned arg-clobber. Seed + fingerprint.
  echo 'active_project = "other"' > "$DA_HOME/state/_active.toml"
  touch -d '2026-01-01 00:00:00' "$DA_HOME/state/_active.toml"
  before="$(stat -c '%Y' "$DA_HOME/state/_active.toml"; cat "$DA_HOME/state/_active.toml")"
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 7
  [ "$status" -eq 0 ]
  after="$(stat -c '%Y' "$DA_HOME/state/_active.toml"; cat "$DA_HOME/state/_active.toml")"
  [ "$before" = "$after" ]
}

@test "pull.sh applies a devdoc checklist-template override (#120)" {
  mkdir -p "$DEVDOC/templates"
  printf '# PULL OVERRIDE MARKER #120\n- [ ]  0. pull\n- [ ] 23. cleanup\n\n## Log\n' \
    > "$DEVDOC/templates/checklist-standard.md"
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 7
  [ "$status" -eq 0 ]
  grep -q 'PULL OVERRIDE MARKER #120' "$DEVDOC/Issue-7/checklist.md"
}

# --- #415: displacement parks + is recoverable; re-pull restores -------------
_seed_displaced_676() {   # pull 676, give it a branch, pull 842 → 676 displaced
  "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676 >/dev/null
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/state/volk.toml" branch "feat/676-work"
  "$PLUGIN_ROOT/scripts/pull.sh" volk origin 842 >/dev/null   # displaces Issue-676
}

@test "#415: pull displacing an in-flight issue parks it AND marks it displaced" {
  _seed_displaced_676
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" parked.Issue-676
  [ "$status" -eq 0 ]
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" displaced.Issue-676
  [ "$status" -eq 0 ]
  # Its context snapshot is preserved.
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" context.Issue-676.branch
  [ "$status" -eq 0 ]
}

@test "#415 AC1: displaced issue is recoverable via the advertised resume" {
  _seed_displaced_676
  run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-676
  [ "$status" -eq 0 ]
  grep -qE '^active_issue = "Issue-676"$' "$DA_HOME/state/volk.toml"
  grep -qE '^branch = "feat/676-work"$' "$DA_HOME/state/volk.toml"   # context restored
}

@test "#415 AC1: displaced issue is recoverable via the advertised switch" {
  _seed_displaced_676
  run "$PLUGIN_ROOT/scripts/switch.sh" volk Issue-676
  [ "$status" -eq 0 ]
  grep -qE '^active_issue = "Issue-676"$' "$DA_HOME/state/volk.toml"
  grep -qE '^branch = "feat/676-work"$' "$DA_HOME/state/volk.toml"
}

@test "#415 AC2: re-pull of the displaced issue restores it — does NOT delete the context" {
  _seed_displaced_676
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676   # re-pull the displaced issue
  [ "$status" -eq 0 ]
  grep -qE '^active_issue = "Issue-676"$' "$DA_HOME/state/volk.toml"
  # The preserved branch is RESTORED to the live top level (not lost, and not left
  # stranded in the context table — read the top-level key precisely).
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" branch
  [ "$output" = "feat/676-work" ]
  # the snapshot is consumed by the restore, and the displacement marker cleared
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" context.Issue-676.branch
  [ "$status" -ne 0 ]
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" displaced.Issue-676
  [ "$status" -ne 0 ]
}

@test "#415: operator park clears a leaked displaced marker → re-pull GCs, no MAJ-1 resurrection" {
  # Seed a LEAKED displacement marker on an issue carrying real live work.
  mkdir -p "$DA_HOME/state" "$DEVDOC/Issue-676"
  cat > "$DA_HOME/state/volk.toml" <<CTX
active_issue = "Issue-676"
issue_dir = "$DEVDOC/Issue-676"
branch = "feat/676-REAL-WORK"

[displaced]
Issue-676 = true
CTX
  "$PLUGIN_ROOT/scripts/park.sh" volk            # operator park MUST clear the marker
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" displaced.Issue-676
  [ "$status" -ne 0 ]
  "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676 >/dev/null   # re-pull: fresh start
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get "$DA_HOME/state/volk.toml" branch
  [ "$output" != "feat/676-REAL-WORK" ]          # #98 MAJ-1: stale context NOT resurrected
}

# --- #537: per-issue tier override -------------------------------------------

@test "pull with tier: oneshot in Workflow flags scaffolds checklist-oneshot (#537)" {
  export GH_STUB_BODY_JSON='"Intro.\n\n## Workflow flags\ntier: oneshot\n\n## Motivation\nStuff."'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 700
  [ "$status" -eq 0 ]
  grep -q '^Template: oneshot$' "$DEVDOC/Issue-700/checklist.md"
  [ "$(grep -cE '^\- \[.\] +[0-9]+\.' "$DEVDOC/Issue-700/checklist.md")" -eq 5 ]
  grep -qE '^\- \[x\] +0\. pull' "$DEVDOC/Issue-700/checklist.md"
  grep -qE '^\- \[ \] +9\. implement' "$DEVDOC/Issue-700/checklist.md"
}

@test "pull rejects unknown tier pre-path with the legal-names list (#537)" {
  export GH_STUB_BODY_JSON='"## Workflow flags\ntier: ../evil\n"'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 701
  [ "$status" -ne 0 ]
  [[ "$output" == *"legal tiers: oneshot standard perf docs-only research"* ]]
  [ ! -f "$DEVDOC/Issue-701/checklist.md" ]
}

@test "flags block quoted in a comment does not override the default (#537)" {
  export GH_STUB_COMMENTS_JSON='[{"author": {"login": "bob"}, "createdAt": "2026-05-12T08:14:22Z", "body": "quoting:\n## Workflow flags\ntier: oneshot"}]'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 702
  [ "$status" -eq 0 ]
  grep -q '^Template: standard$' "$DEVDOC/Issue-702/checklist.md"
}

@test "tier flag added after first scaffold is inert on re-pull (#537)" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 703
  [ "$status" -eq 0 ]
  grep -q '^Template: standard$' "$DEVDOC/Issue-703/checklist.md"
  export GH_STUB_BODY_JSON='"## Workflow flags\ntier: oneshot\n"'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 703
  [ "$status" -eq 0 ]
  grep -q '^Template: standard$' "$DEVDOC/Issue-703/checklist.md"
}

@test "template boilerplate comment left in the body does not tier the issue (#537 redmr)" {
  export GH_STUB_BODY_JSON='"## Motivation\nStuff.\n\n<!-- Optional per-issue workflow tier (spec §6.3 tier table; delete if unused):\n## Workflow flags\ntier: oneshot\n-->\n"'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 704
  [ "$status" -eq 0 ]
  grep -q '^Template: standard$' "$DEVDOC/Issue-704/checklist.md"
}

# ---- #561: per-issue model steering — body keys and the tier: compat shim ----
#
# Every case asserts the MARKER CONTENT pull.sh wrote AND resolves it through the
# real step-model.sh for a step in each class. Asserting rc alone would pass
# whether or not the marker was written (register: Issue-32 — assert an
# observable per-item effect, never just rc), and resolving pull.sh's OWN
# produced artifact is what pins the two components' format agreement rather
# than a prose promise (register: Issue-232).

_step_tier() {  # <step> <issue-dir> -> stdout tier (stderr dropped)
  "$PLUGIN_ROOT/scripts/step-model.sh" volk "$1" "$2" 2>/dev/null
}

@test "#561 AC1: checking-model: fable steers 5/15/16/17 and leaves the thinking class alone" {
  cat >> "$DA_HOME/config.toml" <<'EOF'

[project.volk.step_models]
thinking = "sonnet"
checking = "opus"
EOF
  export GH_STUB_BODY_JSON='"Intro.\n\n## Workflow flags\nchecking-model: fable\n\n## Motivation\nStuff."'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 710
  [ "$status" -eq 0 ]
  local d="$DEVDOC/Issue-710"
  grep -q '^checking: fable$' "$d/.devagent-step-models"
  run grep -c '^thinking:' "$d/.devagent-step-models"
  [ "$status" -eq 1 ]   # precise no-match, never -ne 0 (register: Issue-337)
  for s in 5 15 16 17; do
    [ "$(_step_tier "$s" "$d")" = "fable" ]
  done
  # thinking class still resolves the config table
  for s in 2 9 10 11 14; do
    [ "$(_step_tier "$s" "$d")" = "sonnet" ]
  done
}

@test "#561 AC2: implementation-model: haiku steers 2/9/10/11/14 only" {
  cat >> "$DA_HOME/config.toml" <<'EOF'

[project.volk.step_models]
thinking = "sonnet"
checking = "opus"
EOF
  export GH_STUB_BODY_JSON='"## Workflow flags\nimplementation-model: haiku\n"'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 711
  [ "$status" -eq 0 ]
  local d="$DEVDOC/Issue-711"
  grep -q '^thinking: haiku$' "$d/.devagent-step-models"
  run grep -c '^checking:' "$d/.devagent-step-models"
  [ "$status" -eq 1 ]
  for s in 2 9 10 11 14; do
    [ "$(_step_tier "$s" "$d")" = "haiku" ]
  done
  for s in 5 15 16 17; do
    [ "$(_step_tier "$s" "$d")" = "opus" ]
  done
}

@test "#561 AC1+AC2: both keys together write one line per class" {
  export GH_STUB_BODY_JSON='"## Workflow flags\nchecking-model: fable\nimplementation-model: sonnet\n"'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 712
  [ "$status" -eq 0 ]
  local d="$DEVDOC/Issue-712"
  grep -q '^checking: fable$' "$d/.devagent-step-models"
  grep -q '^thinking: sonnet$' "$d/.devagent-step-models"
  [ "$(_step_tier 16 "$d")" = "fable" ]
  [ "$(_step_tier 9 "$d")" = "sonnet" ]
}

@test "#561 AC3: tier: opus-checking pulls with a warning — the koopman-gnn#106 shape" {
  # Pre-#561 this body died pre-path ("unknown tier 'opus-checking'"), blocking
  # the pull of an already-drafted issue. It must now succeed, leave the template
  # on the project default chain, and steer the checking class.
  export GH_STUB_BODY_JSON='"## Workflow flags\ntier: opus-checking\n"'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 713
  [ "$status" -eq 0 ]
  [[ "$output" == *"model annotation, not a template tier"* ]]
  [[ "$output" == *"prefer 'checking-model:'"* ]]
  local d="$DEVDOC/Issue-713"
  grep -q '^Template: standard$' "$d/checklist.md"
  grep -q '^checking: opus$' "$d/.devagent-step-models"
  [ "$(_step_tier 16 "$d")" = "opus" ]
}

@test "#561 AC3: fable-checking shims too; bogus-checking still dies as a tier" {
  export GH_STUB_BODY_JSON='"## Workflow flags\ntier: fable-checking\n"'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 714
  [ "$status" -eq 0 ]
  grep -q '^checking: fable$' "$DEVDOC/Issue-714/.devagent-step-models"
  # NOT a shim (bogus is not a legal model) => falls through to tier_require_legal
  export GH_STUB_BODY_JSON='"## Workflow flags\ntier: bogus-checking\n"'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 715
  [ "$status" -ne 0 ]
  [[ "$output" == *"legal tiers: oneshot standard perf docs-only research"* ]]
  [ ! -f "$DEVDOC/Issue-715/checklist.md" ]
  [ ! -f "$DEVDOC/Issue-715/.devagent-step-models" ]
}

@test "#561 AC9: explicit checking-model beats the tier: shim, with a warning" {
  export GH_STUB_BODY_JSON='"## Workflow flags\ntier: opus-checking\nchecking-model: fable\n"'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 716
  [ "$status" -eq 0 ]
  [[ "$output" == *"beats 'tier: opus-checking'"* ]]
  local d="$DEVDOC/Issue-716"
  grep -q '^checking: fable$' "$d/.devagent-step-models"
  [ "$(_step_tier 16 "$d")" = "fable" ]
}

@test "#561 AC8: an illegal model token dies listing the tokens, BEFORE any write" {
  export GH_STUB_BODY_JSON='"## Workflow flags\nchecking-model: bogus\n"'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 717
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown model token 'bogus'"* ]]
  [[ "$output" == *"sonnet opus haiku fable inherit"* ]]
  # fail-closed: neither artifact exists, so a fail-open write is caught even if
  # the rc were wrong
  [ ! -f "$DEVDOC/Issue-717/checklist.md" ]
  [ ! -f "$DEVDOC/Issue-717/.devagent-step-models" ]
  # same for the thinking key
  export GH_STUB_BODY_JSON='"## Workflow flags\nimplementation-model: ../evil\n"'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 718
  [ "$status" -ne 0 ]
  [[ "$output" == *"sonnet opus haiku fable inherit"* ]]
  [ ! -f "$DEVDOC/Issue-718/checklist.md" ]
}

@test "#561: model keys are SCAFFOLD-ONLY — inert on re-pull, existing marker never stomped" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 719
  [ "$status" -eq 0 ]
  [ ! -f "$DEVDOC/Issue-719/.devagent-step-models" ]
  # a key added after first scaffold does not retro-write the marker
  export GH_STUB_BODY_JSON='"## Workflow flags\nchecking-model: fable\n"'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 719
  [ "$status" -eq 0 ]
  [ ! -f "$DEVDOC/Issue-719/.devagent-step-models" ]
  # and a hand-authored marker outranks a first-scaffold key: warn, do not stomp
  export GH_STUB_BODY_JSON='"## Workflow flags\nchecking-model: fable\n"'
  mkdir -p "$DEVDOC/Issue-720"
  printf 'haiku' > "$DEVDOC/Issue-720/.devagent-step-models"
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 720
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  [ "$(cat "$DEVDOC/Issue-720/.devagent-step-models")" = "haiku" ]
}

@test "#561: a model key quoted in a tracker comment cannot steer" {
  export GH_STUB_COMMENTS_JSON='[{"author": {"login": "bob"}, "createdAt": "2026-05-12T08:14:22Z", "body": "quoting:\n## Workflow flags\nchecking-model: fable"}]'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 721
  [ "$status" -eq 0 ]
  [ ! -f "$DEVDOC/Issue-721/.devagent-step-models" ]
}
