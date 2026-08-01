#!/usr/bin/env bats
# tests/checklist-numbering.bats — #558. Step numbers are POSITIONS, not IDs:
# every checklist template's rows carry strictly increasing numbers in file order,
# and the standard template is contiguous 0..23. Retires the permanent-ID scheme.
# NOTE: bats-support is not installed here, so diagnostics use printf+return 1.

load 'lib/bats-helpers'


_die() { printf '%s\n' "$1" >&2; return 1; }

# Emit "<num> <name>" per checklist row.
_rows() {
    sed -n 's/^- \[.\] *\([0-9]*\)\. *\([A-Za-z][A-Za-z0-9_-]*\).*$/\1 \2/p' "$1"
}

@test "numbering: every checklist template is strictly increasing in file order" {
    local n_templates=0
    for f in "$PLUGIN_ROOT"/templates/checklist-*.md "$PLUGIN_ROOT"/templates/revision_block.md; do
        n_templates=$((n_templates + 1))
        local prev=-1 num name rows=0
        while read -r num name; do
            rows=$((rows + 1))
            [ "$num" -gt "$prev" ] \
                || _die "$(basename "$f"): row '$num $name' not > previous '$prev'"
            prev="$num"
        done < <(_rows "$f")
        # Issue-151: a loop that never iterates passes vacuously.
        [ "$rows" -ge 5 ] || _die "$(basename "$f"): only $rows rows parsed — selector broke"
    done
    # Issue-439: assert the SUBJECT COUNT so a renamed template cannot empty this guard.
    [ "$n_templates" -eq 6 ] || _die "expected 6 templates, selected $n_templates"
}

@test "numbering: the standard template is contiguous 0..23" {
    local expect=0 num name
    while read -r num name; do
        [ "$num" -eq "$expect" ] || _die "standard: expected $expect for '$name', got $num"
        expect=$((expect + 1))
    done < <(_rows "$PLUGIN_ROOT/templates/checklist-standard.md")
    [ "$expect" -eq 24 ] || _die "standard: expected 24 rows, got $expect"
}

@test "numbering: execution order matches the canonical step sequence" {
    local expected="pull research draft spike scope improve prune tighten branch \
implement quality document commit analyze draftmr review redmr preship ship \
mergetoall updatewbs impact lessonslearned cleanup"
    local actual
    actual="$(_rows "$PLUGIN_ROOT/templates/checklist-standard.md" | cut -d' ' -f2 | tr '\n' ' ')"
    [ "$(echo $actual)" = "$(echo $expected)" ] || _die "standard step order drifted: $actual"
}

@test "numbering: the step->class map uses the new numbers (#558)" {
    grep -qF 'case " 2 9 10 11 14 " in' "$PLUGIN_ROOT/scripts/lib/config.sh"
    grep -qF 'case " 5 15 16 17 " in' "$PLUGIN_ROOT/scripts/lib/config.sh"
}

@test "numbering: step-model resolves the CHECKING class at the new numbers (#558)" {
    # Not a vacuous rc probe (improve A5): seed a config whose ONLY entry is the
    # checking tier, then assert the resolved tier on stdout per step.
    # DA_HOME is the config/state override (scripts/lib/paths.sh).
    local home="$BATS_TEST_TMPDIR/dh"; mkdir -p "$home/state"
    cat > "$home/config.toml" <<CFG
[project.p]
devdoc_dir = "$BATS_TEST_TMPDIR/dd"
[project.p.step_models]
checking = "opus"
CFG
    for step in 5 15 16 17; do
        run env DA_HOME="$home" bash "$PLUGIN_ROOT/scripts/step-model.sh" p "$step"
        [ "$status" -eq 0 ] || _die "step $step: expected rc 0, got $status"
        [ "$output" = "opus" ] || _die "step $step: expected opus, got '$output'"
    done
    # and a NON-checking step must NOT resolve checking
    run env DA_HOME="$home" bash "$PLUGIN_ROOT/scripts/step-model.sh" p 21
    [ "$output" != "opus" ] || _die "step 21 (impact) wrongly resolved as checking"
}

