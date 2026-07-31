#!/usr/bin/env bash
# run-eval.sh — MANUAL, LOCAL, NON-CI-GATING skill-steering eval harness (#460).
#
# This script NEVER invokes a model. Model runs are non-deterministic and must
# never gate CI (see evals/README.md). It assembles the exact fresh-session
# prompt for a case and prints its rubric so a human can run the prompt in a
# fresh session (3x) and hand-score each run against the rubric.
#
# Usage:
#   bash evals/run-eval.sh --list          # list case ids
#   bash evals/run-eval.sh <case-id>       # print the fresh-session prompt + rubric
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
EVALS_JSON="$HERE/evals.json"
[ -f "$EVALS_JSON" ] || { echo "run-eval: missing $EVALS_JSON" >&2; exit 1; }

if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then
  python3 - "$EVALS_JSON" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for c in data["cases"]:
    print(f"{c['id']:22} {c['skill']:14} {c['fixture']}")
PY
  exit 0
fi

case_id="${1:-}"
[ -n "$case_id" ] || { echo "usage: run-eval.sh --list | <case-id>" >&2; exit 2; }

# Extract the case fields with python3 (never parse JSON in bash). NUL-delimited
# so multi-line rubric fields survive intact.
# mapfile from a process substitution cannot see the subshell's exit code, and a
# NUL-delimited stream cannot be captured into a bash variable — so validate the
# result by field count instead of trusting the python rc.
mapfile -d '' fields < <(python3 - "$EVALS_JSON" "$case_id" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
cid = sys.argv[2]
case = next((c for c in data["cases"] if c["id"] == cid), None)
if case is None:
    sys.stderr.write(f"run-eval: no case '{cid}' in evals.json\n")
    sys.exit(3)
def emit(*vals):
    for v in vals:
        sys.stdout.write(str(v)); sys.stdout.write("\0")
emit(case["skill"], case["fixture"], "|".join(case["inputs"]))
emit(case["rubric"]["verdict"])
emit("\n".join(f"  - {m}" for m in case["rubric"]["must_name"]))
PY
) || true
if [ "${#fields[@]}" -lt 5 ]; then
  echo "run-eval: case lookup failed for '$case_id' (unknown id or malformed evals.json)" >&2
  exit 3
fi

skill="${fields[0]}"; fixture="${fields[1]}"; inputs="${fields[2]}"
verdict="${fields[3]}"; must_name="${fields[4]}"

skill_path="$REPO/skills/$skill/SKILL.md"
# #559: a case may target a command-form doc (e.g. crrf) that has no
# skills/ entry; fall back to commands/<skill>.md, and die clearly when
# neither home exists instead of printing a prompt at a missing file.
[ -f "$skill_path" ] || skill_path="$REPO/commands/$skill.md"
[ -f "$skill_path" ] || {
  echo "run-eval: no skills/$skill/SKILL.md and no commands/$skill.md" >&2
  exit 3
}
fixture_abs="$REPO/$fixture"

# Build the input-file list and detect the diff.patch / preship special-cases.
input_lines=""; has_diff=0
IFS='|' read -ra arr <<< "$inputs"
for f in "${arr[@]}"; do
  input_lines+="  - $fixture_abs/$f"$'\n'
  [ "$f" = "diff.patch" ] && has_diff=1
done

echo "=== FRESH-SESSION PROMPT for case: $case_id (skill: $skill) ==="
echo
echo "You are running devAgent step for the '$skill' skill in a FRESH session."
echo "Read the skill body verbatim and apply it to the fixture inputs below."
echo
echo "Skill body: $skill_path"
echo "Fixture inputs (read each):"
printf '%s' "$input_lines"
if [ "$has_diff" -eq 1 ]; then
  echo "IMPORTANT: treat '$fixture_abs/diff.patch' as the ENTIRE 'baseline..HEAD'"
  echo "diff. Do NOT run git — there is no branch; the patch file IS the change."
fi
if [ "$skill" = "core-preship" ]; then
  echo "Score verifications 1-3 only (acceptance criteria, findings-applied-&-"
  echo "committed, push-preview). SKIP verification 4 (preship-evidence.sh) and 5"
  echo "(spec-touch): this fixture has no suite-count artifact or spec tree."
fi
echo
echo "Produce the skill's judgment (verdict + findings) exactly as the skill"
echo "directs, then STOP. Do not modify any file."
echo
echo "=== RUBRIC (hand-score this run PASS/FAIL) ==="
echo "Required verdict:"
echo "  $verdict"
echo "Must name (all required):"
printf '%s\n' "$must_name"
echo
echo "This run PASSES iff the verdict matches AND every 'must name' point appears."
echo "Record 3 runs; the case passes at >= 2/3. See evals/README.md."
