#!/usr/bin/env bats
# #443: redteam_issue.md is split by triage tier — a single-sourced shared core
# (triage gate, severity scale, adversarial questions, output contract) plus three
# cumulative dimension parts (light 1,3,5 / standard 2,4,6,7,12,15 / full
# 8-11,13,14,16). These guards pin: the composed dimension set is exactly {1..16}
# with no duplication, tier-shared content lives ONLY in _shared (the anti-#440
# re-duplication check), the "14 dimensions" typo is fixed, and a monolithic
# devdoc override still resolves and shadows all tiers (§12 registry migration).

REPO="${BATS_TEST_DIRNAME}/.."
T="$REPO/templates"
SHARED="$T/redteam_issue_shared.md"
LIGHT="$T/redteam_issue_light.md"
STANDARD="$T/redteam_issue_standard.md"
FULL="$T/redteam_issue_full.md"

@test "the 4 tier files exist and the monolith is gone (#443)" {
  for f in "$SHARED" "$LIGHT" "$STANDARD" "$FULL"; do
    [ -f "$f" ] || { echo "missing $f" >&2; return 1; }
  done
  [ ! -f "$T/redteam_issue.md" ] || { echo "plugin monolith redteam_issue.md must be removed" >&2; return 1; }
}

@test "composed dimensions are exactly {1..16}, each appearing once (#443)" {
  # dimension headers live only in the 3 tier files; shared carries none.
  run bash -c "grep -hoE '^### [0-9]+\. ' '$LIGHT' '$STANDARD' '$FULL' | grep -oE '[0-9]+' | sort -n | tr '\n' ' '"
  [ "$status" -eq 0 ]
  [ "$output" = "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 " ] \
    || { echo "composed dims != 1..16 once each: [$output]" >&2; return 1; }
  # shared must carry zero dimension bodies (all partitioned out).
  run grep -cE '^### [0-9]+\. ' "$SHARED"
  [ "$output" -eq 0 ] || { echo "_shared still has $output dimension bodies" >&2; return 1; }
}

@test "tier membership matches the triage gate (#443)" {
  local get="grep -hoE '^### [0-9]+\\. ' \"\$1\" | grep -oE '[0-9]+' | sort -n | tr '\\n' ' '"
  [ "$(bash -c "$get" _ "$LIGHT")" = "1 3 5 " ]
  [ "$(bash -c "$get" _ "$STANDARD")" = "2 4 6 7 12 15 " ]
  [ "$(bash -c "$get" _ "$FULL")" = "8 9 10 11 13 14 16 " ]
}

@test "tier-shared content is single-sourced in _shared, absent from tier files (#443)" {
  # The severity scale, the adversarial-questions battery, and the output contract
  # must appear ONLY in _shared — a copy in a tier file re-creates the duplication.
  grep -q '## Adversarial Questions' "$SHARED"
  grep -q '## Output Format' "$SHARED"
  grep -q 'severity scale' "$SHARED"
  local f
  for f in "$LIGHT" "$STANDARD" "$FULL"; do
    run grep -cE '## Adversarial Questions|## Output Format|## The Sixteen Dimensions|severity scale' "$f"
    [ "$output" -eq 0 ] || { echo "$(basename "$f") duplicates shared content" >&2; return 1; }
  done
}

@test "the pre-existing '14 dimensions' typo is fixed to 16 (#443)" {
  run grep -rl '14 dimensions' "$SHARED" "$LIGHT" "$STANDARD" "$FULL"
  [ "$status" -eq 1 ] || { echo "'14 dimensions' still present:" >&2; echo "$output" >&2; return 1; }
  grep -q '16 dimensions of scrutiny' "$SHARED"
}

@test "a monolithic devdoc override resolves and shadows all tiers (#443 registry migration)" {
  source "$REPO/scripts/lib/template_resolve.sh"
  export DEVAGENT_PLUGIN_TEMPLATES="$T"           # the real plugin templates (no monolith)
  local dd; dd="$(mktemp -d)"; mkdir -p "$dd/templates"
  export DEVAGENT_TEST_DEVDOC="$dd"

  # No override: `redteam_issue` (the monolith key) must NOT resolve — the plugin
  # ships no monolith, so the default path is the tier composition.
  run template_resolve devagent redteam_issue
  [ "$status" -eq 1 ] || { echo "redteam_issue resolved with no override + no plugin monolith (status=$status): $output" >&2; rm -rf "$dd"; return 1; }
  # The tier parts DO resolve at the plugin layer.
  run template_resolve devagent redteam_issue_shared
  [ "$status" -eq 0 ] && echo "$output" | grep -q 'layer=plugin' || { echo "redteam_issue_shared did not resolve at plugin: $output" >&2; rm -rf "$dd"; return 1; }

  # With a devdoc monolith override present, `redteam_issue` resolves at the devdoc
  # layer — the command uses it whole and shadows the tiers.
  printf '# my monolith override\n' > "$dd/templates/redteam_issue.md"
  run template_resolve devagent redteam_issue
  [ "$status" -eq 0 ] || { echo "monolith override did not resolve: $output" >&2; rm -rf "$dd"; return 1; }
  echo "$output" | grep -q 'layer=devdoc' || { echo "override resolved at wrong layer: $output" >&2; rm -rf "$dd"; return 1; }
  rm -rf "$dd"
}
