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
import re
import shlex
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


def _span(lines, start):
    """lines[start:] up to the next line starting `## ` after start (exclusive)."""
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    return lines[start:end]


def _section(lines, version):
    """The lines of `## [<version>]` from its first col-0 `- **` line to the next `## `."""
    start = next(i for i, ln in enumerate(lines) if ln.startswith("## [%s]" % version))
    body = _span(lines, start)[1:]
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


# --- release and preview -----------------------------------------------------------

HEADER = "# Changelog\n\nHeader paragraph.\n\n"
CARRIED = (
    "- **Fixed: carried one (#7).** First carried entry\n"
    "  wrapped onto a second line.\n"
    "\n"
    "- **Docs: carried two (#6).** Second carried entry.\n"
)
OLDER = (
    "## [1.0.0] — 2026-01-01\n"
    "\n"
    "The first release opens with prose.\n"
    "\n"
    "- **Added: the start (#1).** Old entry.\n"
)
CHANGELOG = HEADER + "## [Unreleased]\n\n" + CARRIED + "\n" + OLDER
E10 = (
    "- **Added: ten (#10).** Ten.\n"
    "\n"
    "- **Changed (breaking): ten moves (#10).** It\n"
    "  moves.\n"
    "\n"
    "  **Migration:** do the new thing.\n"
)
E9 = "- **Fixed: nine (#9).** Nine.\n"
EDOCS = "- **Docs: a docs pass.** Docs.\n"
EAGENTS = "- **Changed: an agents note.** Note.\n"
FILES = {"9.md": E9, "10.md": E10, "docs-pass.md": EDOCS, "agents-note.md": EAGENTS}
INTRO = "\nFirst paragraph of the\nintro.\n\nSecond paragraph.\n\n"
NEW_ENTRIES = E10 + "\n" + E9 + "\n" + EAGENTS + "\n" + EDOCS + "\n" + CARRIED
HEADING = "## [9.9.9] — 2026-12-01\n"
EXPECTED = (
    HEADER
    + "## [Unreleased]\n\n"
    + HEADING
    + "\n"
    + "First paragraph of the\nintro.\n\nSecond paragraph.\n\n"
    + NEW_ENTRIES
    + "\n"
    + OLDER
)


def _fixture(tmp, changelog=CHANGELOG, files=FILES):
    _write(tmp / "CHANGELOG.md", changelog)
    _write(tmp / "keep.txt", "not an entry\n")
    if files is not None:
        _entries(tmp, files)
    return tmp


def _snapshot(tmp):
    return {
        str(p.relative_to(tmp)): (p.read_bytes() if p.is_file() else None)
        for p in sorted(tmp.rglob("*"))
    }


def test_release_fixture(tool, tmp_path, capsys):
    _fixture(tmp_path)
    _write(tmp_path / "intro.md", INTRO)
    intro = str(tmp_path / "intro.md")
    rc, out, err = _run(tool, tmp_path, capsys, "release", "9.9.9", "2026-12-01", "--intro", intro)
    assert (rc, err) == (0, "")
    assert out == P + "wrote ## [9.9.9] — 2026-12-01: 7 entries, 4 entry files deleted\n"
    assert (tmp_path / "CHANGELOG.md").read_text(encoding="utf-8") == EXPECTED
    assert (tmp_path / "changelog.d").is_dir()
    assert list((tmp_path / "changelog.d").iterdir()) == []
    assert sorted(p.name for p in tmp_path.iterdir()) == [
        "CHANGELOG.md",
        "changelog.d",
        "intro.md",
        "keep.txt",
    ]


def test_release_without_intro(tool, tmp_path, capsys):
    _fixture(tmp_path)
    rc, out, err = _run(tool, tmp_path, capsys, "release", "9.9.9", "2026-12-01")
    assert (rc, err) == (0, "")
    text = (tmp_path / "CHANGELOG.md").read_text(encoding="utf-8")
    assert text == HEADER + "## [Unreleased]\n\n" + HEADING + "\n" + NEW_ENTRIES + "\n" + OLDER


