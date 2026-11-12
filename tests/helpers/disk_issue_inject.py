#!/usr/bin/env python3
"""Failure injection for scripts/lib/disk-issue.py (#1008).

    disk_issue_inject.py <mode> [<mode-arg>] -- <disk-issue args>

Loads the module by path, patches module attributes in-process for <mode>, and
returns main(args). Production code carries no environment seams (register
Issue-565;578): every failure a test needs is injected here.
"""
from __future__ import annotations

import importlib.util
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


MODES: dict = {
    "none": lambda mod: None,
}


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
