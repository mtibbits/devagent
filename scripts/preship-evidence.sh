#!/usr/bin/env bash
# scripts/preship-evidence.sh — mechanism 2/3 (#359; design: Issue-333/designs/
# m2m3-preship-evidence.md, normative). core-preship's verification #4: cross-check
# mr.md's ## Evidence block against the generated suite-count artifact + git, so a
# hand-written wrong number (#120/#85/#284) or an mr.md stale against post-draftmr
# fixes can't ship. The COMPARED TREE is the resolved issue's worktree_path when
# recorded, else source_dir (active_tree_resolve, #571) — the same tree run-suite
# measures when both resolve the same issue — and
# the artifact's tree: stamp is cross-checked against it, so the artifact and its
# checker cannot agree with each other while both disagreeing with reality.
# A tree: path that does not exist in THIS environment (an artifact produced
# elsewhere, e.g. the WSL clone) is undecidable HERE, so it fails TREE UNATTESTED
# unless the caller attests the tree for this run (#655; the vocabulary is below).
# ISSUE PRECEDENCE (#659): the [issue] argument, else the DEVAGENT_ACTIVE_ISSUE pin
# (the argument wins when both are set), else the SHARED per-project issue_dir slot,
# with the tree from the shared worktree_path. run-suite.sh REFUSES at that last rung;
# this script still reads it, because making its argument mandatory is a separate
# decision (out of #659's scope). The slot is state another session moves: pass the
# issue (preship-evidence.sh <project> <Issue-N>) wherever another session is active.
# Back-compat: mr.md WITHOUT an Evidence block → single
# WARN, rc 0 (the #149 absent⇒no-gate pattern — old issues stay shippable; note
# the tree resolution and guard above run first, so a dead recorded
# worktree_path or a same-project-checkout invocation still refuses even for a
# no-Evidence legacy issue — fail-closed by design, #571); an
# artifact without a tree: line (pre-#571) skips the tree check. An artifact without a
# branch: or upstream: line (pre-#660) FAILS: there is no back-compat pass for those,
# because a missing branch is the #570 shape. Block present
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
# #655/#660 PROVENANCE-RUNG VOCABULARY. Stated once, here; further #580 siblings reuse
# these names instead of minting their own.
#   Usage: preship-evidence.sh [project] [issue] [--attest-tree '<attestation>']
#                              [--attest-upstream '<attestation>']
#                              [--attest-platform '<attestation>']
#   rung        one provenance check on the artifact. There are three: `tree` (the #571
#               stamp), `upstream` (#660: what the producing tree's origin said about
#               its branch), and `platform` (#654: where the artifact was produced,
#               checked against the CHECKING operator's declaration). Each rung's arms
#               are listed where it runs, below.
#   verdict     the PASS line ends with ` [tree=<verdict>] [upstream=<verdict>] [platform=<verdict>]`, from:
#                 checked     decided HERE (platform: a declared entry matched);
#                 attested    decided by the CALLER, in the environment that produced
#                             the artifact, for this run; the attestation is echoed;
#                 unstamped   tree always; platform only while nothing is declared: the
#                             artifact predates the rung (no line). The upstream rung has
#                             no such pass: #660 fails a missing line;
#                 no-origin   upstream only: the producing tree has no origin, the
#                             single-tree case (nothing to compare, not a degradation).
#                 unpushed    upstream only, with tree=checked: origin has no copy of the
#                             branch the shipped tree holds (B′; the first push is at ship).
#                 undeclared  platform only: nothing is declared (no evidence_platforms); the
#                             stamp is echoed.
#   <RUNG> UNATTESTED   the failure tag (TREE UNATTESTED, UPSTREAM UNATTESTED,
#               PLATFORM UNATTESTED) for a rung this environment cannot decide and no
#               attestation covers. rc 1, like every fails+= entry.
#   --attest-<rung> '<attestation>'   the per-run input, also spelled
#               --attest-<rung>=<attestation>.
#               tree: exactly 'head=<full sha> dirty=no path=<the artifact's tree: path>'.
#               That is what `git -C <path> rev-parse HEAD` and
#               `git -C <path> status --porcelain` printed when the caller ran them in the
#               producing environment. It must match the artifact's head: and tree:
#               exactly, so a pasted literal fails at the next commit.
#               upstream: exactly 'head=<full sha> upstream=<full sha>|(unpushed)'. That
#               is what `git -C <tree> rev-parse HEAD` and
#               `git -C <tree> ls-remote origin refs/heads/<branch>` printed there
#               ((unpushed) when ls-remote exited 0 and printed nothing). head= must match
#               the artifact's head:. An upstream=<sha> must still be contained in the
#               head being shipped, and that is decided HERE.
#               platform: exactly 'head=<full sha> platform=<the artifact's platform: line,
#               after the colon>'. NOT a fact checked in the producing environment: the
#               operator's acknowledgment that this artifact's UNDECLARED platform is
#               accepted for this run, so it is taken from the artifact by design and binds
#               to its head: and platform:. The preship verifier never passes it.
#               ARGUMENTS, never env vars, so there is no exported value to leave set (the
#               standing shape #655 rejects). DEVAGENT_TREE_GUARD_OVERRIDE answers a
#               different question (which checkout a run may act FROM) and silences no rung.
#   Stated blind spot: an attestation is a CLAIM. This script checks that it is
#   well-formed and bound to this artifact; it cannot check that the caller looked.
#   One derived from the artifact itself, not from the producing tree, passes here;
#   the verifier procedure forbids exactly that, and the PASS line records the claim.
# #660 BRANCH (not a rung: decidable here in every environment, so nothing attests it).
# The artifact's branch: must equal the issue's recorded branch (state `branch`, which
# branch.sh writes, read with the ISSUE PRECEDENCE above). A missing line, an issue with
# no recorded branch, and a mismatch each fail. A matching head: on the wrong branch is
# the #570 shape: a clone parked on a sibling's branch.
# #654 PLATFORM (the third rung). run-suite stamps `platform: os=… kernel=… fs=… modes=…`
# (grammar: scripts/lib/platform.sh). The CHECKING operator may declare, in THEIR
# config.toml, `[project.<name>] evidence_platforms = ["os=Linux fs=ext4 modes=posix", …]`; an entry
# matches when each of its key=value pairs appears in the artifact's line. The declaration
# is read once, below, and a malformed one dies before anything is decided. It governs
# BOTH exits, the main path and the #149 no-Evidence exit, so deleting the Evidence block
# cannot sidestep it (the #466 MAJOR-2 shape). Stated blind spot: the stamp is a claim the
# artifact makes; a hand-written artifact can carry any well-formed platform: line.
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
# shellcheck source=lib/platform.sh
. "$DEVAGENT_ROOT/scripts/lib/platform.sh"

