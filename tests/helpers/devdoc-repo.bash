# tests/helpers/devdoc-repo.bash — fixtures for the #749 devDoc repository
# discipline (owned-path commits, the repository lock, read-only git calls).
# Loaded by tests/cleanup.bats, tests/promote-potholes.bats,
# tests/statusreport.bats, tests/devdoc-lock.bats and
# tests/cleanup-concurrency.bats, after helpers/common.
# shellcheck disable=SC2034  # variables are read by the bats files that load this helper
# #338: every loaded setup layer sources the hermetic-env guard (pins / git config / TZ / locale).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/hermetic-env.bash"

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
#   <holder pid> <holder issue> <holder cmd> <DEVAGENT_DEVDOC_LOCK_TOKEN or ->
# The toplevel is the repository the call ran in (cwd, or the -C target), so a
# test can keep only the devDoc repository's rows. The holder columns are the
# #749 lock record of that repository at the time of the call (via the real
# git), `-` when the lock is free.
devdoc_git_logging_wrapper() {
    _devdoc_git_wrapper "$1" "" "$DEVAGENT_TMP/git-logging"
}

# devdoc_git_gate_wrapper <dir> — the logging wrapper (log: <dir>/git.log,
# script: <dir>/git; prints the script path) that also OBEYS control files in
# <dir> at every `commit` inside a repository — one <dir> per cleanup run:
#   pause       touch <dir>/in-commit, then wait (<= 60 s) for <dir>/gate
#   index-lock  create .git/index.lock before the first commit (a foreign
#               writer's lock: the commit fails)
#   ro-state    after the real commit, chmod a-w the devagent state dir (the
#               test restores it)
#   snap-state  copy the state dir to <dir>/state-snap before the commit
devdoc_git_gate_wrapper() {
    mkdir -p "$1"
    _devdoc_git_wrapper "$1/git.log" "$1" "$1/git"
}

