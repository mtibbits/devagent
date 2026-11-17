#!/usr/bin/env python3
"""Test probe for the notifications file (#961): tests/lib_notify.bats only.

    notify_probe.py count <file>               lines; fails unless every line is a v1 dict
    notify_probe.py keys <file> <n>            line n's keys, space-joined (n: 1-based, -1 = last)
    notify_probe.py field <file> <n> <key>     line n's value for <key>, as UTF-8 bytes
    notify_probe.py type <file> <n> <key>      str | int | null | absent | other
    notify_probe.py bytes <file> <n>           line n's length in bytes, its \\n included
    notify_probe.py prefix-count <file> <p>    lines whose detail starts with <p>
    notify_probe.py hold-lock <state-dir> <ready> <release>
                                               hold the module's own lock; touch <ready>;
                                               release when <release> exists (or after 30 s)
    notify_probe.py deny-share <file> <ready> <release>
                                               Windows: hold <file> open with share mode 0

Loads scripts/lib/_notify.py by path, so the lock it holds is the module's own
locked(), never a copy. Writes bytes; the test compares them in bash.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import time
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2] / "scripts" / "lib" / "_notify.py"
HOLD_SECONDS = 30


def load():
    spec = importlib.util.spec_from_file_location("_notify", MODULE)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["_notify"] = mod
    spec.loader.exec_module(mod)
    return mod


def raw_lines(path: str) -> list:
    data = Path(path).read_bytes()
    parts = data.split(b"\n")
    if parts and parts[-1] == b"":
        parts.pop()
    return parts


def line_obj(path: str, n: str):
    return json.loads(raw_lines(path)[int(n) - 1 if int(n) > 0 else int(n)].decode("utf-8"))


def out(text: str) -> int:
    sys.stdout.buffer.write(text.encode("utf-8"))
    return 0


def fail(msg: str) -> int:
    print(f"notify_probe: {msg}", file=sys.stderr)
    return 1


def wait_for(release: str) -> None:
    deadline = time.monotonic() + HOLD_SECONDS
    while not os.path.exists(release) and time.monotonic() < deadline:
        time.sleep(0.02)


def cmd_count(path: str) -> int:
    data = Path(path).read_bytes()
    if not data.endswith(b"\n"):
        return fail("the file does not end in \\n")
    if b"\r" in data:
        return fail("the file holds a CR")
    lines = raw_lines(path)
    for i, raw in enumerate(lines, 1):
        try:
            obj = json.loads(raw.decode("utf-8"))
        except ValueError:
            return fail(f"line {i} does not parse")
        if not isinstance(obj, dict) or type(obj.get("v")) is not int or obj["v"] != 1:
            return fail(f"line {i} is not a version-1 object")
    return out(str(len(lines)))


def cmd_type(path: str, n: str, key: str) -> int:
    obj = line_obj(path, n)
    if key not in obj:
        return out("absent")
    v = obj[key]
    if v is None:
        return out("null")
    if type(v) is int:
        return out("int")
    if type(v) is str:
        return out("str")
    return out("other")


def cmd_hold_lock(state_dir: str, ready: str, release: str) -> int:
    mod = load()
    with mod.locked(state_dir):
        Path(ready).touch()
        wait_for(release)
    return 0


def cmd_deny_share(path: str, ready: str, release: str) -> int:
    if os.name != "nt":
        return fail("deny-share is Windows only")
    import ctypes
    from ctypes import wintypes
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateFileW.restype = wintypes.HANDLE
    k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                                wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    generic_read, open_existing, attr_normal = 0x80000000, 3, 0x80
    h = k32.CreateFileW(str(path), generic_read, 0, None, open_existing, attr_normal, None)
    if h in (None, wintypes.HANDLE(-1).value):
        return fail(f"CreateFileW failed: {ctypes.get_last_error()}")
    try:
        Path(ready).touch()
        wait_for(release)
    finally:
        k32.CloseHandle(h)
    return 0


def main(argv: list) -> int:
    if not argv:
        return fail("no verb")
    verb, args = argv[0], argv[1:]
    if verb == "count" and len(args) == 1:
        return cmd_count(args[0])
    if verb == "keys" and len(args) == 2:
        return out(" ".join(line_obj(*args).keys()))
    if verb == "field" and len(args) == 3:
        v = line_obj(args[0], args[1]).get(args[2])
        return out(v if isinstance(v, str) else json.dumps(v))
    if verb == "type" and len(args) == 3:
        return cmd_type(*args)
    if verb == "bytes" and len(args) == 2:
        n = int(args[1])
        return out(str(len(raw_lines(args[0])[n - 1 if n > 0 else n]) + 1))
    if verb == "prefix-count" and len(args) == 2:
        count = 0
        for raw in raw_lines(args[0]):
            try:
                obj = json.loads(raw.decode("utf-8"))
            except ValueError:
                continue
            if isinstance(obj, dict) and str(obj.get("detail", "")).startswith(args[1]):
                count += 1
        return out(str(count))
    if verb == "hold-lock" and len(args) == 3:
        return cmd_hold_lock(*args)
    if verb == "deny-share" and len(args) == 3:
        return cmd_deny_share(*args)
    return fail(f"unknown verb or arity: {verb}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
