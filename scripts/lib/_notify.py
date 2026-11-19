#!/usr/bin/env python3
"""The launcher notifications file's helper (#961). Called only by scripts/lib/notify.sh.

    _notify.py append|check <state-dir> <config-path>    fields on stdin
    _notify.py rotate <state-dir> <new-name>

Stdin framing: one <key>=<value> per line, UTF-8, LF only, split at the first
`=`, ended by EOF. Location comes only from argv (never DA_HOME, HOME,
DEVAGENT_STATE_DIR or a session pin); project and issue only from the fields.

Exits: 0 done; 2 refused; 3 lock timeout; 4 I/O; 5 nothing to rotate.
Diagnostics go to stderr, stdout stays empty, and no message repeats a field
value. Spec §7.3.

Python 3.8 syntax floor: no `match`, no PEP 604 unions at runtime.
"""
from __future__ import annotations

import contextlib
import errno
import importlib.util
import json
import os
import re
import sys
import time
import unicodedata
from datetime import datetime

try:
    import fcntl
except ImportError:   # Windows: msvcrt, imported where it is used
    fcntl = None

FILE_NAME = "notifications.jsonl"
LOCK_NAME = FILE_NAME + ".lock"
LOCK_WAIT_SECONDS = 10
LOCK_POLL_SECONDS = 0.05
MAX_LINE_BYTES = 4096
ELLIPSIS = "\u2026"   # the shortening mark ending a cut detail
EVENTS = ("hold", "notify", "answered", "stuck")
KEYS = ("event", "project", "issue", "capture", "step", "question", "detail")
O_BINARY = getattr(os, "O_BINARY", 0)   # Windows: no newline translation on os.open fds
ISSUE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
STEP_RE = re.compile(r"[A-Za-z][A-Za-z0-9_-]{0,63}")   # the checklist row form (checklist.sh:68)


class Refused(Exception):
    """A refused input: exit 2, nothing written."""

    def __init__(self, rid: str, rule: str):
        super().__init__(rid)
        self.rid = rid
        self.rule = rule


class IOFault(Exception):
    """An I/O failure: exit 4, nothing written."""


class LockTimeout(Exception):
    """The lock stayed held past the deadline: exit 3, nothing written."""


class NothingToRotate(Exception):
    """--rotate found no notifications file: exit 5."""


def parse_fields(raw: bytes) -> dict:
    """The stdin fields as {key: value}, in the order given.

    Checks run in the order of the id list (newline, encoding, framing,
    unknown-field, duplicate), so a one-fault input has one id.
    """
    if raw.endswith(b"\n"):
        raw = raw[:-1]
    lines = raw.split(b"\n")
    if any(b"\r" in line for line in lines):
        raise Refused("newline", "a field line holds a CR")
    try:
        texts = [line.decode("utf-8") for line in lines]
    except UnicodeDecodeError:
        raise Refused("encoding", "the fields are not UTF-8")
    pairs = []
    for text in texts:
        key, sep, value = text.partition("=")
        if not sep:
            raise Refused("framing", "a field line has no =")
        pairs.append((key, value))
    for key, _ in pairs:
        if key not in KEYS:
            raise Refused("unknown-field", "a field name is not one of " + " ".join(KEYS))
    fields = {}
    for key, value in pairs:
        if key in fields:
            raise Refused("duplicate", "a field is given twice")
        fields[key] = value
    return fields


def is_absolute(path: str) -> bool:
    """`^/` on POSIX; `^[A-Za-z]:/` or `^//[^/]` on Windows. Never os.path.isabs,
    whose answer for /x on Windows changed in Python 3.13."""
    if os.name == "nt":
        return re.match(r"[A-Za-z]:/", path) is not None or re.match(r"//[^/]", path) is not None
    return path.startswith("/")


def configured_projects(config_path: str) -> list:
    """The project names config_list_projects prints: tables `project.<name>`, two parts."""
    lib = os.path.dirname(os.path.abspath(__file__))
    try:
        spec = importlib.util.spec_from_file_location("_notify_toml", os.path.join(lib, "_toml.py"))
        toml = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(toml)
    except (OSError, ImportError) as e:
        raise IOFault(f"cannot load _toml.py: {type(e).__name__}")
    try:
        data = toml._load(toml.Path(config_path), retry=True)
    except OSError as e:
        raise IOFault(f"cannot read config.toml: {e.strerror}")
    except ValueError:
        raise IOFault("cannot read config.toml: not valid TOML")
    names = []
    for table in toml._list_tables(data):
        parts = table.split(".")
        if len(parts) == 2 and parts[0] == "project":
            names.append(parts[1])
    return names


