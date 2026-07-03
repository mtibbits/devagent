#!/usr/bin/env python3
"""Minimal TOML CLI shim used by devAgent bash libraries.

Reads via Python 3.11+ stdlib tomllib. Writes by emitting a conservative
subset of TOML by hand — we only need: top-level tables, nested tables,
string/bool/int scalars. Lists/dates/inline-tables are read-only.

Mutation verbs (set [--print-old], set-bool, set-int, unset, set-many,
set-if) acquire an exclusive lock on a sibling .lock file for the entire
read-modify-write cycle and write via tempfile + atomic os.rename.
Concurrent writers are serialized. The lock uses fcntl.flock on POSIX
and falls back to msvcrt.locking on Windows (where fcntl does not
exist); read-only verbs never touch the lock, so a missing fcntl must
not break them (that was #288).

On POSIX, readers do not need to lock: rename atomicity guarantees a
consistent view. That guarantee is weaker on Windows — a concurrent
reader holding the file open can make a writer's os.replace raise
PermissionError — a pre-existing gap this module does not yet close on
Windows (tracked in #293); it is not introduced here.
"""

from __future__ import annotations
import datetime
try:
    import fcntl
except ImportError:   # Windows / any interpreter without fcntl
    fcntl = None      # _locked_rmw falls back to msvcrt (imported there,
                      # so read-only verbs never depend on either module)
import sys
import tomllib
from contextlib import contextmanager
from pathlib import Path


def _load(path: Path) -> dict:
    with path.open("rb") as fh:
        return tomllib.load(fh)


class _NoWrite(Exception):
    """Sentinel: escape _locked_rmw WITHOUT dumping (#96 — a compare-fail or
    rejected transaction must leave the file byte-identical; the clean-exit
    path always rewrites)."""
    def __init__(self, code: int, msg: str = ""):
        self.code = code
        self.msg = msg


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
    # Open with "a" (never "w"): msvcrt byte-range locks are mandatory, and a
    # truncating open of a .lock another process holds can fail. "a" never
    # truncates and is equivalent for advisory flock. Content is never used.
    with lock_path.open("a") as lock:
        if fcntl:
            fcntl.flock(lock, fcntl.LOCK_EX)
        else:
            import errno
            import msvcrt
            # msvcrt.locking(LK_LOCK) waits ~10×1s then raises OSError with
            # errno EDEADLOCK when the region is held elsewhere; flock(LOCK_EX)
            # instead blocks indefinitely. Retry ONLY that contention error to
            # match flock semantics (each attempt blocks internally, so this is
            # not a busy-spin); any other OSError (bad fd, invalid arg) is a
            # real failure and must propagate rather than spin. Lock 1 byte
            # at a fixed offset (0).
            lock.seek(0)
            while True:
                try:
                    msvcrt.locking(lock.fileno(), msvcrt.LK_LOCK, 1)
                    break
                except OSError as e:
                    if e.errno != errno.EDEADLOCK:
                        raise
        try:
            data = _load(path)
            yield data
            _dump(path, data)
        finally:
            if fcntl:
                fcntl.flock(lock, fcntl.LOCK_UN)
            else:
                # Best-effort unlock: the OS drops the lock at handle close
                # regardless, so a raising seek/LK_UNLCK here must never mask
                # an exception propagating from the with-block body.
                try:
                    lock.seek(0)
                    msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
                except OSError:
                    pass


def _walk(data: dict, dotted: str):
    cur = data
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            raise KeyError(dotted)
        cur = cur[part]
    return cur


def _emit_str(s: str) -> str:
    # #99: escape \ " and control chars so a value containing a newline (or any
    # control char) can't produce invalid TOML that bricks every later load.
    out = []
    for c in s:
        o = ord(c)
        if c == "\\":
            out.append("\\\\")
        elif c == '"':
            out.append('\\"')
        elif c == "\n":
            out.append("\\n")
        elif c == "\t":
            out.append("\\t")
        elif c == "\r":
            out.append("\\r")
        elif o < 0x20 or o == 0x7F:
            out.append(f"\\u{o:04X}")
        else:
            out.append(c)
    return '"' + "".join(out) + '"'


