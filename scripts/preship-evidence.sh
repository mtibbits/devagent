#!/usr/bin/env bash
# scripts/preship-evidence.sh — mechanism 2/3 (#359; design: Issue-333/designs/
# m2m3-preship-evidence.md, normative). core-preship's verification #4: cross-check
# mr.md's ## Evidence block against the generated suite-count artifact + git, so a
# hand-written wrong number (#120/#85/#284) or an mr.md stale against post-draftmr
# fixes can't ship. The COMPARED TREE is state.worktree_path when recorded, else
# source_dir (active_tree_resolve, #571) — the same tree run-suite measures — and
# the artifact's tree: stamp is cross-checked against it, so the artifact and its
# checker cannot agree with each other while both disagreeing with reality.
# A tree: path that does not exist in THIS environment (an artifact produced
# elsewhere, e.g. the WSL clone) is undecidable HERE, so it fails TREE UNATTESTED
# unless the caller attests the tree for this run (#655; the vocabulary is below).
# Back-compat: mr.md WITHOUT an Evidence block → single
# WARN, rc 0 (the #149 absent⇒no-gate pattern — old issues stay shippable; note
# the tree resolution and guard above run first, so a dead recorded
# worktree_path or a same-project-checkout invocation still refuses even for a
# no-Evidence legacy issue — fail-closed by design, #571); an
# artifact without a tree: line (pre-#571) skips the tree check. Block present
# → every check hard-dies. Any git/parse failure dies loud (#117/#314 — never
# "0 checked"); no prompts (safe under --auto).
# #466: the reconstruction is PER-FRAMEWORK. A bats-only project's Evidence line is
# `<ok>/<plan> bats @ <sha>` (NOT `…, 0 pytest`, which claimed a measured zero for an
# absent framework) and a pytest-only project's is `<passed> pytest @ <sha>` (previously
# the nonsense `/ bats, …`, which reconciled against itself and shipped twice). This is
# a DELIBERATE break for any single-framework mr.md drafted before #466: the mismatch
# message names the exact correct line, so remediation is one edit. An artifact
# recording `pytest: (error)` — tests present, no counts parsed — FAILS rather than
# reconciling; that state means the suite was never measured, which no Evidence line can
# honestly report. There is no OVERRIDE for it, and — unlike every other check here —
# it also runs ABOVE the no-Evidence back-compat exit, so it cannot be sidestepped by
# deleting the Evidence block (review MAJOR-2). Stated blind spot: this canNOT
# repair an artifact that already recorded `0 passed, 0 failed` for a suite that never
# ran — those reconcile as `0 pytest` and are indistinguishable here from a real zero.
# The fix is at the producer, for artifacts written at or after #466.
#
# #655 PROVENANCE-RUNG VOCABULARY. Stated once, here; the #580 unsupported-environment
# sibling reuses these names instead of minting its own.
#   Usage: preship-evidence.sh [project] [issue] [--attest-tree '<attestation>']
#   rung        one provenance check on the artifact. Today there is one, `tree` (the
#               #571 stamp; its arms are listed at the rung below).
#   verdict     the PASS line ends with ` [<rung>=<verdict>]`, one of:
#                 checked     decided HERE;
#                 attested    decided by the CALLER, in the environment that produced
#                             the artifact, for this run; the attestation is echoed;
#                 unstamped   the artifact predates the rung (no line to check).
#   <RUNG> UNATTESTED   the failure tag (TREE UNATTESTED) for a rung this environment
#               cannot decide and no attestation covers. rc 1, like every fails+= entry.
#   --attest-<rung> '<attestation>'   the per-run input. For tree it is exactly
#               'head=<full sha> dirty=no path=<the artifact's tree: path>' (also
#               spelled --attest-tree=<...>): what `git -C <path> rev-parse HEAD` and
#               `git -C <path> status --porcelain` printed when the caller ran them in
#               the producing environment. It must match the artifact's head: and
#               tree: exactly, so a pasted literal fails at the next commit. It is an
#               ARGUMENT, never an env var, so there is no exported value to leave
#               set (the standing shape #655 rejects). DEVAGENT_TREE_GUARD_OVERRIDE
#               answers a different question (which checkout a run may act FROM) and
#               does not silence a rung.
#   Stated blind spot: an attestation is a CLAIM. This script checks that it is
#   well-formed and bound to this artifact; it cannot check that the caller looked.
#   One derived from the artifact itself, not from the producing tree, passes here;
#   the verifier procedure forbids exactly that, and the PASS line records the claim.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=lib/paths.sh
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
# shellcheck source=lib/io.sh
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
# shellcheck source=lib/config.sh
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
# shellcheck source=lib/state.sh
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
# shellcheck source=lib/active.sh
. "$DEVAGENT_ROOT/scripts/lib/active.sh"

