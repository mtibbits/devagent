"""Tests for scripts/lib/wbs-import.py (#706)."""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "scripts" / "lib" / "wbs-import.py"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


wbs_import = _load("wbs_import", LIB)


def rec(id_="1", **kw):
    r = {"id": id_, "title": "t", "body": "", "state": "open", "class": "open",
         "created": "2026-01-02", "closed": None, "milestone": None,
         "labels": [], "type": None, "parent": None, "blocked_by": [],
         "url": f"https://github.com/o/r/issues/{id_}"}
    r.update(kw)
    return r


def lines(*recs):
    return "".join((r if isinstance(r, str) else json.dumps(r)) + "\n" for r in recs)


# --- the record contract (Task 2) -------------------------------------------
def test_contract_parse_issue_list_ok_and_empty():
    closed = rec("2", state="closed", **{"class": "done"}, closed="2026-02-01")
    assert len(wbs_import.parse_issue_list(lines(rec("1"), closed))) == 2
    assert wbs_import.parse_issue_list("") == []


@pytest.mark.parametrize("name, bad", [
    ("null_line", "null"),
    ("list_line", "[]"),
    ("non_json", "{not json"),
    ("missing_key", {k: v for k, v in rec("2").items() if k != "url"}),
    ("wrong_type", rec("2", labels="epic")),
    ("bad_class", rec("2", **{"class": "closed"})),
    ("bad_date", rec("2", created="2026-02-30")),
    ("closed_on_open", rec("2", closed="2026-02-01")),
    ("no_closed_date", rec("2", state="closed", **{"class": "done"})),
    ("duplicate_id", rec("1")),
])
def test_contract_parse_issue_list_rejects(name, bad):
    with pytest.raises(ValueError, match=r"^malformed line 2: "):
        wbs_import.parse_issue_list(lines(rec("1"), bad))


def test_contract_check_cli():
    ok = subprocess.run([sys.executable, str(LIB), "check"], input=lines(rec("1"), rec("2")),
                        capture_output=True, text=True)
    assert (ok.returncode, ok.stdout) == (0, "2\n")
    bad = subprocess.run([sys.executable, str(LIB), "check"], input="null\n",
                         capture_output=True, text=True)
    assert bad.returncode == 1 and "malformed line 1" in bad.stderr
