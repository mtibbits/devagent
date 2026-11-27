#!/usr/bin/env bats
# #713 task 9: the trust policy's documentation stays equal to the code — the
# spec §3.8 key table to trust_policy.py's KEYS (one claim, two homes), and
# the pointers that lead an operator to §3.8.

load 'lib/bats-helpers'
load 'lib/trust-fixture'
. "$(dirname "$BATS_TEST_FILENAME")/lib/changelog-text.bash"

SPEC="$PLUGIN_ROOT/docs/specs/2026-05-19-devagent-plugin-design.md"

# _key_rows: stdin markdown → `key|type`, one per row of the table headed
# `| Key | Type | Default |`. The one parser for the spec side.
_key_rows() {
  awk -F'|' '
    /^\| *Key *\| *Type *\| *Default *\|/ { on = 1; next }
    on && /^\|[- |]+\|$/ { next }
    on && /^\|/ { k = $2; t = $3; gsub(/^ +| +$|`/, "", k); gsub(/^ +| +$|`/, "", t); print k "|" t; next }
    on { exit }'
}

@test "docs: spec key table equals KEYS" {
  local spec code
  spec="$(_key_rows < "$SPEC" | sort)"
  code="$(trust_py keys | tr '\t' '|' | sort)"
  [ "$(grep -c . <<<"$code")" -ge 30 ]
  [ "$spec" = "$code" ] || { diff <(echo "$spec") <(echo "$code"); false; }
}

@test "docs: §3.8 and §8 cover the trust policy" {
  grep -q '^### 3.8 Trust policy' "$SPEC"
  grep -q '^### 8.2 Gates under trust' "$SPEC"
  local sec
  sec="$(awk '/^### 3.8 Trust policy/ { on = 1 } /^## 4\./ { on = 0 } on' "$SPEC")"
  local want
  for want in /etc/devagent/trust /c/ProgramData/devagent/trust '$HOME/.config/devagent/trust' \
              'exit 9' 'exit 10' digest single_identity system_policy '#902' '#720' 'gh auth status'; do
    [[ "$sec" == *"$want"* ]] || { echo "§3.8 lacks: $want" >&2; return 1; }
  done
}

@test "docs: README, the config skel, doctor.md and CHANGELOG point at §3.8" {
  grep -q '§3.8' "$PLUGIN_ROOT/README.md"
  grep -q '§3.8' "$PLUGIN_ROOT/templates/config.toml.skel"
  grep -q '§3.8' "$PLUGIN_ROOT/commands/doctor.md"
  # From [Unreleased] to the end, so a release cut that moves the entry under
  # a dated heading keeps this green.
  awk '/^## \[Unreleased\]/ { on = 1; next } on' "$PLUGIN_ROOT/CHANGELOG.md" | grep -q '#713'
}

@test "docs: the hermetic guard's system locations equal TRUST_SYSTEM_DIRS" {
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
  source "$PLUGIN_ROOT/scripts/lib/trust.sh"
  local guard
  guard="$(sed -n 's/^for _trust_loc in \(.*\); do$/\1/p' "$PLUGIN_ROOT/tests/lib/hermetic-env.bash" \
    | tr ' ' '\n' | grep -v HOME)"
  # positive control: the parser found the guard's loop.
  [ -n "$guard" ]
  [ "$guard" = "$(printf '%s\n' "${TRUST_SYSTEM_DIRS[@]}")" ] \
    || { echo "hermetic guard: $guard; TRUST_SYSTEM_DIRS: ${TRUST_SYSTEM_DIRS[*]}" >&2; false; }
}

# --- #715: staging, the trust render and the floor

@test "docs: §3.3 names state/staging and §9.3 carries the trust render (#715)" {
  local s33 s93
  s33="$(awk '/^### 3\.3 / { on = 1 } /^### 3\.4 / { on = 0 } on' "$SPEC")"
  s93="$(awk '/^### 9\.3 / { on = 1 } /^### 9\.3\.1 / { on = 0 } on' "$SPEC")"
  [[ "$s33" == *"state/staging"* ]]
  [[ "$s33" == *"trap staging_discard EXIT"* ]]
  [[ "$s93" == *"Comments not rendered under trust:"* ]]
  [[ "$s93" == *"<U+00HH>"* ]]
  [[ "$s93" == *"With no trust policy in scope, \`pull.sh\` writes this verbatim"* ]]
  [[ "$s93" == *"#953"* ]]
}

