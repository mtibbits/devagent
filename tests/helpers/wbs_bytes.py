#!/usr/bin/env python3
"""Byte-level helpers for the #701 WBS tests (stdlib only, binary I/O).

Deliberately does not import scripts/lib/wbs-parser.py: expected values are
derived independently of the code under test.

    wbs_bytes.py variant <src> <lf|crlf|lf-nofinal|crlf-nofinal> <dst>
    wbs_bytes.py glyph-offset <file> <needle>
    wbs_bytes.py insert-after <src> <dst> <anchor> <lf|crlf> <line>...
"""

from __future__ import annotations

import sys
from pathlib import Path

LF = bytes([10])
CRLF = bytes([13, 10])
KINDS = ("lf", "crlf", "lf-nofinal", "crlf-nofinal")


def _lf_only(data: bytes) -> bytes:
    return data.replace(CRLF, LF)


def variant(src: str, kind: str, dst: str) -> int:
    if kind not in KINDS:
        print(f"wbs_bytes: unknown variant '{kind}'", file=sys.stderr)
        return 2
    data = _lf_only(Path(src).read_bytes())
    if kind.endswith("-nofinal"):
        data = data.rstrip(LF)
    if kind.startswith("crlf"):
        data = data.replace(LF, CRLF)
    Path(dst).write_bytes(data)
    # Guard against a no-op conversion: re-read and check the property.
    got = Path(dst).read_bytes()
    if kind.startswith("crlf"):
        n_crlf = got.count(CRLF)
        if n_crlf == 0 or n_crlf != got.count(LF):
            print(f"wbs_bytes: {dst} is not all-CRLF", file=sys.stderr)
            return 1
    elif got.count(bytes([13])):
        print(f"wbs_bytes: {dst} carries a CR", file=sys.stderr)
        return 1
    if kind.endswith("-nofinal") and got.endswith(LF):
        print(f"wbs_bytes: {dst} ends in a newline", file=sys.stderr)
        return 1
    if not kind.endswith("-nofinal") and not got.endswith(LF):
        print(f"wbs_bytes: {dst} lacks a final newline", file=sys.stderr)
        return 1
    return 0


def glyph_offset(path: str, needle: str) -> int:
    data = Path(path).read_bytes()
    want = needle.encode("utf-8")
    pos = 0
    for line in data.splitlines(keepends=True):
        if want in line:
            i = line.find(b"- [")
            if i >= 0 and line[i + 4 : i + 6] == b"] " and want in line[i + 6 :]:
                print(pos + i + 4)
                return 0
        pos += len(line)
    print(f"wbs_bytes: no '- [g] {needle}' line in {path}", file=sys.stderr)
    return 1


def insert_after(src: str, dst: str, anchor: str, eol: str, lines: list[str]) -> int:
    if eol not in ("lf", "crlf"):
        print(f"wbs_bytes: unknown eol '{eol}'", file=sys.stderr)
        return 2
    term = CRLF if eol == "crlf" else LF
    data = Path(src).read_bytes()
    want = anchor.encode("utf-8")
    out: list[bytes] = []
    done = False
    for line in data.splitlines(keepends=True):
        out.append(line)
        if not done and want in line:
            out.extend(x.encode("utf-8") + term for x in lines)
            done = True
    if not done:
        print(f"wbs_bytes: anchor '{anchor}' not in {src}", file=sys.stderr)
        return 1
    Path(dst).write_bytes(b"".join(out))
    return 0


def main(argv: list[str]) -> int:
    if len(argv) >= 5 and argv[1] == "variant":
        return variant(argv[2], argv[3], argv[4])
    if len(argv) == 4 and argv[1] == "glyph-offset":
        return glyph_offset(argv[2], argv[3])
    if len(argv) >= 7 and argv[1] == "insert-after":
        return insert_after(argv[2], argv[3], argv[4], argv[5], argv[6:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
