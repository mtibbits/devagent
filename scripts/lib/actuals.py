#!/usr/bin/env python3
"""actuals.py — #735. Build the per-issue actuals document: cost-report's tokens,
time and overhead joined with milestones.sh's dated events, per (project, issue),
in one versioned, deterministic JSON file the portfolio reads.

    actuals.py preflight [--archive DIR] [--project P] [--out PATH | --stdout] [--if-stale]
    actuals.py build     [--archive DIR] [--project P] [--out PATH | --stdout]

scripts/actuals.sh parses the flags, runs `preflight`, runs
`milestones.sh <p> --all --json` once per project, then `build`. The milestones
results arrive in an ACTUALS_* manifest (the wrapper unsets every inherited
ACTUALS_* first): ACTUALS_MS_COUNT, then per project i (0-based)
ACTUALS_MS_<i>_PROJECT, ACTUALS_MS_<i>_RC (the exit status) and
ACTUALS_MS_<i>_OUT / ACTUALS_MS_<i>_ERR (paths of the captured stdout/stderr).

Inputs. --archive DIR reads only that scripts/archive-transcripts.sh archive.
Without it: every live transcript dir under <CLAUDE_CONFIG_DIR or ~/.claude>/projects,
plus [archive].transcripts_dir when the table is configured and accepted, in one
cost-report collect() pass (one message-id set: a call is counted once however
many copies are read). This host's own archive partition is skipped per cwd dir
when every file in it is still live. A source that cannot be read is a `sources`
row, never a failure.

preflight exits 0 go, 3 fresh (--if-stale: <devagent_home>/actuals.json is a
usable document younger than [archive].actuals_max_age_hours), 1 the config
cannot be read, 2 refused (--archive not a directory, an --out under a
project's dir or inside a git work tree, a refused actuals_max_age_hours).
build exits 0 written or printed, 1 or 2 likewise; nothing is written on 1 or 2.

Standard library only. commands/actuals.md is the user doc; the slot shapes
are the portfolio schema's (docs/portfolio-schema.md, "Actuals").
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
from collections.abc import Mapping
from datetime import datetime, timezone
from pathlib import Path

LIB = Path(__file__).resolve().parent
PROG = "actuals"
EXIT_GO, EXIT_CONFIG, EXIT_REFUSED, EXIT_FRESH = 0, 1, 2, 3
OUT_IN_REPO = ("--out", "the document lists project names, session ids and cwd paths")
TIME_KEYS = ("agent_busy_s", "agent_wall_s", "operator_s", "operator_events", "returns_after_absence",
             "fallback_events")
TOKEN_KEYS = ("main", "subagents", "total", "raw")


def _load_archive():
    spec = importlib.util.spec_from_file_location("_actuals_archive", LIB / "archive-transcripts.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


# One instance of each sibling: archive-transcripts' own loader, under its names.
at = _load_archive()
cr = at._cost_report()
pf = at._lib("_archive_portfolio", "portfolio.py")
pc = pf.pc
STAMP = pc.ACTUALS_STAMP_FORMAT
NO_PAIR = (cr.NO_PROJECT, cr.NO_ISSUE)

ACTUALS_VERSION = pc.ACTUALS_READER


class Refused(Exception):
    """Exit 2, nothing written."""


class ConfigError(Exception):
    """Exit 1: the config cannot be read."""


def _say(stream, line: str) -> None:
    """One line as UTF-8 bytes, whatever the locale codec (a path may not fit it)."""
    stream.buffer.write((line + "\n").encode("utf-8"))
    stream.flush()


def default_out() -> Path:
    """<devagent_home>/actuals.json, devagent_home as scripts/lib/paths.sh resolves it."""
    return at.config_path().parent / "actuals.json"


def check_out(out: Path) -> None:
    """Refuse an --out under a configured project dir, or inside a git work tree (it fails closed)."""
    for d, name in cr.project_dirs(cr._project_tables()):
        if pf._is_under(out, d):
            raise Refused(f"refusing to write under a directory of project '{name}' ({d})")
    try:
        at._git_check(os.path.realpath(out), OUT_IN_REPO)
    except at.Refusal as e:
        raise Refused(str(e)) from None


def _now() -> datetime:
    return datetime.now(timezone.utc)


def gate() -> int:
    """--if-stale: EXIT_FRESH when the default file is usable and 0 <= age < max age, else EXIT_GO."""
    try:
        table = at.load_table(at.config_path())
    except at.Refusal as e:
        raise ConfigError(str(e)) from None
    try:
        hours = at.max_age_hours(table or {})
    except at.Refusal as e:
        raise Refused(str(e)) from None
    path = default_out()
    if pf._regular_file(path)[0] != "regular":
        return EXIT_GO   # absent, or not a file this gate may open (a FIFO would block a close)
    try:
        doc = pc.read_document(path)
    except pc.DocumentError:
        return EXIT_GO
    if pc.actuals_usable(doc) is not None:
        return EXIT_GO
    stamp = datetime.strptime(doc["generated_at"], STAMP).replace(tzinfo=timezone.utc)
    age = (_now() - stamp).total_seconds()
    return EXIT_FRESH if 0 <= age < hours * 3600 else EXIT_GO


def preflight(opts) -> int:
    """The checks that run before any slow work, then the --if-stale gate."""
    if opts.archive is not None and not opts.archive.is_dir():
        raise Refused(f"no archive dir {opts.archive}")
    if opts.project is not None and opts.out is None and not opts.stdout:
        raise Refused("--project builds a one-project document; pass --out PATH or --stdout")
    if opts.out is not None:
        check_out(opts.out)
    return gate() if opts.if_stale else EXIT_GO


# --- inputs ---------------------------------------------------------------------------

class Sources:
    """The document's `sources` rows: one per source consulted, ok or missing."""

    def __init__(self):
        self.rows: list[dict] = []

    def add(self, source: str, status: str, detail: str | None = None, project: str | None = None):
        self.rows.append({"source": source, "project": project, "status": status, "detail": detail})

    def sorted(self) -> list[dict]:
        return sorted(self.rows, key=lambda r: (r["source"], r["project"] or "", r["detail"] or "",
                                                r["status"]))


