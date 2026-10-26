#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # the EVIDENCE_* setter-globals are the return channel
# scripts/lib/evidence.sh — the ONE home (#894) of what the MR Evidence block's
# machine-checked lines are, given a suite-count artifact: which artifact is newest, the
# canonical suite: line rebuilt from it, the files: count, the platform: line, and the
# #571/#655 tree rung that says whether the artifact describes the tree being shipped.
# Two consumers: scripts/preship-evidence.sh (the checker, verification #4) and
# scripts/evidence-stamp.sh (the writer, run by core-draft-mr step 6 and after a review or
# redmr commit). Both build the lines from these functions, so the writer cannot write a
# line the checker would rebuild differently (register Issue-565/585: two
# implementations of one question drift). The messages are the checker's, moved here
# byte for byte; the vocabulary (rung, verdict, <RUNG> UNATTESTED, --attest-tree) is
# preship-evidence.sh's header.
# Sourced, never executed. Setter-globals: never call a setter inside $( … ), and none
# of these functions dies (each caller decides whether a problem is a fails+= entry or
# a refusal). Requires lib/platform.sh (platform_body_valid); DEVAGENT_GIT defaults to git.

# The tree rung's failure tag. Column 0 so a sweep can read it with one sed.
tree_unattested="TREE UNATTESTED"

# evidence_newest_artifact <issue_dir> - stdout: the newest analysis/*-suite-count.txt,
# "" when there is none.
evidence_newest_artifact() {
  # shellcheck disable=SC2012  # run-suite names these <date>-suite-count.txt
  ls -1 "$1/analysis/"*-suite-count.txt 2>/dev/null | sort | tail -1 || true
}

# evidence_art_head <artifact> - stdout: the head: sha (q-form: no pipe for pipefail,
# register wf Issue-595). The ONE read of that field.
evidence_art_head() { sed -n '/^head:/{s/^head:[[:space:]]*\([^ ]*\).*/\1/p;q;}' "$1"; }

# evidence_platform_line <artifact> - stdout: the first column-0 platform: line, raw
# ("" when there is none).
evidence_platform_line() { sed -n '/^platform:/{p;q;}' "$1"; }

# evidence_platform_check <raw platform: line> - sets EVIDENCE_PLATFORM_BODY (the line
# after the colon, leading blanks stripped) and EVIDENCE_PLATFORM_PROBLEM (the message
# for a line that is not the one shape run-suite writes; "" when it is).
evidence_platform_check() {
  EVIDENCE_PLATFORM_BODY="${1#platform:}"
  EVIDENCE_PLATFORM_BODY="${EVIDENCE_PLATFORM_BODY#"${EVIDENCE_PLATFORM_BODY%%[![:space:]]*}"}"
  EVIDENCE_PLATFORM_PROBLEM=""
  platform_body_valid "$EVIDENCE_PLATFORM_BODY" \
    || EVIDENCE_PLATFORM_PROBLEM="artifact 'platform:' line '$EVIDENCE_PLATFORM_BODY' is not the one shape run-suite writes ('os=<v> kernel=<v> fs=<v> modes=posix|no-op') — re-run run-suite (#654)"
}

