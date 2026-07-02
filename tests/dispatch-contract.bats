#!/usr/bin/env bats
# #151: dispatch-contract carrier sweep (pattern: completion-handoff-mark.bats).
#
# Every file that names step-model.sh carries the checking-class dispatch
# contract: fresh-context packaging, model resolution with inherit fallback,
# and the mandatory context:/model: artifact-header grammar. Discovering
# carriers by grep (not a hardcoded list) means a future carrier — a new
# checking-class skill, or review gaining its own core- skill — is covered
# the day it appears, and a vacuous-pass guard pins today's floor.

REPO="${BATS_TEST_DIRNAME}/.."

_contract_carriers() {
  grep -rl 'step-model.sh' "$REPO/skills" "$REPO/commands"
}

@test "every dispatch-contract carrier states the full contract (#151)" {
  local files; mapfile -t files < <(_contract_carriers)
  # Guard against a vacuous pass: core-improve, core-redmr, review.md,
  # plus the improve/redmr wrappers that name the resolver.
  [ "${#files[@]}" -ge 3 ]
  local f p missing=()
  for f in "${files[@]}"; do
    # Wrappers that merely hand the project through only need the pointer;
    # full-contract carriers are the files defining a dispatch.
    grep -qE '## Dispatch contract|requesting-code-review' "$f" || continue
    for p in 'step-model.sh' 'inherit' 'context: subagent' 'context: inline'; do
      grep -qF "$p" "$f" || missing+=("$f:$p")
    done
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'missing contract token: %s\n' "${missing[@]}" >&2
  fi
  [ "${#missing[@]}" -eq 0 ]
}

@test "both checking-class skills define the contract section + path packaging (#151)" {
  local f
  for f in "$REPO/skills/core-improve/SKILL.md" "$REPO/skills/core-redmr/SKILL.md"; do
    grep -q '## Dispatch contract' "$f"
    grep -q 'paths, not' "$f"
  done
}