def _subdirs(path: Path) -> list[Path]:
    return sorted((p for p in path.iterdir() if p.is_dir()), key=lambda p: p.name)


def _archived_copy_of_live(slug_dir: Path, live_root: Path) -> bool:
    """Every file under an archive cwd dir, the sessions and everything under each <session>/
    (subagent files included), is a copy of the live file at the same relative path (minus .gz).

    Any other archive file means the dir holds something live does not: it is read
    (the shared message-id set keeps the double read correct).
    """
    live = live_root / slug_dir.name
    try:
        if not live.is_dir() or any(slug_dir.glob("*.jsonl")):
            return False
        for f in slug_dir.rglob("*"):
            if f.is_dir():
                continue
            rel = f.relative_to(slug_dir).as_posix()
            if not (live / rel.removesuffix(".gz")).is_file():
                return False
        return True
    except OSError:
        return False


def archive_dirs(root: Path, skipped: list, own_host: str | None = None,
                 live_root: Path | None = None) -> list[Path]:
    """cost-report's archive_dirs, one host at a time: an unreadable host is a skipped row, not a failure.

    With own_host, that partition's cwd dirs whose files are all still live are left out.
    """
    out = []
    for host in _subdirs(root):
        try:
            slugs = _subdirs(host)
        except OSError as e:
            skipped.append((str(host), f"skipped {host} ({e})"))
            continue
        if host.name == own_host and live_root is not None:
            slugs = [s for s in slugs if not _archived_copy_of_live(s, live_root)]
        out += slugs
    return out