def test_release_no_newer_section(tool, tmp_path, capsys):
    _fixture(tmp_path, changelog=HEADER + "## [Unreleased]\n", files={"1.md": ENTRY})
    rc, out, err = _run(tool, tmp_path, capsys, "release", "9.9.9", "2026-12-01")
    assert (rc, err) == (0, "")
    assert out == P + "wrote ## [9.9.9] — 2026-12-01: 1 entry, 1 entry file deleted\n"
    text = (tmp_path / "CHANGELOG.md").read_text(encoding="utf-8")
    assert text == HEADER + "## [Unreleased]\n\n" + HEADING + "\n" + ENTRY


def test_release_carried_entries_only(tool, tmp_path, capsys):
    _fixture(tmp_path, files=None)
    rc, out, err = _run(tool, tmp_path, capsys, "release", "9.9.9", "2026-12-01")
    assert (rc, err) == (0, "")
    assert out == P + "wrote ## [9.9.9] — 2026-12-01: 2 entries, 0 entry files deleted\n"
    text = (tmp_path / "CHANGELOG.md").read_text(encoding="utf-8")
    assert text == HEADER + "## [Unreleased]\n\n" + HEADING + "\n" + CARRIED + "\n" + OLDER


EXISTS_NEWEST = (
    "CHANGELOG.md already has a section for 9.9.9; add to it with release 9.9.9 "
    "--fold before it is tagged, or release a new version"
)
UNRELEASED_PROSE = HEADER + "## [Unreleased]\n\n" + CARRIED + "\nSome prose.\n\n" + OLDER
UNRELEASED_HEADING = HEADER + "## [Unreleased]\n\n### Added\n\n" + CARRIED + "\n" + OLDER
NOTHING = "nothing is waiting: no entry files in changelog.d/ and no entries under ## [Unreleased]"
# A second heading's entries would sit outside the span every command reads, so a
# release would leave them unreleased while preview reported nothing waiting.
DUP_UNRELEASED = HEADER + "## [Unreleased]\n\n" + E9 + "\n## [Unreleased]\n\n" + CARRIED + "\n" + OLDER
SECOND_UNRELEASED = (
    "CHANGELOG.md line 9: a second '## [Unreleased]' line; move its entries under "
    "the first and delete it"
)
REFUSALS = {
    "second-unreleased": ({"changelog": DUP_UNRELEASED}, ["9.9.9", "2026-12-01"], [SECOND_UNRELEASED]),
    "exists": (
        {"changelog": HEADER + "## [Unreleased]\n\n" + HEADING + "\n" + ENTRY + "\n" + OLDER},
        ["9.9.9", "2026-12-01"],
        [EXISTS_NEWEST],
    ),
    "exists-not-newest": (
        {
            "changelog": HEADER
            + "## [Unreleased]\n\n"
            + CARRIED
            + "\n## [2.0.0] — 2026-06-01\n\n- **Added: two.**\n\n"
            + OLDER
        },
        ["1.0.0", "2026-12-01"],
        ["CHANGELOG.md already has a section for 1.0.0; release a new version"],
    ),
    "version-shape": ({}, ["9.9", "2026-12-01"], ["'9.9' is not a plain X.Y.Z version"]),
    "version-leading-zero": ({}, ["09.9.9", "2026-12-01"], ["'09.9.9' is not a plain X.Y.Z version"]),
    "version-prerelease": ({}, ["9.9.9-rc1", "2026-12-01"], ["'9.9.9-rc1' is not a plain X.Y.Z version"]),
    "date-shape": ({}, ["9.9.9", "2026-12-1"], ["'2026-12-1' is not a YYYY-MM-DD date"]),
    "date-calendar": ({}, ["9.9.9", "2026-02-30"], ["'2026-02-30' is not a YYYY-MM-DD date"]),
    "no-unreleased": (
        {"changelog": HEADER + OLDER},
        ["9.9.9", "2026-12-01"],
        ["CHANGELOG.md has no '## [Unreleased]' line"],
    ),
    "nothing-waiting": (
        {"changelog": HEADER + "## [Unreleased]\n\n" + OLDER, "files": None},
        ["9.9.9", "2026-12-01"],
        [NOTHING],
    ),
    "check-fails": (
        {"files": dict(FILES, **{"012.md": ENTRY})},
        ["9.9.9", "2026-12-01"],
        [
            "changelog.d/012.md: the issue number has a leading zero",
            "release refused: fix the changelog.d/ problems above",
        ],
    ),
    "unreleased-prose": (
        {"changelog": UNRELEASED_PROSE},
        ["9.9.9", "2026-12-01"],
        ["CHANGELOG.md line 12: prose outside an entry under ## [Unreleased]"],
    ),
    "unreleased-heading": (
        {"changelog": UNRELEASED_HEADING},
        ["9.9.9", "2026-12-01"],
        ["CHANGELOG.md line 7: a heading under ## [Unreleased]"],
    ),
}


