#!/usr/bin/env bash
# scripts/run-suite.sh — mechanism 2/3 (#359; design: Issue-333/designs/
# m2m3-preship-evidence.md, normative). The canonical suite runner + provenance
# artifact. Runs bats + pytest (per tree presence) with the hermetic env-unset
# baked in, and writes <issue-dir>/analysis/<date>-suite-count.txt:
#     head: <sha>  dirty: yes|no
#     tree: <canonical path of the measured checkout>
#     bats: <ok>/<plan> notok=<n>
#     pytest: <passed> passed, <failed> failed, <errors> errors | (none) | (error)
#     python: <interpreter that ran pytest> | (none)
#     suite_env: <NAMES…> | (none)
# On the framework lines, `(none)` means the framework is ABSENT from the measured tree
# and `(error)` means its tests exist but could not be RUN (a suite that ran and had
# nothing to count — all skipped, or nothing collected — records a truthful 0/0); preship-evidence.sh treats
# those differently and refuses to ship on `(error)` (#466). bats has no `(error)` state
# by construction: a bats run with no `1..N` plan line dies below rather than reaching
# the artifact, so the asymmetry is deliberate.
# Producer rule, so the next framework added knows which arm it belongs in: DIE when the
# artifact would be FALSE (#565 chmod no-op, #406 truncation, a mid-run HEAD move);
# record `(error)` when it would be UNKNOWN. bats has no unknown state — a run with no
# plan line cannot reach the artifact — so its die is an INSTANCE of that rule, not an
# exemption from it.
# DEVAGENT_PYTEST_PYTHON overrides the interpreter search (see below).
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
# shellcheck source=lib/python-interp.sh
. "$DEVAGENT_ROOT/scripts/lib/python-interp.sh"

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
python_line="python: (none)"
# #466 (redmr): the presence probe must agree with the MEASUREMENT below, which runs
# `pytest tests/` and collects RECURSIVELY. A non-recursive glob called a project with
# tests/unit/test_*.py "absent", and since #466 makes presence load-bearing for the
# Evidence reconstruction, the whole suite then vanished from the green instead of
# merely showing as `, 0 pytest`. `(none)` must mean ABSENT, never NOT LOOKED FOR.
if [ -n "$(find tests -name 'test_*.py' -print -quit 2>/dev/null)" ]; then
  # #466: Python projects conventionally carry their interpreter in <tree>/.venv/, where
  # the AMBIENT python3 has no pytest — measuring a 51-test suite with system python3
  # recorded "0 passed" (factor-ai Issue-9). Prefer the tree's own venv: the artifact is
  # a function of the TREE wherever it can be — the venv normally IS part of the tree, so
  # preferring it removes the session dependence that ambient python3 introduced (#458).
  # It is not absolute: DEVAGENT_PYTEST_PYTHON and the fallback arm both admit an
  # interpreter from outside the measured tree, which is why the `python:` line below
  # records which one ran. cwd has been $work_dir since the cd above.
  # Only `.venv/` is honoured — the `venv/` spelling and Windows `.venv/Scripts/` are
  # deliberately out of scope, and a project using either is no longer SILENT: it lands
  # in the `(error)` arm below rather than recording a false zero.
  # Interpreter resolution lives in scripts/lib/python-interp.sh — born-red.sh invokes
  # pytest too and had the same defect, so the fact has ONE home (register Issue-82).
  # Setter-global; never $( … ). $work_dir is the measured tree; source_dir is the
  # fallback for a linked worktree, which an untracked venv never reaches.
  python_interp_resolve "$work_dir" "$(config_get_project_field "$project" source_dir 2>/dev/null || true)"
  py="$PYTHON_INTERP"
  # #466 (redmr): RESTORED after being pruned at step 6, on evidence the prune did not
  # have. Three things make it load-bearing rather than nice-to-have: (a) the artifact is
  # NO LONGER a function of the tree alone — DEVAGENT_PYTEST_PYTHON and the fallback arm
  # both let the interpreter come from outside the measured tree, so two operators at one
  # commit can produce different counts in otherwise byte-identical artifacts (register
  # Issue-106: an artifact pinned to a gitignored, mutable input needs a provenance block
  # INSIDE it); (b) an `(error)` artifact is undiagnosable without knowing WHICH
  # interpreter failed; (c) under the fallback arm the interpreter comes from source_dir
  # while head:/tree: stamp the worktree, and that divergence is exactly what #571's tree
  # guard exists to make visible. NAMES only, like suite_env: — never a value.
  python_line="python: $py"
  # Capture pytest's EXIT CODE. The first draft of the tri-state discriminated
  # "ran, nothing to count" from "could not run" by grepping the summary PROSE, and
  # redmr found that BLOCKING: pytest orders its summary `failed, passed, skipped,
  # deselected, xfailed, xpassed, error`, so `1 skipped, 1 error in 0.01s` matched a
  # `^[0-9]+ skipped` prefix and recorded a clean `0 passed, 0 failed` for a suite that
  # ERRORED — the exact false green this file exists to prevent. The same hand-written
  # category list omitted `xpassed`, so a healthy `1 xpassed` suite recorded (error).
  # Both faults are the same mistake: reading prose where an authoritative signal
  # exists. The exit code IS that signal (pytest documents 0/1/2/3/4/5).
  pout=""; prc=0
  pout="$(env -u DEVAGENT_ACTIVE_PROJECT -u DEVAGENT_ACTIVE_ISSUE \
            "${SUITE_ENV_ASSIGNMENTS[@]+"${SUITE_ENV_ASSIGNMENTS[@]}"}" \
            "$py" -m pytest tests/ -q 2>&1)" || prc=$?
  # `grep -oE '[0-9]+ passed'` matches the count wherever it sits — including at
  # column 0, which pytest -q's summary ("285 passed, 9 skipped in Xs") always
  # is. The prior sed required a non-digit BEFORE the digits and so recorded 0
  # for every line-start summary (#555). `tail -1` here is the summary line (pytest
  # prints it last) — NOT the header's forbidden tail-derived count (#85), which
  # is about the bats `1..N`/`^ok ` counting, a different mechanism.
  # `|| true`: a category absent from the summary makes grep exit 1, which under this
  # script's `set -euo pipefail` would kill run-suite. No match means a zero count.
  # ` passed` is matched with its leading space so `1 xpassed` is not read as `1 passed`.
  passed="$(printf '%s\n' "$pout" | grep -oE '(^| )[0-9]+ passed' | tail -1 | grep -oE '[0-9]+' || true)"
  failed="$(printf '%s\n' "$pout" | grep -oE '(^| )[0-9]+ failed' | tail -1 | grep -oE '[0-9]+' || true)"
  # #466 (redmr): pytest ERRORS were invisible to the whole evidence chain — they are
  # not "failed", so `2 passed, 1 error` recorded `0 failed` and shipped green. bats has
  # had the equivalent invariant since #406 (ok+notok == plan); pytest had none.
  errors="$(printf '%s\n' "$pout" | grep -oE '(^| )[0-9]+ errors?' | tail -1 | grep -oE '[0-9]+' || true)"
  # MEASURED vs COULD-NOT-RUN, from the exit code:
  #   0  all collected tests passed — including the all-skipped and all-xpassed suites,
  #      which are measurements OF ZERO and must stay shippable (the point of the
  #      original MAJOR-1 fix).
  #   5  no tests collected — also a measurement of zero (a standalone-script suite).
  #   1  AMBIGUOUS: "tests failed" and "python3 -m pytest with no pytest module" BOTH
  #      exit 1. Discriminate on whether any count was actually parsed — a real run
  #      always reports at least one category; a missing module reports none.
  #   2,3,4,127,… interrupted / internal error / usage error / no interpreter: nothing
  #      was measured.
  if [ "$prc" -eq 0 ] || [ "$prc" -eq 5 ] \
     || { [ "$prc" -eq 1 ] && [ -n "${passed}${failed}${errors}" ]; }; then
    pytest_line="pytest: ${passed:-0} passed, ${failed:-0} failed, ${errors:-0} errors"
  else
    # Nothing was measured. This is a DIFFERENT FACT from "this project has no pytest
    # suite" — the two must not share one token, because preship-evidence reconstructs
    # the Evidence line from framework PRESENCE and would read a shared `(none)` as
    # "no pytest here", dropping the unmeasured suite out of the green entirely. An
    # absent-vs-can't-determine ambiguity fails CLOSED (register Issue-243). Recording
    # "0 passed, 0 failed" here is the other false green, and it is what
    # factorAI/Issue-85 and koopmanGNN/Issue-106 shipped.
    pytest_line="pytest: (error)"
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
  echo "$python_line"
  echo "$suite_env_line"
} > "$artifact"
echo "run-suite: wrote $artifact ($bats_line; $pytest_line; dirty=$dirty; tree=$tree_canon)" >&2