def _inputs(archive: Path | None, src: Sources, skipped: list):
    """(live dirs, archive dirs, the archive root read or None)."""
    if archive is not None:
        try:
            dirs = archive_dirs(archive, skipped)
        except OSError as e:
            src.add("archive", "missing", f"cannot read {archive} ({e})")
            return [], [], None
        src.add("archive", "ok", str(archive))
        return [], dirs, archive
    root = cr.transcripts_root()
    live: list[Path] = []
    if root.is_dir():
        try:
            live = cr.all_dirs()
            src.add("live", "ok", str(root))
        except OSError as e:
            src.add("live", "missing", f"cannot read {root} ({e})")
    else:
        src.add("live", "missing", f"no transcript dir {root}")
    tdir = "[archive].transcripts_dir"   # named in an OSError raised before resolve() returns
    try:
        table = at.load_table(at.config_path())
        if not at.configured(table):
            raise at.Refusal("no [archive].transcripts_dir configured")
        tdir, host, _ = at.resolve(table)
        aroot = Path(tdir)
        if not aroot.is_dir():
            raise at.Refusal(f"no archive dir {tdir}")
        dirs = archive_dirs(aroot, skipped, own_host=host, live_root=root if live else None)
    except at.Refusal as e:
        src.add("archive", "missing", str(e))
        return live, [], None
    except OSError as e:
        src.add("archive", "missing", f"cannot read {tdir} ({e})")
        return live, [], None
    src.add("archive", "ok", tdir)
    return live, dirs, aroot


def _read(path: str | None) -> str:
    if not path:
        return ""
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _jsonl(text: str):
    """milestones.sh --json output as (header, rows), or None when it is not whole JSON Lines."""
    if not text.endswith("\n"):
        return None
    docs = []
    for line in text[:-1].split("\n"):
        try:
            d = json.loads(line)
        except ValueError:
            return None
        if not isinstance(d, dict):
            return None
        docs.append(d)
    if not docs or docs[0].get("kind") != "header" or not isinstance(docs[0].get("missing"), list):
        return None
    rows = docs[1:]
    keys = ("project", "issue", "event", "at", "source")
    if not all(r.get("kind") == "row" and all(isinstance(r.get(k), str) for k in keys) for r in rows):
        return None
    if not all(isinstance(m, dict) and isinstance(m.get("source"), str) for m in docs[0]["missing"]):
        return None
    return docs[0], rows


def milestones(env: Mapping, project: str | None, src: Sources):
    """({(project, issue): [event rows]}, {projects whose milestones source is missing}) from the manifest."""
    try:
        n = int(env.get("ACTUALS_MS_COUNT") or 0)
    except ValueError:
        n = 0
    events: dict[tuple, list] = {}
    failed: set[str] = set()
    for i in range(n):
        p = env.get(f"ACTUALS_MS_{i}_PROJECT") or ""
        if not p or (project is not None and p != project):
            continue
        rc = env.get(f"ACTUALS_MS_{i}_RC") or "?"
        err = [ln.rstrip("\r") for ln in _read(env.get(f"ACTUALS_MS_{i}_ERR")).splitlines() if ln.strip()]
        if rc != "0":
            src.add("milestones", "missing", f"exit {rc}: {err[-1]}" if err else f"exit {rc}", p)
            failed.add(p)
            continue
        parsed = _jsonl(_read(env.get(f"ACTUALS_MS_{i}_OUT")))
        if parsed is None:
            src.add("milestones", "missing", "exit 0: output is not whole JSON Lines", p)
            failed.add(p)
            continue
        header, rows = parsed
        src.add("milestones", "ok", None, p)
        for line in err:
            src.add("milestones", "ok", line, p)
        for m in header["missing"]:
            detail = m.get("detail")
            src.add(m["source"], "missing", detail if isinstance(detail, str) else None, p)
        for r in rows:
            events.setdefault((r["project"], r["issue"]), []).append(
                {"at": r["at"], "event": r["event"], "source": r["source"]})
    return events, failed


# --- the document --------------------------------------------------------------------------

def _tokens(o: dict) -> dict:
    return {k: o[k] for k in TOKEN_KEYS}


