# tests/helpers/devdoc-repo.bash — fixtures for the #749 devDoc repository
# discipline (owned-path commits, the repository lock, read-only git calls).
# Loaded by tests/cleanup.bats, tests/promote-potholes.bats,
# tests/statusreport.bats, tests/devdoc-lock.bats and
# tests/cleanup-concurrency.bats, after helpers/common.
# shellcheck disable=SC2034  # variables are read by the bats files that load this helper

# devdoc_parent_repo_fixture — re-init the devDoc repository one level ABOVE
# devdoc_dir ($DEVAGENT_TMP/devdoc), the production shape where every project's
# devdoc_dir is a subdirectory (as cleanup.bats' #611 repo-root test). Seeds a
# second issue of this project (testproj/Issue-2) and another project's issue
# (proj2/Issue-9) before the seed commit, so a test can dirty paths cleanup
# does not own.
devdoc_parent_repo_fixture() {
    DEVDOC_REPO="$DEVAGENT_TMP/devdoc"
    rm -rf "$DEVDOC_DIR/.git"
    mkdir -p "$DEVDOC_DIR/Issue-2" "$DEVDOC_REPO/proj2/Issue-9"
    printf '# Issue-2 checklist\n' > "$DEVDOC_DIR/Issue-2/checklist.md"
    printf '# Issue-9 checklist\n' > "$DEVDOC_REPO/proj2/Issue-9/checklist.md"
    ( cd "$DEVDOC_REPO" && git -c init.defaultBranch=main init -q \
      && git config user.email t@example.com && git config user.name Test \
      && git add -A && git commit -q -m seed )
}

# devdoc_lock_test_path <devdoc_dir> — where the #749 repository lock for
# <devdoc_dir> lives, computed independently of the library under test: the
# git common dir's devagent-devdoc.lock, or the side lock outside git.
devdoc_lock_test_path() {
    local d="$1" c
    if c="$(cd "$d" && git rev-parse --git-common-dir 2>/dev/null)" && [ -n "$c" ]; then
        printf '%s/devagent-devdoc.lock\n' "$(cd "$d" && cd "$c" && pwd -P)"
    else
        printf '%s/.devagent-wbs.lock\n' "$(cd "$d" && pwd -P)"
    fi
}

# devdoc_lock_stub_holder <devdoc_dir> <issue> — take the lock as a FOREIGN
# holder (another session): the lock dir plus a holder record whose pid/host
# are not ours. Prints the lock path.
devdoc_lock_stub_holder() {
    local p
    p="$(devdoc_lock_test_path "$1")"
    mkdir "$p"
    printf '%s\n' 'token=4242.1700000000.7' 'pid=4242' 'host=otherhost' "issue=$2" \
        'start=2026-11-01T10:00:00Z' 'cmd=cleanup.sh' > "$p/holder"
    printf '%s\n' "$p"
}

# devdoc_git_logging_wrapper <log> — write an executable DEVAGENT_GIT stand-in
# to $DEVAGENT_TMP/git-logging and print its path. Every call runs the real git
# and appends one TAB-separated row to <log>:
#   <subcommand> <GIT_OPTIONAL_LOCKS or -> <index mtime_ns before> <after> <repo toplevel or ->
# The toplevel is the repository the call ran in (cwd, or the -C target), so a
# test can keep only the devDoc repository's rows.
devdoc_git_logging_wrapper() {
    local log="$1" w="$DEVAGENT_TMP/git-logging"
    cat > "$w" <<EOF
#!/usr/bin/env bash
log='$log'
EOF
    cat >> "$w" <<'EOF'
dir="$PWD"; sub=""; i=1
while [ "$i" -le "$#" ]; do
    a="${!i}"
    case "$a" in
        -C) i=$((i + 1)); t="${!i}"; case "$t" in /*) dir="$t" ;; *) dir="$dir/$t" ;; esac ;;
        -c) i=$((i + 1)) ;;
        -*) ;;
        *) sub="$a"; break ;;
    esac
    i=$((i + 1))
done
top="$(GIT_OPTIONAL_LOCKS=0 git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || top=""
idx=""
if [ -n "$top" ]; then
    idx="$(GIT_OPTIONAL_LOCKS=0 git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)/index"
fi
_mt() { [ -n "$1" ] && python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$1" 2>/dev/null || echo none; }
before="$(_mt "$idx")"
git "$@"; rc=$?
after="$(_mt "$idx")"
printf '%s\t%s\t%s\t%s\t%s\n' "$sub" "${GIT_OPTIONAL_LOCKS:--}" "$before" "$after" "${top:--}" >> "$log"
exit "$rc"
EOF
    chmod +x "$w"
    printf '%s\n' "$w"
}

# devdoc_assert_status_rows_readonly <log> <repo> — every `status` row the
# wrapper logged for <repo> ran with GIT_OPTIONAL_LOCKS=0 and left the index
# mtime unchanged; at least one such row exists (an absent call is not a pass).
devdoc_assert_status_rows_readonly() {
    local log="$1" repo n=0 sub ol b a top
    repo="$(cd "$2" && pwd -P)"
    while IFS=$'\t' read -r sub ol b a top; do
        [ "$sub" = status ] || continue
        [ "$(cd "$top" 2>/dev/null && pwd -P)" = "$repo" ] || continue
        n=$((n + 1))
        if [ "$ol" != 0 ] || [ "$b" != "$a" ]; then
            echo "status row not read-only: GIT_OPTIONAL_LOCKS=$ol index mtime $b -> $a" >&2
            return 1
        fi
    done < "$log"
    [ "$n" -ge 1 ] || { echo "no status row logged for $repo" >&2; return 1; }
}