: "${DEVAGENT_GIT:=git}"

# #655: take the per-run attestation out of the argument list, leaving the positional
# [project] [issue] contract unchanged. An ARGUMENT, never an env var: no exported
# value outlives the run it describes (vocabulary in the header).
attest_tree=""; _n_attest=0; _pos=()
_attest_need="preship-evidence: --attest-tree needs a value: 'head=<full sha> dirty=no path=<tree>' (#655)"
while [ $# -gt 0 ]; do
  case "$1" in
    --attest-tree)
      [ $# -ge 2 ] && [ -n "$2" ] || die "$_attest_need"
      attest_tree="$2"; _n_attest=$((_n_attest + 1)); shift 2 ;;
    --attest-tree=*)
      attest_tree="${1#--attest-tree=}"; _n_attest=$((_n_attest + 1)); shift
      [ -n "$attest_tree" ] || die "$_attest_need" ;;
    --*) die "preship-evidence: unknown option '$1' — usage: preship-evidence.sh [project] [issue] [--attest-tree '<attestation>'] (#655)" ;;
    *) _pos+=("$1"); shift ;;
  esac
done
[ "$_n_attest" -le 1 ] || die "preship-evidence: --attest-tree given more than once — pass one attestation per run (#655)"
set -- "${_pos[@]+"${_pos[@]}"}"

active_resolve_project_try "${1:-}" 2>/dev/null || true
project="$ACTIVE_RESOLVED_PROJECT"
[ -n "$project" ] || die "preship-evidence: project required (no arg and no active project)"
config_is_project "$project" || die "preship-evidence: unknown project '$project'"
active_guard_scope preship-evidence
issue_arg="${2:-}"
issue_dir="$(issue_context_dir "$project" "$issue_arg" 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "preship-evidence: issue_dir not set or missing"
mr="$issue_dir/mr.md"
[ -f "$mr" ] || die "preship-evidence: no mr.md at $mr (run /devagent:draftmr first)"

# #571: resolve the tree the evidence claims are ABOUT — worktree_path else
# source_dir, the commit.sh/ship.sh rule. Strictly AFTER active_guard_scope
# above, for the same SCOPE-before-TREE reason run-suite.sh declares: a
# wrong-PROJECT invocation must still die SCOPE MISMATCH first.
active_tree_resolve "$project" "$issue_arg"     # setter-globals; never $( … )
active_guard_tree preship-evidence
work_dir="$ACTIVE_TREE_DIR"

