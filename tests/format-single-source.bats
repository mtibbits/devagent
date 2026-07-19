#!/usr/bin/env bats
# #134: single-source the red-team output formats. Templates define CHECKS;
# skills define OUTPUT (severity taxonomy, summary counts, verdict vocabulary,
# and — for redmr — the statusreport-parsed log line). These are exact-sentence
# canaries (#116 style): the mapping notes deliberately retain the historical
# tokens, so bare-token greps would be wrong.

REPO="${DEVAGENT_ROOT:-$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)}"

@test "redteam_mr.md no longer mandates its own severity scale (#134)" {
    run grep -F 'rate severity as: **block**' "$REPO/templates/redteam_mr.md"
    [ "$status" -ne 0 ]
}

@test "redteam_issue.md no longer mandates the READY-TO-POST verdict line (#134)" {
    run grep -F '<READY TO POST / REVISE (Major) / NOT READY (Blocking)>' \
        "$REPO/templates/redteam_issue_shared.md"
    [ "$status" -ne 0 ]
}

@test "redteam_issue.md no longer mandates the dimension-count Summary line (#134)" {
    run grep -F 'X Blocking, X Major, X Minor, X Clean, X N/A' \
        "$REPO/templates/redteam_issue_shared.md"
    [ "$status" -ne 0 ]
}

@test "old red/orange verdict RULES are gone from redteam_issue.md (#134 improve H3)" {
    run grep -F 'An issue with two or more :orange_circle: scores should be revised.' \
        "$REPO/templates/redteam_issue_shared.md"
    [ "$status" -ne 0 ]
}

@test "both red-team surfaces state the precedence rule (#134/#458)" {
    # #458: the MR red-team's output contract moved into its agent system prompt
    # (skills/core-redmr is now a fork prompt bound to devagent:redteam-reviewer).
    # core-redissue still owns its contract skill-side — the asymmetry is real,
    # so each assertion names the file that OWNS the rule.
    grep -qF "output contract wins" "$REPO/agents/redteam-reviewer.md"
    grep -qF "this skill's output contract wins" "$REPO/skills/core-redissue/SKILL.md"
}

@test "redmr names the machine-parsed log token (#134/#458)" {
    # The log line is emitted by the MAIN session, so the token lives with it.
    grep -q 'machine-parsed by statusreport' "$REPO/commands/redmr.md"
}

@test "core-redissue never references checklist.md (#130 pin preserved) (#134)" {
    run grep -q 'checklist\.md' "$REPO/skills/core-redissue/SKILL.md"
    [ "$status" -ne 0 ]
}

@test "redmr's documented log line keeps the parsed token (#134 review MED/#458)" {
    # The one machine-parsed surface: rewording "B blocking" (e.g. to
    # "B blockers") would silently blind statusreport while every other
    # test stays green — empirically confirmed during review.
    # #458 moved the log emission to the wrapper; the count line ALSO appears in
    # the agent's artifact format, so pin both or a reword could split them.
    grep -qF '"Red-team: B blocking, M major, m minor, I info' \
        "$REPO/commands/redmr.md"
    grep -qF 'B blocking, M major, m minor, I info' \
        "$REPO/agents/redteam-reviewer.md"
}

