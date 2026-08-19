#!/usr/bin/env bash
# scripts/run-suite.sh — mechanism 2/3 (#359; design: Issue-333/designs/
# m2m3-preship-evidence.md, normative). The canonical suite runner + provenance
# artifact. Runs bats + pytest (per tree presence) with the hermetic env-unset
# baked in, and writes <issue-dir>/analysis/<date>-suite-count.txt:
#     head: <sha>  dirty: yes|no
#     tree: <canonical path of the measured checkout>
#     bats: <ok>/<plan> notok=<n>
#     pytest: <passed> passed, <failed> failed
#     suite_env: <NAMES…> | (none)
# The optional [project.<name>.suite_env] config table (#603) is exported into
# both suite child processes — for a project whose tests need environment that
# is not derivable from the tree (lawFirm's LAWFIRM_DATA_ROOT, whose data layer
# lives outside git by design). Declaring it in config rather than inheriting it
# from the invoking shell is what keeps the artifact a function of the TREE and
# not of the operator's session (#458).
# The MEASURED TREE is state.worktree_path when recorded, else source_dir — the
# commit.sh/ship.sh rule, via active_tree_resolve (#571). Invoking from another
# checkout of the SAME project (a linked worktree, or a clone with the same
# origin) REFUSES via active_guard_tree rather than silently measuring the
# configured tree; a mid-run HEAD move also refuses, so the head: stamp always
# names the tree the suites actually ran against.
# Counts come from `grep -c '^ok '` + the `1..N` plan line — NEVER the tail (#85
# shipped a tail-derived false count). preship-evidence.sh cross-checks mr.md
# against this artifact (verification #4).
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
# shellcheck source=lib/utf8-locale.sh
. "$DEVAGENT_ROOT/scripts/lib/utf8-locale.sh"
# shellcheck source=lib/secrets.sh
. "$DEVAGENT_ROOT/scripts/lib/secrets.sh"

: "${DEVAGENT_GIT:=git}"

active_resolve_project_try "${1:-}" 2>/dev/null || true
project="$ACTIVE_RESOLVED_PROJECT"
[ -n "$project" ] || die "run-suite: project required (no arg and no active project)"
config_is_project "$project" || die "run-suite: unknown project '$project'"
active_guard_scope run-suite
issue_dir="$(issue_context_dir "$project" 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "run-suite: issue_dir not set or missing"
active_tree_resolve "$project"            # setter-globals; never $( … )  (#282/#120)
active_guard_tree run-suite               # #571: strictly AFTER active_guard_scope
work_dir="$ACTIVE_TREE_DIR"

# #603: resolve the optional [project.<name>.suite_env] table BEFORE running
# anything, so a malformed declaration dies before a suite burns minutes and
# before any artifact exists to be half-written. Setter-globals; never $( … ).
config_suite_env_resolve "$project"

cd "$work_dir"

# #565: refuse to manufacture an evidence artifact from a filesystem where
# chmod is a no-op. A suite that asserts file modes fails wholesale on such a
# mount (here, the auth/secrets tests), so the artifact would record a red suite
# that says nothing about the branch — and preship-evidence.sh consumes it as
# authority. posix_modes_representable is the repo's existing probe for this
# (#289); it is checked on BOTH the measured tree and TMPDIR, because tests
# create their fixtures in the latter. Fires only where there is actually a
# suite to run: run-suite.sh serves every configured project, and a tests-less
# tree legitimately records (none)/(none). Deliberately conservative — it
# cannot tell whether a given project's tests assert modes without running them.
if compgen -G "tests/*.bats" >/dev/null 2>&1 || compgen -G "tests/test_*.py" >/dev/null 2>&1; then
  # Residual, deliberate: posix_modes_representable is FAIL-OPEN on an
  # unprobeable dir (mktemp/chmod/stat failure) because its original caller is
  # an audit that must still run. For this gate that direction is inverted, so a
  # mount where chmod ERRORS (rather than no-ops) is not caught here. The noacl
  # case this exists for IS caught, because there chmod succeeds and lies.
  for _fs_dir in "$work_dir" "${TMPDIR:-/tmp}"; do
    posix_modes_representable "$_fs_dir" \
      || die "run-suite: chmod is a NO-OP under '$_fs_dir' — a suite that asserts file modes cannot pass on this filesystem, so any artifact written here would be false evidence (#565). Run the suite on a native POSIX filesystem; on Windows that means a WSL clone on ext4 with its own ~/.claude/devagent/config.toml, not a /mnt/c checkout or native Git Bash. See README 'Running the test suite'."
  done
