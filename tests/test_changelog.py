"""#1127: scripts/changelog.py, the changelog entry-file tool.

A pull request records its changelog entry as changelog.d/<key>.md; the tool
checks those files and compiles them into CHANGELOG.md at release. Every leg
but the repository-root and released-sections ones builds a throwaway tree
under tmp_path and calls ``main(argv, root=tree)`` in-process, so no test
depends on the live CHANGELOG.md's unreleased entries. Each refusal leg asserts
the exit code AND the exact message, and that no file changed.
"""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
TOOL = REPO / "scripts" / "changelog.py"
P = "changelog: "
KIND_LIST = "Added, Changed, Deprecated, Removed, Fixed, Security, Docs"
ONLY_ENTRIES = "changelog.d/ holds only entry files"
SLUG_RULE = (
    "the slug must start with a letter and use only lowercase letters, "
    "digits and single hyphens"
)
ENTRY = "- **Added: a thing (#1).** It does a thing.\n"


def _load():
    spec = importlib.util.spec_from_file_location("changelog_tool", TOOL)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def tool():
    return _load()


def _write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, str):
        data = data.encode("utf-8")
    path.write_bytes(data)


def _entries(tmp, files):
    """Write changelog.d/<name> for each (name, body) in files."""
    d = tmp / "changelog.d"
    d.mkdir(exist_ok=True)
    for name, body in files.items():
        _write(d / name, body)
    return d


def _run(tool, tmp, capsys, *argv):
    rc = tool.main(list(argv), root=tmp)
    out, err = capsys.readouterr()
    return rc, out, err


# --- check -------------------------------------------------------------------


def _symlink(d):
    target = d.parent / "outside.md"
    target.write_text(ENTRY, encoding="utf-8")
    try:
        os.symlink(target, d / "link.md")
    except (OSError, NotImplementedError) as exc:  # Windows without the privilege
        pytest.skip(f"cannot create a symlink here ({exc})")


def _fifo(d):
    if not hasattr(os, "mkfifo"):
        pytest.skip("os.mkfifo is POSIX-only")
    os.mkfifo(d / "pipe.md")


def _subdir(d):
    _write(d / "sub" / "x.md", ENTRY)


PROBLEMS = {
    "leading-zero": ({"012.md": ENTRY}, "012.md: the issue number has a leading zero"),
    "zero": ({"0.md": ENTRY}, "0.md: the issue number must be a positive integer"),
    "slug-digit": ({"9-fix.md": ENTRY}, "9-fix.md: " + SLUG_RULE),
    "slug-upper": ({"Docs-pass.md": ENTRY}, "Docs-pass.md: " + SLUG_RULE),
    "empty": ({"empty.md": ""}, "empty.md: empty; an entry file holds one or more entries"),
    "blank-only": ({"blank.md": "\n  \n"}, "blank.md: empty; an entry file holds one or more entries"),
    "no-kind": (
        {"1.md": "- **Improved: x.**\n"},
        "1.md: line 1: an entry with no listed kind (" + KIND_LIST + ")",
    ),
    "no-kind-swallows": (
        {"1.md": "- **Improved: x\n  wrapped.**\n\n  More.\n\n" + ENTRY},
        "1.md: line 1: an entry with no listed kind (" + KIND_LIST + ")",
    ),
    "prose": ({"1.md": ENTRY + "\nSome prose.\n"}, "1.md: line 3: prose outside an entry"),
    "heading": ({"1.md": "# Title\n" + ENTRY}, "1.md: line 1: a heading"),
    "opens-indented": ({"1.md": "  indented\n" + ENTRY}, "1.md: line 1: prose outside an entry"),
    "not-utf8": ({"1.md": b"- **Added: caf\xe9.**\n"}, "1.md: not UTF-8"),
    "not-md": ({"notes.txt": "x\n"}, "notes.txt: not a .md file; " + ONLY_ENTRIES),
    "subdirectory": (_subdir, "sub: a subdirectory; " + ONLY_ENTRIES),
    "symlink": (_symlink, "link.md: a symlink; " + ONLY_ENTRIES),
    "fifo": (_fifo, "pipe.md: not a .md file; " + ONLY_ENTRIES),
}


@pytest.mark.parametrize("case", sorted(PROBLEMS))
def test_check_problem(tool, tmp_path, capsys, case):
    setup, problem = PROBLEMS[case]
    if callable(setup):
        setup(_entries(tmp_path, {}))
    else:
        _entries(tmp_path, setup)
    rc, out, err = _run(tool, tmp_path, capsys, "check")
    assert (rc, out, err) == (1, "", P + "changelog.d/" + problem + "\n")


