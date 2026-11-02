#!/usr/bin/env bats
# #713 task 9: the trust policy's documentation stays equal to the code — the
# spec §3.8 key table to trust_policy.py's KEYS (one claim, two homes), and
# the pointers that lead an operator to §3.8.

load 'lib/bats-helpers'
load 'lib/trust-fixture'

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
  awk '/^## \[Unreleased\]/ { on = 1; next } /^## \[/ { on = 0 } on' "$PLUGIN_ROOT/CHANGELOG.md" | grep -q '#713'
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