fi

head="$("$DEVAGENT_GIT" rev-parse HEAD 2>/dev/null || true)"
[ -n "$head" ] || die "run-suite: could not resolve HEAD in $work_dir"
if [ -n "$("$DEVAGENT_GIT" status --porcelain 2>/dev/null)" ]; then dirty=yes; else dirty=no; fi

bats_line="bats: (none)"
if compgen -G "tests/*.bats" >/dev/null 2>&1; then
  # #565: bats registers @test names in a CHILD process that inherits this
  # environment; without a UTF-8 locale a non-ASCII name can be silently skipped
  # while still counted in the 1..N plan, so the artifact would be thinner than
  # its own plan. See README "Running the test suite" for the mechanism.
  utf8_locale_resolve \
    || die "run-suite: no UTF-8-capable locale found (tried \$LC_ALL, \$LC_CTYPE, \$LANG, then C.UTF-8/en_US.UTF-8/C.utf8/en_US.utf8) — bats would silently skip @test names containing non-ASCII characters (#565). Install a UTF-8 locale or export LC_ALL to one."
  tap="$(env -u DEVAGENT_ACTIVE_PROJECT -u DEVAGENT_ACTIVE_ISSUE \
           "${SUITE_ENV_ASSIGNMENTS[@]+"${SUITE_ENV_ASSIGNMENTS[@]}"}" \
           LC_ALL="$UTF8_LOCALE" LANG="$UTF8_LOCALE" bats --tap tests/ 2>&1 || true)"
  ok="$(printf '%s\n' "$tap"    | grep -c '^ok '     || true)"
  notok="$(printf '%s\n' "$tap" | grep -c '^not ok ' || true)"
  plan="$(printf '%s\n' "$tap"  | sed -n 's/^1\.\.\([0-9][0-9]*\)$/\1/p' | tail -1)"
  [ -n "$plan" ] || die "run-suite: no bats plan line (1..N) — bats did not run cleanly"
  # #406: bats --tap emits the plan (1..N) up front, so a killed/crashed run leaves
  # ok+notok < plan while still looking well-formed. Recording ok/plan without this
  # invariant lets a truncated run pass as "green" (the #85 never-trust-the-tail
  # class, one layer up). Fail loud — a truncated suite must not ship evidence.
  [ "$((ok + notok))" -eq "$plan" ] \
    || die "run-suite: suite truncated — accounted for $((ok + notok)) of $plan planned tests (ok=$ok notok=$notok); a killed/crashed bats run leaves ok+notok<plan"
  bats_line="bats: $ok/$plan notok=$notok"
fi