# Back-compat: no ## Evidence block ⇒ WARN + rc 0 (#149).
if ! grep -q '^## Evidence' "$mr"; then
  # #466 (review MAJOR-2): the #149 rule lets a LEGACY issue ship without an Evidence
  # block — it must not let ANY issue ship on evidence that was never taken. Deleting
  # two lines from mr.md used to skip the (error) refusal entirely, while four homes
  # claimed the gate could not be bypassed: an unenforced control wearing a guarantee
  # (register lawFirm Issue-14 — a "cannot be verified" state whose refusal lives only
  # in the test suite fails open at runtime). So the refusal is repeated HERE, on the
  # one path that would otherwise skip it.
  # It is a `die` on this path and a `fails+=` entry on the main path below, and the
  # asymmetry is deliberate: there is no fails[] to accumulate into here, whereas below
  # the contract is to report EVERY failure in one run. Same verdict, same message,
  # two exits.
  # "No artifact at all" stays the plain #149 path — absence is not a failed
  # measurement, and the non-empty guard is what keeps it that way.
  _early_artifact="$(ls -1 "$issue_dir/analysis/"*-suite-count.txt 2>/dev/null | sort | tail -1 || true)"
  # #601: read the pytest body with the SAME whitespace-tolerant parse as a_pytest_body
  # below (keep the two spellings identical), so a padded '(error)' is refused here
  # exactly as it is on the main path; the exact-match grep this replaced let
  # 'pytest:   (error)' fall through to the WARN below. Declared blind spot: a TRAILING
  # blank ('(error) ') is not '(error)' on either path. It is an unparseable line, and
  # this back-compat path deliberately lets unparseable lines through (#149).
  _early_pytest_body=""
  if [ -n "$_early_artifact" ]; then
    _early_pytest_body="$(sed -n 's/^pytest:[[:space:]]*\(.*\)$/\1/p' "$_early_artifact" | head -1)"
  fi
  if [ "$_early_pytest_body" = "(error)" ]; then
    die "preship-evidence: artifact records 'pytest: (error)' — tests/test_*.py exist in the measured tree but pytest could not be RUN (missing interpreter, a venv without pytest, or an import/collection error). The suite was NOT measured, so nothing can honestly describe it, and removing the '## Evidence' block does not make it shippable (#466). Point DEVAGENT_PYTEST_PYTHON at an interpreter that can run the suite, then re-run run-suite."
  fi
  echo "preship-evidence: WARN — mr.md has no '## Evidence' block; skipping evidence checks (#149 absent⇒no-gate)" >&2
  exit 0
fi

# Extract the Evidence block (between '## Evidence' and the next '## ' / EOF).
block="$(awk '/^## Evidence/{f=1;next} /^## /{f=0} f' "$mr")"
ev_suite="$(printf '%s\n' "$block" | sed -n 's/^suite:[[:space:]]*\(.*\)$/\1/p' | head -1)"
ev_files="$(printf '%s\n' "$block" | sed -n 's/^files:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*changed.*/\1/p' | head -1)"
[ -n "$ev_suite" ] || die "preship-evidence: Evidence block has no 'suite:' line"
[ -n "$ev_files" ] || die "preship-evidence: Evidence block has no 'files: <n> changed' line"

# Newest suite-count artifact.
artifact="$(ls -1 "$issue_dir/analysis/"*-suite-count.txt 2>/dev/null | sort | tail -1 || true)"
[ -n "$artifact" ] || die "preship-evidence: no suite-count artifact — run \`bash \"\$CLAUDE_PLUGIN_ROOT/scripts/run-suite.sh\" $project\` at HEAD (#572: pass the project explicitly)"

a_head="$(sed -n 's/^head:[[:space:]]*\([^ ]*\).*/\1/p' "$artifact" | head -1)"
a_dirty="$(sed -n 's/^head:.*dirty:[[:space:]]*\([a-z]*\).*/\1/p' "$artifact" | head -1)"
a_ok="$(sed -n 's/^bats:[[:space:]]*\([0-9][0-9]*\)\/.*/\1/p' "$artifact" | head -1)"
a_plan="$(sed -n 's/^bats:[[:space:]]*[0-9][0-9]*\/\([0-9][0-9]*\).*/\1/p' "$artifact" | head -1)"
a_notok="$(sed -n 's/^bats:.*notok=\([0-9][0-9]*\).*/\1/p' "$artifact" | head -1)"
a_passed="$(sed -n 's/^pytest:[[:space:]]*\([0-9][0-9]*\) passed.*/\1/p' "$artifact" | head -1)"
a_failed="$(sed -n 's/^pytest:.*[^0-9]\([0-9][0-9]*\) failed.*/\1/p' "$artifact" | head -1)"
# #466 (redmr): pytest ERRORS were invisible to this whole chain — an error is not a
# "failed", so `2 passed, 1 error` recorded `0 failed` and reconciled green. The bats
# side has had its equivalent invariant since #406; this is pytest's.
a_errors="$(sed -n 's/^pytest:.*[^0-9]\([0-9][0-9]*\) errors\?.*/\1/p' "$artifact" | head -1)"
# #466: the framework line BODIES (everything after the separator whitespace, verbatim),
# parsed HERE with the same sed idiom as the numeric fields above rather than by inline
# greps further down — one parsing convention for one file format, so a new state
# token or a schema tweak has a single home. The numeric fields cannot answer the
# presence question: a_ok/a_passed are empty for BOTH "(none)" and an unparseable line,
# and this checker must tell those apart. #601: the ':[[:space:]]*' strips LEADING
# padding only, so 'bats:   (none)' reads as absent, while 'bats: (none) ' (a trailing
# blank) is unparseable and fails closed. tests/preship-evidence.bats pins both, so these
# two reads need no separate whitespace normalisation.
a_bats_body="$(sed -n 's/^bats:[[:space:]]*\(.*\)$/\1/p' "$artifact" | head -1)"
a_pytest_body="$(sed -n 's/^pytest:[[:space:]]*\(.*\)$/\1/p' "$artifact" | head -1)"

