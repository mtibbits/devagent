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
import json
import os
import sys
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


class Refused(Exception):
    """A refused input: exit 2, nothing written."""

    def __init__(self, rid: str, rule: str):
        super().__init__(rid)
        self.rid = rid
        self.rule = rule


class IOFault(Exception):
    """An I/O failure: exit 4, nothing written."""


def parse_fields(raw: bytes) -> dict:
    """The stdin fields as {key: value}, in the order given."""
    text = raw.decode("utf-8")
    if text.endswith("\n"):
        text = text[:-1]
    fields = {}
    for line in text.split("\n"):
        key, _, value = line.partition("=")
        fields[key] = value
    return fields


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
    if len(argv) != 3 or argv[0] not in ("append", "check"):
        raise Refused("usage", "_notify.py append|check <state-dir> <config-path>")
    mode, state_dir, _config = argv
    fields = parse_fields(sys.stdin.buffer.read())
    line = encode(build_record(fields))
    if mode == "append":
        append(state_dir, line)
    return 0


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