def check_fields(fields: dict, config_path: str) -> None:
    """Refuse the first faulty field, in the order of the id list."""
    if fields.get("event") not in EVENTS:
        raise Refused("event", "event is not one of " + " ".join(EVENTS))
    project = fields.get("project")
    if not project:
        raise Refused("project", "project is missing or empty")
    if project not in configured_projects(config_path):
        raise Refused("project", "project is not a configured project")
    if ("issue" in fields) == ("capture" in fields):
        raise Refused("issue-capture", "give exactly one of issue and capture")
    if "issue" in fields and not ISSUE_RE.fullmatch(fields["issue"]):
        raise Refused("issue", "issue is outside [A-Za-z0-9][A-Za-z0-9._-]{0,63}")
    if "capture" in fields:
        capture = fields["capture"]
        if not capture or any(ch == " " or unicodedata.category(ch) == "Cc" for ch in capture):
            raise Refused("capture", "capture is empty or holds a space or a control character")
    if "step" in fields and not STEP_RE.fullmatch(fields["step"]):
        raise Refused("step", "step is outside [A-Za-z][A-Za-z0-9_-]{0,63}")
    if "question" in fields and not is_absolute(fields["question"]):
        raise Refused("question", "question is not an absolute path")
    if not fields.get("detail"):
        raise Refused("detail", "detail is missing or empty")


ROTATE_USAGE = "_notify.py rotate <state-dir> <new-name>"


def check_rotate_name(name: str) -> None:
    if not name or name in (".", "..") or any(ch in name for ch in "/\\:"):
        raise Refused("rotate-name", "the new name must be a bare file name: no /, \\ or :, not . or ..")


def build_record(fields: dict) -> dict:
    """The version-1 object: v, ts, then KEYS in order. Of issue and capture only
    the one given appears (check_fields allows exactly one); an absent step or
    question is null."""
    obj = {"v": 1, "ts": datetime.now().astimezone().isoformat(timespec="seconds")}
    for key in KEYS:
        if key in ("issue", "capture") and key not in fields:
            continue
        obj[key] = fields.get(key)
    return obj


def encode(obj: dict) -> bytes:
    return (json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def fit(obj: dict) -> bytes:
    """The encoded line, at most MAX_LINE_BYTES with its \\n.

    A longer line keeps the longest code-point prefix of `detail` that fits with
    ELLIPSIS appended (a binary search: the encoded length only grows with the
    prefix). If even `detail` equal to ELLIPSIS alone does not fit, refuse.
    """
    line = encode(obj)
    if len(line) <= MAX_LINE_BYTES:
        return line
    detail = obj["detail"]

    def with_prefix(k: int) -> bytes:
        return encode(dict(obj, detail=detail[:k] + ELLIPSIS))

    if len(with_prefix(0)) > MAX_LINE_BYTES:
        raise Refused("too-long", f"the line is longer than {MAX_LINE_BYTES} bytes even with an empty detail")
    lo, hi = 0, min(len(detail), MAX_LINE_BYTES)   # every code point encodes to at least one byte
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if len(with_prefix(mid)) <= MAX_LINE_BYTES:
            lo = mid
        else:
            hi = mid - 1
    return with_prefix(lo)


def ensure_state_dir(state_dir: str) -> None:
    """Create the state directory 0700, only when it is missing."""
    if not os.path.isdir(state_dir):
        try:
            os.makedirs(state_dir, 0o700, exist_ok=True)
        except OSError as e:
            raise IOFault(f"cannot create the state directory: {e.strerror}")


def open_retrying(path: str, flags: int, deadline: float) -> int:
    """os.open, retrying a Windows sharing violation (PermissionError) until the
    deadline; on POSIX a refused open fails at once."""
    while True:
        try:
            return os.open(path, flags, 0o600)
        except PermissionError:
            if os.name != "nt" or time.monotonic() >= deadline:
                raise
            time.sleep(LOCK_POLL_SECONDS)


def _try_lock(fd: int) -> bool:
    """One non-blocking attempt: True when held, False when another process has it."""
    if fcntl:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError as e:
            if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES):
                return False
            raise
    import msvcrt
    os.lseek(fd, 0, os.SEEK_SET)
    try:
        msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)   # one byte at offset 0
        return True
    except OSError as e:
        if e.errno in (errno.EACCES, errno.EDEADLOCK):
            return False
        raise


