"""#1096: structural pins on .github/workflows/gitbash.yml.

The workflow runs every `gitbash`-tagged bats file under real Git Bash on a
pinned Windows runner. Its check-run name, `Git Bash tagged files`, is a
contract: #1097 reads it at merge time.

WHAT THESE PINS OWN: the shape of the file. One job carries the check name, and
it is the gate (#1197): not a matrix, a literal name, no `needs:`, an ubuntu
runner, `actions: read` + `contents: read`, and a `gate <K> ...` call whose bounds
cover a full shard. The shard job is one `fail-fast: false` matrix over 1..K on a
pinned `windows-NNNN` label, named `Git Bash shard <i> of <K>`, with a 30-minute
timeout; it keeps #1096's frozen steps, then selects, shards by
scripts/ci/gitbash-times.txt and runs its shard. Bash is the default shell, the
workflow token is read-only, the triggers match test.yml, no secret is read, the
locale is pinned, no DEVAGENT_* interpreter override is set, each Windows job's
first step confirms Git Bash before any repo code runs, bats is cloned at its
release tag and checked against its commit, selection goes through
scripts/ci/gitbash-tagged.sh and never `bats --filter-tags`, and the header
states which events produce a run.

WHAT THEY DO NOT OWN: whether GitHub behaves as the header says (which events
start a run, that `windows-2025` is live, that `shell: bash` is Git for Windows'
bash). Those are claims about the forge; only a run discharges them, and the PR
records each as CONFIRMED or ASSERTED.

Forbidden tokens are asserted on the PARSED YAML (keys, `runs-on` values, step
`run` strings), never on the raw text: the header comment names them on purpose.
"""
import os
import re

import pytest
import yaml

_REPO = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
_WF = os.path.join(_REPO, ".github", "workflows", "gitbash.yml")

CHECK_NAME = "Git Bash tagged files"
HELPER = "scripts/ci/gitbash-tagged.sh"
BATS_SHA = "eb7f42f8d608ac693d7a4b67474f6714ea68cfc5"


@pytest.fixture(scope="module")
def wf(text):
    doc = yaml.safe_load(text)
    # YAML 1.1 reads the bare key `on` as boolean True; accept either spelling.
    doc["_on"] = doc.get("on", doc.get(True))
    assert isinstance(doc["_on"], dict), "workflow has no `on:` mapping"
    return doc


@pytest.fixture(scope="module")
def text():
    with open(_WF, encoding="utf-8") as fh:
        return fh.read()


@pytest.fixture(scope="module")
def header(text):
    """The leading comment block, up to the first non-comment line."""
    out = []
    for line in text.splitlines():
        if line.startswith("#") or not line.strip():
            out.append(line)
            continue
        break
    return out


def _jobs(wf):
    return wf["jobs"]


def _named_job(wf):
    named = [j for j in _jobs(wf).values() if j.get("name") == CHECK_NAME]
    assert len(named) == 1, f"expected exactly one job named {CHECK_NAME!r}"
    return named[0]


def _shard_job(wf):
    sharded = [j for j in _jobs(wf).values() if "strategy" in j]
    assert len(sharded) == 1, "expected exactly one job with a strategy (the shard matrix)"
    return sharded[0]


def _k(wf):
    return len(_shard_job(wf)["strategy"]["matrix"]["shard"])


# Anchored: the gate call is a bare command on its own line, never an argument
# to echo or the right side of a ||.
GATE_RE = re.compile(r"^[ \t]*" + re.escape(HELPER) + r" gate (\d+) (\d+) (\d+) (\d+)[ \t]*$", re.M)
SHARD_NAME = "Git Bash shard ${{ matrix.shard }} of ${{ strategy.job-total }}"
FROZEN_STEPS = ["Confirm Git Bash", "actions/checkout@v4", "Install bats 1.14.0",
                "Ensure python3", "Tool versions and locale"]


def _gate(wf):
    hits = [m for r in _runs(_named_job(wf)["steps"]) for m in GATE_RE.finditer(r)]
    assert len(hits) == 1, "expected exactly one gate call in the check job"
    return tuple(int(g) for g in hits[0].groups())


def _step_label(step):
    return step.get("name") or step.get("uses")


def _all_steps(wf):
    for job in _jobs(wf).values():
        for step in job.get("steps", []):
            yield step


