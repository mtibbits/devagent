#!/usr/bin/env bats
# tests/next-backing.bats — #812. A step's backing is spec §6.3's Type column
# (docs/specs/2026-05-19-devagent-plugin-design.md); next.sh infers it from an
# executable scripts/<step>.sh, and a helper that takes a step's NAME silently
# turns that step script-backed (spike.sh did). This guard pins every
# scripts/<step>.sh against §6.3.
# Method: run the REAL next.sh from a copied tree in which every step-named
# script is a stub, then assert only the dispatch header and whether the stub
# ran. No real pull/branch/commit/... code runs, and nothing re-spells next.sh's
# backing rule or greps its source.
# NOTE: bats-support is not installed here, so diagnostics use printf+return 1.

load 'lib/bats-helpers'

setup() { setup_tmp_devagent_home; }
teardown() { teardown_tmp_devagent_home; }

_die() { printf '%s\n' "$1" >&2; return 1; }

# Source of truth: docs/specs/2026-05-19-devagent-plugin-design.md §6.3, the
# Type column. These are the rows whose Type INCLUDES `script` (branch is
# "script + skill"). A step with an executable scripts/<step>.sh dispatches
# script-backed iff it is listed here. Edit this list only together with §6.3.
# Same 7-set as the #558 self-mark census in tests/checklist-numbering.bats;
# change both with §6.3.
SCRIPT_TYPED=" pull branch commit analyze ship mergetoall cleanup "

# D4's stub: exit 3 is distinct from every real refusal, and next.sh's set -e
# propagates it; the header prints before the exec, so it is captured either way.
_write_stub() {
    printf '#!/usr/bin/env bash\necho STUB-RAN\nexit 3\n' > "$1"
    chmod +x "$1"
}

# Stage a copy of the plugin's scripts/ + templates/ and a one-project config.
# Sets the GLOBAL `root` (callers pass "$root"); reuses setup's exported DA_HOME.
_stage_tree() {
    root="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$root/scripts" "$BATS_TEST_TMPDIR/dd/Issue-1"
    cp -r "$PLUGIN_ROOT/scripts/." "$root/scripts/"
    cp -r "$PLUGIN_ROOT/templates" "$root/"
    cat > "$DA_HOME/config.toml" <<CFG
[project.p]
source_dir = "$root"
devdoc_dir = "$BATS_TEST_TMPDIR/dd"
CFG
    printf 'active_issue = "Issue-1"\nissue_dir = "%s/dd/Issue-1"\n' "$BATS_TEST_TMPDIR" \
        > "$DA_HOME/state/p.toml"
}

# "N name" for every row of the shipped standard checklist template — the
# canonical step list, reused rather than minted a third time.
_canonical_steps() {
    sed -nE 's/^- \[.\][[:space:]]+([0-9]+)\.[[:space:]]+([a-z]+).*$/\1 \2/p' \
        "$PLUGIN_ROOT/templates/checklist-standard.md"
}

# _backing_mismatches <root>: stub every step-named executable script in <root>
# (pass 1, before ANY run), then dispatch each one's row through the real
# next.sh (pass 2). Prints `EXAMINED <name>` per stubbed step and a `MISMATCH`
# line per step whose header or stub-run disagrees with §6.3 — both directions.
_backing_mismatches() {
    local r="$1" num name
    local -a examined=()
    while read -r num name; do
        if [[ -x "$r/scripts/$name.sh" ]]; then
            _write_stub "$r/scripts/$name.sh"
            examined+=("$num $name")
            echo "EXAMINED $name"
        fi
    done < <(_canonical_steps)

    local row out want hdr hdr_ok stub_ok
    for row in "${examined[@]}"; do
        num="${row%% *}"; name="${row#* }"
        printf '%s\n' "- [ ] $num. $name" '' '## Log' > "$BATS_TEST_TMPDIR/dd/Issue-1/checklist.md"
        out="$(env DA_HOME="$DA_HOME" bash "$r/scripts/next.sh" p 2>&1)" || true
        want=skill-backed
        if [[ "$SCRIPT_TYPED" == *" $name "* ]]; then
            want=script-backed
        fi
        hdr="$(grep -m1 '^dispatch: ' <<<"$out" || true)"
        if [[ -z "$hdr" ]]; then
            echo "MISMATCH $name: no dispatch header; out='$(head -n3 <<<"$out")'"
            continue
        fi
        hdr_ok=no
        if [[ "$hdr" == *"step $num ($name), $want"* ]]; then
            hdr_ok=yes
        fi
        stub_ok=no
        if [[ "$out" == *STUB-RAN* ]]; then
            if [[ "$want" == script-backed ]]; then stub_ok=yes; fi
        else
            if [[ "$want" == skill-backed ]]; then stub_ok=yes; fi
        fi
        if [[ "$hdr_ok" != yes || "$stub_ok" != yes ]]; then
            local ran=no
            if [[ "$out" == *STUB-RAN* ]]; then ran=yes; fi
            echo "MISMATCH $name: want $want; header '$hdr'; hdr-ok $hdr_ok; stub-ran $ran"
        fi
    done
}

@test "backing: every scripts/<step>.sh dispatches as spec 6.3 types it (#812)" {
    local n
    n="$(_canonical_steps | wc -l)"
    # A thinned template would make this test vacuous.
    [ "$n" -eq 24 ] || _die "expected 24 canonical steps, parsed $n"
    _stage_tree
    local res
    res="$(_backing_mismatches "$root")"
    local s
    for s in $SCRIPT_TYPED; do
        grep -qx "EXAMINED $s" <<<"$res" || _die "script-typed step '$s' not examined: $res"
    done
    # Floor: keeps the skill-backed-with-a-script branch non-empty. It pins the
    # collision's EXISTENCE — a later rename of spike.sh fails here; edit this
    # floor together with next.sh's STEP_NAMED_HELPERS.
    grep -qx "EXAMINED spike" <<<"$res" || _die "spike.sh not examined: $res"
    if grep -q '^MISMATCH' <<<"$res"; then
        _die "$res"
    fi
}

@test "backing: a helper planted under a step name is caught (#812)" {
    # Positive control for the detector: green on the unfixed and the fixed tree
    # alike, by design. impact is step 21; its §6.3 Type is `skill`.
    [ ! -e "$PLUGIN_ROOT/scripts/impact.sh" ] || _die "scripts/impact.sh exists; the plant is not a plant"
    _stage_tree
    _write_stub "$root/scripts/impact.sh"
    local res
    res="$(_backing_mismatches "$root")"
    [[ "$res" == *"MISMATCH impact: want skill-backed"* ]] || _die "planted collision not caught: $res"
}
