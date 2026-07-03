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
[ -n "$project" ] || die "analyze-sanitizers.sh: project required"
config_is_project "$project" || die "analyze-sanitizers.sh: unknown project '$project'"

issue_arg="${2:-}"
if [ -z "$issue_arg" ]; then
    # #240: mutating steps never act on a scan-GUESSED issue (the scan tier
    # can adopt a parked issue's checklist) — pin/state only, else die.
    # (stderr NOT suppressed: an invalid pin must die loudly here, F6.)
    active_resolve_issue_src "$project" || true
    if [ -z "$ACTIVE_RESOLVED_ISSUE" ] || [ "$ACTIVE_ISSUE_RESOLVED_FROM" = "scan" ]; then
        die "analyze-sanitizers.sh: no active issue and no issue arg"
    fi
    issue_arg="$ACTIVE_RESOLVED_ISSUE"
fi

issue_dir="$(issue_context_dir "$project" "$issue_arg" 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "analyze-sanitizers.sh: issue_dir not set or missing"

source_dir="$(config_get_project_field "$project" source_dir)"
[ -d "$source_dir" ] || die "analyze-sanitizers.sh: source_dir missing: $source_dir"

mkdir -p "$issue_dir/analysis"
date_tag="$(date +%Y-%m-%d)"

run_one() {
    local tag="$1" flag="$2"
    local out="$issue_dir/analysis/$date_tag-$tag.txt"
    local build="$source_dir/build-$tag"
    mkdir -p "$build"
    {
        echo "=== $tag ==="
        "$DEVAGENT_CMAKE" -S "$source_dir" -B "$build" \
            "-DCMAKE_BUILD_TYPE=Debug" \
            "-DCMAKE_C_FLAGS=-fsanitize=$flag" \
            "-DCMAKE_CXX_FLAGS=-fsanitize=$flag" 2>&1 || true
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
        "${launcher[@]}" "$DEVAGENT_CMAKE" --build "$build" 2>&1 || true
        set +e
        ( cd "$build" && "${launcher[@]}" "$DEVAGENT_CTEST" --output-on-failure )
        local rc=$?
        set -e
        echo "exit=$rc"
    } > "$out"
}

run_one asan  address
run_one ubsan undefined
run_one tsan  thread