cur_head="$("$DEVAGENT_GIT" -C "$work_dir" rev-parse HEAD 2>/dev/null || true)"
[ -n "$cur_head" ] || die "preship-evidence: could not resolve current HEAD"

fails=()

# #571/#655 TREE RUNG. The artifact names the checkout that produced it; compare it
# with the tree THIS check resolves, so the artifact and its checker can no longer
# agree with each other while both disagree with reality. Every arm, in the header's
# vocabulary (the verdict ends the PASS line):
#   no tree: line         -> unstamped: the #149 absent⇒no-gate pattern above (every
#                            pre-#571 artifact).
#   exists here and -ef   -> checked.
#   exists here, not -ef  -> FAIL "produced from tree" (#571). A mismatch can also be
#                            CAUSED by the pair's arity asymmetry (this script resolves
#                            with $issue_arg; run-suite without one — see #571's plan).
#   absent here           -> undecidable HERE: the artifact came from another
#                            environment (e.g. the WSL clone). Before #655 this arm
#                            warned and passed on head: alone, so the rung never ran
#                            for any cross-environment preship. Now it FAILS
#                            TREE UNATTESTED unless --attest-tree matches this
#                            artifact's head: and tree: exactly, with dirty=no ->
#                            attested, and the attestation is echoed on the PASS line.
# The head:/dirty:/suite checks below run on EVERY arm: an attestation vouches for the
# checkout, never for the counts.
tree_unattested="TREE UNATTESTED"
a_tree="$(sed -n 's/^tree:[[:space:]]*\(.*\)$/\1/p' "$artifact" | head -1)"
tree_verdict="unstamped"; _attest_used=false
if [ -z "$a_tree" ]; then
  :
elif [ -d "$a_tree" ]; then
  if [ "$a_tree" -ef "$work_dir" ]; then
    tree_verdict="checked"
  else
    fails+=("artifact was produced from tree '$a_tree' but this check resolves '$work_dir' — re-run run-suite in the tree being shipped (#571)")
  fi
elif [ -z "$attest_tree" ]; then
  fails+=("$tree_unattested — the artifact records tree '$a_tree', which does not exist in THIS environment, so this check cannot tell which checkout produced the evidence (#571/#655). Either re-run run-suite in the tree being shipped, from an environment that can run the suite; or, when the artifact came from another environment (the sanctioned WSL flow), verify that tree THERE (git -C '<tree>' rev-parse HEAD must print the artifact's head:, and git -C '<tree>' status --porcelain must print nothing) and re-run this check adding --attest-tree 'head=<the sha it printed> dirty=no path=<that tree>'. The rung is then attested by you, not checked here, and the PASS line records your claim; an attestation binds to this artifact's head: and tree:, so every new artifact needs a new one.")
