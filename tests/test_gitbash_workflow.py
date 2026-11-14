"""#1096: structural pins on .github/workflows/gitbash.yml.

The workflow runs every `gitbash`-tagged bats file under real Git Bash on a
pinned Windows runner. Its check-run name, `Git Bash tagged files`, is a
contract: #1097 reads it at merge time.

WHAT THESE PINS OWN: the shape of the file. One job carries the check name; every
job runs on a pinned `windows-NNNN` label with bash as the default shell, a
30-minute timeout and a read-only token; the triggers match test.yml; no secret
is read; the locale is pinned; no DEVAGENT_* interpreter override is set; each
job's first step confirms Git Bash before any repo code runs; bats is cloned at
its release tag and checked against its commit; selection goes through
scripts/ci/gitbash-tagged.sh and never `bats --filter-tags`; and the header
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


def test_runs_on_pinned_windows(wf):
    for jid, job in _jobs(wf).items():
        assert re.fullmatch(r"windows-\d{4}", str(job.get("runs-on"))), jid


def test_defaults_shell_bash(wf):
    assert wf["defaults"]["run"]["shell"] == "bash"


def test_permissions_read_only(wf):
    assert wf["permissions"] == {"contents": "read"}
    for jid, job in _jobs(wf).items():
        assert "permissions" not in job, jid


def test_timeout_30(wf):
    for jid, job in _jobs(wf).items():
        assert job.get("timeout-minutes") == 30, jid


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
    for jid, job in _jobs(wf).items():
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
    runs = _runs(_named_job(wf)["steps"])
    sel = [i for i, r in enumerate(runs) if f"{HELPER} select tests" in r]
    run = [i for i, r in enumerate(runs) if f"{HELPER} run" in r]
    assert sel and run and min(sel) < max(run)
    for r in _runs(_all_steps(wf)):
        assert "--filter-tags" not in r


def test_header_states_run_events(header):
    start = [i for i, l in enumerate(header) if l.startswith("# Events that produce a run")]
    assert len(start) == 1
    block = " ".join(header[start[0]:])
    for token in ("pull_request", "push to master", "head of the push", "merge conflict",
                  "skip ci", "skip-checks", "no run yet"):
        assert token in block, token


def test_header_names_the_rejected_alternatives(header):
    block = "\n".join(header)
    for token in ("--filter-tags", "pull_request_target", "windows-latest"):
        assert token in block, token


def test_checkout_depth_one(wf):
    for job in _jobs(wf).values():
        assert _checkout(job).get("with", {}).get("fetch-depth") == 1


def test_header_records_parallelism(wf, header):
    # P1 measured serial against concurrent, cold, in one push (#1096 Task 8). The
    # line names both times, the run, and the choice; the choice must match the
    # Run step.
    pat = re.compile(r"^# Parallelism: serial \d+m\d{2}s, concurrent \(xargs -P 2\) "
                     r"\d+m\d{2}s \(run \d+\) -> (serial|concurrent)$")
    hits = [m for m in map(pat.match, header) if m]
    assert len(hits) == 1
    runs = " ".join(_runs(_named_job(wf)["steps"]))
    if hits[0].group(1) == "concurrent":
        assert f"{HELPER} run --jobs 2 " in runs
    else:
        assert "--jobs" not in runs