@test "numbering: the idle threshold tracks cleanup's new number (#558)" {
    grep -qF 'if last_step >= 23:' "$PLUGIN_ROOT/scripts/lib/statusreport-detect.py"
    grep -qF 'last_step = 23 if any' "$PLUGIN_ROOT/scripts/statusreport.sh"
}

@test "numbering: each script self-marks its own new step number (#558)" {
    declare -A EXPECT=( [pull]=0 [branch]=8 [commit]=12 [analyze]=13 \
                        [ship]=18 [mergetoall]=19 [cleanup]=23 )
    local n=0
    for name in "${!EXPECT[@]}"; do
        grep -qE "checklist_mark \"\\\$issue_dir/checklist\.md\" ${EXPECT[$name]} " \
            "$PLUGIN_ROOT/scripts/${name}.sh" || _die "${name}.sh: no self-mark ${EXPECT[$name]}"
        n=$((n + 1))
    done
    [ "$n" -eq 7 ] || _die "expected 7 script self-marks, checked $n"
}

@test "numbering: state_cleanup_finish stamps the new cleanup number (#558, B4)" {
    grep -qF 'str last_step "23" str last_step_name "cleanup"' "$PLUGIN_ROOT/scripts/lib/state.sh"
}

@test "numbering: revise excludes the pre-draft steps BY NAME from a retier block (#558, B1)" {
    # Name-keyed, so no number literal to go stale. tests/revise.bats covers the
    # behavior end-to-end; this pins that the filter never regresses to numbers.
    grep -qF '(pull|research|spike)$/' "$PLUGIN_ROOT/scripts/revise.sh"
    run grep -cE '\+(2[0-3]|1?[0-9])\\\. ' "$PLUGIN_ROOT/scripts/revise.sh"
    [ "$status" -eq 1 ] || _die "revise.sh regressed to a number-keyed row filter"
}

@test "numbering: pull's flag->row table uses the new rows (#558, B2)" {
    grep -qF '"research:required:1"' "$PLUGIN_ROOT/scripts/pull.sh"
    grep -qF '"spike:required:3"' "$PLUGIN_ROOT/scripts/pull.sh"
}

@test "numbering: the checking contract's canonical steps match the class map (#558)" {
    local c="$PLUGIN_ROOT/docs/checking-dispatch-contract.md"
    grep -qF '`5` improve / `16` redmr / `17` preship' "$c"
    run grep -c '`3` improve' "$c"
    [ "$status" -eq 1 ] || _die "contract still names the old canonical step 3"
}

@test "numbering: each checker agent names its new step number (#558)" {
    grep -qF 'step 5'  "$PLUGIN_ROOT/agents/plan-improver.md"
    grep -qF 'step 16' "$PLUGIN_ROOT/agents/redteam-reviewer.md"
    grep -qF 'step 17' "$PLUGIN_ROOT/agents/preship-verifier.md"
}

@test "numbering: the smoke eval tracks preship-verifier's sentence (#558, S1)" {
    # The eval asserts an exact-uniqueness attestation; it must quote the CURRENT text.
    grep -qF 'workflow step 17' "$PLUGIN_ROOT/evals/smoke/smoke.json"
}

@test "numbering: every step-model.sh doc invocation carries a new-scheme step (#558, audit)" {
    # The load-bearing dispatcher instructions: `step-model.sh" <project> N` in the
    # wrappers and contracts. Legal N post-renumber: 2 draft, 5 improve, 15 review,
    # 16 redmr, 17 preship. Subject count asserted (Issue-439): exactly 6 sites.
    local n=0 bad=0 line num
    while IFS= read -r line; do
        n=$((n + 1))
        num="$(sed -E 's/.*<project> ([0-9]+).*/\1/' <<<"$line")"
        # shellcheck disable=SC2194 # constant subject; space-padded membership test
        case " 2 5 15 16 17 " in
            *" $num "*) : ;;
            *) printf 'STALE invocation: %s\n' "$line" >&2; bad=1 ;;
        esac
    done < <(grep -rn '<project> [0-9]' "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/docs")
    [ "$n" -eq 6 ] || _die "expected 6 step-model invocation sites, found $n"
    [ "$bad" -eq 0 ]
}