_devdoc_git_wrapper() {
    local log="$1" ctl="$2" w="$3"
    cat > "$w" <<EOF
#!/usr/bin/env bash
log='$log'
ctl='$ctl'
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
idx="" holder=""
if [ -n "$top" ]; then
    idx="$(GIT_OPTIONAL_LOCKS=0 git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)/index"
    common="$(cd "$dir" && c="$(GIT_OPTIONAL_LOCKS=0 git rev-parse --git-common-dir 2>/dev/null)" && cd "$c" && pwd -P)"
    holder="$common/devagent-devdoc.lock/holder"
fi
_mt() { [ -n "$1" ] && python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$1" 2>/dev/null || echo none; }
_hf() { local v=""; [ -n "$holder" ] && v="$(sed -n "s/^$1=//p" "$holder" 2>/dev/null)"; printf '%s' "${v:--}"; }
before="$(_mt "$idx")"
h_pid="$(_hf pid)" h_issue="$(_hf issue)" h_cmd="$(_hf cmd)"
if [ -n "$ctl" ] && [ "$sub" = commit ] && [ -n "$top" ]; then
    if [ -e "$ctl/index-lock" ] && [ ! -e "$ctl/index-lock.done" ]; then
        : > "${idx}.lock"; : > "$ctl/index-lock.done"
    fi
    if [ -e "$ctl/snap-state" ]; then
        rm -rf "$ctl/state-snap"; cp -r "$HOME/.claude/devagent/state" "$ctl/state-snap"
    fi
    if [ -e "$ctl/pause" ]; then
        : > "$ctl/in-commit"
        n=0; until [ -e "$ctl/gate" ] || [ "$n" -ge 600 ]; do sleep 0.1; n=$((n + 1)); done
    fi
fi
git "$@"; rc=$?
if [ -n "$ctl" ] && [ "$sub" = commit ] && [ -n "$top" ] && [ "$rc" -eq 0 ] && [ -e "$ctl/ro-state" ]; then
    chmod a-w "$HOME/.claude/devagent/state"
fi
after="$(_mt "$idx")"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sub" "${GIT_OPTIONAL_LOCKS:--}" "$before" "$after" "${top:--}" \
    "$h_pid" "$h_issue" "$h_cmd" "${DEVAGENT_DEVDOC_LOCK_TOKEN:--}" >> "$log"
exit "$rc"
EOF
    chmod +x "$w"
    printf '%s\n' "$w"
}

# devdoc_assert_status_rows_readonly <log> <repo> — every `status` row the
# wrapper logged for <repo> ran with GIT_OPTIONAL_LOCKS=0 and left the index
# mtime unchanged; at least one such row exists (an absent call is not a pass).
devdoc_assert_status_rows_readonly() {
    local log="$1" repo n=0 sub ol b a top _rest
    repo="$(cd "$2" && pwd -P)"
    while IFS=$'\t' read -r sub ol b a top _rest; do
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

# two_project_devdoc_fixture — after devagent_test_setup: two projects, projA
# and projB, each with its own source repo (on feat/1-x, a local main to
# restore to) and a closable Issue-1 (every row [x] but cleanup, a clean
# lessons file) under ONE devDoc repository at $DEVAGENT_TMP/devdoc. Each
# devdoc_dir holds a WBS.md whose Issue-1 leaf is [~]; a stub tracker reports
# issue 1 done, so each cleanup's reconcile flips its own leaf. Replaces the
# testproj config.
two_project_devdoc_fixture() {
    DEVDOC_REPO="$DEVAGENT_TMP/devdoc"
    local cfg="$HOME/.claude/devagent/config.toml" p src doc
    printf '[defaults]\nchecklist_template = "standard"\n' > "$cfg"
    for p in projA projB; do
        src="$DEVAGENT_TMP/src/$p"; doc="$DEVDOC_REPO/$p"
        mkdir -p "$src" "$doc/Issue-1"
        ( cd "$src" && git -c init.defaultBranch=main init -q && git config user.email t@example.com \
          && git config user.name Tester && touch README.md && git add README.md && git commit -q -m init \
          && git checkout -q -b feat/1-x )
        cat >> "$cfg" <<EOF

[project.$p]
source_dir       = "$src"
devdoc_dir       = "$doc"
default_baseline = "origin/main"

[project.$p.permissions]
commit_devdoc = true

[project.$p.issue_source]
backend    = "github"
repo       = "acme/$p"
dir_prefix = "Issue-"
EOF
        printf 'active_issue = "Issue-1"\nissue_dir = "%s"\nbranch = "feat/1-x"\n\n[parked]\n' "$doc/Issue-1" \
            > "$HOME/.claude/devagent/state/$p.toml"
        sed -e 's/^- \[ \]/- [x]/' -e 's/^- \[x\]\( *23\. cleanup\)/- [ ]\1/' \
            "$DEVDOC_DIR/Issue-1/checklist.md" > "$doc/Issue-1/checklist.md"
        seed_lessons_learned "$doc/Issue-1"
        printf '%s\n' "# $p WBS" '' '- [ ] Plan {est: 1w}' '  - [~] Working leaf {issue: Issue-1, est: 1w}' > "$doc/WBS.md"
    done
    rm -rf "$DEVDOC_DIR"
    ( cd "$DEVDOC_REPO" && git -c init.defaultBranch=main init -q && git config user.email t@example.com \
      && git config user.name Test && git add -A && git commit -q -m seed )
    . "$(dirname "${BASH_SOURCE[0]}")/wbs-tracker.bash"
    export WBS_STUB_ROOT="$DEVAGENT_TMP"
    export DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_TMP/backends"
    wbs_tracker_install_stub "$DEVAGENT_ISSUE_BACKEND_DIR"
    printf '1\tdone\n' > "$DEVAGENT_TMP/state-list.github"
    # a github source is looked up only with `gh` on PATH; the shim logs and
    # fails, so a real backend call is caught instead of reaching the network
    wbs_tracker_install_shims "$DEVAGENT_TMP/shims" "$DEVAGENT_TMP/network.log"
    export PATH="$DEVAGENT_TMP/shims:$PATH"
    unset DEVAGENT_ACTIVE_PROJECT DEVAGENT_ACTIVE_ISSUE
}