def _emit_value(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return _emit_str(v)
    # #99: emit the remaining legal-to-read types so mutating a file that already
    # contains them does not die with a raw TypeError mid-rewrite.
    if isinstance(v, float):
        return repr(v)
    if isinstance(v, (datetime.datetime, datetime.date, datetime.time)):
        return v.isoformat()
    if isinstance(v, list):
        return "[" + ", ".join(_emit_value(x) for x in v) + "]"
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


def _coerce(typ: str, key: str, raw: str):
    """Coerce a typed CLI value (#96). Raises ValueError with a clean message
    (callers map it to exit 2) — shared by set-many and the set-int path so
    typing policy cannot diverge."""
    if typ == "str":
        return _parse_raw(raw)
    if typ == "int":
        try:
            return int(raw)
        except ValueError:
            raise ValueError(f"'{raw}' is not an int for key '{key}'")
    if typ == "bool":
        if raw not in ("true", "false"):
            raise ValueError(f"'{raw}' is not true|false for key '{key}'")
        return raw == "true"
    raise ValueError(f"unknown type '{typ}'")


def _parse_raw(raw: str):
    """Parse a raw CLI-supplied scalar.

    Quoted strings ('...' or "...") are stripped. Bare tokens are passed
    through as strings (callers should use set-bool/set-int for typed values).
    """
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in ('"', "'"):
        return raw[1:-1]
    return raw


def _has_comment(raw: str) -> bool:
    """True if the TOML text contains a real comment (a '#' outside a string).

    #100: mutation rewrites from the parsed tree and drops comments, so the
    mutation verbs refuse comment-bearing files. A '#' inside a "..."/'...'
    string value is not a comment.
    """
    for line in raw.splitlines():
        quote = None
        for ch in line:
            if quote:
                if ch == quote:
                    quote = None
            elif ch in ('"', "'"):
                quote = ch
            elif ch == '#':
                return True
    return False


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: _toml.py <verb> <file> [args...]", file=sys.stderr)
        return 2
    # #96: `set --print-old <file> <key> <value>` — strip the flag before
    # positional parsing (it sits between verb and file).
    print_old = False
    if argv[0] == "set" and len(argv) >= 2 and argv[1] == "--print-old":
        print_old = True
        argv = [argv[0]] + argv[2:]
        if len(argv) < 2:
            print("usage: _toml.py set --print-old <file> <key> <value>", file=sys.stderr)
            return 2
    # #96: set-many --print-old <key> — emit that key's pre-write value from
    # inside the lock (the race-free clobber-warn input for transactions).
    sm_print_old = None
    if argv[0] == "set-many" and len(argv) >= 3 and argv[1] == "--print-old":
        sm_print_old = argv[2]
        argv = [argv[0]] + argv[3:]
        if len(argv) < 2:
            print("usage: _toml.py set-many --print-old <key> <file> <triplets...>", file=sys.stderr)
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
        # #99: distinguish an unparseable file (exit 2) from a missing key
        # (exit 1) so state_get does not silently report "no active issue" on a
        # corrupted state file.
        try:
            data = _load(file)
        except Exception as e:
            print(f"_toml: {file}: {e}", file=sys.stderr)
            return 2
        try:
            v = _walk(data, rest[0])
        except KeyError:
            return 1
        if isinstance(v, dict):
            print(f"_toml: '{rest[0]}' is a table, not a value", file=sys.stderr)
            return 1
        print(v if isinstance(v, str) else _emit_value(v))
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

    # #100: mutation rewrites the file from the parsed tree, dropping comments
    # and reformatting inline tables. Refuse a comment-bearing file (e.g. the
    # hand-commented config.toml) so a mis-pointed mutation can't destroy it.
    # Machine-written state files have no comments; new files don't exist yet.
    # Shared by ALL mutation verbs (#96 hoisted the duplicate).
    if verb in {"set", "set-bool", "set-int", "unset", "set-many", "set-if"}:
        if file.exists() and _has_comment(file.read_text()):
            print(f"_toml: refusing to mutate comment-bearing file {file} "
                  "(mutation drops comments; it is for comment-free state files)",
                  file=sys.stderr)
            return 1

    if verb in {"set", "set-bool", "set-int", "unset"}:
        # #96: print_old (set --print-old) emits the pre-write value from
        # INSIDE the lock (race-free clobber-warn input): the old value line
        # if the key existed (empty line for empty string), nothing if absent.
        # Validate args BEFORE entering the lock so a bad invocation
        # doesn't briefly hold the lock for no reason.
        if verb == "set-bool" and rest[1] not in ("true", "false"):
            print("_toml: set-bool wants true|false", file=sys.stderr)
            return 2
        if verb == "set-int":
            try:
                _coerce("int", rest[0], rest[1])
            except ValueError as e:
                print(f"_toml: set-int: {e}", file=sys.stderr)
                return 2
        with _locked_rmw(file) as data:
            if verb == "unset":
                _unset_path(data, rest[0])
            else:
                key, raw = rest[0], rest[1]
                if verb == "set-bool":
                    _set_path(data, key, raw == "true")
                elif verb == "set-int":
                    _set_path(data, key, int(raw))  # pre-validated above
                else:
                    if print_old:
                        try:
                            prev = _walk(data, key)
                            if not isinstance(prev, dict):
                                print(prev if isinstance(prev, str) else _emit_value(prev))
                        except KeyError:
                            pass
                    _set_path(data, key, _parse_raw(raw))
        return 0

    if verb == "set-many-if":
        # #240: conditional-mirror transaction. Usage:
        #   set-many-if <file> <pred-key> <expected> --then <triplets> --also <triplets>
        # --also triplets are written unconditionally; --then triplets are
        # included iff <pred-key>'s CURRENT value == <expected>, evaluated
        # INSIDE the lock (an absent pred-key is a mismatch). This is the
        # primitive that makes "mirror top-level iff this issue is the active
        # one" race-free — a read-then-set-many pair has a TOCTOU window.
        # All triplets (both lists) validate before any write; exit 2 on any
        # validation/parse error with the file untouched (_NoWrite).
        try:
            if len(rest) < 2:
                print("_toml: set-many-if wants <pred-key> <expected> --then ... --also ...", file=sys.stderr)
                return 2
            pred_key, expected = rest[0], rest[1]
            then_raw: list[str] = []
            also_raw: list[str] = []
            bucket = None
            for tok in rest[2:]:
                if tok == "--then":
                    bucket = then_raw
                elif tok == "--also":
                    bucket = also_raw
                elif bucket is None:
                    print(f"_toml: set-many-if: unexpected '{tok}' before --then/--also", file=sys.stderr)
                    return 2
                else:
                    bucket.append(tok)

            def _triplets(raw: list[str], label: str):
                if len(raw) % 3 != 0:
                    raise ValueError(f"{label} wants <str|int|bool> <key> <value> triplets")
                out = []
                for i in range(0, len(raw), 3):
                    out.append((raw[i + 1], _coerce(raw[i], raw[i + 1], raw[i + 2])))
                return out

            try:
                then_triplets = _triplets(then_raw, "--then")
                also_triplets = _triplets(also_raw, "--also")
            except ValueError as e:
                print(f"_toml: set-many-if: {e}", file=sys.stderr)
                return 2
            with _locked_rmw(file) as data:
                try:
                    cur = _walk(data, pred_key)
                    cur_str = cur if isinstance(cur, str) else _emit_value(cur)
                    matched = (not isinstance(cur, dict)) and cur_str == expected
                except KeyError:
                    matched = False
                for key, value in also_triplets:
                    _set_path(data, key, value)
                if matched:
                    for key, value in then_triplets:
                        _set_path(data, key, value)
            return 0
        except tomllib.TOMLDecodeError as e:
            print(f"_toml: {file}: {e}", file=sys.stderr)
            return 2

    if verb in {"set-many", "set-if"}:
        # #96 transactional verbs. Both catch parse errors as exit 2 (the #99
        # convention `get` already follows) and escape the RMW without a dump
        # on any rejection path (see _NoWrite).
        try:
            if verb == "set-many":
                # Triplets: <str|int|bool> <key> <value> ... Validate ALL
                # before any write (all-or-nothing).
                if not rest or len(rest) % 3 != 0:
                    print("_toml: set-many wants <str|int|bool> <key> <value> triplets", file=sys.stderr)
                    return 2
                triplets = []
                for i in range(0, len(rest), 3):
                    typ, key, raw = rest[i], rest[i + 1], rest[i + 2]
                    try:
                        triplets.append((key, _coerce(typ, key, raw)))
                    except ValueError as e:
                        print(f"_toml: set-many: {e}", file=sys.stderr)
                        return 2
                with _locked_rmw(file) as data:
                    if sm_print_old is not None:
                        try:
                            prev = _walk(data, sm_print_old)
                            if not isinstance(prev, dict):
                                print(prev if isinstance(prev, str) else _emit_value(prev))
                        except KeyError:
                            pass
                    for key, value in triplets:
                        _set_path(data, key, value)
                return 0
            # set-if <file> <key> <expected|--absent> <new>
            if len(rest) != 3:
                print("_toml: set-if wants <key> <expected|--absent> <new>", file=sys.stderr)
                return 2
            key, expected, new_raw = rest
            with _locked_rmw(file) as data:
                try:
                    cur = _walk(data, key)
                    if isinstance(cur, dict):
                        # A table is not CAS-able (review L1: keep the exit
                        # contract — 0/2/3 — instead of a traceback).
                        raise _NoWrite(2, "")
                    cur_str = cur if isinstance(cur, str) else _emit_value(cur)
                    absent = False
                except KeyError:
                    cur_str, absent = None, True
                ok = absent if expected == "--absent" else ((not absent) and cur_str == expected)
                if not ok:
                    raise _NoWrite(3, "" if absent else cur_str)
                _set_path(data, key, _parse_raw(new_raw))
            return 0
        except _NoWrite as nw:
            if nw.msg:
                print(nw.msg)
            return nw.code
        except tomllib.TOMLDecodeError as e:
            print(f"_toml: {file}: {e}", file=sys.stderr)
            return 2

    print(f"_toml: unknown verb '{verb}'", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