@test "the artifact-header model enumeration is single-valued across its nine homes (#458/#527)" {
    # The rc table tells the wrapper WHAT to stamp; the enumeration and the
    # agent's ## Artifact format tell the checker what is LEGAL. They are three
    # statements of one contract per bound step, and they shipped divergent
    # once: the rc-2 stamp `inherit (per-issue)` was absent from every
    # enumeration (review MAJOR-1), so a checker resolving the conflict could
    # normalise the provenance of the one path that most needs an audit trail.
    # #527 added the third bound step (improve): 3 wrappers + 3 agents + 3
    # fork-prompt skills = nine homes, one sweep.
    local f tok
    for tok in '<tier> (per-issue)' 'inherit (per-issue)' 'inherit (fallback from <tier>)'; do
        for f in "$REPO/commands/preship.md" "$REPO/commands/redmr.md" \
                 "$REPO/commands/improve.md" \
                 "$REPO/agents/preship-verifier.md" "$REPO/agents/redteam-reviewer.md" \
                 "$REPO/agents/plan-improver.md"; do
            grep -qF "$tok" "$f" || { echo "missing '$tok' from $f" >&2; false; }
        done
    done
    # The fork-prompt skills are the remaining homes (redmr r2 MAJOR: their
    # direct-invocation stamp `model: inherit` shipped outside the enumerated
    # set). Every stamp a skill names must be in the set; bare `inherit` is now
    # enumerated, and the skills carry both forms they can instruct.
    for f in "$REPO/skills/core-preship/SKILL.md" "$REPO/skills/core-redmr/SKILL.md" \
             "$REPO/skills/core-improve/SKILL.md"; do
        grep -qF 'inherit (per-issue)' "$f" || { echo "missing rc-2 stamp in $f" >&2; false; }
        grep -qF '`model: inherit`' "$f" || { echo "missing direct-invocation stamp in $f" >&2; false; }
    done
    for f in "$REPO/commands/preship.md" "$REPO/commands/redmr.md" \
             "$REPO/commands/improve.md" \
             "$REPO/agents/preship-verifier.md" "$REPO/agents/redteam-reviewer.md" \
             "$REPO/agents/plan-improver.md"; do
        grep -qF '`inherit`,' "$f" || { echo "bare inherit missing from the enumeration in $f" >&2; false; }
    done
    # Each side names its own agent-default form, and no other's — the negative
    # half is load-bearing: a §-for-§ copy that leaves a neighbour's token in
    # place re-opens the exact divergence this test exists to close.
    grep -qF 'agent-default (preship-verifier)' "$REPO/commands/preship.md"
    grep -qF 'agent-default (preship-verifier)' "$REPO/agents/preship-verifier.md"
    grep -qF 'agent-default (redteam-reviewer)' "$REPO/commands/redmr.md"
    grep -qF 'agent-default (redteam-reviewer)' "$REPO/agents/redteam-reviewer.md"
    grep -qF 'agent-default (plan-improver)' "$REPO/commands/improve.md"
    grep -qF 'agent-default (plan-improver)' "$REPO/agents/plan-improver.md"
    run grep -c 'agent-default (redteam-reviewer)' "$REPO/agents/preship-verifier.md"
    [ "$output" -eq 0 ]
    run grep -c 'agent-default (redteam-reviewer)' "$REPO/agents/plan-improver.md"
    [ "$output" -eq 0 ]
    run grep -c 'agent-default (preship-verifier)' "$REPO/agents/plan-improver.md"
    [ "$output" -eq 0 ]
    run grep -c 'agent-default (plan-improver)' "$REPO/agents/preship-verifier.md"
    [ "$output" -eq 0 ]
    run grep -c 'agent-default (plan-improver)' "$REPO/agents/redteam-reviewer.md"
    [ "$output" -eq 0 ]
    # ... and the WRAPPERS too (#527 review S1): a botched wrapper copy that
    # leaves a neighbour's token behind would pass a positive-only check.
    run grep -c 'agent-default (redteam-reviewer)' "$REPO/commands/improve.md"
    [ "$output" -eq 0 ]
    run grep -c 'agent-default (preship-verifier)' "$REPO/commands/improve.md"
    [ "$output" -eq 0 ]
    run grep -c 'agent-default (plan-improver)' "$REPO/commands/redmr.md"
    [ "$output" -eq 0 ]
    run grep -c 'agent-default (preship-verifier)' "$REPO/commands/redmr.md"
    [ "$output" -eq 0 ]
    run grep -c 'agent-default (plan-improver)' "$REPO/commands/preship.md"
    [ "$output" -eq 0 ]
    run grep -c 'agent-default (redteam-reviewer)' "$REPO/commands/preship.md"
    [ "$output" -eq 0 ]
}

@test "all bound-step wrappers carry the same wrapper-owned step default (#458/#527)" {
    # The rc-3 default model lives in the WRAPPERS (the agents are deliberately
    # unpinned — a frontmatter pin makes the #291 inherit escape unreachable;
    # measured, see tests/agents.bats). Wrapper copies of one constant are a
    # twin-drift surface: pin that all name the same token, and that no
    # agent grew a model pin back.
    run grep -c 'explicit `model: opus`' "$REPO/commands/preship.md"
    [ "$output" -eq 1 ]
    run grep -c 'explicit `model: opus`' "$REPO/commands/redmr.md"
    [ "$output" -eq 1 ]
    run grep -c 'explicit `model: opus`' "$REPO/commands/improve.md"
    [ "$output" -eq 1 ]
    run grep -c '^model:' <(awk '/^---$/{c++; next} c==1{print} c==2{exit}' "$REPO/agents/preship-verifier.md")
    [ "$output" -eq 0 ]
    run grep -c '^model:' <(awk '/^---$/{c++; next} c==1{print} c==2{exit}' "$REPO/agents/redteam-reviewer.md")
    [ "$output" -eq 0 ]
    run grep -c '^model:' <(awk '/^---$/{c++; next} c==1{print} c==2{exit}' "$REPO/agents/plan-improver.md")
    [ "$output" -eq 0 ]
}