def _runs(steps):
    return [s["run"] for s in steps if "run" in s]


def _checkout(job):
    co = [s for s in job.get("steps", []) if str(s.get("uses", "")).startswith("actions/checkout@")]
    assert len(co) == 1, "expected exactly one actions/checkout step"
    return co[0]


def _envs(wf):
    yield wf.get("env") or {}
    for job in _jobs(wf).values():
        yield job.get("env") or {}
        for step in job.get("steps", []):
            yield step.get("env") or {}


def test_one_job_named_for_the_check(wf):
    _named_job(wf)


def test_check_job_is_not_a_matrix_and_has_a_literal_name(wf):
    job = _named_job(wf)
    assert "strategy" not in job
    assert "${{" not in job["name"]


def test_shard_matrix_shape(wf):
    job = _shard_job(wf)
    k = _k(wf)
    assert k >= 2
    assert job["strategy"]["fail-fast"] is False
    assert job["strategy"]["matrix"] == {"shard": list(range(1, k + 1))}
    assert job["name"] == SHARD_NAME
    sel = [s for s in job["steps"] if s.get("name") == "Select tagged files"]
    assert len(sel) == 1
    assert sel[0]["env"]["SHARD"] == "${{ matrix.shard }}"
    assert sel[0]["env"]["SHARDS"] == "${{ strategy.job-total }}"


def test_shard_job_keeps_the_frozen_steps(wf):
    # #1096's steps, in order, then Select and Run (#1197 A7).
    labels = [_step_label(s) for s in _shard_job(wf)["steps"]]
    assert labels == FROZEN_STEPS + ["Select tagged files", "Run tagged files"]


def test_shard_names_never_equal_the_check_name(wf):
    assert not SHARD_NAME.startswith(CHECK_NAME)


def test_only_two_jobs(wf):
    assert len(_jobs(wf)) == 2


def test_runs_on_pinned(wf):
    assert re.fullmatch(r"windows-\d{4}", str(_shard_job(wf).get("runs-on")))
    assert re.fullmatch(r"ubuntu-\d{2}\.04", str(_named_job(wf).get("runs-on")))


def test_defaults_shell_bash(wf):
    assert wf["defaults"]["run"]["shell"] == "bash"


def test_permissions_read_only(wf):
    assert wf["permissions"] == {"contents": "read"}
    assert _named_job(wf)["permissions"] == {"actions": "read", "contents": "read"}
    for jid, job in _jobs(wf).items():
        if job is not _named_job(wf):
            assert "permissions" not in job, jid


def test_shard_timeout_30(wf):
    # The issue's 30-minute cap is on the shards, not the gate.
    assert _shard_job(wf).get("timeout-minutes") == 30


def test_gate_bounds_cover_a_full_shard(wf):
    _, interval, run_secs, start_secs = _gate(wf)
    shard_timeout = _shard_job(wf)["timeout-minutes"]
    assert run_secs > shard_timeout * 60, "a shard's own cancel must land before the gate's run bound"
    assert _named_job(wf)["timeout-minutes"] * 60 >= start_secs + run_secs + 300
    assert 0 < interval <= 60


def test_check_job_gates_every_shard(wf):
    job = _named_job(wf)
    assert "needs" not in job, "a needs: job has no check run until its needs finish (#1197 U1)"
    k, _, _, _ = _gate(wf)
    assert k == _k(wf)
    gate_steps = [s for s in job["steps"] if GATE_RE.search(s.get("run", ""))]
    assert len(gate_steps) == 1
    assert gate_steps[0]["env"]["GH_TOKEN"] == "${{ github.token }}"


def test_triggers_are_pull_request_and_master_push(wf):
    on = wf["_on"]
    assert set(on) == {"pull_request", "push"}
    assert on["push"] == {"branches": ["master"]}
    assert not on["pull_request"], "pull_request must carry no filter"
    assert "concurrency" not in wf


def test_no_secrets(wf):
    for step in _all_steps(wf):
        for key in ("run", "with", "env"):
            assert "secrets." not in repr(step.get(key, "")), step.get("name")
    for env in _envs(wf):
        assert "secrets." not in repr(env)
    for job in _jobs(wf).values():
        assert _checkout(job).get("with", {}).get("persist-credentials") is False


def test_locale_pinned(wf):
    env = wf["env"]
    assert env["LC_ALL"] == env["LANG"] == "C.UTF-8"