: "${DEVAGENT_GIT:=git}"

# #655/#660: take the per-run attestations out of the argument list, leaving the
# positional [project] [issue] contract unchanged. ARGUMENTS, never env vars: no exported
# value outlives the run it describes (vocabulary in the header).
attest_tree=""; attest_upstream=""; attest_platform=""; _rep_flag=""; _rep_ref=""; _pos=()
_attest_take() {   # <flag> <value>: the ONE table of per-rung attestation flags
  local var form ref
  case "$1" in
    --attest-tree)     var=attest_tree     form="'head=<full sha> dirty=no path=<tree>'"                  ref="#655" ;;
    --attest-platform) var=attest_platform form="'head=<full sha> platform=<the artifact's platform: line, after the colon>'" ref="#654" ;;
    --attest-upstream) var=attest_upstream form="'head=<full sha> upstream=<full sha>|(unpushed)'" ref="#660" ;;
  esac
  [ -n "$2" ] || die "preship-evidence: $1 needs a value: $form ($ref)"
  # A repeat is reported after the loop, so an unknown option later in argv still wins.
  if [ -n "${!var}" ] && [ -z "$_rep_flag" ]; then _rep_flag="$1"; _rep_ref="$ref"; fi
  printf -v "$var" '%s' "$2"
}
while [ $# -gt 0 ]; do
  case "$1" in
    --attest-tree|--attest-upstream|--attest-platform)
      _attest_take "$1" "${2-}"; shift 2 ;;
    --attest-tree=*|--attest-upstream=*|--attest-platform=*)
      _attest_take "${1%%=*}" "${1#*=}"; shift ;;
    --*) die "preship-evidence: unknown option '$1' — usage: preship-evidence.sh [project] [issue] [--attest-tree '<attestation>'] [--attest-upstream '<attestation>'] [--attest-platform '<attestation>'] (#655/#660/#654)" ;;
    *) _pos+=("$1"); shift ;;
  esac
