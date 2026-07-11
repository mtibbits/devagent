#!/usr/bin/env bats
# #136: the plugin's shipped templates and skills must be PROJECT-NEUTRAL — no
# VOLK-specific criteria injected into a non-VOLK project. VOLK's specifics live
# in its devdoc override (registry L2), not the plugin defaults.

REPO="${BATS_TEST_DIRNAME}/.."

@test "no VOLK-specific token in the plugin templates (#136)" {
  # Case-insensitive VOLK project markers that must NOT ship in the defaults.
  run grep -rniE 'volk|lgpl|\bdsp\b|\bsdr\b|gnu ?radio|plot_pr_evidence|VOLK_CONFIGPATH|num_points|\bsimd\b|dechirp|\bneon\b|kernel|warmup|vector length' "$REPO/templates"
  # #337: rc-precise. grep rc 1 = clean no-match; rc 2 = error (dir renamed/
  # unreadable) which `-ne 0` would false-pass, blinding the canary.
  [ "$status" -eq 1 ] || { echo "VOLK token in templates/ (or grep error):" >&2; echo "$output" >&2; return 1; }
}

@test "no VOLK-specific token in the shipped skills (#136)" {
  run grep -rniE 'volk|lgpl|\bdsp\b|\bsdr\b|gnu ?radio|plot_pr_evidence|VOLK_CONFIGPATH|src/devDoc/volk|num_points|\bsimd\b|dechirp|\bneon\b|kernel|warmup|vector length' "$REPO/skills"
  # #337: rc-precise (see the templates canary above).
  [ "$status" -eq 1 ] || { echo "VOLK token in skills/ (or grep error):" >&2; echo "$output" >&2; return 1; }
}

@test "the redteam_issue 16-dimension structure survives genericization (#136/#134)" {
  # Genericizing the prose must not remove the dimensions #134 depends on.
  local f="$REPO/templates/redteam_issue.md"
  grep -q '## The Sixteen Dimensions' "$f"
  local n; n="$(grep -cE '^### [0-9]+\. ' "$f")"
  [ "$n" -eq 16 ]
}

@test "no phantom /devagent:run-suite or :born-red in shipped invocation messages (#412)" {
  # Neither has a commands/*.md or a skills-registry entry; the real invocation is
  # the bash script (run-suite.sh / born-red.sh). Grep shipped source only — NOT
  # tests/, which necessarily names the forbidden strings here.
  run grep -rnE '/devagent:(run-suite|born-red)' \
      "$REPO/scripts" "$REPO/commands" "$REPO/skills" "$REPO/templates"
  # rc-precise (#337): rc 1 = clean no-match; rc 2 = grep error must not false-pass.
  [ "$status" -eq 1 ] || { echo "phantom invocation (or grep error):" >&2; echo "$output" >&2; return 1; }
}

@test "the real /devagent:draftmr reference survives in mr_template (#412)" {
  grep -q '/devagent:draftmr' "$REPO/templates/mr_template.md"
}