@pytest.mark.parametrize("case", sorted(REFUSALS))
def test_release_refuses(tool, tmp_path, capsys, case):
    kwargs, args, messages = REFUSALS[case]
    _fixture(tmp_path, **kwargs)
    before = _snapshot(tmp_path)
    rc, out, err = _run(tool, tmp_path, capsys, "release", *args)
    assert (rc, out) == (1, "")
    assert err.splitlines() == [P + m for m in messages]
    assert _snapshot(tmp_path) == before


def test_release_refusal_order(tool, tmp_path, capsys):
    # A bad version is reported before anything is read, even with nothing waiting.
    _fixture(tmp_path, changelog=HEADER + OLDER, files=None)
    rc, out, err = _run(tool, tmp_path, capsys, "release", "9.9", "bad")
    assert (rc, err) == (1, P + "'9.9' is not a plain X.Y.Z version\n")


INTRO_REFUSALS = {
    "missing": (None, "could not read (No such file or directory)"),
    "empty": ("\n\n", "empty"),
    "heading": ("A paragraph.\n\n# Heading\n", "line 3 is a heading or an entry's first line; the intro is prose"),
    "entry": ("- **Added: x.**\n", "line 1 is a heading or an entry's first line; the intro is prose"),
}


@pytest.mark.parametrize("case", sorted(INTRO_REFUSALS))
def test_release_intro_refuses(tool, tmp_path, capsys, case):
    body, reason = INTRO_REFUSALS[case]
    _fixture(tmp_path)
    intro = tmp_path / "intro.md"
    if body is not None:
        _write(intro, body)
    before = _snapshot(tmp_path)
    rc, out, err = _run(tool, tmp_path, capsys, "release", "9.9.9", "2026-12-01", "--intro", str(intro))
    assert (rc, out) == (1, "")
    assert err == P + "--intro %s: %s\n" % (intro, reason)
    assert _snapshot(tmp_path) == before


USAGE = {
    "no-date": (["release", "9.9.9"], "release needs a <date>, or --fold"),
    "fold-with-date": (
        ["release", "9.9.9", "2026-12-01", "--fold"],
        "release --fold takes no date; the section keeps its own",
    ),
    "fold-with-intro": (
        ["release", "9.9.9", "--fold", "--intro", "x.md"],
        "release --fold takes no --intro; the section keeps its opening prose",
    ),
    "unknown-command": (["relase", "9.9.9", "2026-12-01"], "invalid choice: 'relase'"),
    "abbreviated-flag": (["release", "9.9.9", "--fo"], "unrecognized arguments: --fo"),
}


@pytest.mark.parametrize("case", sorted(USAGE))
def test_usage_errors(tool, tmp_path, capsys, case):
    argv, message = USAGE[case]
    _fixture(tmp_path)
    before = _snapshot(tmp_path)
    rc, out, err = _run(tool, tmp_path, capsys, *argv)
    assert rc == 2
    assert message in err
    assert _snapshot(tmp_path) == before


def test_preview_matches_release(tool, tmp_path, capsys):
    a = _fixture(tmp_path / "a")
    b = _fixture(tmp_path / "b")
    rc, preview, err = _run(tool, a, capsys, "preview")
    assert (rc, err) == (0, "")
    rc, _out, err = _run(tool, b, capsys, "release", "9.9.9", "2026-12-01")
    assert (rc, err) == (0, "")
    released = (b / "CHANGELOG.md").read_text(encoding="utf-8")
    body = released.split(HEADING + "\n", 1)[1].split("\n\n## [1.0.0]", 1)[0]
    assert preview == "## [Unreleased]\n\n" + body + "\n"
    assert preview == "## [Unreleased]\n\n" + NEW_ENTRIES