done
[ -z "$_rep_flag" ] || die "preship-evidence: $_rep_flag given more than once — pass one attestation per run ($_rep_ref)"
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

# #654: the CHECKING operator's declaration, read ONCE (setter-globals; never $( … )).
# A malformed one dies HERE, before anything is decided (the suite_env/suite_jobs shape).
platform_declaration_resolve "$project"

# #654 PLATFORM RUNG (header "#654 PLATFORM"). Every arm; the verdict ends the PASS line
# as [platform=<verdict>]:
#   no platform: line  -> unstamped while nothing is declared (every pre-#654 artifact);
#                         FAIL once evidence_platforms is declared: a missing stamp is
#                         refused, never a bypass (the pytest: (error) precedent)
#   not the one shape  -> FAIL, declared or not: only run-suite writes this line
#   nothing declared   -> undeclared: <line>   (the facts, echoed)
#   an entry matches   -> checked: <line> — matches evidence_platforms '<entry>' (decided HERE)
#   no entry matches   -> FAIL PLATFORM UNATTESTED; with a matching --attest-platform
#                         -> attested: <acknowledgment> — …
# Appends to fails[]; sets platform_verdict, _plat_attest_used and a_platform_line (the
# artifact's raw platform: line, "" when absent). Task 6's Evidence arm and Task 4's #149
# exit read that line, so the artifact line is parsed ONCE (register Issue-565). Called on
# BOTH exits, so the #149 exit and the main path read the same arms. The #149 exit passes
# a third argument, no-block: an acknowledgment cannot clear an mr.md with no Evidence
# block, so there the UNATTESTED message offers remedies (1) and (2) only (imPlan D10).
platform_unattested="PLATFORM UNATTESTED"
_platform_rung() {   # <artifact file> <its head: sha> [no-block]
  local art="$1" head="$2" no_block="${3:-}" line body e decl="" n ack_head ack_body ack_remedy
  local ack_re='^head=([[:xdigit:]]+) platform=(.+)$'
  platform_verdict=""; _plat_attest_used=false
  line="$(sed -n '/^platform:/{p;q;}' "$art")"
  a_platform_line="$line"
  if [ -z "$line" ]; then
    if $PLATFORM_DECLARED_SET; then
      fails+=("artifact has no 'platform:' line, and [project.$project] evidence_platforms in $(config_path) declares which platforms count, so an unstamped artifact is refused (#654). It predates #654, or came from a run-suite that does not stamp one (a clone running old plugin scripts). Re-run run-suite with this plugin's scripts, on a declared platform.")
    else
      platform_verdict="unstamped"
    fi
    return 0
  fi
  body="${line#platform:}"
  body="${body#"${body%%[![:space:]]*}"}"
  if ! platform_body_valid "$body"; then
    fails+=("artifact 'platform:' line '$body' is not the one shape run-suite writes ('os=<v> kernel=<v> fs=<v> modes=posix|no-op') — re-run run-suite (#654)")
    return 0
  fi
  if ! $PLATFORM_DECLARED_SET; then
    platform_verdict="undeclared: $body"
    return 0
  fi
  for e in "${PLATFORM_DECLARED[@]}"; do
    if platform_entry_matches "$e" "$body"; then
      platform_verdict="checked: $body — matches evidence_platforms '$e'"
      return 0
    fi
    decl+="${decl:+, }'$e'"
  done
  if [ -z "$attest_platform" ]; then
    if [ -n "$no_block" ]; then
      ack_remedy=". No acknowledgment can clear this exit: mr.md has no Evidence block (reported first), so give it one, then re-run this check."
    else
      ack_remedy="; (3) to accept THIS artifact anyway (an operator's decision, not a fix, and never one an agent makes on its own), re-run this check adding --attest-platform 'head=$head platform=$body'. The PASS line then records the acknowledgment, which binds to this artifact's head: and platform:, so every new artifact needs a new one."
    fi
    fails+=("$platform_unattested — the artifact was produced on '$body', which matches no entry of [project.$project] evidence_platforms ($decl) in $(config_path), so this check does not accept it as evidence (#654). (1) re-run run-suite on a declared platform, then re-run this check; (2) if this platform is in fact supported for $project, add an entry naming it to evidence_platforms in that file$ack_remedy")
    return 0
  fi
  _plat_attest_used=true
  if [[ "$attest_platform" =~ $ack_re ]]; then
    ack_head="${BASH_REMATCH[1]}"; ack_body="${BASH_REMATCH[2]}"; n="${#fails[@]}"
    [ "$ack_head" = "$head" ] \
      || fails+=("$platform_unattested — --attest-platform names head $ack_head but the artifact records head $head; an acknowledgment binds to one artifact (#654)")
    [ "$ack_body" = "$body" ] \
      || fails+=("$platform_unattested — --attest-platform names platform '$ack_body' but the artifact records '$body'; acknowledge the platform this artifact names (#654)")
    [ "${#fails[@]}" -gt "$n" ] \
      || platform_verdict="attested: $attest_platform — acknowledged by the caller for this run; not in this project's evidence_platforms"
  else
    fails+=("$platform_unattested — malformed --attest-platform '$attest_platform': the one accepted form is 'head=<full sha> platform=<the artifact's platform: line, after the colon>' (#654)")
  fi
}
# The #655 rule: an acknowledgment the rung did not need is warned about and ignored.
_platform_attest_warn() {
  if [ -n "$attest_platform" ] && [ "$_plat_attest_used" = false ]; then
    warn "preship-evidence: --attest-platform ignored — the platform rung did not need it (#654)"
  fi
}

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
[ -n "$artifact" ] || die "preship-evidence: no suite-count artifact — run \`bash \"\$CLAUDE_PLUGIN_ROOT/scripts/run-suite.sh\" $project $(basename "$issue_dir")\` at HEAD (#572/#659: pass the project and the issue explicitly)"

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
#   exists here, not -ef  -> FAIL "produced from tree" (#571). #659 retired the pair's
#                            old arity asymmetry: run-suite now takes its issue from the
#                            argument or the pin and refuses the shared slot. A mismatch
#                            still follows when the two are pointed at DIFFERENT issues,
#                            e.g. this script run bare and unpinned reads the shared
#                            slot (header, ISSUE PRECEDENCE).
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
# #660 BRANCH (header).
issue_label="$(basename "$issue_dir")"
# _art_field <key>: one artifact field, first match, whitespace after the colon stripped.
# `sed '/re/{s///p;q;}'`, not `sed … | head -1`: under this script's pipefail a sed killed
# by SIGPIPE after head exits turns the read EMPTY (register Issue-595). One match, then
# quit, so there is no pipe to break. The #660 fields read through it; the older reads
# above keep their form (a file-wide change is its own issue).
_art_field() { sed -n "/^$1:/{s/^$1:[[:space:]]*//p;q;}" "$artifact"; }
a_branch="$(_art_field branch)"
st_branch="$(state_ctx_get "$project" branch "$issue_arg" 2>/dev/null || true)"
case "$st_branch" in null|'""') st_branch="" ;; esac
if [ -z "$a_branch" ]; then
  fails+=("artifact has no 'branch:' line — it predates #660, or came from a run-suite that does not stamp one (a clone running old plugin scripts, the #570 shape), so nothing says which branch it measured. Re-run run-suite with this plugin's scripts in the producing tree, on the issue's branch${st_branch:+ '$st_branch'} (#660)")
