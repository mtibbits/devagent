#!/usr/bin/env bats
# #460: STRUCTURAL guard for the skill-steering evals. This is the ONLY
# CI-durable eval artifact and it NEVER invokes a model — model runs are
# non-deterministic and must not gate CI (evals/README.md). It asserts the eval
# STRUCTURE so a case cannot silently lose its fixture, rubric, or baseline, and
# so each judgment skill keeps >= 2 cases (the issue's "measure structure, not
# model" contract).

REPO="${BATS_TEST_DIRNAME}/.."
EVALS="$REPO/evals/evals.json"

@test "evals.json exists and is valid JSON (#460)" {
  [ -f "$EVALS" ] || { echo "missing $EVALS" >&2; return 1; }
  run python3 -m json.tool "$EVALS"
  [ "$status" -eq 0 ] || { echo "evals.json is not valid JSON:" >&2; echo "$output" >&2; return 1; }
}

@test "every case has id, skill, fixture (dir exists), rubric, baseline (#460)" {
  run python3 - "$EVALS" "$REPO" <<'PY'
import json, os, sys
data = json.load(open(sys.argv[1])); repo = sys.argv[2]
errs = []
for c in data["cases"]:
    cid = c.get("id", "<no-id>")
    for key in ("id", "skill", "fixture", "rubric", "baseline"):
        if key not in c:
            errs.append(f"{cid}: missing {key}")
    fx = c.get("fixture")
    if fx and not os.path.isdir(os.path.join(repo, fx)):
        errs.append(f"{cid}: fixture dir absent: {fx}")
    r = c.get("rubric", {})
    if not r.get("verdict"):    errs.append(f"{cid}: rubric.verdict empty")
    if not r.get("must_name"):  errs.append(f"{cid}: rubric.must_name empty")
    for f in c.get("inputs", []):
        if fx and not os.path.isfile(os.path.join(repo, fx, f)):
            errs.append(f"{cid}: input file absent: {fx}/{f}")
if errs:
    sys.stderr.write("\n".join(errs) + "\n"); sys.exit(1)
print(f"{len(data['cases'])} cases OK")
PY
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "each judgment skill has >= 2 cases (#460)" {
  run python3 - "$EVALS" <<'PY'
import json, sys
from collections import Counter
data = json.load(open(sys.argv[1]))
counts = Counter(c["skill"] for c in data["cases"])
required = {"core-scope", "core-redmr", "core-preship"}
errs = [f"{s}: {counts.get(s,0)} cases (need >= 2)" for s in required if counts.get(s,0) < 2]
if errs:
    sys.stderr.write("\n".join(errs) + "\n"); sys.exit(1)
print("all three judgment skills have >= 2 cases")
PY
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "run-eval.sh --list enumerates every case id, model never invoked (#460)" {
  run bash "$REPO/evals/run-eval.sh" --list
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  # every id in evals.json appears in the listing
  run python3 - "$EVALS" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print("\n".join(c["id"] for c in data["cases"]))
PY
  local ids="$output"
  run bash "$REPO/evals/run-eval.sh" --list
  local listing="$output"
  while IFS= read -r id; do
    [[ "$listing" == *"$id"* ]] || { echo "id '$id' missing from --list" >&2; return 1; }
  done <<< "$ids"
}