def test_no_devagent_interpreter_override(wf):
    for env in _envs(wf):
        assert not [k for k in env if str(k).startswith("DEVAGENT_")]
    for run in _runs(_all_steps(wf)):
        assert not re.search(r"\bDEVAGENT_\w+=", run)


def test_first_step_confirms_git_bash(wf):
    windows = [(jid, job) for jid, job in _jobs(wf).items()
               if str(job.get("runs-on", "")).startswith("windows-")]
    assert windows
    for jid, job in windows:
        first = job["steps"][0]
        assert "uses" not in first, jid
        run = first.get("run", "")
        assert "uname -s" in run, jid
        assert "command -v bash" in run, jid
        assert "MINGW*|MSYS*)" in run, jid


def test_bats_pinned_to_release_tag(text):
    assert "--branch v1.14.0" in text
    assert BATS_SHA in text


def test_selection_through_helper_not_filter_tags(wf):
    runs = "\n".join(_runs(_shard_job(wf)["steps"]))
    sel = runs.find(f"{HELPER} select tests")
    shard = runs.find(f'{HELPER} shard "$SHARD" "$SHARDS" scripts/ci/gitbash-times.txt')
    run = runs.find(f"{HELPER} run --jobs 2")
    assert -1 < sel < shard < run
    run_step = [s for s in _shard_job(wf)["steps"] if s.get("name") == "Run tagged files"]
    assert len(run_step) == 1
    assert "gitbash-shard.txt" in run_step[0]["run"]
    assert "gitbash-files.txt" not in run_step[0]["run"]
    assert os.path.isfile(os.path.join(_REPO, "scripts", "ci", "gitbash-times.txt"))
    for r in _runs(_all_steps(wf)):
        assert "--filter-tags" not in r


def test_header_states_run_events(header):
    start = [i for i, l in enumerate(header) if l.startswith("# Events that produce a run")]
    assert len(start) == 1
    block = " ".join(header[start[0]:])
    for token in ("pull_request", "push to master", "head of the push", "merge conflict",
                  "skip ci", "skip-checks", "no run yet", "shard", "run attempt"):
        assert token in block, token


def test_header_names_the_rejected_alternatives(header):
    block = "\n".join(header)
    for token in ("--filter-tags", "pull_request_target", "windows-latest"):
        assert token in block, token


def test_checkout_depth_one(wf):
    for job in _jobs(wf).values():
        assert _checkout(job).get("with", {}).get("fetch-depth") == 1


def test_header_records_last_green_run(header):
    # P5 (#1096 Task 8): the Time AC. The run, the head it measured, and the job time.
    pat = re.compile(r"^# Last green run: https://github\.com/mtibbits/devagent/actions/runs/\d+ "
                     r"@ [0-9a-f]{40} in \d+m\d{2}s$")
    assert len([line for line in header if pat.match(line)]) == 1


def test_header_records_parallelism(wf, header):
    # P1 measured serial against concurrent, cold, in one push (#1096 Task 8). The
    # line names both times, the run, and the choice; the choice must match the
    # Run step.
    pat = re.compile(r"^# Parallelism: serial \d+m\d{2}s, concurrent \(xargs -P 2\) "
                     r"\d+m\d{2}s \(run \d+\) -> (serial|concurrent)$")
    hits = [m for m in map(pat.match, header) if m]
    assert len(hits) == 1
    runs = " ".join(_runs(_shard_job(wf)["steps"]))
    if hits[0].group(1) == "concurrent":
        assert f"{HELPER} run --jobs 2 " in runs
    else:
        assert "--jobs" not in runs


def test_header_records_shards(wf, header):
    pat = re.compile(r"^# Shards \(#1197\): (\d+) jobs")
    hits = [m for m in map(pat.match, header) if m]
    assert len(hits) == 1
    assert int(hits[0].group(1)) == _k(wf)


def test_jobs_cannot_be_softened(wf):
    # #1197 review: a skipped job reads as passing and continue-on-error turns a red
    # step green, so neither may sit on the gate, the shards, or any of their steps.
    for jid, job in _jobs(wf).items():
        for key in ("if", "continue-on-error"):
            assert key not in job, (jid, key)
        for step in job.get("steps", []):
            for key in ("if", "continue-on-error"):
                assert key not in step, (jid, _step_label(step), key)