@contextlib.contextmanager
def locked(state_dir: str):
    """Hold the exclusive lock on <state-dir>/notifications.jsonl.lock; yield the
    deadline, which also bounds the caller's Windows open retry.

    One time.monotonic() deadline, LOCK_WAIT_SECONDS from entry, polled every
    LOCK_POLL_SECONDS with a non-blocking attempt (LK_LOCK is not used: its own
    bound is the CRT's). Past it, LockTimeout. The lock file is opened for append,
    never truncated (an msvcrt byte lock is mandatory, and a truncating open of a
    held file can fail), and created 0600.
    """
    deadline = time.monotonic() + LOCK_WAIT_SECONDS
    path = os.path.join(state_dir, LOCK_NAME)
    try:
        fd = open_retrying(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | O_BINARY, deadline)
    except OSError as e:
        raise IOFault(f"cannot open {LOCK_NAME}: {e.strerror}")
    try:
        while not _try_lock(fd):
            if time.monotonic() >= deadline:
                raise LockTimeout()
            time.sleep(LOCK_POLL_SECONDS)
        try:
            yield deadline
        finally:
            if fcntl:
                fcntl.flock(fd, fcntl.LOCK_UN)
            else:
                import msvcrt
                try:
                    os.lseek(fd, 0, os.SEEK_SET)
                    msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
                except OSError:
                    pass   # the OS drops the lock at close regardless
    finally:
        os.close(fd)


def write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        n = os.write(fd, view)
        view = view[n:]


def ends_in_newline(fd: int) -> bool:
    """True for an empty file or one whose last byte is \\n."""
    size = os.fstat(fd).st_size
    if size == 0:
        return True
    os.lseek(fd, size - 1, os.SEEK_SET)
    return os.read(fd, 1) == b"\n"


def append(state_dir: str, make_line) -> None:
    """Write one line under the lock. make_line() builds it once the lock is
    held, so `ts` is the write time, not the time the wait began.

    The data file is opened only after the lock is held and closed before it is
    released (a waiting writer never holds it open, which would block a Windows
    rename). The last-byte read and the write are both inside the lock: after a
    torn line from a crashed writer, a \\n goes first.
    """
    ensure_state_dir(state_dir)
    path = os.path.join(state_dir, FILE_NAME)
    with locked(state_dir) as deadline:
        try:
            fd = open_retrying(path, os.O_RDWR | os.O_CREAT | os.O_APPEND | O_BINARY, deadline)
        except OSError as e:
            raise IOFault(f"cannot open {FILE_NAME}: {e.strerror}")
        try:
            line = make_line()
            write_all(fd, line if ends_in_newline(fd) else b"\n" + line)
        except OSError as e:
            raise IOFault(f"cannot write {FILE_NAME}: {e.strerror}")
        finally:
            os.close(fd)


def rotate(state_dir: str, new_name: str) -> None:
    """Rename the file to <new-name> in the same directory, under the lock.

    The name is checked before the lock is taken; the target's absence and the
    rename are both inside it. A failed rename is not retried: the file stays
    in place and the exit is 4.
    """
    check_rotate_name(new_name)
    path = os.path.join(state_dir, FILE_NAME)
    target = os.path.join(state_dir, new_name)
    if not os.path.isdir(state_dir):
        raise NothingToRotate()
    with locked(state_dir):
        if os.path.lexists(target):
            raise Refused("rotate-exists", "the new name already exists in the state directory")
        if not os.path.exists(path):
            raise NothingToRotate()
        try:
            os.rename(path, target)
        except OSError as e:
            raise IOFault(f"cannot rename {FILE_NAME}: {e.strerror}")


def run(argv: list) -> int:
    if len(argv) == 3 and argv[0] in ("append", "check"):
        mode, state_dir, config_path = argv
        fields = parse_fields(sys.stdin.buffer.read())
        check_fields(fields, config_path)
        fit(build_record(fields))   # refuses too-long before any lock or directory
        if mode == "append":
            append(state_dir, lambda: fit(build_record(fields)))
        return 0
    if len(argv) == 3 and argv[0] == "rotate":
        rotate(argv[1], argv[2])
        return 0
    raise Refused("usage", "_notify.py append|check <state-dir> <config-path> | " + ROTATE_USAGE)


def main(argv: list) -> int:
    try:
        return run(argv)
    except Refused as e:
        print(f"notify: refused ({e.rid}): {e.rule}", file=sys.stderr)
        return 2
    except NothingToRotate:
        print("notify: nothing-to-rotate", file=sys.stderr)
        return 5
    except LockTimeout:
        print(f"notify: lock-timeout: waited {LOCK_WAIT_SECONDS} s for {LOCK_NAME}; nothing written", file=sys.stderr)
        return 3
    except IOFault as e:
        print(f"notify: io: {e}", file=sys.stderr)
        return 4
    except Exception as e:   # never Python's own 1 or 2 to a writer
        print(f"notify: io: internal: {type(e).__name__}", file=sys.stderr)
        return 4


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