else
  _attest_used=true
  _attest_re='^head=([[:xdigit:]]+) dirty=([^ ]+) path=(.+)$'
  if [[ "$attest_tree" =~ $_attest_re ]]; then
    _att_head="${BASH_REMATCH[1]}"; _att_dirty="${BASH_REMATCH[2]}"; _att_path="${BASH_REMATCH[3]}"
    _n_fails="${#fails[@]}"
    [ "$_att_path" = "$a_tree" ] \
      || fails+=("$tree_unattested — --attest-tree names path '$_att_path' but the artifact records tree '$a_tree'; attest the tree the artifact names (#655)")
    [ "$_att_head" = "$a_head" ] \
      || fails+=("$tree_unattested — --attest-tree names head $_att_head but the artifact records head $a_head; attest the full SHA the producing tree prints now (#655)")
    [ "$_att_dirty" = "no" ] \
      || fails+=("$tree_unattested — --attest-tree reports dirty=$_att_dirty: the producing tree has uncommitted changes, so it is no longer the tree that was measured; commit or clean it there and re-run run-suite (#655)")
    [ "${#fails[@]}" -gt "$_n_fails" ] \
      || tree_verdict="attested: $attest_tree — verified by the caller in the producing environment, not checked here"
  else
    fails+=("$tree_unattested — malformed --attest-tree '$attest_tree': the one accepted form is 'head=<full sha> dirty=no path=<tree>' (#655)")
  fi
fi
# An attestation the rung did not need (the checked, mismatch and unstamped arms) is
# redundant: this environment decided, or there is no stamp to bind to. Refusing it
# would fail an idempotent caller whose environments happen to coincide, so warn and
# ignore it (the rule the #580 sibling's rungs copy).
if [ -n "$attest_tree" ] && [ "$_attest_used" = false ]; then
  warn "preship-evidence: --attest-tree ignored — the tree rung did not need it (#655)"
fi
[ "$a_head" = "$cur_head" ] || fails+=("artifact head ($a_head) != current HEAD ($cur_head) — re-run run-suite at HEAD")
[ "$a_dirty" = "no" ] || fails+=("artifact records a dirty tree (dirty=$a_dirty) — commit or clean, then re-run run-suite")
[ "${a_notok:-0}" = "0" ] || fails+=("bats notok=$a_notok (suite not green)")
# #406: a truncated bats run (killed/crashed) leaves ok<plan with notok=0 — it
# looks green but did not run every planned test. Gate on notok==0 so a
# legitimately-FAILING run (ok<plan because notok>0) is reported by the notok
# check above, not mislabeled "truncated". Empty a_ok/a_plan (the `bats: (none)`
# no-bats path) compare equal, so this does not false-fire there (#411 hardens
# the `suite: none` representation separately).
if [ "${a_notok:-0}" = "0" ] && [ "${a_ok:-}" != "${a_plan:-}" ]; then
  fails+=("bats ran ${a_ok:-?} of ${a_plan:-?} planned tests — suite truncated (fewer ran than planned, 0 failures)")
fi
[ "${a_failed:-0}" = "0" ] || fails+=("pytest failed=$a_failed (suite not green)")
[ "${a_errors:-0}" = "0" ] || fails+=("pytest errors=$a_errors (suite not green — a collection/fixture ERROR is not a 'failed' and was invisible to this check before #466)")