elif [ -z "$st_branch" ]; then
  fails+=("no branch is recorded in state for $issue_label, so the artifact's branch '$a_branch' cannot be checked — record the issue's branch in its state (/devagent:branch writes it when it creates the branch), then re-run this check (#660)")
elif [ "$a_branch" != "$st_branch" ]; then
  fails+=("artifact was produced on branch '$a_branch', but $issue_label's branch is '$st_branch' — check out '$st_branch' in the producing tree and re-run run-suite there (#660; the #570 shape: a clone parked on another issue's branch)")
fi

# #660 UPSTREAM RUNG (vocabulary in the header). What the producing tree's origin said
# about its branch when run-suite asked it (a bounded ls-remote). Every arm:
#   <sha>          -> checked when the head being shipped contains it (merge-base
#                     --is-ancestor, HERE); else FAIL, since that contradicts run-suite's
#                     own BEHIND ORIGIN refusal.
#   (no-origin)    -> no-origin: the single-tree case (nothing to compare, not a degradation).
#   (unpushed)     -> origin has no such branch. With tree=checked it is the single-tree
#                     case (B′): unpushed. Otherwise a DEGRADATION, as below.
#   (unreachable)  -> origin did not answer (failed or timed out): a DEGRADATION in every tree. A
#                     DEGRADATION FAILs UPSTREAM UNATTESTED unless a matching
#                     --attest-upstream -> attested.
#   no line/other  -> FAIL: no back-compat pass (a pre-#660 artifact), and one shape per state.
# Containment has THREE answers, never two: is-ancestor 0 (contained), 1 (not contained:
# behind), anything else (128: the tip is not an object in THIS checking tree, so it is
# undecidable here; the remedy is a fetch HERE, never an accusation that the producing
# tree was behind: register Issue-458/243, improve B1).
upstream_unattested="UPSTREAM UNATTESTED"
# #660 LIMITATION (red-team): B′ passes a single-tree (unpushed) because origin, the remote
# ship pushes to, holds no copy. A project that ships to another source_remote breaks that
# premise (the fork holds a copy this check never asks), so B′ is withheld there.
_push_remote="$(config_get_project_field "$project" source_remote 2>/dev/null || true)"
_push_note=""
if [ -n "$_push_remote" ] && [ "$_push_remote" != "origin" ]; then
  _push_note=" This project ships to source_remote '$_push_remote', which this check does not ask, so a single-tree (unpushed) is not passed on its own (#660 limitation)."
