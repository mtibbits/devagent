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

@test "no VOLK-specific token in the shipped command docs (#136/#427)" {
  # #427: commands/ is where residual identity text actually survived (ship.md
  # named gnuradio/volk, auth.md examples used volk) because the #340 canary
  # scanned only templates/ + skills/. Widen the scan to the command docs so an
  # identity regression in a shipped command fails CI. (cite-hygiene.bats already
  # scans commands/ but as a citation-PROSE canary (#342) — a different invariant.)
  run grep -rniE 'volk|lgpl|\bdsp\b|\bsdr\b|gnu ?radio|plot_pr_evidence|VOLK_CONFIGPATH|src/devDoc/volk|num_points|\bsimd\b|dechirp|\bneon\b|kernel|warmup|vector length' "$REPO/commands"
  # #337: rc-precise (see the templates canary above).
  [ "$status" -eq 1 ] || { echo "VOLK token in commands/ (or grep error):" >&2; echo "$output" >&2; return 1; }
}

@test "the redteam_issue 16-dimension structure survives genericization (#136/#134/#443)" {
  # Genericizing the prose must not remove the dimensions #134 depends on.
  # #443: the monolith was split — the "Sixteen Dimensions" intro lives in
  # _shared, and the 16 dimension bodies are partitioned across the 3 tier files
  # (light 1,3,5 / standard 2,4,6,7,12,15 / full 8-11,13,14,16). Assert the intro
  # survives in _shared and the COMPOSED dimension count across the tier files is 16.
  grep -q '## The Sixteen Dimensions' "$REPO/templates/redteam_issue_shared.md"
  # Summed with awk, not `paste -sd+ | bc`: bc is NOT a documented prerequisite
  # (docs-site/install.md lists bash, python3, jq, git + bats/shellcheck) and does
  # not ship with Git for Windows, so the bc form made this the one test that
  # could not run on a stock Windows checkout. awk is already required and used
  # throughout the suite.
  local n; n="$(grep -hcE '^### [0-9]+\. ' \
      "$REPO/templates/redteam_issue_light.md" \
      "$REPO/templates/redteam_issue_standard.md" \
      "$REPO/templates/redteam_issue_full.md" | awk '{s+=$1} END{print s+0}')"
  [ "$n" -eq 16 ] || { echo "composed dimension count = $n (expected 16)" >&2; return 1; }
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

@test "#561: every issue/epic template boilerplate names BOTH model keys" {
  # Sweep guard (register: Issue-458 — a contract enumerated in N files needs ONE
  # sweep over all N homes, extended in the same change that adds a home). The
  # subject set is DERIVED, not listed: any template carrying the `## Workflow
  # flags` boilerplate must document both keys, so a seventh template added later
  # cannot ship divergent.
  local f n=0 missing=()
  for f in "$REPO"/templates/*.md; do
    grep -q 'Optional per-issue `## Workflow flags`' "$f" || continue
    n=$((n + 1))
    grep -q 'implementation-model' "$f" && grep -q 'checking-model' "$f" \
      || missing+=("$(basename "$f")")
  done
  # assert the DENOMINATOR too: a glob that stops selecting its subjects passes
  # silently (register: Issue-439), so pin the count of boilerplate carriers.
  [ "$n" -eq 6 ] || { echo "boilerplate carriers = $n (expected 6)" >&2; return 1; }
  [ "${#missing[@]}" -eq 0 ] || { echo "missing model keys: ${missing[*]}" >&2; return 1; }
}

@test "#561: the marker prose in config.toml.skel documents the keyed form" {
  # config.toml.skel is the file every new project copies its config from, and it
  # previously said the marker holds "ONE tier token" pinning "the CHECKING-class
  # steps" with "Non-checking steps ignore the marker" — all false after #561.
  # This home was missed by the round-1 plan's enumerated list even though its own
  # derivation command (grep -rn devagent-step-models) finds it.
  grep -q 'checking: fable' "$REPO/templates/config.toml.skel"
  grep -q 'thinking: sonnet' "$REPO/templates/config.toml.skel"
  run grep -c 'Non-checking$' "$REPO/templates/config.toml.skel"
  [ "$status" -eq 1 ]
}

@test "#561: prose step numbers are the UNION of the authoritative class lists in config.sh" {
  # BLIND SPOT, stated here because a checker's green overclaims unless its limits
  # are written into the checker itself (register: Issue-558). This asserts SET
  # MEMBERSHIP over the union of both class lists, per file — it catches renumbering
  # drift (its motivation: #560 renumbered these three commits before this issue,
  # and this issue's own capture shipped the pre-#560 numbers). It does NOT verify
  # class ASSIGNMENT: a home that swapped the lists — claiming
  # `implementation-model` steers 5/15/16/17 — would pass, because the union is
  # identical. That is the more damaging drift for an operator. Anchoring each
  # class's numbers to its key's vicinity needs per-paragraph scoping over prose
  # that varies in shape across 11 homes; deferred rather than faked, and recorded
  # in the issue's future-enhancements file. Found by the step-16 red-team.
  # The step->class map lives in code (scripts/lib/config.sh's two `case` lines).
  # This change restated those step numbers in prose across many homes, and #560
  # renumbered them three commits earlier — this issue's own capture shipped the
  # PRE-#560 numbers and had to be hand-corrected. So DERIVE both lists from
  # config.sh and assert every home that documents the model keys agrees, rather
  # than trusting ~9 hand-copied lists (register: Issue-439, derive the member set
  # mechanically; Issue-458, one sweep over all N homes).
  local thinking checking
  thinking="$(sed -n 's/.*case " \(2 9[0-9 ]*\)" in.*/\1/p' "$REPO/scripts/lib/config.sh" | head -1)"
  checking="$(sed -n 's/.*case " \(5 15[0-9 ]*\)" in.*/\1/p' "$REPO/scripts/lib/config.sh" | head -1)"
  thinking="$(echo $thinking)"; checking="$(echo $checking)"
  # guard the DERIVATION itself: an empty capture would make every check below
  # vacuously pass (register: Issue-151, mutation-test the guard)
  [ "$thinking" = "2 9 10 11 14" ] || { echo "thinking map drifted or capture failed: '$thinking'" >&2; return 1; }
  [ "$checking" = "5 15 16 17" ]   || { echo "checking map drifted or capture failed: '$checking'" >&2; return 1; }

  # Subject set: files that ENUMERATE the class mapping, not merely mention the
  # keys. A file that enumerates the thinking class names `draftmr` (step 14, the
  # list's tail); one that only references the keys in passing — e.g.
  # docs/draft-dispatch-contract.md, which is about step 2 alone, or pull.sh's
  # implementation comments — legitimately does not, and must not be forced to.
  local f n=0 bad=()
  while IFS= read -r f; do
    grep -q 'draftmr' "$f" || continue
    n=$((n + 1))
    # normalize both prose forms: "2 draft · 9 implement …" and "steps 2 9 10 11 14"
    local nums
    nums="$(grep -oE '\b(2|5|9|10|11|14|15|16|17)\b' "$f" | sort -n -u | tr '\n' ' ')"
    for s in $thinking $checking; do
      [[ " $nums " == *" $s "* ]] || { bad+=("$(basename "$f"):missing-$s"); break; }
    done
  done < <(grep -rl 'implementation-model' "$REPO/docs" "$REPO/commands" "$REPO/templates" "$REPO/scripts" "$REPO/CHANGELOG.md" 2>/dev/null)
  # Pin the DENOMINATOR: a glob or grep that stops selecting its subjects passes
  # silently (register: Issue-439). 11 = 6 issue/epic templates + config.toml.skel
  # + spec + commands/pull.md + flags.sh + CHANGELOG.md.
  [ "$n" -eq 11 ] || { echo "class-enumerating homes = $n (expected 11) — did a home lose its enumeration, or gain one?" >&2; return 1; }
  [ "${#bad[@]}" -eq 0 ] || { echo "homes with an incomplete step list: ${bad[*]}" >&2; return 1; }
}
