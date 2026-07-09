#!/usr/bin/env bash
# scripts/analyze-sanitizers.sh — run ASan, UBSan, TSan in separate build dirs.
# Per spec §18: no sub-step tracking. analyze.sh (Task 10) sequences this and
# writes the step-11 checklist mark.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/active.sh"

: "${DEVAGENT_CMAKE:=cmake}"
: "${DEVAGENT_CTEST:=ctest}"

project="${1:-}"
[ -n "$project" ] || die "project required"
config_is_project "$project" || die "unknown project '$project'"

issue_arg="${2:-}"
if [ -z "$issue_arg" ]; then
    # #240: mutating steps never act on a scan-GUESSED issue (the scan tier
    # can adopt a parked issue's checklist) — pin/state only, else die.
    # (stderr NOT suppressed: an invalid pin must die loudly here, F6.)
    active_resolve_issue_src "$project" || true
    if [ -z "$ACTIVE_RESOLVED_ISSUE" ] || [ "$ACTIVE_ISSUE_RESOLVED_FROM" = "scan" ]; then
        die "no active issue and no issue arg"
    fi
    issue_arg="$ACTIVE_RESOLVED_ISSUE"
fi

issue_dir="$(issue_context_dir "$project" "$issue_arg" 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "issue_dir not set or missing"

source_dir="$(config_get_project_field "$project" source_dir)"
[ -d "$source_dir" ] || die "source_dir missing: $source_dir"

# #117: non-CMake source loud-skips the sanitizer legs. A project under the
# default `analyze = "cmake"` knob with no CMakeLists.txt is a misconfiguration
# (post-#55, non-C projects set analyze = "none"/"shellcheck"). Hard-dying on
# the default knob would be hostile to a fresh project's first analyze, so the
# path stays non-fatal — but NOT silent: warn (the vacuous-pass class this
# issue exists to kill) and name the fix. exit 0 lets analyze.sh mark step 11
# [x], mirroring the analyze-static.sh:48 guard.
if [ ! -f "$source_dir/CMakeLists.txt" ]; then
    warn "no CMakeLists.txt in $source_dir — skipping sanitizer legs (not a CMake project; set analyze = \"none\" or \"shellcheck\" per #55 so step 11 is meaningful)"
    exit 0
fi

mkdir -p "$issue_dir/analysis"
date_tag="$(date +%Y-%m-%d)"

# #117: each failing leg records "<tag> (<phase> exit=<rc>) → <artifact>" here;
# after all three legs run, a non-empty list fails step 11 loud (see below).
declare -a fail_summaries=()

run_one() {
    local tag="$1" flag="$2"
    local out="$issue_dir/analysis/$date_tag-$tag.txt"
    local build="$source_dir/build-$tag"
    mkdir -p "$build"
    # #117: per-phase rc capture with intra-leg short-circuit — a failed
    # configure skips build+ctest for THIS leg; a failed build skips ctest.
    # The artifact records the skip so a later reader is not left with a
    # fabricated exit=0. All three legs still run (aggregate evidence).
    local conf_rc=0 build_rc=0 test_rc=0 ran_ctest=0
    {
        echo "=== $tag ==="
        "$DEVAGENT_CMAKE" -S "$source_dir" -B "$build" \
            "-DCMAKE_BUILD_TYPE=Debug" \
            "-DCMAKE_C_FLAGS=-fsanitize=$flag" \
            "-DCMAKE_CXX_FLAGS=-fsanitize=$flag" 2>&1 || conf_rc=$?
        if [ "$conf_rc" -ne 0 ]; then
            echo "build skipped: configure failed (exit=$conf_rc)"
            echo "ctest skipped: configure failed (exit=$conf_rc)"
        else
            # ASLR + TSan are incompatible on Ubuntu 24.04+ (kernel changed
            # mmap layout, TSan's shadow-memory mapping fails at process
            # startup). Disable ASLR for the TSan tag only; ASan/UBSan are
            # unaffected. Long form matches static_analysis_diff.py (run_tsan /
            # _build_sanitizer setarch launcher) for
            # portability across older util-linux versions (RHEL/CentOS).
            # Built BEFORE the build step: gtest_discover_tests execs the freshly
            # linked test binary at BUILD time, so TSan needs ASLR off there too —
            # else that target's discovery FATALs and it silently drops out of the
            # ctest run while the log still says "100% passed" (#32, residual of #1
            # which only wrapped the ctest run).
            local -a launcher=()
            if [ "$tag" = "tsan" ] && command -v setarch >/dev/null 2>&1; then
                launcher=(setarch "$(uname -m)" --addr-no-randomize)
            fi
            "${launcher[@]}" "$DEVAGENT_CMAKE" --build "$build" 2>&1 || build_rc=$?
            if [ "$build_rc" -ne 0 ]; then
                echo "ctest skipped: build failed (exit=$build_rc)"
            else
                set +e
                ( cd "$build" && "${launcher[@]}" "$DEVAGENT_CTEST" --output-on-failure )
                test_rc=$?
                set -e
                ran_ctest=1
                echo "exit=$test_rc"
            fi
        fi
    } > "$out"
    # Aggregate the leg's failure (first failing phase wins the summary).
    if [ "$conf_rc" -ne 0 ]; then
        fail_summaries+=("$tag (configure exit=$conf_rc) → $out")
    elif [ "$build_rc" -ne 0 ]; then
        fail_summaries+=("$tag (build exit=$build_rc) → $out")
    elif [ "$ran_ctest" -eq 1 ] && [ "$test_rc" -ne 0 ]; then
        fail_summaries+=("$tag (ctest exit=$test_rc) → $out")
    fi
    # Explicit success return (belt-and-suspenders): the if/elif/fi above
    # already returns 0 on every path (no-branch-taken → 0; each taken branch
    # ends in a 0-returning array append), so this is NOT test-pinned — it
    # guards a future refactor that appends a trailing test/&&-chain (whose
    # false result would otherwise abort the leg sequence under set -e).
    return 0
}

run_one asan  address
run_one ubsan undefined
run_one tsan  thread

# #117: fail step 11 loud when any leg failed. die (lib/io.sh) exits 1 → under
# analyze.sh's `set -e` the state write / step-11 mark / log never run (step
# stays [ ]), and next.sh's `set -e` halts an --auto chain. The message names
# every failing leg, its failing phase, and the artifact to read.
if [ "${#fail_summaries[@]}" -gt 0 ]; then
    joined="$(printf '%s; ' "${fail_summaries[@]}")"
    die "sanitizer leg(s) FAILED: ${joined%; }"
fi
