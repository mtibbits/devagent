#!/usr/bin/env python3
"""`wbs exclude`'s entry point (#761): add one `<!-- wbs-exclude: ... -->`
line to WBS.md, after checking every id.

scripts/wbs-exclude.sh resolves the project and runs this twice: `validate`
before it takes the devDoc lock, then `write` under the lock. The ids come
on stdin, each NUL-terminated, so an id holding a newline arrives whole and
is refused whole. The sources come from the environment:
WBS_EXCL_{ORIGIN,FORK}_{BACKEND,REPO,PREFIX} (`issue_source` and
`issue_source_fork`), WBS_EXCL_PROJECT, and WBS_PATH (`write` only).

`validate` checks each id against the exclusion grammar (wbs-parser.py
`ID_TOKEN_RE`), then against the configured sources with the shared resolver
(wbs-tracker.py `parse_leaf`). No tracker is called. A refusal names every
bad id, then `nothing written`, and exits 2.

`write` checks the ids again, folds ids that name one issue, and skips ids
an existing exclusion line already lists. Both use wbs-tracker.py
`same_issue`, the rule `wbs update` reads exclusion lines with. It renders
the line with wbs-parser.py `insert_exclusion`, then writes only when two
postconditions hold: the text gained whole lines only (`inserted_only`), and
a re-parse lists the old ids plus exactly the new ones, with no new grammar
warning. The one write is wbs-parser.py `write_document`. It never prints
the existing `exclusion_warnings`: `wbs init --merge` reports those.

Output: stderr only, ASCII, each line prefixed `wbs exclude: `, except the
parser's own `wbs-parser: unclosed code fence ...` warning; stdout stays
empty. Exit: 0 written, or nothing to do; 1 a WBS.md that cannot be read or
is not UTF-8, a failed postcondition, or a failed write (nothing written);
2 a refused id or a usage error.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import re
import sys
from collections import Counter
from collections.abc import Mapping, Sequence
from pathlib import Path
from types import ModuleType

HERE = Path(__file__).resolve().parent
SAY_PREFIX = "wbs exclude: "
USAGE = "usage: wbs-exclude.py validate|write  (NUL-terminated ids on stdin)"
NOTHING_WRITTEN = "nothing written"
LINE_NO_RE = re.compile(r"^line [0-9]+: ")


def _load(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


psr = _load("wbs_parser", HERE / "wbs-parser.py")
trk = _load("wbs_tracker", HERE / "wbs-tracker.py")


def _say(msg: str) -> None:
    # ASCII only: a cp1252 stderr must not crash the run
    print(msg.encode("ascii", "replace").decode("ascii"), file=sys.stderr)


def config_sources(env: Mapping[str, str]) -> list[dict]:
    """The configured sources, origin first, as wbs-tracker.py's codec reads
    them. A source counts only when its backend, repo and dir_prefix are all
    set, as `wbs update` requires. On Jira, `keyprefix` follows the backend's
    key-prefix rule (wbs-tracker.py `jira_keyprefix`) over `env`."""
    out = []
    for s in ("ORIGIN", "FORK"):
        backend, repo, prefix = (env.get(f"WBS_EXCL_{s}_{k}", "")
                                 for k in ("BACKEND", "REPO", "PREFIX"))
        if not (backend and repo and prefix):
            continue
        keyprefix = trk.jira_keyprefix(env, repo) if backend == "jira" else ""
        out.append({"prefix": prefix, "backend": backend, "keyprefix": keyprefix})
    return out


def read_ids(data: bytes) -> list[str]:
    """NUL-terminated ids. An empty argument stays an empty id, to be refused."""
    parts = data.split(b"\0")
    if parts and parts[-1] == b"":
        parts.pop()
    return [p.decode("utf-8", "surrogateescape") for p in parts]


def check_ids(sources: Sequence[Mapping[str, str]], ids: Sequence[str],
              project: str) -> list[str]:
    """The refusal lines, unprefixed, in input order; [] when every id is good.

    The grammar comes first. With no configured source, the per-id source
    lines become one config-gap line, after the grammar lines, when any id
    passed the grammar."""
    out = []
    gap = False
    for iid in ids:
        if not psr.ID_TOKEN_RE.fullmatch(iid):
            out.append(f"{ascii(iid)} is not an issue id")
        elif not sources:
            gap = True
        elif trk.parse_leaf(sources, iid) is None:
            out.append(f"{ascii(iid)} names no configured issue source")
    if gap:
        out.append(f"no issue source of {project} has backend, repo and dir_prefix set")
    return out


def fold(sources: Sequence[Mapping[str, str]], ids: Sequence[str]) -> list[str]:
    """The first spelling of each issue, in input order (`same_issue`)."""
    out: list[str] = []
    for iid in ids:
        if not any(trk.same_issue(sources, kept, iid) for kept in out):
            out.append(iid)
    return out


def _unnumbered(warnings: Sequence[str]) -> Counter:
    return Counter(LINE_NO_RE.sub("", w) for w in warnings)


def exclude(path: str, ids: list[str], sources: list[dict]) -> tuple[int, list[str]]:
    """Add the ids WBS.md does not yet list: `(rc, report lines unprefixed)`."""
    try:
        old = psr.parse_file(path)
    except (OSError, UnicodeDecodeError) as e:
        return 1, [f"cannot read {path}: {e}"]
    text = old["source_text"]
    old_ids = [iid for _ln, iid in old["exclusions"]]
    wanted = fold(sources, ids)
    listed = [i for i in wanted if any(trk.same_issue(sources, x, i) for x in old_ids)]
    new_ids = [i for i in wanted if i not in listed]
    if not new_ids:
        return 0, [f"nothing to exclude; {', '.join(listed)} already listed"]
    new = psr.insert_exclusion(text, new_ids)
    if not psr.inserted_only(text, new):
        return 1, [f"refusing to write {path}: an existing line would change "
                   "(a bug; please report); nothing written"]
    with contextlib.redirect_stderr(io.StringIO()):
        after = psr.parse_text(new)
    took = Counter(i for _ln, i in after["exclusions"]) == Counter(old_ids) + Counter(new_ids)
    if not took or (_unnumbered(after["exclusion_warnings"])
                    != _unnumbered(old["exclusion_warnings"])):
        return 1, [f"refusing to write {path}: the new line would not take effect "
                   "(a bug; please report); nothing written"]
    try:
        psr.write_document(path, new)
    except OSError as e:
        return 1, [f"cannot write {path}: {e}"]
    report = f"excluded {', '.join(new_ids)} in {path}"
    if listed:
        report += f"; {', '.join(listed)} already listed"
    return 0, [report]


def main(argv: list[str]) -> int:
    mode = argv[1] if len(argv) == 2 else None
    if mode not in ("validate", "write") or (mode == "write" and not os.environ.get("WBS_PATH")):
        _say(USAGE)
        return 2
    ids = read_ids(sys.stdin.buffer.read())
    if not ids:
        _say(SAY_PREFIX + "no issue id given")
        return 2
    sources = config_sources(os.environ)
    bad = check_ids(sources, ids, os.environ.get("WBS_EXCL_PROJECT", ""))
    if bad:
        for line in bad + [NOTHING_WRITTEN]:
            _say(SAY_PREFIX + line)
        return 2
    if mode == "validate":
        return 0
    rc, report = exclude(os.environ["WBS_PATH"], ids, sources)
    for line in report:
        _say(SAY_PREFIX + line)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