# evidence_suite_resolve <artifact> - read the artifact's head:/dirty:/bats:/pytest:
# fields and rebuild the canonical suite: line. Sets:
#   EVIDENCE_A_HEAD EVIDENCE_A_DIRTY
#   EVIDENCE_BATS_OK EVIDENCE_BATS_PLAN EVIDENCE_BATS_BODY
#   EVIDENCE_PYTEST_PASSED EVIDENCE_PYTEST_BODY
#   EVIDENCE_SUITE_LINE      the value after 'suite: ' (<parts> @ <head>, or none @ <head>)
#   EVIDENCE_SUITE_PROBLEMS  () or the (error) / unparseable verdicts, in that order
# #466: the reconstruction is PER-FRAMEWORK, from the frameworks the artifact reports
# PRESENT. #411 established the neither-framework form; #466 generalized it, because the
# pair had two working shapes and two broken:
#   both        -> "<ok>/<plan> bats, <passed> pytest @ <full head sha>"  (byte-identical to #359)
#   neither     -> "none @ <full head sha>"                                (byte-identical to #411)
#   pytest-only -> was "/ bats, <passed> pytest @ <full head sha>". NOT merely unmatchable:
#                  the checker compares mr.md against its OWN reconstruction, so an
#                  operator who copied the nonsense string reconciled cleanly.
#                  factorAI/Issue-85 and koopmanGNN/Issue-106 both SHIPPED that way (#466).
#   bats-only   -> was "<ok>/<plan> bats, 0 pytest @ <full head sha>". "0 pytest" reads as
#                  a MEASURED zero rather than an absent framework: a false green
#                  (#572 redmr MINOR-5).
# One representation, both sides — mirrored in templates/mr_template.md,
# skills/core-draft-mr/SKILL.md and agents/preship-verifier.md, which move in the same
# commit. An (error) artifact contributes no parts entry, so the line still reconstructs
# from whatever else is present and the checker reports the suite-line verdict ALONGSIDE
# the (error) verdict rather than instead of it.
evidence_suite_resolve() {
  local artifact="$1" unparseable
  local -a parts=()
  EVIDENCE_SUITE_PROBLEMS=()
  EVIDENCE_A_HEAD="$(evidence_art_head "$artifact")"
  EVIDENCE_A_DIRTY="$(sed -n 's/^head:.*dirty:[[:space:]]*\([a-z]*\).*/\1/p' "$artifact" | head -1)"
  EVIDENCE_BATS_OK="$(sed -n 's/^bats:[[:space:]]*\([0-9][0-9]*\)\/.*/\1/p' "$artifact" | head -1)"
  EVIDENCE_BATS_PLAN="$(sed -n 's/^bats:[[:space:]]*[0-9][0-9]*\/\([0-9][0-9]*\).*/\1/p' "$artifact" | head -1)"
  EVIDENCE_PYTEST_PASSED="$(sed -n 's/^pytest:[[:space:]]*\([0-9][0-9]*\) passed.*/\1/p' "$artifact" | head -1)"
  # #466: the framework line BODIES (everything after the separator whitespace, verbatim),
  # parsed with the same sed idiom as the numeric fields above, so one file format has one
  # parsing convention. The numeric fields cannot answer the presence question: OK and
  # PASSED are empty for BOTH "(none)" and an unparseable line. #601: ':[[:space:]]*'
  # strips LEADING padding only, so 'bats:   (none)' reads as absent, while
  # 'bats: (none) ' (a trailing blank) is unparseable and fails closed.
  EVIDENCE_BATS_BODY="$(sed -n 's/^bats:[[:space:]]*\(.*\)$/\1/p' "$artifact" | head -1)"
  EVIDENCE_PYTEST_BODY="$(sed -n 's/^pytest:[[:space:]]*\(.*\)$/\1/p' "$artifact" | head -1)"
  # One sentence, one home: both unparseable-artifact verdicts end in it, and a reworded
  # copy would leave the operator two phrasings for one class of failure.
  unparseable="— refusing to reconstruct an Evidence line from an unparseable artifact (#466). Re-run run-suite. Set DEVAGENT_PYTEST_PYTHON if run-suite cannot find your project's interpreter."
  if [ "$EVIDENCE_PYTEST_BODY" = "(error)" ]; then
    EVIDENCE_SUITE_PROBLEMS+=("artifact records 'pytest: (error)' — tests/test_*.py exist in the measured tree but pytest produced no counts (missing interpreter, a venv without pytest, or a collection error). The pytest suite was NOT measured, so no Evidence line can honestly describe it. Point DEVAGENT_PYTEST_PYTHON at an interpreter that can run them, or fix the venv, then re-run run-suite (#466). There is no OVERRIDE for this — unlike the tree guard's DEVAGENT_TREE_GUARD_OVERRIDE, an unmeasured suite is not a condition an operator can knowingly accept, and the DEVAGENT_PYTEST_PYTHON seam names a working interpreter rather than silencing the verdict. Deleting the Evidence block does not help either: the same refusal runs above the #149 back-compat exit.")
  fi
  if [ "$EVIDENCE_BATS_BODY" != "(none)" ]; then
    if [ -n "$EVIDENCE_BATS_OK" ] && [ -n "$EVIDENCE_BATS_PLAN" ]; then
      parts+=("$EVIDENCE_BATS_OK/$EVIDENCE_BATS_PLAN bats")
    else
      EVIDENCE_SUITE_PROBLEMS+=("artifact 'bats:' line is neither '(none)' nor '<ok>/<plan> notok=<n>' $unparseable")
    fi
  fi
  if [ "$EVIDENCE_PYTEST_BODY" != "(none)" ] && [ "$EVIDENCE_PYTEST_BODY" != "(error)" ]; then
    if [ -n "$EVIDENCE_PYTEST_PASSED" ]; then
      parts+=("$EVIDENCE_PYTEST_PASSED pytest")
    else
      EVIDENCE_SUITE_PROBLEMS+=("artifact 'pytest:' line is neither '(none)'/'(error)' nor '<n> passed, <m> failed' $unparseable")
    fi
  fi
  if [ "${#parts[@]}" -eq 0 ]; then
    EVIDENCE_SUITE_LINE="none @ $EVIDENCE_A_HEAD"
  elif [ "${#parts[@]}" -eq 1 ]; then
    EVIDENCE_SUITE_LINE="${parts[0]} @ $EVIDENCE_A_HEAD"
  else
    EVIDENCE_SUITE_LINE="${parts[0]}, ${parts[1]} @ $EVIDENCE_A_HEAD"
  fi
}

