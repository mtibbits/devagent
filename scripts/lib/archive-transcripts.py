#!/usr/bin/env python3
"""Copy Claude Code session transcripts into a durable, append-only archive (#731).

Claude Code deletes a transcript cleanupPeriodDays after its last write, and a
reinstall or a new machine loses them all. This copies every session
transcript (<projects>/<cwd-slug>/<session>.jsonl) and everything under its
<session>/subagents/ (workflow agents included) into

    <transcripts_dir>/<host_id>/<cwd-slug>/<session>.jsonl.gz

configured by the [archive] table of ${DA_HOME:-~/.claude/devagent}/config.toml:

    transcripts_dir  absolute path, required; never inside a git work tree or
                     inside <CLAUDE_CONFIG_DIR or ~/.claude>/projects
    host_id          the partition name, [A-Za-z0-9._-]+ without ".." and not
                     "."; default the hostname, with "-wsl" under WSL
    exclude          cwd-slug globs never archived (case-insensitive)

Nothing is ever deleted or rewritten. A transcript only grows, so a grown one
gets one more gzip member holding only the new bytes; a file whose archived
prefix no longer matches (truncated or rewritten) is kept, and the source is
written beside it as <session>.<sha6>.jsonl.gz. <host_id>/manifest.jsonl
records size, mtime and sha256 per file, so an unchanged file costs one stat.
An archived file keeps its source's mtime. "unchanged" means the content is
unchanged; an mtime-only change refreshes the archived mtime and the manifest.

    archive-transcripts.py [--if-configured]   archive (cleanup passes the flag)
    archive-transcripts.py --doctor            doctor's warnings, one per line

Exit 0 archived (or, with --if-configured, no [archive].transcripts_dir);
1 ran but a file failed or another run held the lock (no last-run stamp);
2 refused or usage (nothing written). --doctor prints "<label>\\t<detail>"
lines and exits 0; it writes nothing.
"""

from __future__ import annotations

import argparse
import contextlib
import errno
import fnmatch
import functools
import hashlib
import importlib.util
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import zlib
from datetime import datetime, timezone
from pathlib import Path

try:
    import fcntl
except ImportError:   # Windows: msvcrt byte-range locks instead
    fcntl = None

PROG = "archive-transcripts"
LIB = Path(__file__).resolve().parent
# Read at call time (a module global, so a test points it at a fixture file).
OSRELEASE = "/proc/sys/kernel/osrelease"
KEYS = ("transcripts_dir", "host_id", "exclude")
HOST_ID = re.compile(r"(?!\.$)(?!.*\.\.)[A-Za-z0-9._-]+")
STALE_DAYS = 7
CHUNK = 1 << 20
O_BINARY = getattr(os, "O_BINARY", 0)   # Windows: no newline translation on os.open fds


class Refusal(Exception):
    """A configuration the archive will not run with: exit 2, nothing written."""


@functools.cache
def _lib(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, LIB / file)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module   # portfolio's dataclasses look themselves up here
    spec.loader.exec_module(module)
    return module


def _cost_report():
    return _lib("_archive_cost_report", "cost-report.py")


def _err(msg: str):
    print(f"{PROG}: {msg}", file=sys.stderr)


def config_path() -> Path:
    """${DA_HOME:-$HOME/.claude/devagent}/config.toml, as scripts/lib/paths.sh resolves it."""
    home = os.environ.get("DA_HOME") or Path(os.environ.get("HOME") or Path.home()) / ".claude" / "devagent"
    return Path(home) / "config.toml"


def load_table(path: Path):
    """The [archive] table, or None when the file or the table is absent."""
    if not path.is_file():
        return None
    try:
        data = _lib("_archive_toml", "_toml.py")._load(path, retry=True)
    except (OSError, ValueError, ImportError) as e:
        raise Refusal(f"cannot read {path} ({e})")
    table = data.get("archive")
    if table is not None and not isinstance(table, dict):
        raise Refusal(f"[archive] must be a table in {path}")
    return table


