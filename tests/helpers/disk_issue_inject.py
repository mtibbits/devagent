#!/usr/bin/env python3
"""Failure injection for scripts/lib/disk-issue.py (#1008).

    disk_issue_inject.py <mode> [<mode-arg>] -- <disk-issue args>

Loads the module by path, patches module attributes in-process for <mode>, and
returns main(args). Production code carries no environment seams (register
Issue-565;578): every failure a test needs is injected here.
"""
from __future__ import annotations

import errno
import importlib.util
import os
import sys
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2] / "scripts" / "lib" / "disk-issue.py"


def load():
    spec = importlib.util.spec_from_file_location("disk_issue", MODULE)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["disk_issue"] = mod
    spec.loader.exec_module(mod)
    return mod


def main(argv: list) -> int:
    if "--" not in argv:
        print("usage: disk_issue_inject.py <mode> [<arg>] -- <disk-issue args>", file=sys.stderr)
        return 2
    cut = argv.index("--")
    mode_args, args = argv[:cut], argv[cut + 1:]
    if not mode_args:
        print("disk_issue_inject.py: no mode", file=sys.stderr)
        return 2
    mod = load()
    mode, rest = mode_args[0], mode_args[1:]
    patch = MODES.get(mode)
    if patch is None:
        print(f"disk_issue_inject.py: unknown mode {mode!r}", file=sys.stderr)
        return 2
    after = patch(mod, *rest)
    try:
        return mod.main(args)
    finally:
        if after:
            after()


def _kill_before_replace(mod):
    def replace(tmp, path):
        os._exit(137)          # no cleanup: what a crash leaves behind
    mod._replace = replace


def _change(times):
    def patch(mod):
        real = mod._write_temp
        state = {"left": times}

        def write_temp(folder, base, data, mode):
            tmp = real(folder, base, data, mode)
            if state["left"]:
                state["left"] -= 1
                with open(os.path.join(folder, base), "ab") as fh:
                    fh.write(b"other session\n")
            return tmp
        mod._write_temp = write_temp
    return patch


def _count_replace(mod):
    real = mod._replace
    count = {"n": 0}

    def replace(tmp, path):
        count["n"] += 1
        real(tmp, path)
    mod._replace = replace
    return lambda: print(f"replaces={count['n']}", file=sys.stderr)


def _win_share(mod, k):
    mod._IS_WINDOWS = True
    real = mod._replace
    left = {"n": -1 if k == "always" else int(k)}

    def replace(tmp, path):
        if left["n"] != 0:
            left["n"] -= 1
            raise PermissionError(13, "The process cannot access the file")
        real(tmp, path)
    mod._replace = replace


def _lock_wait(mod, seconds):
    mod._LOCK_WAIT_S = float(seconds)


def _no_link(mod):
    def link(src, dst):
        raise OSError(errno.EPERM, "Operation not permitted")   # FAT, some network shares
    mod._link = link


MODES: dict = {
    "none": lambda mod: None,
    "kill-before-replace": _kill_before_replace,
    "change-once": _change(1),
    "change-always": _change(-1),
    "count-replace": _count_replace,
    "win-share": _win_share,
    "lock-wait": _lock_wait,
    "no-link": _no_link,
}


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