# Reconstruct the canonical suite line from the frameworks the artifact reports
# PRESENT, and compare (exact). #411 established the neither-framework form; #466
# generalizes it per-framework, because the pair had two working shapes and two broken:
#   both        -> "<ok>/<plan> bats, <passed> pytest @ <sha>"  (byte-identical to #359)
#   neither     -> "none @ <sha>"                                (byte-identical to #411)
#   pytest-only -> was "/ bats, <passed> pytest @ <sha>". NOT merely unmatchable: this
#                  checker compares mr.md against its OWN reconstruction, so an operator
#                  who copied the nonsense string reconciled cleanly. factorAI/Issue-85
#                  and koopmanGNN/Issue-106 both SHIPPED that way (#466).
#   bats-only   -> was "<ok>/<plan> bats, 0 pytest @ <sha>". "0 pytest" reads as a
#                  MEASURED zero rather than an absent framework: a false green
#                  (#572 redmr MINOR-5).
# One representation, both sides — mirrored in templates/mr_template.md,
# skills/core-draft-mr/SKILL.md and agents/preship-verifier.md, which move in the same
# commit. All three verdicts below are fails+= entries, never die: this script's
# contract is to accumulate and report EVERY failure in one run (fails=() above), and a
# die would hand the operator one failure per round-trip.
# One sentence, one home: both unparseable-artifact verdicts end in it, and a reworded
# copy would leave the operator two phrasings for one class of failure.
unparseable="— refusing to reconstruct an Evidence line from an unparseable artifact (#466). Re-run run-suite. Set DEVAGENT_PYTEST_PYTHON if run-suite cannot find your project's interpreter."
if [ "$a_pytest_body" = "(error)" ]; then
  fails+=("artifact records 'pytest: (error)' — tests/test_*.py exist in the measured tree but pytest produced no counts (missing interpreter, a venv without pytest, or a collection error). The pytest suite was NOT measured, so no Evidence line can honestly describe it. Point DEVAGENT_PYTEST_PYTHON at an interpreter that can run them, or fix the venv, then re-run run-suite (#466). There is no OVERRIDE for this — unlike the tree guard's DEVAGENT_TREE_GUARD_OVERRIDE, an unmeasured suite is not a condition an operator can knowingly accept, and the DEVAGENT_PYTEST_PYTHON seam names a working interpreter rather than silencing the verdict. Deleting the Evidence block does not help either: the same refusal runs above the #149 back-compat exit.")
fi
parts=()
if [ "$a_bats_body" != "(none)" ]; then
  if [ -n "$a_ok" ] && [ -n "$a_plan" ]; then
    parts+=("$a_ok/$a_plan bats")
  else
    fails+=("artifact 'bats:' line is neither '(none)' nor '<ok>/<plan> notok=<n>' $unparseable")
  fi
fi
if [ "$a_pytest_body" != "(none)" ] && [ "$a_pytest_body" != "(error)" ]; then
  if [ -n "$a_passed" ]; then
    parts+=("$a_passed pytest")
  else
    fails+=("artifact 'pytest:' line is neither '(none)'/'(error)' nor '<n> passed, <m> failed' $unparseable")
  fi
fi
# An (error) artifact contributes no parts entry, so expected_suite still reconstructs
# from whatever else is present and the operator sees the suite-line verdict ALONGSIDE
# the (error) verdict rather than instead of it.
if [ "${#parts[@]}" -eq 0 ]; then
  expected_suite="none @ $a_head"
elif [ "${#parts[@]}" -eq 1 ]; then
  expected_suite="${parts[0]} @ $a_head"
else
  expected_suite="${parts[0]}, ${parts[1]} @ $a_head"
fi
[ "$ev_suite" = "$expected_suite" ] \
  || fails+=("Evidence suite line mismatch: mr.md='$ev_suite' vs artifact='$expected_suite'")

# files: == diff of baseline..HEAD (baseline from state — die loud when unset).
baseline="$(state_ctx_get "$project" baseline_sha "$issue_arg" 2>/dev/null || true)"
[ -n "$baseline" ] || die "preship-evidence: baseline_sha unset — cannot verify files: (never diff against nothing)"
actual_files="$("$DEVAGENT_GIT" -C "$work_dir" diff --name-only "$baseline..HEAD" 2>/dev/null | grep -c . || true)"
[ "$ev_files" = "$actual_files" ] \
  || fails+=("Evidence files mismatch: mr.md=$ev_files vs git diff $baseline..HEAD=$actual_files")

if [ "${#fails[@]}" -gt 0 ]; then
  printf 'preship-evidence: FAIL\n' >&2
  for f in "${fails[@]}"; do printf '  - %s\n' "$f" >&2; done
  exit 1
fi
echo "preship-evidence: PASS — mr.md Evidence matches $artifact ($expected_suite; files=$ev_files) [tree=$tree_verdict]" >&2
