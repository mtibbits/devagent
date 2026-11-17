#!/usr/bin/env python3
"""The launcher notifications file's helper (#961). Called only by scripts/lib/notify.sh.

    _notify.py append|check <state-dir> <config-path>    fields on stdin
    _notify.py rotate <state-dir> <new-name>

Stdin framing: one <key>=<value> per line, UTF-8, LF only, split at the first
`=`, ended by EOF. Location comes only from argv (never DA_HOME, HOME,
DEVAGENT_STATE_DIR or a session pin); project and issue only from the fields.

Exits: 0 done; 2 refused; 3 lock timeout; 4 I/O. Diagnostics go to stderr,
stdout stays empty, and no message repeats a field value. Spec §7.3.

Python 3.8 syntax floor: no `match`, no PEP 604 unions at runtime.
"""
from __future__ import annotations

import contextlib
import importlib.util
import json
import os
import re
import sys
import unicodedata
from datetime import datetime

try:
    import fcntl
except ImportError:   # Windows: msvcrt, imported where it is used
    fcntl = None

FILE_NAME = "notifications.jsonl"
LOCK_NAME = FILE_NAME + ".lock"
LOCK_WAIT_SECONDS = 10
MAX_LINE_BYTES = 4096
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
    """The version-1 object, in the contract's key order."""
    obj = {
        "v": 1,
        "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
        "event": fields.get("event"),
        "project": fields.get("project"),
    }
    if "issue" in fields:
        obj["issue"] = fields["issue"]
    else:
        obj["capture"] = fields.get("capture")
    obj["step"] = fields.get("step")
    obj["question"] = fields.get("question")
    obj["detail"] = fields.get("detail")
    return obj


def encode(obj: dict) -> bytes:
    return (json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def ensure_state_dir(state_dir: str) -> None:
    """Create the state directory 0700, only when it is missing."""
    if not os.path.isdir(state_dir):
        try:
            os.makedirs(state_dir, 0o700, exist_ok=True)
        except OSError as e:
            raise IOFault(f"cannot create the state directory: {e.strerror}")


@contextlib.contextmanager
def locked(state_dir: str):
    """Hold the exclusive lock on <state-dir>/notifications.jsonl.lock.

    The lock file is opened for append (never truncated: an msvcrt byte lock is
    mandatory, and a truncating open of a held file can fail) and created 0600.
    """
    path = os.path.join(state_dir, LOCK_NAME)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | O_BINARY, 0o600)
    except OSError as e:
        raise IOFault(f"cannot open {LOCK_NAME}: {e.strerror}")
    try:
        if fcntl:
            fcntl.flock(fd, fcntl.LOCK_EX)
        else:
            import msvcrt
            os.lseek(fd, 0, os.SEEK_SET)
            msvcrt.locking(fd, msvcrt.LK_LOCK, 1)
        try:
            yield
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


def append(state_dir: str, line: bytes) -> None:
    ensure_state_dir(state_dir)
    path = os.path.join(state_dir, FILE_NAME)
    with locked(state_dir):
        try:
            fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_APPEND | O_BINARY, 0o600)
        except OSError as e:
            raise IOFault(f"cannot open {FILE_NAME}: {e.strerror}")
        try:
            write_all(fd, line)
        except OSError as e:
            raise IOFault(f"cannot write {FILE_NAME}: {e.strerror}")
        finally:
            os.close(fd)


def run(argv: list) -> int:
    if len(argv) == 3 and argv[0] in ("append", "check"):
        mode, state_dir, config_path = argv
        fields = parse_fields(sys.stdin.buffer.read())
        check_fields(fields, config_path)
        line = encode(build_record(fields))
        if mode == "append":
            append(state_dir, line)
        return 0
    if len(argv) == 3 and argv[0] == "rotate":
        check_rotate_name(argv[2])
        raise IOFault("rotate is not implemented")
    raise Refused("usage", "_notify.py append|check <state-dir> <config-path> | " + ROTATE_USAGE)


def main(argv: list) -> int:
    try:
        return run(argv)
    except Refused as e:
        print(f"notify: refused ({e.rid}): {e.rule}", file=sys.stderr)
        return 2
    except IOFault as e:
        print(f"notify: io: {e}", file=sys.stderr)
        return 4
    except Exception as e:   # never Python's own 1 or 2 to a writer
        print(f"notify: io: internal: {type(e).__name__}", file=sys.stderr)
        return 4


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