@test "numbering: doc surfaces mark BY NAME only — no literal-number invocations (#558 r3 B1)" {
    # quality.md shipped `8 -`, was corrected to `10 -`, and STILL silently
    # marked commit's row on a pre-#558 checklist — a literal that is correct
    # today is the defect, not just a stale one, because numbers are positions
    # and differ across schemes. Doc-driven marks are therefore banned from
    # carrying numbers at all; every invocation resolves by name.
    run grep -rnE 'checklist-mark\.sh"? +("\$ISSUE_DIR"|\S+) +[0-9]+ ' \
        "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/agents"
    [ -z "$output" ] || _die "literal-number checklist-mark invocation(s):"$'\n'"$output"
    # ...and every --by-name invocation names its OWN step.
    local n=0 bad=0 hit f base name
    while IFS= read -r hit; do
        f="${hit%%:*}"; base="$(basename "$f" .md)"
        name="$(sed -E 's/.*--by-name +\S+ +([A-Za-z][A-Za-z0-9_-]*) .*/\1/' <<<"$hit")"
        n=$((n + 1))
        [ "$name" = "$base" ] \
            || { printf 'WRONG-name mark: %s marks %s\n' "$f" "$name" >&2; bad=1; }
    done < <(grep -rnE 'checklist-mark\.sh"? +--by-name +("\$ISSUE_DIR"|\S+) +[A-Za-z]' \
                "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/agents" || true)
    # Issue-439: assert the SUBJECT COUNT so an emptied selector cannot pass.
    # 17 = the 14 converted handoffs (quality carries two sites) + the three
    # early adopters (spike, research, updatewbs).
    [ "$n" -ge 17 ] || _die "only $n by-name invocations found — selector broke"
    [ "$bad" -eq 0 ]
}

# --- #558 loop regression: a post-renumber script vs a pre-renumber checklist ---

_old_scheme_checklist() {   # pre-#558 numbering: 10=commit, 12=draftmr
    F="$BATS_TEST_TMPDIR/old/checklist.md"; mkdir -p "$(dirname "$F")"
    cat > "$F" <<'CL'
# Issue-1 — Workflow checklist

## Revision 1

- [x]  9. document
- [ ] 10. commit
- [ ] 12. draftmr

## Log
CL
}

@test "numbering: checklist_mark refuses a name/number mismatch (#558 loop regression)" {
    source "$PLUGIN_ROOT/scripts/lib/paths.sh"
    source "$PLUGIN_ROOT/scripts/lib/io.sh"
    source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
    _old_scheme_checklist
    # post-#558 commit.sh marks 12; on this checklist row 12 is draftmr.
    run checklist_mark "$F" 12 x commit
    [ "$status" -ne 0 ] || _die "expected a refusal, got rc 0"
    [[ "$output" == *"that row is 'draftmr'"* ]] || _die "message did not name the actual row: $output"
    # and it must NOT have written: the wrong row stays pending (assert the delta)
    grep -qE '^- \[ \] 12\. draftmr' "$F" || _die "draftmr was marked despite the refusal"
}

@test "numbering: checklist_mark still marks when the name matches (#558)" {
    source "$PLUGIN_ROOT/scripts/lib/paths.sh"
    source "$PLUGIN_ROOT/scripts/lib/io.sh"
    source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
    _old_scheme_checklist
    checklist_mark "$F" 10 x commit          # 10 IS commit on this checklist
    grep -qE '^- \[x\] 10\. commit' "$F"
}