def test_preview_order_is_numeric_then_slug(tool, tmp_path, capsys):
    files = {
        name: "- **Fixed: %s.**\n" % name[:-3]
        for name in ("9.md", "100.md", "1100.md", "20.md", "b-note.md", "a-note.md")
    }
    _fixture(tmp_path, changelog=HEADER + "## [Unreleased]\n", files=files)
    rc, out, err = _run(tool, tmp_path, capsys, "preview")
    assert (rc, err) == (0, "")
    order = [ln[len("- **Fixed: ") : -len(".**")] for ln in out.splitlines() if ln.startswith("- ")]
    assert order == ["1100", "100", "20", "9", "a-note", "b-note"]


def test_preview_nothing_waiting(tool, tmp_path, capsys):
    _fixture(tmp_path, changelog=HEADER + "## [Unreleased]\n\n" + OLDER, files=None)
    rc, out, err = _run(tool, tmp_path, capsys, "preview")
    assert (rc, out, err) == (0, "## [Unreleased]\n", "")


def test_preview_changes_nothing(tool, tmp_path, capsys):
    _fixture(tmp_path)
    before = _snapshot(tmp_path)
    rc, out, err = _run(tool, tmp_path, capsys, "preview")
    assert rc == 0
    assert _snapshot(tmp_path) == before


PREVIEW_REFUSALS = {
    "check-fails": (
        {"files": dict(FILES, **{"012.md": ENTRY})},
        [
            "changelog.d/012.md: the issue number has a leading zero",
            "preview refused: fix the changelog.d/ problems above",
        ],
    ),
    "unreleased-prose": (
        {"changelog": UNRELEASED_PROSE},
        ["CHANGELOG.md line 12: prose outside an entry under ## [Unreleased]"],
    ),
    # preview is README's tag gate: it must fail closed, never print a bare heading
    # while release would refuse (final review, Issue-1127).
    "unreleased-trailing-space": (
        {"changelog": HEADER + "## [Unreleased] \n\n" + CARRIED + "\n" + OLDER},
        ["CHANGELOG.md has no '## [Unreleased]' line"],
    ),
    "no-unreleased": ({"changelog": HEADER + OLDER}, ["CHANGELOG.md has no '## [Unreleased]' line"]),
    "second-unreleased": ({"changelog": DUP_UNRELEASED}, [SECOND_UNRELEASED]),
}


@pytest.mark.parametrize("case", sorted(PREVIEW_REFUSALS))
def test_preview_refuses(tool, tmp_path, capsys, case):
    kwargs, messages = PREVIEW_REFUSALS[case]
    _fixture(tmp_path, **kwargs)
    rc, out, err = _run(tool, tmp_path, capsys, "preview")
    assert (rc, out) == (1, "")
    assert err.splitlines() == [P + m for m in messages]


def test_versioning_section_check_after_release(tool, tmp_path, capsys, monkeypatch):
    import test_plugin_versioning

    _fixture(tmp_path)
    _write(tmp_path / ".claude-plugin" / "plugin.json", '{"version": "9.9.9"}\n')
    monkeypatch.setattr(test_plugin_versioning, "_REPO", str(tmp_path))
    with pytest.raises(AssertionError):
        test_plugin_versioning.test_changelog_has_section_for_plugin_version()
    rc, _out, err = _run(tool, tmp_path, capsys, "release", "9.9.9", "2026-12-01")
    assert (rc, err) == (0, "")
    test_plugin_versioning.test_changelog_has_section_for_plugin_version()


def _crlf(text):
    return text.replace("\n", "\r\n")


def test_release_writes_lf(tool, tmp_path, capsys):
    _fixture(tmp_path, changelog=_crlf(CHANGELOG), files={k: _crlf(v) for k, v in FILES.items()})
    _write(tmp_path / "intro.md", _crlf(INTRO))
    rc, out, err = _run(
        tool, tmp_path, capsys, "release", "9.9.9", "2026-12-01", "--intro", str(tmp_path / "intro.md")
    )
    assert (rc, err) == (0, "")
    data = (tmp_path / "CHANGELOG.md").read_bytes()
    assert b"\r" not in data
    assert data.decode("utf-8") == EXPECTED


