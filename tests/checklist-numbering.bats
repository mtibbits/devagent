#!/usr/bin/env bats
# tests/checklist-numbering.bats — #558. Step numbers are POSITIONS, not IDs:
# every checklist template's rows carry strictly increasing numbers in file order,
# and the standard template is contiguous 0..23. Retires the permanent-ID scheme.
# NOTE: bats-support is not installed here, so diagnostics use printf+return 1.

setup() {
    PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

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

@test "numbering: revise excludes the new pre-draft rows from a retier block (#558, B1)" {
    # The filter must exclude 0 pull / 1 research / 3 spike — NOT 22/23, which are
    # now lessonslearned and cleanup and MUST appear in every revision block.
    grep -qE '\+0\\\. .*\+1\\\. .*\+3\\\. ' "$PLUGIN_ROOT/scripts/revise.sh"
    run grep -c '+22\\\. ' "$PLUGIN_ROOT/scripts/revise.sh"
    [ "$status" -eq 1 ] || _die "revise.sh still filters row 22 (now lessonslearned)"
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
        case " 2 5 15 16 17 " in
            *" $num "*) : ;;
            *) printf 'STALE invocation: %s\n' "$line" >&2; bad=1 ;;
        esac
    done < <(grep -rn '<project> [0-9]' "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/docs")
    [ "$n" -eq 6 ] || _die "expected 6 step-model invocation sites, found $n"
    [ "$bad" -eq 0 ]
}
