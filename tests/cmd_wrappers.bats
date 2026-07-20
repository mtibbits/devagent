#!/usr/bin/env bats

bats_require_minimum_version 1.5.0   # #526: run --separate-stderr for the offender-naming test

CMD_DIR="$BATS_TEST_DIRNAME/../commands"

# #526: classify skills by the user-invocable frontmatter marker with YAML-truth
# semantics, matching the pytest guard (test_frontmatter_yaml.py). Echoes the
# sorted DIRECTORY names (never `basename` — every skill is SKILL.md) of the
# user-invocable (NOT hidden) skills. A skill is HIDDEN iff, inside its frontmatter
# (between the first two `---`), `user-invocable:` has a value — trailing `#comment`
# and whitespace stripped — that is exactly one of PyYAML's bool casings
# {false,False,FALSE}. A space after the colon is required (YAML mapping rule), so
# body text, `user-invocable:false` (no space), and quoted/other-cased values all
# read as user-invocable, agreeing with yaml.safe_load. CR-tolerant (a `\r` on a
# CRLF file must not defeat the `---` anchor or leak into the value). Verified
# mawk-safe (`[ \t]`, no gawk-isms).
_user_invocable_skills() {
  local dir="${1:-$BATS_TEST_DIRNAME/../skills}" f name val
  local -a uinv=()
  for f in "$dir"/*/SKILL.md; do
    [ -e "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    val="$(awk '
      /^---[ \t\r]*$/ { c++; if (c >= 2) exit; next }
      c == 1 && /^user-invocable:[ \t]/ {
        sub(/\r$/, ""); sub(/^user-invocable:[ \t]*/, ""); sub(/[ \t]*#.*/, ""); sub(/[ \t]+$/, "")
        print; exit
      }
    ' "$f")"
    case "$val" in
      false|False|FALSE) ;;          # hidden — omit from the user-invocable set
      *) uinv+=("$name") ;;
    esac
  done
  [ ${#uinv[@]} -eq 0 ] && return 0
  printf '%s\n' "${uinv[@]}" | sort | tr '\n' ' ' | sed 's/ $//'
}

# #526: assert the user-invocable set equals the expected skills, NAMING the
# offenders on stderr (not a bare count) on mismatch. Run-able for the AC3 test.
# shellcheck disable=SC2120  # args ARE passed by the offender-naming @test; the
# count @test calls it argless via the ${1:-}/${2:-} defaults.
_check_user_invocable() {
  local dir="${1:-$BATS_TEST_DIRNAME/../skills}" expected="${2:-capture next ship}" got
  got="$(_user_invocable_skills "$dir")"
  if [ "$got" != "$expected" ]; then
    echo "user-invocable skills mismatch: got ($got), expected ($expected)" >&2
    return 1
  fi
}

@test "draft.md exists and is non-empty" {
  [ -f "$CMD_DIR/draft.md" ]
  [ -s "$CMD_DIR/draft.md" ]
}

@test "draft.md documents \$NOTE parsing per spec §6.1" {
  grep -qE '\$NOTE' "$CMD_DIR/draft.md"
  grep -qE 'project|issue' "$CMD_DIR/draft.md"
}

@test "draft.md references the wrapped skill (superpowers:writing-plans)" {
  grep -q 'superpowers:writing-plans' "$CMD_DIR/draft.md"
}

@test "draft.md instructs the pothole-register read + Potholes considered section (#286)" {
  grep -q 'potholes' "$CMD_DIR/draft.md"
  grep -q '## Potholes considered' "$CMD_DIR/draft.md"
}

@test "draft.md instructs the model to append a checklist log entry" {
  grep -q 'checklist-log.sh' "$CMD_DIR/draft.md"
}

@test "scope.md exists, invokes core-scope, parses \$NOTE, logs" {
  F="$CMD_DIR/scope.md"
  [ -f "$F" ]
  grep -q 'core-scope' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "improve.md exists, invokes core-improve, parses \$NOTE, logs" {
  F="$CMD_DIR/improve.md"
  [ -f "$F" ]
  grep -q 'core-improve' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "prune.md exists, invokes core-prune, parses \$NOTE, logs" {
  F="$CMD_DIR/prune.md"
  [ -f "$F" ]
  grep -q 'core-prune' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "tighten.md exists, invokes core-tighten, parses \$NOTE, logs" {
  F="$CMD_DIR/tighten.md"
  [ -f "$F" ]
  grep -q 'core-tighten' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "implement.md exists, invokes superpowers:executing-plans, parses \$NOTE, logs" {
  F="$CMD_DIR/implement.md"
  [ -f "$F" ]
  grep -q 'superpowers:executing-plans' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "quality.md exists, invokes simplify, references coding_standards.md, logs" {
  F="$CMD_DIR/quality.md"
  [ -f "$F" ]
  grep -q 'simplify' "$F"
  grep -q 'coding_standards' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "document.md exists, invokes core-document-actual-work, parses \$NOTE, logs" {
  F="$CMD_DIR/document.md"
  [ -f "$F" ]
  grep -q 'core-document-actual-work' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "draftmr.md exists, invokes core-draft-mr, parses \$NOTE, logs" {
  F="$CMD_DIR/draftmr.md"
  [ -f "$F" ]
  grep -q 'core-draft-mr' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "review.md exists, invokes superpowers:requesting-code-review, logs" {
  F="$CMD_DIR/review.md"
  [ -f "$F" ]
  grep -q 'superpowers:requesting-code-review' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "redmr.md exists, invokes core-redmr, parses \$NOTE, logs" {
  F="$CMD_DIR/redmr.md"
  [ -f "$F" ]
  grep -q 'core-redmr' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "impact.md exists, invokes core-impact, parses \$NOTE, logs" {
  F="$CMD_DIR/impact.md"
  [ -f "$F" ]
  grep -q 'core-impact' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "lessonslearned.md exists, invokes core-lessons-learned, parses \$NOTE, logs" {
  F="$CMD_DIR/lessonslearned.md"
  [ -f "$F" ]
  grep -q 'core-lessons-learned' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

# #114: the capture family must document a REAL env-derivation path, not a
# non-existent "Phase 1 config loader".
@test "capture skill documents the env-derivation sources, not a phantom loader (#114)" {
  F="$BATS_TEST_DIRNAME/../skills/capture/SKILL.md"
  grep -q 'CLAUDE_PLUGIN_ROOT' "$F"            # DEVAGENT_PLUGIN_DIR source
  grep -q 'config\.toml' "$F"                  # DEVAGENT_DEVDOC_DIR source
  grep -q 'devdoc_dir' "$F"
  grep -q 'active_project' "$F"                # DEVAGENT_PROJECT source (state)
  run grep -q 'Phase 1' "$F"                   # the phantom loader claim is gone
  [ "$status" -ne 0 ]
}

@test "file.md names the real push_mr env gate the script reads (#114)" {
  F="$CMD_DIR/file.md"
  grep -q 'DEVAGENT_PERMISSION_PUSH_MR' "$F"
}

# #133: a prerequisite whose producing step is absent from the issue's checklist
# must be treated as N/A, not halted on (docs-only omits analyze → draftmr; research
# omits branch → document).
@test "draftmr.md treats absent analyze step as N/A, not a halt (#133)" {
  F="$CMD_DIR/draftmr.md"
  grep -q 'absent from the issue' "$F"
  grep -q 'N/A' "$F"
  grep -qi 'docs-only' "$F"
}

@test "document.md treats absent branch step as N/A, not a halt (#133)" {
  F="$CMD_DIR/document.md"
  grep -q 'absent from the issue' "$F"
  grep -q 'N/A' "$F"
  grep -qi 'research' "$F"
}

@test "core-draft-mr and core-document-actual-work mirror the N/A carve-out (#133)" {
  grep -q 'absent from the issue' "$BATS_TEST_DIRNAME/../skills/core-draft-mr/SKILL.md"
  grep -q 'absent from the issue' "$BATS_TEST_DIRNAME/../skills/core-document-actual-work/SKILL.md"
}

@test "preship.md points to the checking-dispatch contract + keeps its wrapper duties (#149/#458/#528)" {
  F="$CMD_DIR/preship.md"
  [ -s "$F" ]
  grep -q 'core-preship' "$F"
  grep -q 'checklist-stuck.sh' "$F"
  # #528 INVERTS #458. #458 made preship.md a FULL carrier of the dispatch
  # contract (tier resolution, the inherit/context: enumeration). #528 extracted
  # that shared text into docs/checking-dispatch-contract.md, so preship.md is
  # now a POINTER stub: it keeps its `## Dispatch contract` heading, names the
  # doc it points at, and carries only its per-step delta (here, the bound
  # agent's default stamp). The full-carrier tokens (the step-model.sh call, the
  # inherit / context: subagent|inline enumeration) live in the doc now, and
  # dispatch-contract.bats asserts the doc carries them + that this wrapper is
  # correctly classified as a pointer.
  grep -q '^## Dispatch contract' "$F"
  grep -qF 'checking-dispatch-contract.md' "$F"
  grep -qF 'agent-default (preship-verifier)' "$F"
}

@test "command count matches the documented totals (#149)" {
  # Derived count — a new command that forgets the README/marketplace sweep
  # fails here instead of drifting silently (the '53 commands' class).
  # #452: next/capture/ship live as user-invocable skills; the skill half is
  # derived from the user-invocable frontmatter marker (core-* are pinned
  # `user-invocable: false`), so an unmarked core skill fails here too.
  # #526: the split is derived by `_user_invocable_skills` — a FRONTMATTER-scoped,
  # YAML-truth classifier (value in {false,False,FALSE}) that agrees with the
  # pytest guard and NAMES offenders, not the old whole-file literal-lowercase
  # grep (which missed `user-invocable: False` and failed as a bare count).
  # Assert the SPLIT, not just the sum: a 4th command->skill conversion keeps
  # the sum at 57 (53+4) and would slip through a sum-only check — while
  # falsifying README's explicit "54 commands + 3 user-invocable skills".
  n="$(ls "$CMD_DIR"/*.md | wc -l)"
  _check_user_invocable   # names offenders on stderr, fails on mismatch (AC3)
  s="$(_user_invocable_skills | wc -w)"
  [ "$n" -eq 54 ]
  [ "$s" -eq 3 ]
  [ $((n + s)) -eq 57 ]
  grep -q "57 slash commands" "$CMD_DIR/../README.md"
  # BOTH manifests carry the claim (#439 plan's enumeration); plugin.json was
  # unpinned while marketplace.json was, so the two could drift apart.
  grep -q "57 slash commands" "$CMD_DIR/../.claude-plugin/marketplace.json"
  grep -q "57 slash commands" "$CMD_DIR/../.claude-plugin/plugin.json"
  # #535: CHANGELOG is a FOURTH count home the sweep previously missed — the exact
  # drift this canary exists to catch, so it is enumerated here too.
  grep -q "57 slash commands" "$CMD_DIR/../CHANGELOG.md"
  # #535 redmr: the SPEC is a fifth home and contradicted itself three lines apart
  # (tree comment said 52 while the sum line said 53+3=56) — pin both.
  grep -q "54 + 3 = the 57 slash commands" "$CMD_DIR/../docs/specs/2026-05-19-devagent-plugin-design.md"
  grep -qE "command-form slash command \(54\)" "$CMD_DIR/../docs/specs/2026-05-19-devagent-plugin-design.md"
}

@test "user-invocable: frontmatter 'user-invocable: False' is hidden (#526)" {
  # Co-locate a visible skill so the assertion proves the classifier DISTINGUISHES
  # hidden-False from visible, not merely returns empty (which an empty glob does too).
  mkdir -p "$BATS_TEST_TMPDIR/skills/core-x" "$BATS_TEST_TMPDIR/skills/vis0"
  cat > "$BATS_TEST_TMPDIR/skills/core-x/SKILL.md" <<'S'
---
name: core-x
user-invocable: False
---
body
S
  printf -- '---\nname: vis0\n---\nbody\n' > "$BATS_TEST_TMPDIR/skills/vis0/SKILL.md"
  run _user_invocable_skills "$BATS_TEST_TMPDIR/skills"
  [ "$status" -eq 0 ]
  [ "$output" = "vis0" ]   # capital-False → hidden; vis0 (no marker) → visible (matches pytest)
}

@test "user-invocable: inline-comment 'false  # c' is hidden (#526)" {
  mkdir -p "$BATS_TEST_TMPDIR/skills/core-y" "$BATS_TEST_TMPDIR/skills/vis0"
  cat > "$BATS_TEST_TMPDIR/skills/core-y/SKILL.md" <<'S'
---
name: core-y
user-invocable: false  # hidden from the menu
---
body
S
  printf -- '---\nname: vis0\n---\nbody\n' > "$BATS_TEST_TMPDIR/skills/vis0/SKILL.md"
  run _user_invocable_skills "$BATS_TEST_TMPDIR/skills"
  [ "$status" -eq 0 ]
  [ "$output" = "vis0" ]   # comment-form false → hidden; vis0 → visible
}

@test "user-invocable: CRLF frontmatter 'user-invocable: false' is hidden (#526)" {
  # A \r must not defeat the '---' anchor or leak into the value (yaml.safe_load
  # parses CRLF fine → HIDDEN; the classifier must agree).
  mkdir -p "$BATS_TEST_TMPDIR/skills/core-crlf" "$BATS_TEST_TMPDIR/skills/vis0"
  printf -- '---\r\nname: core-crlf\r\nuser-invocable: false\r\n---\r\nbody\r\n' \
    > "$BATS_TEST_TMPDIR/skills/core-crlf/SKILL.md"
  printf -- '---\nname: vis0\n---\nbody\n' > "$BATS_TEST_TMPDIR/skills/vis0/SKILL.md"
  run _user_invocable_skills "$BATS_TEST_TMPDIR/skills"
  [ "$status" -eq 0 ]
  [ "$output" = "vis0" ]   # core-crlf hidden despite CRLF; vis0 visible
}

@test "user-invocable: body-text marker outside frontmatter does not hide (#526)" {
  mkdir -p "$BATS_TEST_TMPDIR/skills/vis"
  cat > "$BATS_TEST_TMPDIR/skills/vis/SKILL.md" <<'S'
---
name: vis
argument-hint: "x"
---
This skill mentions `user-invocable: false` in its body prose.
S
  run _user_invocable_skills "$BATS_TEST_TMPDIR/skills"
  [ "$status" -eq 0 ]
  [ "$output" = "vis" ]   # frontmatter-scoped: body text neither satisfies nor trips it
}

@test "user-invocable check names the offending skill, not a bare count (#526)" {
  mkdir -p "$BATS_TEST_TMPDIR/skills/core-oops"
  cat > "$BATS_TEST_TMPDIR/skills/core-oops/SKILL.md" <<'S'
---
name: core-oops
description: a core skill that forgot the marker
---
body
S
  run --separate-stderr _check_user_invocable "$BATS_TEST_TMPDIR/skills" "capture next ship"
  [ "$status" -eq 1 ]
  # shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr` (bats idiom)
  [[ "$stderr" == *core-oops* ]]
}