fi
a_upstream="$(_art_field upstream)"
upstream_verdict=""; _up_attest_used=false
# The branch as the messages quote it: quoted when the artifact names one, else a plain
# phrase (the missing-line failure above already fired), never a quoted placeholder that
# would read as a branch name.
if [ -n "$a_branch" ]; then _up_br="'$a_branch'"; else _up_br="(branch unknown)"; fi
# _up_containment <sha> <prefix> <not-contained message>: the ONE three-answer table (above).
# Returns 0 only when the artifact's head contains <sha> here; otherwise appends the fitting
# failure, prefixed with <prefix>, and returns 1.
_up_containment() {
  local rc=0
  "$DEVAGENT_GIT" -C "$work_dir" merge-base --is-ancestor "$1" "$a_head" 2>/dev/null || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) fails+=("$2$3") ;;
    *) fails+=("${2}origin's $_up_br tip $1 is not an object in this checking tree (git merge-base --is-ancestor exited $rc), so containment cannot be decided here — fetch origin here (git -C '$work_dir' fetch origin), then re-run this check (#660)") ;;
  esac
  return 1
}
case "$a_upstream" in
  "")
    fails+=("artifact has no 'upstream:' line — it predates #660, so nothing says whether the producing tree was behind origin's $_up_br. Re-run run-suite with this plugin's scripts (#660)") ;;
  "(no-origin)")
    upstream_verdict="no-origin" ;;
  "(unreachable)"|"(unpushed)")
    if [ "$a_upstream" = "(unpushed)" ] && [ "$tree_verdict" = "checked" ] && [ -z "$_push_note" ]; then
      # #660 B′ (Q1, intent.md ## Answers): the artifact came from the very tree being
      # shipped (the tree rung decided that HERE), and origin holds no copy of its
      # branch, so no other copy can be ahead of it. The single-tree case, like
      # (no-origin): named on the PASS line, not failed. The first push is at the ship
      # step, after preship, so this is every forge-origin project's first-round state.
      upstream_verdict="unpushed"
    elif [ -z "$attest_upstream" ]; then
      fails+=("$upstream_unattested — the artifact records upstream: $a_upstream, so run-suite could not compare the producing tree with origin's $_up_br ((unreachable): its bounded call to origin failed or timed out; (unpushed): origin has no such branch), and nothing shows that tree was not behind it (#660). Either make origin reachable, or push $_up_br, and re-run run-suite in the producing tree. Or check origin THERE (git -C '<tree>' rev-parse HEAD, and git -C '<tree>' ls-remote origin refs/heads/${a_branch:-<branch>}, which must exit 0) and re-run this check adding --attest-upstream 'head=<the sha rev-parse printed> upstream=<the sha ls-remote printed, or (unpushed) if it printed nothing>'. The rung is then attested by you, and an attestation binds to this artifact's head:, so every new artifact needs a new one.$_push_note")
    else
      _up_attest_used=true
      _up_re='^head=([[:xdigit:]]+) upstream=(\(unpushed\)|[[:xdigit:]]+)$'
      if [[ "$attest_upstream" =~ $_up_re ]]; then
        _up_head="${BASH_REMATCH[1]}"; _up_tip="${BASH_REMATCH[2]}"; _n_fails="${#fails[@]}"
        [ "$_up_head" = "$a_head" ] \
          || fails+=("$upstream_unattested — --attest-upstream names head $_up_head but the artifact records head $a_head; attest the full SHA the producing tree prints now (#660)")
        if [ "$_up_tip" = "(unpushed)" ]; then
          _up_note="verified by the caller in the producing environment, not checked here"
        else
          _up_note="origin's tip as the caller saw it in the producing environment; containment checked here"
          _up_containment "$_up_tip" "$upstream_unattested — " \
            "--attest-upstream reports origin's $_up_br at $_up_tip, which the artifact's head $a_head does not contain here (git merge-base --is-ancestor exited 1): the producing tree is behind (or has diverged from) origin. Bring it up to date there and re-run run-suite, which prints the remedy (#660)" || :
        fi
        [ "${#fails[@]}" -gt "$_n_fails" ] \
          || upstream_verdict="attested: $attest_upstream — $_up_note"
      else
        fails+=("$upstream_unattested — malformed --attest-upstream '$attest_upstream': the one accepted form is 'head=<full sha> upstream=<full sha>|(unpushed)' (#660)")
      fi
    fi ;;
  *)
    if [[ "$a_upstream" =~ ^[[:xdigit:]]+$ ]]; then
      if _up_containment "$a_upstream" "" \
           "artifact records origin's $_up_br at $a_upstream, which its head $a_head does not contain here (git merge-base --is-ancestor exited 1) — run-suite refuses that shape (BEHIND ORIGIN), so this artifact did not come from it as recorded; re-run run-suite (#660)"; then
        upstream_verdict="checked"
      fi
    else
      fails+=("artifact 'upstream:' line '$a_upstream' is none of <sha> | (no-origin) | (unreachable) | (unpushed) — re-run run-suite (#660)")
    fi ;;
esac
# The #655 rule: an attestation the rung did not need is warned about and ignored.
if [ -n "$attest_upstream" ] && [ "$_up_attest_used" = false ]; then
  warn "preship-evidence: --attest-upstream ignored — the upstream rung did not need it (#660)"
fi
# #654 PLATFORM RUNG (defined above, beside the declaration it reads).
_platform_rung "$artifact" "$a_head"
_platform_attest_warn
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
echo "preship-evidence: PASS — mr.md Evidence matches $artifact ($expected_suite; files=$ev_files) [tree=$tree_verdict] [upstream=$upstream_verdict] [platform=$platform_verdict]" >&2
