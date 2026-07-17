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