def configured(table) -> bool:
    return bool(table) and table.get("transcripts_dir") not in (None, "")


def default_host_id(hostname: str, osrelease: str) -> str:
    """hostname, with "-wsl" when the kernel release names Microsoft (WSL1 and WSL2)."""
    try:
        with open(osrelease, encoding="utf-8", errors="replace") as f:
            wsl = "microsoft" in f.read().lower()
    except OSError:
        wsl = False
    return hostname + "-wsl" if wsl else hostname


def _git_check(resolved: str):
    """Refuse unless git says the nearest existing ancestor is outside every repository (Issue-243: fail closed)."""
    anc = resolved
    while not os.path.exists(anc):
        parent = os.path.dirname(anc)
        if parent == anc:
            break
        anc = parent
    git = shutil.which("git")
    if not git:
        raise Refusal(f"cannot tell whether {resolved} is inside a git work tree (git not found); refusing")
    # An inherited GIT_DIR/GIT_WORK_TREE would answer for another repository, and a
    # ceiling or a filesystem boundary would stop discovery short of the repository
    # the path is in: either would let a path inside a work tree pass.
    drop = ("GIT_DIR", "GIT_WORK_TREE", "GIT_CEILING_DIRECTORIES")
    env = {k: v for k, v in os.environ.items() if k not in drop}
    env["LC_ALL"] = "C"
    env["GIT_DISCOVERY_ACROSS_FILESYSTEM"] = "1"
    try:
        r = subprocess.run([git, "-C", anc, "rev-parse", "--is-inside-work-tree"], capture_output=True,
                           text=True, errors="replace", env=env, stdin=subprocess.DEVNULL)
    except OSError as e:
        raise Refusal(f"cannot tell whether {resolved} is inside a git work tree ({e}); refusing")
    if r.returncode == 0:   # "true" in a work tree, "false" inside a .git dir: a repository either way
        raise Refusal(f"[archive].transcripts_dir is inside a git work tree ({resolved}); transcripts hold "
                      "everything a session read, so the archive belongs on private storage outside any repository")
    if r.returncode == 128 and "not a git repository" in r.stderr:
        return
    why = next((ln.strip() for ln in r.stderr.splitlines() if ln.strip()), f"rc {r.returncode}")
    raise Refusal(f"cannot tell whether {resolved} is inside a git work tree ({why}); refusing")


def resolve(table: dict, config: Path):
    """(transcripts_dir as given, its Path, host_id, exclude) or Refusal; checks run in a fixed order, before any write."""
    raw = table.get("transcripts_dir")
    if raw in (None, ""):
        raise Refusal(f"[archive].transcripts_dir is not set in {config}")
    for k in table:
        if k not in KEYS:
            raise Refusal(f"[archive].{k} is not a known key (transcripts_dir, host_id, exclude)")
    tdir = os.path.expanduser(raw) if isinstance(raw, str) and raw.startswith("~") else raw
    if not isinstance(tdir, str) or not Path(tdir).is_absolute():
        raise Refusal(f"[archive].transcripts_dir must be an absolute path: {raw} "
                      "(on Windows use a drive-letter path, e.g. C:/Users/me/archive)")
    host = table["host_id"] if "host_id" in table else default_host_id(socket.gethostname(), OSRELEASE)
    if not isinstance(host, str) or not HOST_ID.fullmatch(host):
        raise Refusal(f'[archive].host_id must match [A-Za-z0-9._-]+, without ".." and not ".": {host}')
    exclude = table.get("exclude", [])
    if not isinstance(exclude, list) or not all(isinstance(g, str) for g in exclude):
        raise Refusal("[archive].exclude must be a list of strings")
    root = _cost_report().transcripts_root()
    if _lib("_archive_portfolio", "portfolio.py")._is_under(tdir, root):
        raise Refusal(f"[archive].transcripts_dir is inside {root}, where Claude Code deletes old transcripts")
    _git_check(os.path.realpath(tdir))
    return tdir, Path(tdir), host, exclude