@test "docs: pull.md covers the floor (#715)" {
  local sec want
  sec="$(awk '/^## Under a trust policy/ { on = 1; next } /^## / { on = 0 } on' "$PLUGIN_ROOT/commands/pull.md")"
  for want in allowed_steering size_cap '`steering`' '`size`' '#953' 'state/staging' 'Comments not rendered under trust:'; do
    [[ "$sec" == *"$want"* ]] || { echo "pull.md's trust section lacks: $want" >&2; return 1; }
  done
}

@test "docs: the sample policies load (#715)" {
  local sample six e list
  # The toml sample in pull.md's trust section.
  sample="$(awk '/^## Under a trust policy/ { on = 1 } on && /^```toml/ { f = 1; next } f && /^```/ { exit } f' "$PLUGIN_ROOT/commands/pull.md")"
  [[ "$sample" == *allowed_steering* ]]
  trust_fixture_policy "$BATS_TEST_TMPDIR/a" "${TRUST_FIXTURE_MIN[@]}" "$sample"
  run trust_py load "$BATS_TEST_TMPDIR/a"
  [ "$status" -eq 0 ] || { echo "pull.md sample: $output" >&2; return 1; }
  # The six entries the changelog says this queue uses.
  local cl; cl="$(changelog_text "$PLUGIN_ROOT")"
  six="$(sed -n '/this queue uses six entries/,/tier:impl-sonnet/p' <<<"$cl" | tr '\n' ' ' \
    | sed 's/.*this queue uses six entries,//; s/tier:impl-sonnet`.*/tier:impl-sonnet`/' | grep -oE '`[^`]+`' | tr -d '`')"
  [ "$(grep -c . <<<"$six")" -eq 6 ]
  list=""
  while IFS= read -r e; do list+="${list:+, }\"$e\""; done <<<"$six"
  trust_fixture_policy "$BATS_TEST_TMPDIR/b" "${TRUST_FIXTURE_MIN[@]}" "allowed_steering = [$list]"
  run trust_py load "$BATS_TEST_TMPDIR/b"
  [ "$status" -eq 0 ] || { echo "changelog six: $output" >&2; return 1; }
}

@test "docs: pull.md gives a consumer action for exit 1 under trust (#715)" {
  grep -Eq '^- `1` under a trust policy, with nothing written' "$PLUGIN_ROOT/commands/pull.md"
  grep -q 'do not retry in a loop' "$PLUGIN_ROOT/commands/pull.md"
}

# --- #923: the chars check

@test "docs: pull.md, §9.3 and §3.3 cover chars (#923)" {
  local sec s33 s93 want
  sec="$(awk '/^## Under a trust policy/ { on = 1; next } /^## / { on = 0 } on' "$PLUGIN_ROOT/commands/pull.md")"
  for want in '`chars`' allowed_chars '<U+XXXX>' 'detail:' 'remove the label' 'edit the text' 'subdivision-flag emoji'; do
    [[ "$sec" == *"$want"* ]] || { echo "pull.md's trust section lacks: $want" >&2; return 1; }
  done
  s33="$(awk '/^### 3\.3 / { on = 1 } /^### 3\.4 / { on = 0 } on' "$SPEC")"
  s93="$(awk '/^### 9\.3 / { on = 1 } /^### 9\.3\.1 / { on = 0 } on' "$SPEC")"
  [[ "$s33" == *".mixed.json"* ]]
  for want in '`chars`' '.mixed.json' 'Unicode 16.0.0'; do
    [[ "$s93" == *"$want"* ]] || { echo "spec 9.3 lacks: $want" >&2; return 1; }
  done
}

@test "docs: the changelog names the pinned Unicode version (#923)" {
  local v
  v="$(python3 -I -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("t", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.UNICODE_VERSION)' "$PLUGIN_ROOT/scripts/lib/chars_table.py")"
  [ "$v" = 16.0.0 ]
  [[ "$(changelog_text "$PLUGIN_ROOT")" == *"Unicode $v"* ]]
}