def test_release_unlink_failure_names_files(tool, tmp_path, capsys, monkeypatch):
    _fixture(tmp_path)
    real = Path.unlink

    def unlink(self, *args, **kwargs):
        if self.name == "9.md":
            raise PermissionError(13, "Permission denied", str(self))
        return real(self, *args, **kwargs)

    monkeypatch.setattr(Path, "unlink", unlink)
    rc, out, err = _run(tool, tmp_path, capsys, "release", "9.9.9", "2026-12-01")
    assert (rc, out) == (3, "")
    assert err == P + (
        "the release is written; delete these files by hand — do not re-run "
        "release or --fold: changelog.d/9.md\n"
    )
    assert HEADING in (tmp_path / "CHANGELOG.md").read_text(encoding="utf-8")
    assert sorted(p.name for p in (tmp_path / "changelog.d").iterdir()) == ["9.md"]


def test_release_write_failure_restores(tool, tmp_path, capsys, monkeypatch):
    _fixture(tmp_path)
    before = _snapshot(tmp_path)
    real = Path.write_bytes
    calls = []

    def write_bytes(self, data):
        calls.append(self.name)
        if len(calls) == 1:
            real(self, data[:10])
            raise OSError(28, "No space left on device", str(self))
        return real(self, data)

    monkeypatch.setattr(Path, "write_bytes", write_bytes)
    rc, out, err = _run(tool, tmp_path, capsys, "release", "9.9.9", "2026-12-01")
    assert (rc, out) == (1, "")
    assert err == P + (
        "could not write CHANGELOG.md (No space left on device); it is restored "
        "and no entry file is deleted\n"
    )
    assert calls == ["CHANGELOG.md", "CHANGELOG.md"]
    assert _snapshot(tmp_path) == before


def test_release_write_refused_leaves_file_unchanged(tool, tmp_path, capsys, monkeypatch):
    # A read-only or locked CHANGELOG.md: open() fails, nothing was touched.
    _fixture(tmp_path)
    before = _snapshot(tmp_path)

    def write_bytes(self, data):
        raise PermissionError(13, "Permission denied", str(self))

    monkeypatch.setattr(Path, "write_bytes", write_bytes)
    rc, out, err = _run(tool, tmp_path, capsys, "release", "9.9.9", "2026-12-01")
    assert (rc, out) == (1, "")
    assert err == P + (
        "could not write CHANGELOG.md (Permission denied); it is unchanged and no "
        "entry file is deleted\n"
    )
    assert _snapshot(tmp_path) == before


def test_release_write_and_restore_fail_exits_3(tool, tmp_path, capsys, monkeypatch):
    # Exit 1 promises nothing changed; a truncated file the restore could not undo
    # is a partial state, so it exits 3 like a failed delete.
    _fixture(tmp_path)
    real = Path.write_bytes

    def write_bytes(self, data):
        real(self, data[:10])
        raise OSError(28, "No space left on device", str(self))

    monkeypatch.setattr(Path, "write_bytes", write_bytes)
    rc, out, err = _run(tool, tmp_path, capsys, "release", "9.9.9", "2026-12-01")
    assert (rc, out) == (3, "")
    assert err == P + (
        "could not write CHANGELOG.md (No space left on device) nor restore it; "
        "compare it with git before anything else — no entry file is deleted\n"
    )
    assert sorted(p.name for p in (tmp_path / "changelog.d").iterdir()) == sorted(FILES)


# --- release --fold ----------------------------------------------------------------

E11 = "- **Added: eleven (#11).** Eleven.\n"
E_CARRIED = "- **Fixed: carried (#8).** Carried.\n"
FOLD_SECTION = (
    HEADING + "\nThe release opens with prose.\n\n- **Added: first (#5).** First.\n"
)
FOLD_CHANGELOG = HEADER + "## [Unreleased]\n\n" + E_CARRIED + "\n" + FOLD_SECTION + "\n" + OLDER