def _mkdirs(path: Path):
    """Create path one level at a time, each new dir 0700."""
    missing = []
    while not path.exists():
        missing.append(path)
        if path.parent == path:
            break
        path = path.parent
    for d in reversed(missing):
        try:
            os.mkdir(d, 0o700)
        except FileExistsError:
            pass


@contextlib.contextmanager
def held_lock(path: Path):
    """Yield True holding an exclusive non-blocking lock on path, False when another process holds it."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | O_BINARY, 0o600)
    got = False
    try:
        if fcntl:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                got = True
            except OSError as e:
                if e.errno not in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES):
                    raise
        else:
            import msvcrt
            os.lseek(fd, 0, os.SEEK_SET)
            try:
                msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
                got = True
            except OSError as e:
                if e.errno not in (errno.EACCES, errno.EDEADLOCK):
                    raise
        try:
            yield got
        finally:
            if got and not fcntl:
                import msvcrt
                os.lseek(fd, 0, os.SEEK_SET)
                msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
    finally:
        os.close(fd)


def _read_exact(src, n: int, hasher, sink=None) -> int:
    """Read n bytes from src into hasher (and sink); return the count read (short only if src shrank)."""
    done = 0
    while done < n:
        buf = src.read(min(CHUNK, n - done))
        if not buf:
            break
        hasher.update(buf)
        if sink is not None:
            sink(buf)
        done += len(buf)
    return done


def _compress_member(out, src, start: int, end: int, hasher) -> int:
    """The one compression seam: bytes [start, end) of src (positioned at start) as ONE gzip member on out."""
    z = zlib.compressobj(6, zlib.DEFLATED, 31)   # gzip framing: mtime 0, no file name
    n = _read_exact(src, end - start, hasher, lambda b: out.write(z.compress(b)))
    out.write(z.flush())
    if n != end - start:
        raise OSError(f"source shrank while reading ({n} of {end - start} bytes)")
    return n


def _copy(out, src, size: int, hasher) -> int:
    n = _read_exact(src, size, hasher, out.write)
    if n != size:
        raise OSError(f"source shrank while reading ({n} of {size} bytes)")
    return n


def _publish(tmp: Path, target: Path):
    """Give tmp the name target, failing (FileExistsError) rather than replacing an existing target."""
    if os.name == "nt":
        os.rename(tmp, target)   # Windows rename refuses an existing target
        return
    try:
        os.link(tmp, target)     # POSIX: link refuses an existing target; rename would replace it
    except FileExistsError:
        raise
    except OSError:              # no hard links here (some FAT/network mounts): the lock is held, so check-then-rename
        if os.path.lexists(target):
            raise FileExistsError(errno.EEXIST, "archive name exists", str(target))
        os.rename(tmp, target)
        return
    os.unlink(tmp)


@contextlib.contextmanager
def _signals_exit():
    """Turn SIGTERM/SIGHUP into SystemExit for the run, so an interrupted append is cut back (restored after)."""
    import signal
    import threading
    names = [n for n in ("SIGTERM", "SIGHUP") if hasattr(signal, n)]
    if threading.current_thread() is not threading.main_thread():
        yield
        return

    def _exit(signum, _frame):
        raise SystemExit(128 + signum)

    prior = {n: signal.signal(getattr(signal, n), _exit) for n in names}
    try:
        yield
    finally:
        for n, h in prior.items():
            signal.signal(getattr(signal, n), h)


def _sha256(src: Path, size: int) -> str:
    h = hashlib.sha256()
    with open(src, "rb") as f:
        if _read_exact(f, size, h) != size:
            raise OSError(f"source shrank while reading {src}")
    return h.hexdigest()


class Archive:
    """One run over one host partition, under its lock."""

    def __init__(self, store: Path, host: str):
        self.hostdir = store / host
        self.manifest = self.hostdir / "manifest.jsonl"
        self.by_source: dict[str, dict] = {}
        self.by_archive: dict[str, dict] = {}
        self.counts = dict(new=0, grown=0, unchanged=0, diverged=0, excluded=0)
        self.failed = 0
        self._mf = None
        self._read_manifest()

    def _read_manifest(self):
        try:
            f = open(self.manifest, encoding="utf-8", errors="replace")
        except FileNotFoundError:
            return
        shape = {"archive": str, "archive_size": int, "mtime_ns": int, "session": str,
                 "sha256": str, "size": int, "source": str}
        with f:
            for n, line in enumerate(f, 1):
                try:
                    rec = json.loads(line)
                except (ValueError, RecursionError):
                    rec = None
                if not isinstance(rec, dict) or not all(isinstance(rec.get(k), t) for k, t in shape.items()):
                    _err(f"{self.manifest}:{n}: skipped a malformed manifest line")
                    continue
                self.by_source[rec["source"]] = rec
                self.by_archive[rec["archive"]] = rec

    def _record(self, source: str, archive: str, session: str, st, size: int, sha: str):
        target = self.hostdir / archive
        os.utime(target, ns=(st.st_atime_ns, st.st_mtime_ns))
        self._append({"archive": archive, "archive_size": target.stat().st_size, "mtime_ns": st.st_mtime_ns,
                      "session": session, "sha256": sha, "size": size, "source": source})

    def _append(self, rec: dict):
        """One manifest line per archived file, flushed before the next file (a crash loses at most this one)."""
        if self._mf is None:
            fd = os.open(self.manifest, os.O_WRONLY | os.O_CREAT | os.O_APPEND | O_BINARY, 0o600)
            self._mf = os.fdopen(fd, "ab")
        self._mf.write((json.dumps(rec, sort_keys=True) + "\n").encode("utf-8"))
        self._mf.flush()
        self.by_source[rec["source"]] = rec
        self.by_archive[rec["archive"]] = rec

    def close(self):
        if self._mf is not None:
            self._mf.close()

    def _write_new(self, target: Path, src: Path, st, gz: bool) -> str:
        """Create target (never overwriting a name) from all of src; return the sha256.

        The bytes go to a hidden .<name>.partial beside it and are published by
        a no-overwrite link/rename only after fsync, so a run killed outright
        (no Python cleanup) never leaves a torn file under an archive name.
        """
        _mkdirs(target.parent)
        tmp = target.with_name(f".{target.name}.partial")   # one writer: the partition lock is held
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | O_BINARY, 0o600)
        try:
            with os.fdopen(fd, "wb") as out, open(src, "rb") as f:
                h = hashlib.sha256()
                if gz:
                    _compress_member(out, f, 0, st.st_size, h)
                else:
                    _copy(out, f, st.st_size, h)
                out.flush()
                os.fsync(out.fileno())
            os.utime(tmp, ns=(st.st_atime_ns, st.st_mtime_ns))
            _publish(tmp, target)
        except BaseException:
            with contextlib.suppress(OSError):
                os.unlink(tmp)
            raise
        return h.hexdigest()

    def _grow(self, target: Path, src: Path, st, rec) -> str | None:
        """Append [size, now) as one member when the archived prefix still matches; else None.

        An append cut short (an error, or SIGTERM/SIGHUP turned into SystemExit)
        is truncated back to the recorded size, so the file is never left torn.
        """
        with open(src, "rb") as f:
            h = hashlib.sha256()
            if _read_exact(f, rec["size"], h) != rec["size"] or h.copy().hexdigest() != rec["sha256"]:
                return None
            try:
                with open(target, "ab") as out:
                    _compress_member(out, f, rec["size"], st.st_size, h)
                    out.flush()
                    os.fsync(out.fileno())
            except BaseException:
                with contextlib.suppress(OSError):
                    os.truncate(target, rec["archive_size"])
                raise
        return h.hexdigest()

    def _beside(self, arel: str, src: Path, st, gz: bool, source: str, session: str, kept: str) -> str:
        """Write src beside its archived name as <key>.<sha6>[-n].<rest>; an existing equal copy is reused."""
        sha = _sha256(src, st.st_size)
        folder, name = arel.rsplit("/", 1)
        key, _, rest = name.partition(".")
        n = 0
        while True:
            tag = sha[:6] + (f"-{n}" if n else "")
            cand = f"{folder}/{key}.{tag}" + (f".{rest}" if rest else "")
            if not os.path.lexists(self.hostdir / cand):
                break
            prior = self.by_archive.get(cand)
            if prior and prior["sha256"] == sha and prior["size"] == st.st_size:
                # The same content is already archived under this name: write nothing but the pointer.
                self._append({**prior, "mtime_ns": st.st_mtime_ns, "source": source, "session": session})
                return "unchanged"
            n += 1
        got = self._write_new(self.hostdir / cand, src, st, gz)
        if got != sha:
            os.unlink(self.hostdir / cand)   # this run created the name; never leave an untracked copy
            raise OSError(f"source changed while reading (sha256 {got[:6]}, expected {sha[:6]})")
        self._record(source, cand, session, st, st.st_size, sha)
        print(f"{PROG}: diverged {kept} kept; source written as {cand}")
        return "diverged"

    def one(self, src: Path, slug: str, rel: str) -> str:
        st = os.stat(src)
        gz = src.name.endswith(".jsonl")
        source = f"{slug}/{rel}"
        arel = source + (".gz" if gz else "")
        session = rel.split("/", 1)[0].split(".", 1)[0]
        rec = self.by_source.get(source)
        if rec is None:
            target = self.hostdir / arel
            if os.path.lexists(target):
                return self._beside(arel, src, st, gz, source, session, kept=arel)
            sha = self._write_new(target, src, st, gz)
            self._record(source, arel, session, st, st.st_size, sha)
            return "new"
        if st.st_size == rec["size"] and st.st_mtime_ns == rec["mtime_ns"]:
            return "unchanged"   # stat only: the source is not opened
        target = self.hostdir / rec["archive"]
        try:
            asize = os.stat(target).st_size
        except FileNotFoundError:
            asize = None
        if asize == rec["archive_size"]:   # never append to a torn or foreign file
            if gz and st.st_size > rec["size"]:
                sha = self._grow(target, src, st, rec)
                if sha is not None:
                    self._record(source, rec["archive"], session, st, st.st_size, sha)
                    return "grown"
            elif st.st_size == rec["size"] and _sha256(src, st.st_size) == rec["sha256"]:
                self._record(source, rec["archive"], session, st, st.st_size, rec["sha256"])
                return "unchanged"   # content unchanged: only the mtime moved
        return self._beside(arel, src, st, gz, source, session, kept=rec["archive"])


def _sources(slug_dir: Path) -> list[Path]:
    """The session transcripts and every file under <session>/subagents/ (never tool-results/ or memory/)."""
    files = [p for p in slug_dir.glob("*.jsonl") if p.is_file()]
    for sub in slug_dir.glob("*/subagents"):
        if sub.is_dir():
            files += [p for p in sub.rglob("*") if p.is_file()]
    return sorted(files)


def run(tdir: str, store: Path, host: str, exclude: list[str]) -> int:
    hostdir = store / host
    try:
        _mkdirs(hostdir)
    except OSError as e:
        _err(f"cannot create {hostdir} ({e})")
        return 1
    lock = hostdir / ".lock"
    with _signals_exit(), held_lock(lock) as got:
        if not got:
            _err(f"another run holds {lock}; nothing archived")
            return 1
        arc = Archive(store, host)
        root = _cost_report().transcripts_root()
        try:
            slugs = sorted(p for p in root.iterdir() if p.is_dir()) if root.is_dir() else []
            for slug_dir in slugs:
                files = _sources(slug_dir)
                if any(fnmatch.fnmatchcase(slug_dir.name.lower(), g.lower()) for g in exclude):
                    arc.counts["excluded"] += len(files)
                    continue
                for src in files:
                    rel = src.relative_to(slug_dir).as_posix()
                    try:
                        arc.counts[arc.one(src, slug_dir.name, rel)] += 1
                    except OSError as e:
                        arc.failed += 1
                        _err(f"failed {slug_dir.name}/{rel} ({e})")
        finally:
            arc.close()
        c = arc.counts
        print(f"{PROG}: {host}: new {c['new']}, grown {c['grown']}, unchanged {c['unchanged']}, "
              f"diverged {c['diverged']}, excluded {c['excluded']} ({os.path.join(tdir, host)})")
        if arc.failed:
            return 1
        tmp = hostdir / ".last-run.tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | O_BINARY, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ\n").encode())
        os.replace(tmp, hostdir / "last-run")
        return 0


def _retention(settings: Path) -> str | None:
    """How cleanupPeriodDays reads, when it lets Claude Code delete transcripts within 30 days; else None."""
    try:
        data = json.loads(settings.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return "not set"
    except (OSError, ValueError, RecursionError):
        return "unreadable"
    if not isinstance(data, dict) or "cleanupPeriodDays" not in data:
        return "not set"
    v = data["cleanupPeriodDays"]
    if isinstance(v, bool) or not isinstance(v, int):
        return "not a number"
    return None if v > 30 else str(v)


def doctor_lines() -> list[tuple[str, str]]:
    """doctor's warnings: retention at or under 30 days, and a missing or stale last-run. A pure read."""
    out = []
    settings = _cost_report().transcripts_root().parent / "settings.json"
    value = _retention(settings)
    if value:
        out.append(("claude transcript retention",
                    f"cleanupPeriodDays is {value} in {settings}; Claude Code deletes transcripts older than "
                    "this (default 30). Set it above 30, e.g. 99999"))
    config = config_path()
    try:
        table = load_table(config)
        if not configured(table):
            return out
        _, store, host, _ = resolve(table, config)
    except Refusal as e:
        out.append(("transcript archive", str(e)))
        return out
    stamp = store / host / "last-run"
    try:
        text = stamp.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        out.append(("transcript archive", f"no last-run stamp at {stamp}; run scripts/archive-transcripts.sh"))
        return out
    except OSError as e:
        out.append(("transcript archive", f"cannot read {stamp} ({e}); run scripts/archive-transcripts.sh"))
        return out
    try:
        when = datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        out.append(("transcript archive", f"unreadable last-run stamp at {stamp}; run scripts/archive-transcripts.sh"))
        return out
    age = (datetime.now(timezone.utc) - when).total_seconds()
    if age > STALE_DAYS * 86400:
        out.append(("transcript archive",
                    f"last run {int(age // 86400)} days ago ({stamp}); run scripts/archive-transcripts.sh"))
    return out


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog=PROG, description=__doc__.splitlines()[0])
    ap.add_argument("--if-configured", action="store_true",
                    help="exit 0 silently unless [archive].transcripts_dir is set (cleanup's call)")
    ap.add_argument("--doctor", action="store_true", help="print doctor's warnings as <label>\\t<detail>; write nothing")
    a = ap.parse_args(argv)
    if a.doctor:
        for label, detail in doctor_lines():
            print(f"{label}\t{detail}")
        return 0
    config = config_path()
    try:
        table = load_table(config)
        if not configured(table):
            if a.if_configured:
                return 0
            raise Refusal(f"[archive].transcripts_dir is not set in {config}")
        tdir, store, host, exclude = resolve(table, config)
    except Refusal as e:
        _err(str(e))
        return 2
    return run(tdir, store, host, exclude)


if __name__ == "__main__":
    for stream in (sys.stdout, sys.stderr):
        with contextlib.suppress(AttributeError, ValueError):
            stream.reconfigure(encoding="utf-8", newline="\n")
    sys.exit(main(sys.argv[1:]))