@test "numbering: every script self-mark declares its own step name (#558)" {
    # The 4th arg is what makes the mismatch detectable; a self-mark that omits
    # it silently reopens the wrong-row class.
    local n=0 f
    for f in pull branch commit analyze ship mergetoall cleanup; do
        while IFS= read -r hit; do
            n=$((n + 1))
            [[ "$hit" =~ checklist_mark\ \"\$issue_dir/checklist\.md\"\ [0-9]+\ [x-]\ [a-z]+ ]] \
                || _die "$f.sh: self-mark without an expected-name arg: $hit"
        done < <(grep -o 'checklist_mark "\$issue_dir/checklist\.md" [0-9]* [x-].*' \
                     "$PLUGIN_ROOT/scripts/$f.sh" || true)
    done
    [ "$n" -eq 12 ] || _die "expected 12 script self-marks, found $n"
}

@test "numbering: next.sh STOPS when a script step exits 0 without marking (#558)" {
    # Behavioral, not a string pin (review m1): stage a script-backed step whose
    # script exits 0 and marks nothing — the exact shape that looped ~3255 times.
    local root="$BATS_TEST_TMPDIR/repo"
    local DA_HOME="$BATS_TEST_TMPDIR/dahome"
    mkdir -p "$root/scripts" "$BATS_TEST_TMPDIR/dd/Issue-1" "$DA_HOME/state"
    cp -r "$PLUGIN_ROOT/scripts/." "$root/scripts/"
    cp -r "$PLUGIN_ROOT/templates" "$root/" 2>/dev/null || true
    # a no-op script step standing in for the broken commit.sh
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/scripts/scope.sh"
    chmod +x "$root/scripts/scope.sh"
    printf '%s\n' '# Issue-1' '' '## Revision 1' '' '- [x]  0. pull' '- [x]  2. draft' \
        '- [ ]  4. scope' '- [ ]  5. improve' '' '## Log' \
        > "$BATS_TEST_TMPDIR/dd/Issue-1/checklist.md"
    cat > "$DA_HOME/config.toml" <<CFG
[project.p]
source_dir = "$root"
devdoc_dir = "$BATS_TEST_TMPDIR/dd"
CFG
    printf 'active_issue = "Issue-1"\nissue_dir = "%s/dd/Issue-1"\n' "$BATS_TEST_TMPDIR" \
        > "$DA_HOME/state/p.toml"
    local before; before="$(cat "$BATS_TEST_TMPDIR/dd/Issue-1/checklist.md")"
    # --auto implies --through cleanup, which this mini checklist lacks; the
    # guard is what we are testing, so chain through a row that IS present.
    run env DA_HOME="$DA_HOME" bash "$root/scripts/next.sh" p --through improve
    [ "$status" -ne 0 ] || _die "expected a nonzero halt, got rc 0 (guard did not fire)"
    [[ "$output" == *"did not mark itself"* ]] || _die "no guard message: $output"
    # and it must not have looped or mutated the checklist
    [ "$(cat "$BATS_TEST_TMPDIR/dd/Issue-1/checklist.md")" = "$before" ] \
        || _die "checklist changed despite the halt"
    [ "$(grep -c 'scope' <<<"$output")" -le 3 ] || _die "looks like it looped: $output"
}

@test "numbering: every adjacent name/number pairing agrees with the map (#558 M1)" {
    # Decidable subset of the census, promoted from a session snippet into the
    # suite because it shipped stale twice (census CORRECTION; review M1).
    # The undecidable bare-`step N` form is deliberately NOT asserted here —
    # see scripts/lib/check-step-pairings.py for why, and use --list-bare for
    # the human-triage list.
    run python3 "$PLUGIN_ROOT/scripts/lib/check-step-pairings.py" --root "$PLUGIN_ROOT"
    [ "$status" -eq 0 ] || _die "stale name/number pairings:"$'\n'"$output"
    # Issue-439: assert the SUBJECT COUNT so a broken selector cannot pass empty.
    local n; n="$(sed -nE 's/^checked ([0-9]+) .*/\1/p' <<<"$output")"
    # Floor derived from the GENERALIZED checker (277 after the r4 MAJOR-2
    # family extension), not an earlier narrower run: a floor set below actual
    # coverage cannot register erosion, which is how the NOISE blind spot hid
    # four stale sites (#558 redmr M1c).
    [ -n "$n" ] && [ "$n" -ge 270 ] || _die "only ${n:-0} pairings checked — selector broke"
}

@test "numbering: the checker flags every observed spelling family (#558 r2 BLOCKING-3)" {
    # The spelling CORPUS: one wrong-numbered line per family ever observed on
    # a live surface. r2 found five families invisible to the checker in BOTH
    # its outputs. Add a line here whenever a new spelling ships stale — the
    # test fails until the checker's PAIRED set learns it.
    local root="$BATS_TEST_TMPDIR/corpus-root"
    mkdir -p "$root/commands"
    cat > "$root/commands/corpus.md" <<'EOF'
Step 9 (`/devagent:analyze`) runs next.
the implement (7) step
implement(7) again
7. implement as a row
The commit step (10) comes next in the flow.
ship.sh (15) refuses to push when tracked files are modified.
`cleanup` (20) is required (hardcoded self-mark).
checking steps (improve 3, review 13; #151)
# 21 = preship (#149); keep the bound in step.
(17 for `updatewbs`); resolve it from project state.
so 20/cleanup land in the final state.
steps 18 (commit) and 19 (mergetoall) self-detect.
last_step      = 7
last_step_name = "implement"
run `draft` (step 1) before anything else.
Document (step 12) is the verify beat.
EOF
    run python3 "$PLUGIN_ROOT/scripts/lib/check-step-pairings.py" --root "$root"
    [ "$status" -eq 1 ] || _die "checker passed a corpus of stale spellings:"$'\n'"$output"
    # every corpus line must be flagged (one family per line; lines 8 and 12
    # carry two pairings each; lines 13-14 are ONE cross-line pairing, the
    # r3 MAJOR-1 family, reported at the _name line; 15-16 are the r4 MAJOR-2
    # `name (step N)` family, line 16 exercising case tolerance)
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 14 15 16; do
        grep -q "corpus.md:$i:" <<<"$output" \
            || _die "family on corpus line $i not flagged:"$'\n'"$output"
    done
}

@test "numbering: the checker does not false-positive on known noise shapes (#558 r2)" {
    # Negative controls: real lines from this repo that LOOK like pairings.
    # A checker that flags these floods the signal and gets ignored.
    local root="$BATS_TEST_TMPDIR/noise-root"
    mkdir -p "$root/scripts"
    cat > "$root/scripts/noise.sh" <<'EOF'
st="$(checklist_step_state_by_name "$file" ship 2>/dev/null || true)"
mode="$(config_get_project_field "$project" analyze 2>/dev/null || true)"
local -a _flag_rows=( "research:required:1" "spike:required:3" )
log_append "$issue_dir" commit "$1"
# - 2026-05-19 14:01  pull: fetched gnuradio/volk#676, scaffold created
# log 2026-05-19 10:00 "improve: 1 bug surfaced, fixed in task 2"
# zero-diff guards in commit/ship/mergetoall (#3):
local remote="${1:-}" branch="${2:-}"
local draft=0
EOF
    run python3 "$PLUGIN_ROOT/scripts/lib/check-step-pairings.py" --root "$root"
    [ "$status" -eq 0 ] || _die "checker false-positived on noise:"$'\n'"$output"
}

@test "numbering: EXEMPT suppresses pairing checks but never the triage list (#558 r2 MAJOR-2)" {
    # The opt-out is for lines that deliberately cite pre-#558 numbers. It must
    # not reinstate the whole-line drop: --list-bare is a triage list and has
    # no reason to filter (that filtering is what hid the shipped defect).
    local root="$BATS_TEST_TMPDIR/exempt-root"
    mkdir -p "$root/commands"
    cat > "$root/commands/exempt.md" <<'EOF'
old scheme: step 21 (preship) was the gate.  #558-old-scheme
EOF
    run python3 "$PLUGIN_ROOT/scripts/lib/check-step-pairings.py" --root "$root"
    [ "$status" -eq 0 ] || _die "exempt-marked pairing was still flagged:"$'\n'"$output"
    run python3 "$PLUGIN_ROOT/scripts/lib/check-step-pairings.py" --root "$root" --list-bare
    grep -q 'exempt.md:1:' <<<"$output" \
        || _die "exempt line missing from the triage list:"$'\n'"$output"
}

# ---- #566: the mandatory/optional step-split claim ----
# The split is DERIVED, not asserted: templates/checklist-standard.md is the
# source (its rows are the 24 steps; the rows pre-marked `[-]` are the optional
# ones), so the mandatory count is rows-minus-skipped. Every prose home that
# states a mandatory COUNT must state that derived number.
#
# The subject set comes from the PREDICATE, never a hardcoded path list: a home
# that moves, or a new home that appears, is selected automatically, where a
# guard whose selector stops selecting passes silently (Issue-439). The count
# floor below is that guard's own guard (Issue-151).
#
# The universe is the TRACKED tree (`git grep` searches tracked files only, and
# the candidate list below comes from it), not the filesystem: a raw
# recursive grep also selects gitignored, machine-local, mutable files (a mypy
# cache, a merge-conflict .orig, a stray saved log), which makes the guard's
# result depend on which machine ran it — the environment trap of Issue-559 and
# the gitignored-mutable-input shape of Issue-106.
#
# Newline-flattened before matching: the dominant prose form wraps the claim
# across a continuation line, which a plain line-grep undercounts (Issue-335).
#
# SCOPE CLAIM, stated so the first false positive is a two-minute triage: this
# sweep treats EVERY numeric `<n> mandatory` phrase in the tracked tree as a
# workflow-split claim. A future doc that puts a digit immediately before the
# word — counting a command's required arguments, say — will fail here in a
# sense this guard knows nothing about. That is deliberate fail-loud behavior;
# the fix is to reword the new text or to narrow this predicate, consciously.
# (Spelling such an example literally here would make this comment its own
# offender — the self-trigger trap of Issue-561, observed live in this guard's
# own born-red run.)
#
# DECLARED BLIND SPOTS (Issue-558 — say what the checker cannot decide):
#   1. Only the MANDATORY half, in digit form. A count of the OPTIONAL steps
#      spelled as an English word rather than a digit is invisible. Issue-566
#      closed the one such home by de-numbering it; if that form returns, extend
#      the predicate rather than de-numbering again.
#   2. Only whitespace-separated claims, and only space-separated after the
#      flattening above: a TAB between the digit and the word is not seen.
#   3. Only files `git grep` treats as text — a UTF-16 or otherwise NUL-bearing
#      document is dropped by `-I` before the extractor ever sees it.
# 2 and 3 are consistent between the prefilter and the extractor, so neither can
# drop a claim ASYMMETRICALLY (the failure that would make a green run a lie);
# they are simply not covered. All three are theoretical in an all-ASCII,
# LF-pinned markdown tree, which is what `.gitattributes` enforces today.
#
# This notice deliberately spells no example of any of them, so that a later
# change extending the predicate does not turn the blind-spot notice itself into
# the new guard's first offender (Issue-561 — which is exactly what happened to
# an earlier draft of the comment above).
#
# The retired value this sweep exists to catch is deliberately NOT spelled
# anywhere in this file. The assertion is equality with the derived count, so
# every wrong number reddens AND a repo-wide grep for the retired token stays
# empty — a comment that quoted the literal would re-trigger the very grep it
# warns about (Issue-561).

_mandatory_step_count() {
    local t="$PLUGIN_ROOT/templates/checklist-standard.md" total skipped
    total="$(_rows "$t" | wc -l)"
    skipped="$(grep -cE '^- \[-\] *[0-9]+\.' "$t")"
    # Selector sanity: a broken _rows or a renamed template would derive a
    # meaningless count and make every comparison below vacuous.
    [ "$total" -eq 24 ] || { _die "standard template: parsed $total rows, expected 24"; return 1; }
    [ "$skipped" -ge 1 ] || { _die "standard template: parsed no pre-skipped rows"; return 1; }
    printf '%s\n' "$((total - skipped))"
}

# Emit "<repo-relative path>:<claimed mandatory count>" once per claim.
# Subjects are the TRACKED files only; see the universe note above.
#
# The candidate list is prefiltered on the BARE WORD, never on the full phrase.
# That is what keeps the prefilter compatible with the newline flattening below:
# prose wraps at whitespace, so a claim split across two lines still leaves the
# bare word intact on one of them and the file is still selected. Prefiltering
# on the phrase would silently drop exactly the wrapped claims this guard exists
# to catch. `git grep` also searches tracked files only, so the tracked-tree
# universe is preserved. (Measured: 564 tracked files -> 15 candidates, and the
# test drops from ~3m20s to ~4s. Without this, one test would eat a fifth of the
# suite's CI budget.)
#
# The `-z` is not cosmetic: without it `git grep -l` applies quotePath and emits
# a NON-ASCII path as a quoted C-escaped string, which then names no real file,
# and the read failure is swallowed inside this process substitution — a claim in
# such a file would be silently unswept. NUL-delimited output is unquoted, so the
# name that comes out is the name that goes in.
#
# The `|| true` is safe here only because of the floor below, and for no other
# reason: `git grep` exits nonzero both when it merely matched nothing and when it
# genuinely failed (1 for no-match, 128 for a fatal error such as not-a-repo), and
# this collapses every one of them to an empty candidate list — normally the exact
# "hid a failure as found nothing" shape Issue-314 warns about. It stays loud
# because an empty list means n=0, and the floor turns n=0 into a hard failure
# rather than a pass. Do not remove the floor without also removing this.
_split_claim_hits() {
    local rel phrase
    while IFS= read -r -d '' rel; do
        tr '\n' ' ' < "$PLUGIN_ROOT/$rel" | tr -s ' ' \
          | grep -oE '[0-9]+ (of them )?mandatory' \
          | while IFS= read -r phrase; do printf '%s:%s\n' "$rel" "${phrase%% *}"; done
    done < <(git -C "$PLUGIN_ROOT" grep -lIz 'mandatory' || true)
}

@test "step-split: every prose mandatory-count claim equals the template-derived count (#566)" {
    local m hit n=0 bad=""
    m="$(_mandatory_step_count)" || return 1
    while IFS= read -r hit; do
        n=$((n + 1))
        [ "${hit##*:}" = "$m" ] || bad="$bad $hit"
    done < <(_split_claim_hits)
    # The subject-count floor promised in the header (Issue-439/151).
    #
    # A FLOOR, not equality, on purpose: new correct homes are welcome and are
    # each checked by the equality-with-derived-count test above; only the
    # DISAPPEARANCE of the predicate is what this line catches.
    #
    # If this floor trips: re-run the Issue-566 census (see that issue's
    # analysis/2026-08-01-split-claim-census.txt) and adjust the floor IN THE
    # SAME CHANGE. Lowering it without a census is how a sweep goes quietly
    # blind (Issue-439).
    [ "$n" -ge 8 ] \
        || _die "split-claim sweep selected only $n homes (expected >= 8) — the predicate stopped matching"
    # Locate offenders with:
    #   grep -rnE '[0-9]+ +(of them +)?mandatory|[0-9]+ of them *$' --include='*.md' .
    [ -z "$bad" ] || _die "step-split drift — expected $m mandatory, found:$bad"
}