def test_fold_fixture(tool, tmp_path, capsys):
    _fixture(tmp_path, changelog=FOLD_CHANGELOG, files={"11.md": E11})
    rc, out, err = _run(tool, tmp_path, capsys, "release", "9.9.9", "--fold")
    assert (rc, err) == (0, "")
    assert out == P + "folded 2 entries into ## [9.9.9] — 2026-12-01: 1 entry file deleted\n"
    assert (tmp_path / "CHANGELOG.md").read_text(encoding="utf-8") == (
        HEADER
        + "## [Unreleased]\n\n"
        + HEADING
        + "\nThe release opens with prose.\n\n"
        + E11
        + "\n"
        + E_CARRIED
        + "\n- **Added: first (#5).** First.\n\n"
        + OLDER
    )
    assert list((tmp_path / "changelog.d").iterdir()) == []
    assert (tmp_path / "keep.txt").exists()


NOT_NEWEST = "--fold adds only to the newest dated section, which is %s, not %s; release a new version instead"
FOLD_NOT_NEWEST = {
    "older": ({}, "1.0.0", NOT_NEWEST % ("9.9.9", "1.0.0")),
    "absent": ({}, "4.0.0", NOT_NEWEST % ("9.9.9", "4.0.0")),
    "no-dated-section": (
        {"changelog": HEADER + "## [Unreleased]\n\n" + E_CARRIED},
        "9.9.9",
        NOT_NEWEST % ("none", "9.9.9"),
    ),
}


@pytest.mark.parametrize("case", sorted(FOLD_NOT_NEWEST))
def test_fold_refuses_not_newest(tool, tmp_path, capsys, case):
    kwargs, version, message = FOLD_NOT_NEWEST[case]
    kwargs = dict({"changelog": FOLD_CHANGELOG, "files": {"11.md": E11}}, **kwargs)
    _fixture(tmp_path, **kwargs)
    before = _snapshot(tmp_path)
    rc, out, err = _run(tool, tmp_path, capsys, "release", version, "--fold")
    assert (rc, out, err) == (1, "", P + message + "\n")
    assert _snapshot(tmp_path) == before


def test_fold_section_without_entries(tool, tmp_path, capsys):
    # The older section has entries: an unbounded first-entry search would land there.
    changelog = HEADER + "## [Unreleased]\n\n" + HEADING + "\nProse only.\n\n\n" + OLDER
    _fixture(tmp_path, changelog=changelog, files={"11.md": E11, "docs-pass.md": EDOCS})
    rc, out, err = _run(tool, tmp_path, capsys, "release", "9.9.9", "--fold")
    assert (rc, err) == (0, "")
    assert (tmp_path / "CHANGELOG.md").read_text(encoding="utf-8") == (
        HEADER + "## [Unreleased]\n\n" + HEADING + "\nProse only.\n\n" + E11 + "\n" + EDOCS + "\n" + OLDER
    )


def test_fold_empty_section_at_end(tool, tmp_path, capsys):
    _fixture(tmp_path, changelog=HEADER + "## [Unreleased]\n\n" + HEADING, files={"11.md": E11})
    rc, out, err = _run(tool, tmp_path, capsys, "release", "9.9.9", "--fold")
    assert (rc, err) == (0, "")
    assert (tmp_path / "CHANGELOG.md").read_text(encoding="utf-8") == (
        HEADER + "## [Unreleased]\n\n" + HEADING + "\n" + E11
    )


FOLD_REFUSALS = {
    "second-unreleased": ({"changelog": DUP_UNRELEASED}, "9.9.9", [SECOND_UNRELEASED]),
    "nothing-waiting": (
        {"changelog": HEADER + "## [Unreleased]\n\n" + FOLD_SECTION, "files": None},
        "9.9.9",
        [NOTHING],
    ),
    "check-fails": (
        {"files": {"11.md": E11, "012.md": ENTRY}},
        "9.9.9",
        [
            "changelog.d/012.md: the issue number has a leading zero",
            "release refused: fix the changelog.d/ problems above",
        ],
    ),
    "version-shape": ({}, "9.9", ["'9.9' is not a plain X.Y.Z version"]),
    "no-unreleased": (
        {"changelog": HEADER + FOLD_SECTION},
        "9.9.9",
        ["CHANGELOG.md has no '## [Unreleased]' line"],
    ),
    "unreleased-prose": (
        {"changelog": HEADER + "## [Unreleased]\n\nSome prose.\n\n" + FOLD_SECTION},
        "9.9.9",
        ["CHANGELOG.md line 7: prose outside an entry under ## [Unreleased]"],
    ),
}


