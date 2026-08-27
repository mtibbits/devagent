#!/usr/bin/env bats
# #460: STRUCTURAL guard for the skill-steering evals. This is the ONLY
# CI-durable eval artifact and it NEVER invokes a model — model runs are
# non-deterministic and must not gate CI (evals/README.md). It asserts the eval
# STRUCTURE so a case cannot silently lose its fixture, rubric, or baseline, and
# so each judgment skill keeps >= 2 cases (the issue's "measure structure, not
# model" contract).
#
# #530 EXTENSION: the harness-conformance smoke rungs (evals/smoke/smoke.json)
# get their own structural @tests BELOW, keyed to a SEPARATE file so the four
# steering `cases` @tests above are byte-unchanged (the smoke rungs have a
# different shape —
# they measure the harness, not a skill body — and must not weaken the
# fixture+rubric+baseline guard on steering cases).

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

REPO="${BATS_TEST_DIRNAME}/.."
EVALS="$REPO/evals/evals.json"
SMOKE="$REPO/evals/smoke/smoke.json"

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

# --- #530: harness-conformance smoke rungs (evals/smoke/) ---

@test "smoke.json exists and is valid JSON (#530)" {
  [ -f "$SMOKE" ] || { echo "missing $SMOKE" >&2; return 1; }
  run python3 -m json.tool "$SMOKE"
  [ "$status" -eq 0 ] || { echo "smoke.json is not valid JSON:" >&2; echo "$output" >&2; return 1; }
}

@test "every smoke rung has id, target, procedure, measured, expected, baseline, trigger (#530)" {
  run python3 - "$SMOKE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
errs = []
for r in data["rungs"]:
    rid = r.get("id", "<no-id>")
    for key in ("id", "target", "procedure", "measured", "expected", "baseline", "trigger"):
        if not r.get(key):
            errs.append(f"{rid}: missing/empty {key}")
    b = r.get("baseline", {})
    for key in ("date", "model", "pass_rate", "runs"):
        if key not in b:
            errs.append(f"{rid}: baseline missing {key}")
if errs:
    sys.stderr.write("\n".join(errs) + "\n"); sys.exit(1)
print(f"{len(data['rungs'])} rungs OK")
PY
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "smoke rung count floor >= 3 so an emptied smoke.json REDs (#530 / #439 vacuity guard)" {
  run python3 - "$SMOKE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
n = len(data.get("rungs", []))
if n < 3:
    sys.stderr.write(f"only {n} smoke rungs (need >= 3: the #458 Smoke A/B ladder)\n"); sys.exit(1)
print(f"{n} rungs")
PY
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "smoke.json meta declares non-CI-gating and a run trigger (#530)" {
  run python3 - "$SMOKE" <<'PY'
import json, sys
meta = json.load(open(sys.argv[1]))["meta"]
errs = []
if "NON-CI-GATING" not in meta.get("run", "").upper():
    errs.append("meta.run must declare NON-CI-GATING")
if not meta.get("run_trigger"):
    errs.append("meta.run_trigger missing (harness regression has no skill-edit trigger)")
if errs:
    sys.stderr.write("\n".join(errs) + "\n"); sys.exit(1)
print("meta OK")
PY
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "the broken-binding fixture dir exists with an agent file (#530)" {
  local dir="$REPO/evals/smoke/fixtures/broken-binding"
  [ -d "$dir" ] || { echo "missing $dir" >&2; return 1; }
  [ -f "$dir/preship-verifier.md" ] || { echo "missing broken agent fixture" >&2; return 1; }
}