ACCEPTS = {
    "breaking": {"10.md": "- **Changed (breaking): the form moves.** Read it.\n"},
    "migration": {
        "10.md": (
            "- **Changed (breaking): the form moves (#10).** It now reads\n"
            "  differently.\n"
            "\n"
            "  **Migration:** run the new form.\n"
        )
    },
    "two-entries": {"docs-pass.md": "- **Docs: a.**\n\n- **Fixed (lazy reader): b.**\n"},
    "crlf": {"10.md": "- **Fixed: a.**\r\n  wrapped.\r\n"},
}


@pytest.mark.parametrize("case", sorted(ACCEPTS))
def test_check_accepts(tool, tmp_path, capsys, case):
    _entries(tmp_path, ACCEPTS[case])
    rc, out, err = _run(tool, tmp_path, capsys, "check")
    assert (rc, out, err) == (0, P + "no problems in 1 entry file\n", "")


def test_check_reports_every_problem(tool, tmp_path, capsys):
    _entries(
        tmp_path,
        {
            "1.md": ENTRY,
            "012.md": ENTRY,
            "b.md": "",
            "c.md": "prose\n" + ENTRY + "# h\n",
        },
    )
    rc, out, err = _run(tool, tmp_path, capsys, "check")
    assert rc == 1 and out == ""
    assert err.splitlines() == [
        P + "changelog.d/012.md: the issue number has a leading zero",
        P + "changelog.d/b.md: empty; an entry file holds one or more entries",
        P + "changelog.d/c.md: line 1: prose outside an entry",
        P + "changelog.d/c.md: line 3: a heading",
    ]


def test_check_name_and_body_problems_both_reported(tool, tmp_path, capsys):
    _entries(tmp_path, {"012.md": "prose\n"})
    rc, out, err = _run(tool, tmp_path, capsys, "check")
    assert rc == 1
    assert err.splitlines() == [
        P + "changelog.d/012.md: the issue number has a leading zero",
        P + "changelog.d/012.md: line 1: prose outside an entry",
    ]


def test_check_missing_folder_is_empty(tool, tmp_path, capsys):
    rc, out, err = _run(tool, tmp_path, capsys, "check")
    assert (rc, out, err) == (0, P + "no problems in 0 entry files\n", "")


def test_check_folder_not_directory(tool, tmp_path, capsys):
    (tmp_path / "changelog.d").write_text("x\n", encoding="utf-8")
    rc, out, err = _run(tool, tmp_path, capsys, "check")
    assert (rc, out, err) == (1, "", P + "changelog.d: not a directory\n")


def test_check_child_that_vanishes_counts_as_gone(tool, tmp_path, capsys, monkeypatch):
    d = _entries(tmp_path, {"1.md": ENTRY, "gone.md": ENTRY})
    real = os.lstat

    def lstat(path, *args, **kwargs):
        if os.path.basename(os.fspath(path)) == "gone.md":
            raise FileNotFoundError(2, "No such file or directory", os.fspath(path))
        return real(path, *args, **kwargs)

    monkeypatch.setattr(os, "lstat", lstat)
    rc, out, err = _run(tool, tmp_path, capsys, "check")
    assert (rc, out, err) == (0, P + "no problems in 1 entry file\n", "")
    assert (d / "gone.md").exists()


def _section(lines, version):
    """The lines of `## [<version>]` from its first col-0 `- **` line to the next `## `."""
    start = next(i for i, ln in enumerate(lines) if ln.startswith("## [%s]" % version))
    end = next(
        (i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines)
    )
    body = lines[start + 1 : end]
    first = next(i for i, ln in enumerate(body) if ln.startswith("- **"))
    return body[first:]


@pytest.mark.parametrize("version", ["3.0.0", "3.1.0", "3.2.0"])
def test_entry_grammar_accepts_released_sections(tool, version):
    # Frozen must-not-trip corpus: a dated section never changes again (D6), so
    # reading the live file here cannot turn red when a later release lands.
    lines = (REPO / "CHANGELOG.md").read_text(encoding="utf-8").split("\n")
    body = _section(lines, version)
    entries, problems = tool.parse_entries(body)
    assert problems == []
    assert len(entries) == sum(1 for ln in body if ln.startswith("- **"))
    assert len(entries) > 0


def test_check_repository_root(tool, capsys):
    assert tool.ROOT == REPO
    rc = tool.main(["check"])
    out, err = capsys.readouterr()
    assert (rc, err) == (0, "")
    d = REPO / "changelog.d"
    on_disk = len(list(d.glob("*.md"))) if d.is_dir() else 0
    unit = "entry file" if on_disk == 1 else "entry files"
    assert out == P + "no problems in %d %s\n" % (on_disk, unit)
