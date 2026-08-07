#!/usr/bin/env bash
# scripts/preship-evidence.sh — mechanism 2/3 (#359; design: Issue-333/designs/
# m2m3-preship-evidence.md, normative). core-preship's verification #4: cross-check
# mr.md's ## Evidence block against the generated suite-count artifact + git, so a
# hand-written wrong number (#120/#85/#284) or an mr.md stale against post-draftmr
# fixes can't ship. Back-compat: mr.md WITHOUT an Evidence block → single WARN,
# rc 0 (the #149 absent⇒no-gate pattern — old issues stay shippable). Block present
# → every check hard-dies. Any git/parse failure dies loud (#117/#314 — never
# "0 checked"); no prompts (safe under --auto).
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

: "${DEVAGENT_GIT:=git}"

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

# Back-compat: no ## Evidence block ⇒ WARN + rc 0 (#149).
if ! grep -q '^## Evidence' "$mr"; then
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
[ -n "$artifact" ] || die "preship-evidence: no suite-count artifact — run \`bash \"\$CLAUDE_PLUGIN_ROOT/scripts/run-suite.sh\"\` at HEAD"

a_head="$(sed -n 's/^head:[[:space:]]*\([^ ]*\).*/\1/p' "$artifact" | head -1)"
a_dirty="$(sed -n 's/^head:.*dirty:[[:space:]]*\([a-z]*\).*/\1/p' "$artifact" | head -1)"
a_ok="$(sed -n 's/^bats:[[:space:]]*\([0-9][0-9]*\)\/.*/\1/p' "$artifact" | head -1)"
a_plan="$(sed -n 's/^bats:[[:space:]]*[0-9][0-9]*\/\([0-9][0-9]*\).*/\1/p' "$artifact" | head -1)"
a_notok="$(sed -n 's/^bats:.*notok=\([0-9][0-9]*\).*/\1/p' "$artifact" | head -1)"
a_passed="$(sed -n 's/^pytest:[[:space:]]*\([0-9][0-9]*\) passed.*/\1/p' "$artifact" | head -1)"
a_failed="$(sed -n 's/^pytest:.*[^0-9]\([0-9][0-9]*\) failed.*/\1/p' "$artifact" | head -1)"

cur_head="$("$DEVAGENT_GIT" -C "$(config_get_project_field "$project" source_dir)" rev-parse HEAD 2>/dev/null || true)"
[ -n "$cur_head" ] || die "preship-evidence: could not resolve current HEAD"

fails=()
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

# Reconstruct the canonical suite line from the artifact and compare (exact).
# #411: a project with NEITHER framework yields `bats: (none)` + `pytest: (none)`.
# Reconstruct the explicit no-framework form `none @ <sha>` instead of a nonsensical
# `/ bats, 0 pytest @ <sha>` that could never reconcile — so a ctest-only / non-bats
# project (e.g. volk) preships end-to-end without hand-deleting the Evidence lines.
# Framework projects keep the exact reconstruction, so their artifacts and Evidence
# are byte-identical to today.
if grep -q '^bats: (none)$' "$artifact" && grep -q '^pytest: (none)$' "$artifact"; then
  expected_suite="none @ $a_head"
else
  expected_suite="$a_ok/$a_plan bats, ${a_passed:-0} pytest @ $a_head"
fi
[ "$ev_suite" = "$expected_suite" ] \
  || fails+=("Evidence suite line mismatch: mr.md='$ev_suite' vs artifact='$expected_suite'")

# files: == diff of baseline..HEAD (baseline from state — die loud when unset).
baseline="$(state_ctx_get "$project" baseline_sha "$issue_arg" 2>/dev/null || true)"
[ -n "$baseline" ] || die "preship-evidence: baseline_sha unset — cannot verify files: (never diff against nothing)"
actual_files="$("$DEVAGENT_GIT" -C "$(config_get_project_field "$project" source_dir)" diff --name-only "$baseline..HEAD" 2>/dev/null | grep -c . || true)"
[ "$ev_files" = "$actual_files" ] \
  || fails+=("Evidence files mismatch: mr.md=$ev_files vs git diff $baseline..HEAD=$actual_files")

if [ "${#fails[@]}" -gt 0 ]; then
  printf 'preship-evidence: FAIL\n' >&2
  for f in "${fails[@]}"; do printf '  - %s\n' "$f" >&2; done
  exit 1
fi
echo "preship-evidence: PASS — mr.md Evidence matches $artifact ($expected_suite; files=$ev_files)" >&2