# evidence_files_count <work_dir> <baseline> - sets EVIDENCE_FILES_COUNT to the number
# of paths in git diff --name-only <baseline>..HEAD. Returns 1 (EVIDENCE_FILES_COUNT "")
# when git fails: a failed diff is not a zero (#894 D6; register Issue-314), so the
# checker reports it and the stamper refuses to write it. An empty diff is 0.
evidence_files_count() {
  local out l n=0
  EVIDENCE_FILES_COUNT=""
  out="$("${DEVAGENT_GIT:-git}" -C "$1" diff --name-only "$2..HEAD" 2>/dev/null)" || return 1
  while IFS= read -r l; do
    [ -z "$l" ] || n=$((n + 1))
  done <<<"$out"
  EVIDENCE_FILES_COUNT="$n"
}

# evidence_tree_rung <caller> <artifact> <a_head> <work_dir> <attest_tree>
# #571/#655 TREE RUNG. The artifact names the checkout that produced it; compare it with
# the tree the caller resolves, so the artifact and its checker can no longer agree with
# each other while both disagree with reality. Appends to the CALLER's fails array and
# sets EVIDENCE_TREE_VERDICT. Every arm, in preship-evidence.sh's header vocabulary:
#   no tree: line         -> unstamped: the #149 absent⇒no-gate pattern (every
#                            pre-#571 artifact).
#   exists here and -ef   -> checked.
#   exists here, not -ef  -> FAIL "produced from tree" (#571). #659 retired the pair's
#                            old arity asymmetry: run-suite now takes its issue from the
#                            argument or the pin and refuses the shared slot. A mismatch
#                            still follows when the two are pointed at DIFFERENT issues,
#                            e.g. the checker run bare and unpinned reads the shared
#                            slot (its header, ISSUE PRECEDENCE).
#   absent here           -> undecidable HERE: the artifact came from another
#                            environment (e.g. the WSL clone). Before #655 this arm
#                            warned and passed on head: alone, so the rung never ran
#                            for any cross-environment preship. Now it FAILS
#                            TREE UNATTESTED unless --attest-tree matches this
#                            artifact's head: and tree: exactly, with dirty=no ->
#                            attested, and the attestation is echoed on the PASS line.
# The head:/dirty:/suite checks run on EVERY arm: an attestation vouches for the
# checkout, never for the counts. An attestation the rung did not need (the checked,
# mismatch and unstamped arms) is redundant: this environment decided, or there is no
# stamp to bind to. Refusing it would fail an idempotent caller whose environments
# happen to coincide, so it is warned about and ignored (the rule the #580 sibling's
# rungs copy).
evidence_tree_rung() {
  local caller="$1" artifact="$2" a_head="$3" work_dir="$4" attest_tree="$5"
  local a_tree attest_used=false attest_re att_head att_dirty att_path n_fails
  a_tree="$(sed -n 's/^tree:[[:space:]]*\(.*\)$/\1/p' "$artifact" | head -1)"
  EVIDENCE_TREE_VERDICT="unstamped"
  if [ -z "$a_tree" ]; then
    :
  elif [ -d "$a_tree" ]; then
    if [ "$a_tree" -ef "$work_dir" ]; then
      EVIDENCE_TREE_VERDICT="checked"
    else
      fails+=("artifact was produced from tree '$a_tree' but this check resolves '$work_dir' — re-run run-suite in the tree being shipped (#571)")
    fi
  elif [ -z "$attest_tree" ]; then
    fails+=("$tree_unattested — the artifact records tree '$a_tree', which does not exist in THIS environment, so this check cannot tell which checkout produced the evidence (#571/#655). Either re-run run-suite in the tree being shipped, from an environment that can run the suite; or, when the artifact came from another environment (the sanctioned WSL flow), verify that tree THERE (git -C '<tree>' rev-parse HEAD must print the artifact's head:, and git -C '<tree>' status --porcelain must print nothing) and re-run this check adding --attest-tree 'head=<the sha it printed> dirty=no path=<that tree>'. The rung is then attested by you, not checked here, and the PASS line records your claim; an attestation binds to this artifact's head: and tree:, so every new artifact needs a new one.")
  else
    attest_used=true
    attest_re='^head=([[:xdigit:]]+) dirty=([^ ]+) path=(.+)$'
    if [[ "$attest_tree" =~ $attest_re ]]; then
      att_head="${BASH_REMATCH[1]}"; att_dirty="${BASH_REMATCH[2]}"; att_path="${BASH_REMATCH[3]}"
      n_fails="${#fails[@]}"
      [ "$att_path" = "$a_tree" ] \
        || fails+=("$tree_unattested — --attest-tree names path '$att_path' but the artifact records tree '$a_tree'; attest the tree the artifact names (#655)")
      [ "$att_head" = "$a_head" ] \
        || fails+=("$tree_unattested — --attest-tree names head $att_head but the artifact records head $a_head; attest the full SHA the producing tree prints now (#655)")
      [ "$att_dirty" = "no" ] \
        || fails+=("$tree_unattested — --attest-tree reports dirty=$att_dirty: the producing tree has uncommitted changes, so it is no longer the tree that was measured; commit or clean it there and re-run run-suite (#655)")
      [ "${#fails[@]}" -gt "$n_fails" ] \
        || EVIDENCE_TREE_VERDICT="attested: $attest_tree — verified by the caller in the producing environment, not checked here"
    else
      fails+=("$tree_unattested — malformed --attest-tree '$attest_tree': the one accepted form is 'head=<full sha> dirty=no path=<tree>' (#655)")
    fi
  fi
  if [ -n "$attest_tree" ] && [ "$attest_used" = false ]; then
    warn "$caller: --attest-tree ignored — the tree rung did not need it (#655)"
  fi
}
