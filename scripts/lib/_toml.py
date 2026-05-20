#!/usr/bin/env python3
"""Minimal TOML CLI shim used by devAgent bash libraries.

Reads via Python 3.11+ stdlib tomllib. Writes by emitting a conservative
subset of TOML by hand — we only need: top-level tables, nested tables,
string/bool/int scalars. Lists/dates/inline-tables are read-only.

Mutation verbs (set, set-bool, set-int, unset) acquire an exclusive
fcntl.flock on a sibling .lock file for the entire read-modify-write
cycle and write via tempfile + atomic os.rename. Concurrent writers
are serialized; readers do not need to lock (POSIX rename atomicity
guarantees a consistent view).
"""

from __future__ import annotations
import fcntl
import sys
import tomllib
from contextlib import contextmanager
from pathlib import Path


def _load(path: Path) -> dict:
    with path.open("rb") as fh:
        return tomllib.load(fh)


@contextmanager
def _locked_rmw(path: Path):
    """Exclusive-locked read-modify-write.

    Usage:
        with _locked_rmw(path) as data:
            data["x"] = 1
        # _dump(path, data) happens automatically on clean exit;
        # lock is released even on exception.
    """
    lock_path = path.with_suffix(path.suffix + ".lock")
    lock_path.touch(exist_ok=True)
    with lock_path.open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            data = _load(path)
            yield data
            _dump(path, data)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def _walk(data: dict, dotted: str):
    cur = data
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            raise KeyError(dotted)
        cur = cur[part]
    return cur


def _emit_value(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        # quote double-quotes and backslashes
        esc = v.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{esc}"'
    raise TypeError(f"cannot emit type {type(v).__name__}")


def _emit_table(name: str, table: dict, out: list[str]) -> None:
    if name:
        out.append(f"[{name}]")
    scalars = []
    subtables = []
    for k, v in table.items():
        if isinstance(v, dict):
            subtables.append((k, v))
        else:
            scalars.append((k, v))
    for k, v in scalars:
        out.append(f"{k} = {_emit_value(v)}")
    if name or scalars:
        out.append("")
    for k, sub in subtables:
        _emit_table(f"{name}.{k}" if name else k, sub, out)


def _dump(path: Path, data: dict) -> None:
    out: list[str] = []
    _emit_table("", data, out)
    text = "\n".join(out).rstrip() + "\n"
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text)
    tmp.replace(path)


def _set_path(data: dict, dotted: str, value) -> None:
    parts = dotted.split(".")
    cur = data
    for p in parts[:-1]:
        cur = cur.setdefault(p, {})
        if not isinstance(cur, dict):
            raise ValueError(f"{p} is not a table")
    cur[parts[-1]] = value


def _unset_path(data: dict, dotted: str) -> None:
    parts = dotted.split(".")
    cur = data
    for p in parts[:-1]:
        if p not in cur or not isinstance(cur[p], dict):
            return
        cur = cur[p]
    cur.pop(parts[-1], None)


def _list_tables(data: dict, prefix: str = "") -> list[str]:
    out = []
    for k, v in data.items():
        if isinstance(v, dict):
            name = f"{prefix}.{k}" if prefix else k
            out.append(name)
            out.extend(_list_tables(v, name))
    return out


def _list_keys(data: dict, table: str | None) -> list[str]:
    cur = data if not table else _walk(data, table)
    if not isinstance(cur, dict):
        raise KeyError(table or "")
    return [k for k, v in cur.items() if not isinstance(v, dict)]


def _parse_raw(raw: str):
    """Parse a raw CLI-supplied scalar.

    Quoted strings ('...' or "...") are stripped. Bare tokens are passed
    through as strings (callers should use set-bool/set-int for typed values).
    """
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in ('"', "'"):
        return raw[1:-1]
    return raw


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: _toml.py <verb> <file> [args...]", file=sys.stderr)
        return 2
    verb, file = argv[0], Path(argv[1])
    rest = argv[2:]

    if verb == "validate":
        try:
            _load(file)
        except Exception as e:
            print(f"_toml: {e}", file=sys.stderr)
            return 1
        return 0

    if verb == "get":
        data = _load(file)
        try:
            v = _walk(data, rest[0])
        except KeyError:
            return 1
        if isinstance(v, dict):
            print(f"_toml: '{rest[0]}' is a table, not a value", file=sys.stderr)
            return 1
        print(_emit_value(v).strip('"') if isinstance(v, str)
              else _emit_value(v))
        return 0

    if verb == "list-tables":
        data = _load(file)
        for t in _list_tables(data):
            print(t)
        return 0

    if verb == "list-keys":
        data = _load(file)
        table = rest[0] if rest else None
        try:
            for k in _list_keys(data, table):
                print(k)
        except KeyError:
            return 1
        return 0

    if verb in {"set", "set-bool", "set-int", "unset"}:
        # Validate args BEFORE entering the lock so a bad invocation
        # doesn't briefly hold the lock for no reason.
        if verb == "set-bool" and rest[1] not in ("true", "false"):
            print("_toml: set-bool wants true|false", file=sys.stderr)
            return 2
        with _locked_rmw(file) as data:
            if verb == "unset":
                _unset_path(data, rest[0])
            else:
                key, raw = rest[0], rest[1]
                if verb == "set-bool":
                    _set_path(data, key, raw == "true")
                elif verb == "set-int":
                    _set_path(data, key, int(raw))
                else:
                    _set_path(data, key, _parse_raw(raw))
        return 0

    print(f"_toml: unknown verb '{verb}'", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
