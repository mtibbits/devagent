#!/usr/bin/env bats
# #559: crrf is an orchestration ALIAS whose behavior lives in its prompt.
# bats can pin the DOCUMENT (what the model is told); it cannot pin what the
# model does — that rung is evals/ (the crrf-* cases; open risk R1 in the
# issue's plan).
#
# Pin policy (Issue-561 "pin the CLAIM, not one phrasing of it"): pins target
# normative TOKENS that ARE the claim. Where a whole phrase is pinned, that
# phrase is CANONICAL VOCABULARY — frozen deliberately, and the test says so
# in a comment. Rewording a canonical phrase is a contract change, not an
# editorial edit.
#
# Positive literal pins match against $DOC (one read in setup, no per-assert
# process spawn — ~285ms/grep on this suite's Windows floor). NEGATIVES and
# line-anchored pins stay grep: grep is line-oriented, so `.` cannot cross a
# newline there, while a whole-file [[ ]] match would — that distinction is
# load-bearing for the `file.sh … --yes` guard below.

load 'lib/bats-helpers'

REPO="${BATS_TEST_DIRNAME}/.."
F="$REPO/commands/crrf.md"

setup() { DOC="$(<"$F")"; }

@test "crrf.md exists with frontmatter description and allowed-tools (#559)" {
  # argument-hint presence is already swept for every command doc by
  # tests/test_frontmatter_yaml.py — not re-pinned here (Issue-458).
  [ -s "$F" ]
  skill_frontmatter "$F" | grep -q '^description: '
  skill_frontmatter "$F" | grep -q '^allowed-tools: '
}

@test "AC1: the no-prompt grant is stated (#559)" {
  # canonical vocabulary: the grant phrase. (Bare verb-name greps were
  # dropped as vacuous — the four verbs are pinned by their DOC PATHS in the
  # pointer test below.)
  [[ "$DOC" == *'without intermediate confirmation prompts'* ]]
}

@test "AC2: the topic declaration precedes any artifact (#559)" {
  # canonical vocabulary: both phrases
  [[ "$DOC" == *'a statement, not a question'* ]]
  [[ "$DOC" == *'before any artifact is created'* ]]
}

@test "AC3: the multi-artifact path is specified end to end (#559)" {
  # Q1 — the invocation PRE-ANSWERS capture's multi-epic prompt; the prompt is
  # SATISFIED, not skipped. Canonical vocabulary: the answer sentence itself,
  # so a reword into an override ("ignore the confirmation") fails here.
  [[ "$DOC" == *'author those you deem appropriate for the declared topic'* ]]
  # Q2 — children are PROMOTED to their own top-level captures, then filed.
  [[ "$DOC" == *'scripts/capture/capture.sh'* ]]
  [[ "$DOC" == *'--type issue --subtype'* ]]
  [[ "$DOC" == *'--slug-suffix'* ]]              # U4: collision disambiguator
  [[ "$DOC" == *'content hash'* ]]               # #252 idempotent suffix form
  [[ "$DOC" == *'Parent epic:'* ]]               # linkage home 1 (child draft)
  [[ "$DOC" == *'staging copies superseded'* ]]  # children/NN-*.md disposition
  [[ "$DOC" == *'epic draft is filed as well'* ]]  # case-safe: no leading article
}

@test "AC3 anti-bypass: crrf never tells the model to disregard a verb doc (#559)" {
  # The Q1 answer's whole point is that no Issue-321 contradiction is created.
  # An override-flavored verb is the regression this pins. rc-precise (#337).
  run grep -niE 'bypass|disregard|override the (capture|verb)|skip the (capture )?(skill|prompt)' "$F"
  [ "$status" -eq 1 ]
}

@test "AC4: all three premise-level halt triggers are present (#559)" {
  [[ "$DOC" == *'duplicate'* ]]
  [[ "$DOC" == *'unsound'* ]]
  [[ "$DOC" == *'Verdict: split'* ]]
}

@test "AC5: the revise bound is stated (#559)" {
  # token pin: the bound IS the claim
  [[ "$DOC" == *'at most two revise cycles'* ]]
}

@test "AC6: the push_mr gate is delegated, never bypassed (#559)" {
  # (a) the prohibition sentence
  [[ "$DOC" == *'MUST NOT pass'* ]]
  # (b) rc-precise negative (#337): an OPERATIVE `file.sh … --yes`. The
  # prohibition sentence puts --yes BEFORE file.sh, so it stays legal.
  # `.`, not `[^\n]` — a POSIX bracket expression treats \n as two literals,
  # which let `--target origin --yes` slip the guard (#559 improve B2). Stays
  # grep: line-oriented `.` is the point.
  run grep -nE 'file\.sh.*--yes' "$F"
  [ "$status" -eq 1 ]
  # (c) the delegated gate signal
  [[ "$DOC" == *'exit code 4'* ]]
}

@test "AC7: the manifest contract is stated (#559)" {
  # The doc's operative sections are numbered; pin the numbered heading form
  # (`^## Manifest` can never match `## 5. Manifest` — #559 improve B1).
  grep -qE '^## [0-9]+\. Manifest' "$F"
  [[ "$DOC" == *'tracker URL'* ]]
  [[ "$DOC" == *'halt reason'* ]]
  [[ "$DOC" == *'kept'* ]]
  [[ "$DOC" == *'discarded'* ]]
}

@test "crrf is NOT a workflow-checklist step (#559)" {
  # The updatewbs.md alias precedent carries a Completion-handoff block because
  # it IS a workflow step. crrf lives in the pre-issue capture stage (issue Out
  # of scope), so a copy-pasted handoff block — or any checklist-mark call — is
  # a defect, not boilerplate. rc-precise (#337).
  run grep -nF '## Completion handoff' "$F"; [ "$status" -eq 1 ]
  run grep -nF 'checklist-mark.sh'      "$F"; [ "$status" -eq 1 ]
  run grep -nF 'checklist-log.sh'       "$F"; [ "$status" -eq 1 ]
}

@test "crrf.md carries no workflow STEP NUMBER (#559/#560)" {
  # 938c888 renumbered the 24 steps; a number baked into a doc outside the
  # checklist goes stale on the next renumber (Issue-561: anchor once, refer
  # by role). crrf has no step number by construction — pin that.
  run grep -nE '\b[Ss]tep [0-9]+\b' "$F"; [ "$status" -eq 1 ]
}

@test "crrf.md points at the verbs' docs instead of restating their semantics (#559)" {
  # capture redteam Recommended [Dim 9] + Issue-458: a contract enumerated in N
  # files ships divergent. crrf owns ORCHESTRATION; stage semantics stay in the
  # verb docs it names — all four verbs pinned by their doc paths.
  [[ "$DOC" == *'skills/capture/SKILL.md'* ]]
  [[ "$DOC" == *'commands/scaffold.md'* ]]
  [[ "$DOC" == *'commands/redissue.md'* ]]
  [[ "$DOC" == *'commands/file.md'* ]]
}
