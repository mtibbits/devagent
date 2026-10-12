#!/usr/bin/env python3
"""Byte-level helpers for the #701 WBS tests (stdlib only, binary I/O).

Deliberately does not import scripts/lib/wbs-parser.py: expected values are
derived independently of the code under test.

    wbs_bytes.py variant <src> <lf|crlf|lf-nofinal|crlf-nofinal> <dst>
    wbs_bytes.py glyph-offset <file> <needle>
    wbs_bytes.py insert-after <src> <dst> <anchor> <lf|crlf> <line>...
    wbs_bytes.py patch-leaf <src> <dst> <needle> <glyph> <status_src>
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


def patch_leaf(src: str, dst: str, needle: str, glyph: str, status_src: str) -> int:
    """Expected bytes for a #703 reconcile of the `- [g] <needle>` line.

    The glyph byte becomes <glyph>; an existing `status_src:` value becomes
    <status_src>; otherwise `, status_src: <v>` goes just before the line's
    last `}` (no comma when the block holds only whitespace). Every other
    byte is kept.
    """
    data = Path(src).read_bytes()
    want = needle.encode("utf-8")
    out: list[bytes] = []
    done = False
    for line in data.splitlines(keepends=True):
        i = line.find(b"- [")
        if not done and i >= 0 and line[i + 4 : i + 6] == b"] " and want in line[i + 6 :]:
            line = line[: i + 3] + glyph.encode("utf-8") + line[i + 4 :]
            tok = status_src.encode("utf-8")
            key = line.find(b"status_src:")
            if key >= 0:
                v = key + len(b"status_src:")
                while line[v : v + 1] == b" ":
                    v += 1
                e = v
                while line[e : e + 1] not in (b",", b"}", b" ", b""):
                    e += 1
                line = line[:v] + tok + line[e:]
            else:
                close = line.rfind(b"}")
                open_ = line.rfind(b"{", 0, close)
                if close < 0 or open_ < 0:
                    print(f"wbs_bytes: no meta block on the '{needle}' line", file=sys.stderr)
                    return 1
                sep = b", " if line[open_ + 1 : close].strip() else b""
                line = line[:close] + sep + b"status_src: " + tok + line[close:]
            done = True
        out.append(line)
    if not done:
        print(f"wbs_bytes: no '- [g] {needle}' line in {src}", file=sys.stderr)
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
    if len(argv) == 7 and argv[1] == "patch-leaf":
        return patch_leaf(argv[2], argv[3], argv[4], argv[5], argv[6])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
