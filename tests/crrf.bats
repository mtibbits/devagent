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

REPO="${BATS_TEST_DIRNAME}/.."
F="$REPO/commands/crrf.md"

@test "crrf.md exists, non-empty, frontmatter carries the three keys (#559)" {
  [ -s "$F" ]
  grep -q '^description: ' "$F"
  grep -q '^argument-hint: ' "$F"
  grep -q '^allowed-tools: ' "$F"
}

@test "AC1: the no-prompt grant is stated and the chain names all four verbs (#559)" {
  # canonical vocabulary: the grant phrase
  grep -qF 'without intermediate confirmation prompts' "$F"
  grep -qF 'capture' "$F"
  grep -qF 'scaffold' "$F"
  grep -qF 'redissue' "$F"
  grep -qF 'file' "$F"
}

@test "AC2: the topic declaration precedes any artifact (#559)" {
  # canonical vocabulary: both phrases
  grep -qF 'a statement, not a question' "$F"
  grep -qF 'before any artifact is created' "$F"
}

@test "AC3: the multi-artifact path is specified end to end (#559)" {
  # Q1 — the invocation PRE-ANSWERS capture's multi-epic prompt; the prompt is
  # SATISFIED, not skipped. Canonical vocabulary: the answer sentence itself,
  # so a reword into an override ("ignore the confirmation") fails here.
  grep -qF 'author those you deem appropriate for the declared topic' "$F"
  # Q2 — children are PROMOTED to their own top-level captures, then filed.
  grep -qF 'scripts/capture/capture.sh' "$F"
  grep -qF -- '--type issue --subtype' "$F"
  grep -qF -- '--slug-suffix' "$F"               # U4: collision disambiguator
  grep -qF 'Parent epic:' "$F"                   # linkage home 1 (child draft)
  grep -qF 'staging copies superseded' "$F"      # children/NN-*.md disposition
  grep -qF 'epic draft is filed as well' "$F"    # case-safe: no leading article
}

@test "AC3 anti-bypass: crrf never tells the model to disregard a verb doc (#559)" {
  # The Q1 answer's whole point is that no Issue-321 contradiction is created.
  # An override-flavored verb is the regression this pins. rc-precise (#337).
  run grep -niE 'bypass|disregard|override the (capture|verb)|skip the (capture )?(skill|prompt)' "$F"
  [ "$status" -eq 1 ]
}

@test "AC4: all three premise-level halt triggers are present (#559)" {
  grep -qF 'duplicate' "$F"
  grep -qF 'unsound' "$F"
  grep -qF 'Verdict: split' "$F"
}

@test "AC5: the revise bound is stated (#559)" {
  # token pin: the bound IS the claim
  grep -qF 'at most two revise cycles' "$F"
}

@test "AC6: the push_mr gate is delegated, never bypassed (#559)" {
  # (a) the prohibition sentence
  grep -qF 'MUST NOT pass' "$F"
  # (b) rc-precise negative (#337): an OPERATIVE `file.sh … --yes`. The
  # prohibition sentence puts --yes BEFORE file.sh, so it stays legal.
  # `.`, not `[^\n]` — a POSIX bracket expression treats \n as two literals,
  # which let `--target origin --yes` slip the guard (#559 improve B2).
  run grep -nE 'file\.sh.*--yes' "$F"
  [ "$status" -eq 1 ]
  # (c) the delegated gate signal
  grep -qF 'exit code 4' "$F"
}

@test "AC7: the manifest contract is stated (#559)" {
  # The doc's operative sections are numbered; pin the numbered heading form
  # (`^## Manifest` can never match `## 5. Manifest` — #559 improve B1).
  grep -qE '^## [0-9]+\. Manifest' "$F"
  grep -qF 'tracker URL' "$F"
  grep -qF 'halt reason' "$F"
  grep -qF 'kept' "$F"
  grep -qF 'discarded' "$F"
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
  # verb docs it names.
  grep -qF 'commands/redissue.md' "$F"
  grep -qF 'commands/file.md'     "$F"
  grep -qF 'skills/capture/SKILL.md' "$F"
}