pytest_line="pytest: (none)"
if compgen -G "tests/test_*.py" >/dev/null 2>&1; then
  pout="$(env -u DEVAGENT_ACTIVE_PROJECT -u DEVAGENT_ACTIVE_ISSUE \
            "${SUITE_ENV_ASSIGNMENTS[@]+"${SUITE_ENV_ASSIGNMENTS[@]}"}" \
            python3 -m pytest tests/ -q 2>&1 || true)"
  # `grep -oE '[0-9]+ passed'` matches the count wherever it sits — including at
  # column 0, which pytest -q's summary ("285 passed, 9 skipped in Xs") always
  # is. The prior sed required a non-digit BEFORE the digits and so recorded 0
  # for every line-start summary. `tail -1` here is the summary line (pytest
  # prints it last) — NOT the header's forbidden tail-derived count (#85), which
  # is about the bats `1..N`/`^ok ` counting, a different mechanism.
  # `|| true`: a green run has no "failed" line, so `grep` exits 1 — which under
  # this script's `set -euo pipefail` would kill run-suite mid-way. No match just
  # means a zero count, defaulted below.
  passed="$(printf '%s\n' "$pout" | grep -oE '[0-9]+ passed' | tail -1 | grep -oE '[0-9]+' || true)"
  failed="$(printf '%s\n' "$pout" | grep -oE '[0-9]+ failed' | tail -1 | grep -oE '[0-9]+' || true)"
  if [ -z "$passed" ] && [ -z "$failed" ]; then
    # pytest emitted no count at all: it never ran (missing interpreter — e.g.
    # a Windows Store python3 shim — or a collection error) or collected
    # nothing. tests/test_*.py existing does NOT mean pytest can run them
    # (standalone-script suites). Recording "0 passed, 0 failed" here is a
    # false green — it reads "ran clean" for a suite that was never measured —
    # and it also breaks preship-evidence's no-framework reconciliation
    # (`none @ <sha>`), which requires the explicit `pytest: (none)` form.
    pytest_line="pytest: (none)"
  else
    pytest_line="pytest: ${passed:-0} passed, ${failed:-0} failed"
  fi
fi

# #571 AC2: the stamp at the top and the suites below are two reads of one tree. If
# HEAD moved between them, no single SHA describes what was executed — refuse rather
# than record a HEAD the suite never ran against. Residual window (register Issue-558):
# the microseconds between this check and the write below; `dirty` is still the
# PRE-run reading, deliberately — re-deriving it here would false-fire on any run
# that leaves untracked build output.
head_after="$("$DEVAGENT_GIT" rev-parse HEAD 2>/dev/null || true)"
[ "$head_after" = "$head" ] \
  || die "run-suite: HEAD MOVED mid-run in $work_dir ($head -> ${head_after:-<unresolvable>}) — the suite did not execute against one tree; no artifact written. Re-run at a stable HEAD."

date_str="$(date_tag)"   # #413: honor the #338 DEVAGENT_DATE_OVERRIDE freeze seam
mkdir -p "$issue_dir/analysis"
artifact="$issue_dir/analysis/${date_str}-suite-count.txt"
# #571: tree: is an IDENTITY, not a display string — canonicalized (pwd -P) so the
# stamp survives symlink/case spelling variance; cwd has been $work_dir since the
# cd above. Inserted AFTER head:, so the SHA stays the artifact's first data line
# and no prefix-anchored consumer moves.
tree_canon="$(pwd -P)"
# #603: NAMES ONLY, never values — a declared variable may legitimately hold a
# token, and this artifact is quoted into MR bodies. Recording the names is what
# lets a later reader tell a data-root-fed run from a bare one; without it, a red
# artifact and a green one are indistinguishable on their face (register
# Issue-106: an artifact pinned to a gitignored, mutable input needs a provenance
# block INSIDE the artifact). Appended LAST so every prefix-anchored consumer of
# head:/tree:/bats:/pytest: is unmoved.
if [ "${#SUITE_ENV_NAMES[@]}" -eq 0 ]; then
  suite_env_line="suite_env: (none)"
else
  suite_env_line="suite_env: ${SUITE_ENV_NAMES[*]}"
fi
{
  echo "head: $head  dirty: $dirty"
  echo "tree: $tree_canon"
  echo "$bats_line"
  echo "$pytest_line"
  echo "$suite_env_line"
} > "$artifact"
echo "run-suite: wrote $artifact ($bats_line; $pytest_line; dirty=$dirty; tree=$tree_canon)" >&2