@pytest.mark.parametrize("case", sorted(FOLD_REFUSALS))
def test_fold_refuses(tool, tmp_path, capsys, case):
    kwargs, version, messages = FOLD_REFUSALS[case]
    kwargs = dict({"changelog": FOLD_CHANGELOG, "files": {"11.md": E11}}, **kwargs)
    _fixture(tmp_path, **kwargs)
    before = _snapshot(tmp_path)
    rc, out, err = _run(tool, tmp_path, capsys, "release", version, "--fold")
    assert (rc, out) == (1, "")
    assert err.splitlines() == [P + m for m in messages]
    assert _snapshot(tmp_path) == before


# --- docs --------------------------------------------------------------------------


def _flat(text):
    return " ".join(text.split())


def _md_section(path, heading):
    """The text from the line `heading` to the next line starting `## ` (exclusive)."""
    lines = path.read_text(encoding="utf-8").split("\n")
    return "\n".join(_span(lines, lines.index(heading)))


def test_docs_state_changelog_rules():
    # (a) CHANGELOG.md's header paragraph says where new entries go; nothing sits
    # between it and `## [Unreleased]` but a blank line, and no pointer line follows
    # the heading (open pull requests insert there).
    lines = (REPO / "CHANGELOG.md").read_text(encoding="utf-8").split("\n")
    u = lines.index("## [Unreleased]")
    header = _flat("\n".join(lines[:u]))
    assert "changelog.d/" in header
    assert '"Versioning & releases"' in header
    assert lines[u - 1] == "" and lines[u + 1] == ""
    assert [ln for ln in lines[:u] if ln.startswith("## ")] == []
    # (b) CONTRIBUTING states both rules.
    contributing = _flat(_md_section(REPO / "CONTRIBUTING.md", "## Conventions every change follows"))
    assert "changelog.d/" in contributing
    assert "tests/lib/changelog-text.bash" in contributing
    # (c) README's release section names the files, the tool and every command.
    readme = _flat(_md_section(REPO / "README.md", "## Versioning & releases"))
    for token in (
        "changelog.d/<issue>.md",
        "scripts/changelog.py check",
        "scripts/changelog.py release",
        "scripts/changelog.py preview",
        "--fold",
        "--intro",
    ):
        assert token in readme, token
    # (d) the spec's directory tree has rows for the folder and the tool.
    spec = (REPO / "docs" / "specs" / "2026-05-19-devagent-plugin-design.md").read_text(encoding="utf-8")
    tree = spec.split("\n### 3.1 ", 1)[1].split("\n### 3.2 ", 1)[0]
    assert "├── changelog.d/" in tree
    assert "changelog.py (#1127)" in tree


SUBSTITUTE = {"<version>": "9.9.9", "<date>": "2026-12-01", "<file>": "intro.md", "<issue>": "1"}


def _readme_commands():
    text = (REPO / "README.md").read_text(encoding="utf-8")
    spans = re.findall(r"`(python3\s+scripts/changelog\.py\s[^`]*)`", text)
    fenced = re.findall(r"^\s*(python3 scripts/changelog\.py .*)$", text, re.M)
    return [_flat(c) for c in spans + fenced]


def test_readme_changelog_commands_parse(tool):
    commands = _readme_commands()
    assert len(commands) >= 3, commands
    kinds = set()
    for command in commands:
        for token, value in SUBSTITUTE.items():
            command = command.replace(token, value)
        argv = shlex.split(command)[2:]
        try:
            ns = tool.validate_args(tool.build_parser().parse_args(argv))
        except SystemExit:
            pytest.fail("README command does not parse: %s" % command)
        if ns.command == "release":
            kinds.add("fold" if ns.fold else "release")
        else:
            kinds.add(ns.command)
    assert kinds == {"check", "preview", "release", "fold"}
