"""#465: structural pins on .github/workflows/publish-docs-site.yml.

The workflow's deploy half must stay OFF until the operator sets the repository
variable DOCS_SITE_DEPLOY: GitHub Pages is unavailable while the repo is
private, and an ungated deploy would redden master on every docs push.

WHAT THESE PINS OWN: the shape of the file — that the gate expression carries
all three clauses, that it is spelled in exactly one place, that every step or
job able to publish reads that one place, that the write permissions sit on the
deploy job alone, that the path filters name TRACKED files, that the test step
cannot pass on a red test, and that the Pages concurrency group sits on the
deploy job rather than the workflow.

WHAT THEY DO NOT OWN: whether GitHub evaluates the expression the way this file
assumes (an unset `vars.*` reading as the empty string). That is a claim about
the forge, and only a forge run can discharge it — the first master run after
merge must show the deploy job `skipped`. The plan records that as its own
evidence step; a green run of this file is not that evidence.
"""
import os
import subprocess

import pytest
import yaml

_REPO = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
_WF = os.path.join(_REPO, ".github", "workflows", "publish-docs-site.yml")

GATE_CLAUSES = (
    "github.repository == 'mtibbits/devagent'",
    "github.ref == 'refs/heads/master'",
    "vars.DOCS_SITE_DEPLOY == 'true'",
)
REQUIRED_PATHS = {
    "docs-site/**",
    "scripts/build-docs-site.sh",
    "scripts/docs-site/**",
    "tests/build-docs-site.bats",
    ".github/workflows/publish-docs-site.yml",
}
PUBLISHING_ACTIONS = ("actions/upload-pages-artifact", "actions/deploy-pages")


@pytest.fixture(scope="module")
def wf():
    with open(_WF, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    # YAML 1.1 reads the bare key `on` as boolean True; accept either spelling.
    doc["_on"] = doc.get("on", doc.get(True))
    assert isinstance(doc["_on"], dict), "workflow has no `on:` mapping"
    return doc


@pytest.fixture(scope="module")
def text():
    with open(_WF, encoding="utf-8") as fh:
        return fh.read()


def _steps(job):
    return job.get("steps", [])


def test_default_token_is_read_only(wf):
    assert wf["permissions"] == {"contents": "read"}


def test_triggers_and_path_filters(wf):
    on = wf["_on"]
    assert set(on) == {"push", "pull_request", "workflow_dispatch"}
    assert on["push"]["branches"] == ["master"]
    assert set(on["push"]["paths"]) == REQUIRED_PATHS
    assert on["pull_request"]["paths"] == on["push"]["paths"]


@pytest.mark.parametrize("entry", sorted(REQUIRED_PATHS))
def test_every_path_filter_names_something_tracked(entry):
    # A filter naming a renamed file silently stops triggering the workflow.
    # Ask git, not the filesystem: an untracked leftover or an emptied directory
    # still "exists" and would pass.
    target = entry[: -len("/**")] if entry.endswith("/**") else entry
    tracked = subprocess.run(
        ["git", "-C", _REPO, "ls-files", "-z", "--", target],
        check=True, capture_output=True,
    ).stdout
    assert tracked.strip(b"\0"), f"{target}: no tracked file matches this path filter"


def test_gate_expression_is_spelled_exactly_once_with_all_three_clauses(wf, text):
    for clause in GATE_CLAUSES:
        # comments restate the rule in prose, never as the expression itself
        code = "\n".join(
            line for line in text.splitlines() if not line.lstrip().startswith("#")
        )
        assert code.count(clause) == 1, clause
    gate = [s for s in _steps(wf["jobs"]["build"]) if s.get("id") == "gate"]
    assert len(gate) == 1
    run = gate[0]["run"]
    assert all(clause in run for clause in GATE_CLAUSES)
    assert " && ".join(GATE_CLAUSES) in run, "clauses must be AND-ed, in one expression"
    assert "||" not in run
    assert wf["jobs"]["build"]["outputs"] == {"deploy": "${{ steps.gate.outputs.deploy }}"}


def test_everything_that_can_publish_reads_the_one_gate(wf):
    seen = 0
    for name, job in wf["jobs"].items():
        for step in _steps(job):
            uses = step.get("uses", "")
            if not uses.startswith(PUBLISHING_ACTIONS):
                continue
            seen += 1
            if name == "deploy":
                assert job["if"] == "needs.build.outputs.deploy == 'true'"
            else:
                assert step["if"] == "steps.gate.outputs.deploy == 'true'"
    assert seen == 2, "expected one upload-pages-artifact step and one deploy-pages step"


def test_gate_step_runs_before_anything_that_reads_it(wf):
    ids = [s.get("id") for s in _steps(wf["jobs"]["build"])]
    readers = [
        i for i, s in enumerate(_steps(wf["jobs"]["build"]))
        if "steps.gate.outputs.deploy" in str(s.get("if", ""))
    ]
    assert readers and ids.index("gate") < min(readers)


def test_write_permissions_live_on_the_deploy_job_only(wf):
    deploy = wf["jobs"]["deploy"]
    assert deploy["permissions"] == {"pages": "write", "id-token": "write"}
    assert deploy["needs"] == "build"
    assert deploy["environment"]["name"] == "github-pages"
    for name, job in wf["jobs"].items():
        if name != "deploy":
            assert "permissions" not in job, name


def test_build_lane_runs_the_builder_tests_and_refuses_skips(wf):
    runs = [s.get("run", "") for s in _steps(wf["jobs"]["build"])]
    pandoc_at = next(i for i, r in enumerate(runs) if r.startswith("pandoc --version"))
    bats_at = next(i for i, r in enumerate(runs) if "bats tests/build-docs-site.bats" in r)
    build_at = next(i for i, r in enumerate(runs) if "scripts/build-docs-site.sh" in r)
    assert pandoc_at < bats_at < build_at
    assert "# skip" in runs[bats_at] and "exit 1" in runs[bats_at]


def test_builder_test_step_cannot_pass_on_a_red_test(wf):
    # A bare `run:` is `bash -e` with no pipefail, so `bats | tee` alone would
    # report tee's status. Any step that pipes bats must set pipefail FIRST.
    piped = [
        s["run"] for s in _steps(wf["jobs"]["build"])
        if "bats " in s.get("run", "") and "|" in s.get("run", "")
    ]
    assert piped, "expected the builder-test step to pipe bats through tee"
    for run in piped:
        first = run.strip().splitlines()[0].strip()
        assert first == "set -o pipefail", first


def test_pages_concurrency_group_is_on_the_deploy_job_only(wf):
    assert "concurrency" not in wf, "a workflow-level group queues PR builds behind master"
    assert wf["jobs"]["deploy"]["concurrency"] == {
        "group": "pages", "cancel-in-progress": False,
    }
    assert "concurrency" not in wf["jobs"]["build"]
