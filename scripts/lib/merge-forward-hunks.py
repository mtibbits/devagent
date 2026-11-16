"""#1125: the append-only hunk checker for `preship-verified-head.sh forward`.

Usage: python3 -I merge-forward-hunks.py <merged> <head> <vh40> <T40>

<merged> is git's own merge of <vh40> and <T40> for one file
(`git -c merge.conflictStyle=diff3 merge-tree --write-tree`, conflict markers
labelled with the two arguments); <head> is the same file at HEAD, the
operator's resolution. Both are read as bytes.

Accepts (exit 0, no output) iff HEAD equals git's merge outside the conflict
hunks, and every hunk was resolved by keeping both sides: an empty base
section, and HEAD's non-blank lines in the hunk's slot equal to ours' then
theirs' non-blank lines, or theirs' then ours'. When HEAD's first `## ` line
is `## [Unreleased]`, the branch's (ours') lines must stay under it.

Refuses with exit 3 and one reason line on stdout. Exit 2 is a usage or I/O
error, or any uncaught exception; a caller accepts ONLY on exit 0.
"""

import re
import sys

BLANK = re.compile(rb"^[ \t\r]*$")
BASE_MARK = re.compile(rb"^\|{7}( .*)?$")
SEP_MARK = b"=" * 7
HEADING = re.compile(rb"^## ")
UNRELEASED = re.compile(rb"^## \[Unreleased\][ \t\r]*$")


class Refuse(Exception):
    pass


def _blank(line):
    return BLANK.match(line) is not None


def parse(merged, vh, t):
    """Split git's merge into [ctx0, hunk1, ctx1, ..., ctxN].

    A hunk is (ours, base, theirs), each a list of lines."""
    open_mark = b"<" * 7 + b" " + vh
    close_mark = b">" * 7 + b" " + t
    parts, ctx = [], []
    state, ours, base, theirs, opened_at = "ctx", [], [], [], 0
    for i, line in enumerate(merged, 1):
        if state == "ctx":
            if line == open_mark:
                parts.append(ctx)
                ctx, ours, base, theirs, opened_at = [], [], [], [], i
                state = "ours"
            elif line == close_mark:
                raise Refuse(f"unbalanced conflict markers at line {i}")
            else:
                ctx.append(line)
        elif state == "ours":
            if BASE_MARK.match(line):
                state = "base"
            elif line in (open_mark, close_mark, SEP_MARK):
                raise Refuse(f"unbalanced conflict markers at line {i}")
            else:
                ours.append(line)
        elif state == "base":
            if line == SEP_MARK:
                state = "theirs"
            elif line in (open_mark, close_mark):
                raise Refuse(f"unbalanced conflict markers at line {i}")
            else:
                base.append(line)
        else:  # theirs
            if line == close_mark:
                parts.append((ours, base, theirs))
                state = "ctx"
            elif line == open_mark or line == SEP_MARK or BASE_MARK.match(line):
                raise Refuse(f"unbalanced conflict markers at line {i}")
            else:
                theirs.append(line)
    if state != "ctx":
        raise Refuse(f"unbalanced conflict markers at line {opened_at}")
    parts.append(ctx)
    return parts


def _leading_blanks(lines):
    n = 0
    for line in lines:
        if not _blank(line):
            break
        n += 1
    return n


def check(merged_bytes, head_bytes, vh, t):
    merged = merged_bytes.split(b"\n")
    head = head_bytes.split(b"\n")
    parts = parse(merged, vh, t)
    hunks = parts[1::2]
    if not hunks:
        raise Refuse("no conflict hunk found")
    for n, (_ours, base, _theirs) in enumerate(hunks, 1):
        if base:
            raise Refuse(f"hunk {n} has a non-empty base section")

    pos = 0                 # index into head
    from_ours = []          # HEAD indices whose line came from ours, per hunk
    for k, part in enumerate(parts):
        if k % 2 == 0:      # context: must match HEAD exactly
            for j, line in enumerate(part):
                if pos + j >= len(head) or head[pos + j] != line:
                    raise Refuse("HEAD differs from git's merge outside the conflict"
                                 f" hunks (HEAD line {pos + j + 1})")
            pos += len(part)
            continue
        n = k // 2 + 1
        ours, _base, theirs = part
        o = [x for x in ours if not _blank(x)]
        x = [y for y in theirs if not _blank(y)]
        need = len(o) + len(x)
        # The slot: every blank up to its need-th non-blank line ...
        idx, got, end = pos, [], pos
        while len(got) < need and idx < len(head):
            if not _blank(head[idx]):
                got.append(idx)
            idx += 1
        end = idx
        # ... then as many trailing blanks as leave the next context's leading
        # blanks intact.
        trailing = _leading_blanks(head[end:])
        end += max(0, trailing - _leading_blanks(parts[k + 1]))
        lines = [head[i] for i in got]
        if lines == o + x:
            from_ours.append((n, got[:len(o)]))
        elif lines == x + o:
            from_ours.append((n, got[len(x):]))
        else:
            raise Refuse(f"hunk {n} is not both sides' lines as two contiguous runs")
        pos = end
    if pos != len(head):
        raise Refuse("HEAD differs from git's merge outside the conflict"
                     f" hunks (HEAD line {pos + 1})")

    headings = [i for i, line in enumerate(head) if HEADING.match(line)]
    if headings and UNRELEASED.match(head[headings[0]]):
        start = headings[0]
        stop = headings[1] if len(headings) > 1 else len(head)
        for n, idxs in from_ours:
            if any(not (start < i < stop) for i in idxs):
                raise Refuse(f"hunk {n}: the branch's lines are not under ## [Unreleased]")


def main(argv):
    try:
        if len(argv) != 4:
            print("usage: merge-forward-hunks.py <merged> <head> <vh40> <T40>",
                  file=sys.stderr)
            return 2
        with open(argv[0], "rb") as f:
            merged = f.read()
        with open(argv[1], "rb") as f:
            head = f.read()
        try:
            check(merged, head, argv[2].encode(), argv[3].encode())
        except Refuse as e:
            print(str(e))
            return 3
        return 0
    except Exception as e:  # noqa: BLE001 — any failure is "could not check"
        print(f"merge-forward-hunks: {type(e).__name__}: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