def build_document(archive: Path | None, project: str | None, env: Mapping) -> dict:
    """The actuals document (see docs/portfolio-schema.md, "Actuals", for the slot shapes)."""
    src = Sources()
    skipped: list = []
    live, adirs, aroot = _inputs(archive, src, skipped)
    hosts = {d: d.parent.name for d in adirs}
    rules = cr.TimeRules()
    times: dict = {}
    ov: dict = {}
    pair_sources: dict = {}
    rows, sessions = cr.collect(live + adirs, None, hosts=hosts, sources=pair_sources, timing=rules,
                                times=times, overhead=ov, skipped=skipped)
    pairs = cr.pair_objects(rows, sessions, pair_sources, times, rules)
    lines = cr.overhead_objects(ov)
    for path, message in skipped:
        src.add("transcript", "missing", message)
    events, failed = milestones(env, project, src)

    issues: dict[tuple, dict] = {}
    for o in pairs:
        key = (o["project"], o["issue"])
        if key == NO_PAIR:
            continue   # its calls are the overhead and unassigned rows
        issues[key] = {"sessions": o["sources"], "time": {k: o[k] for k in TIME_KEYS}, "tokens": _tokens(o)}
    for key in events:
        issues.setdefault(key, {"sessions": [], "time": None, "tokens": None})
    for key, a in issues.items():
        a["milestones"] = events.get(key) or (None if key[0] in failed else [])
    if project is not None:
        issues = {k: v for k, v in issues.items() if k[0] == project}

    overhead = {o["project"]: {"rules": {"cwd": o["rules"]["cwd"], "hint": o["rules"]["hint"]},
                               "sessions": o["sources"], "tokens": _tokens(o)}
                for o in lines if o["project"] != cr.UNASSIGNED}
    names = set(cr._project_tables()) | set(overhead)
    if project is not None:
        names = {project}
    unassigned = [] if project is not None else sorted(
        ({"cwd": o["cwd"], "sessions": o["sources"], "tokens": _tokens(o)}
         for o in lines if o["project"] == cr.UNASSIGNED), key=lambda u: u["cwd"])
    read_hosts = set(hosts.values()) | ({"local"} if live else set())
    return {
        "actuals_version": ACTUALS_VERSION,
        "generated_at": _now().strftime(STAMP),
        "inputs": {"archive": str(aroot) if aroot is not None else None, "hosts": sorted(read_hosts),
                   "project": project},
        "issues": [{"project": p, "issue": i, "actuals": issues[(p, i)]} for p, i in sorted(issues)],
        "projects": [{"project": n, "actuals": {"overhead": overhead.get(n)}} for n in sorted(names)],
        "unassigned": unassigned,
        "sources": src.sorted(),
        "time_rule": rules.as_json(),
    }


def render(doc: dict) -> bytes:
    """The portfolio's encoding (2-space indent, UTF-8, LF; NaN and Infinity refused), keys sorted."""
    return pf.dumps(doc, sort_keys=True)


def build(opts, env: Mapping) -> int:
    preflight(argparse.Namespace(**{**vars(opts), "if_stale": False}))
    doc = build_document(opts.archive, opts.project, env)
    # The reader's own predicate (a one-project document read as all-projects): never write what it refuses.
    why = pc.actuals_usable({**doc, "inputs": {**doc["inputs"], "project": None}})
    if why is not None:
        raise Refused(f"refusing to write an unusable document: {why}")
    data = render(doc)
    if opts.stdout:
        sys.stdout.buffer.write(data)
        sys.stdout.flush()
        return EXIT_GO
    out = opts.out or default_out()
    try:
        pf.write_document(data, out)
    except OSError as e:
        raise Refused(f"cannot write {out}: {e}") from None
    missing = sum(1 for s in doc["sources"] if s["status"] == "missing")
    _say(sys.stdout, f"actuals: wrote {out} ({len(doc['issues'])} issues, {len(doc['projects'])} projects, "
                     f"{missing} missing sources)")
    return EXIT_GO


def main(argv: list[str], env: Mapping | None = None) -> int:
    ap = argparse.ArgumentParser(prog="actuals.py", description=__doc__.splitlines()[0])
    ap.add_argument("verb", choices=("preflight", "build"))
    ap.add_argument("--archive", type=Path)
    ap.add_argument("--project")
    out = ap.add_mutually_exclusive_group()
    out.add_argument("--out", type=Path)
    out.add_argument("--stdout", action="store_true")
    ap.add_argument("--if-stale", action="store_true")
    opts = ap.parse_args(argv)
    try:
        if opts.verb == "preflight":
            return preflight(opts)
        return build(opts, os.environ if env is None else env)
    except Refused as e:
        _say(sys.stderr, f"{PROG}: {e}")
        return EXIT_REFUSED
    except ConfigError as e:
        _say(sys.stderr, f"{PROG}: {e}")
        return EXIT_CONFIG


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
