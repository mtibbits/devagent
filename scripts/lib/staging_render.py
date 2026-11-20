#!/usr/bin/env python3
"""staging_render.py — the trust render of a fetched ticket (#715).

Run as `python3 -I -X utf8 staging_render.py <raw> <out> <repo> <num>`
(scripts/lib/staging.sh staging_render). <raw> is the backend's `fetch`
output; <out> receives the candidate issue.md that pull's floor checks and
staging_promote installs byte for byte. Bytes in, bytes out.

Fetch's layout is kept, so flags_get, issue_labels and catchup read the
candidate unchanged:

    # <repo>#<num> — <title>
    <blank>
    - State: …  - Author: …  - Labels: …  - URL: …  [- Created: …]
    <blank>
    ---
    <blank>
    <body, byte for byte>
    <blank>
    ---
    <blank>
    ## Comments (N)
    [<blank>
    Comments not rendered under trust: N]       (only when N > 0)

Rules:
- Lines end at LF. A layout line is matched without its trailing CRs (Git
  Bash jq writes CRLF), and every line is copied with its own ending; the
  count line and the blank before it take the comments heading's ending.
- Strict header: line 1 starts `# <repo>#<num> — `; line 2 is blank; then
  `- State:`, `- Author:`, `- Labels:`, `- URL:` and optionally `- Created:`,
  in that order and nothing else; then blank, `---`, blank.
- The body ends at the FIRST trailer: a line that is exactly
  `## Comments (<1-9 digits>)` whose three predecessors are blank, `---`,
  blank, all of them at or after the first body line. The search starts at
  the first body line, so the header's own rule is never a predecessor.
  Everything after that heading (the comment text) is dropped.
- Each byte 0x00-0x1F or 0x7F in the title or a header value becomes
  `<U+00HH>` (uppercase hex). Nothing else is rewritten; other characters
  are #923's.

The embedded-layout edge, an accepted residual until #953's issue-fields read:
a body that itself holds the full trailer (blank, `---`, blank,
`## Comments (n)`) is cut there, so the workflow reads less than the tracker
shows, never more, and the count is the body's number. flags_get has the same
blind spot (flags.sh residual (b)), so the steering the floor checks and the
steering the scaffold applies still agree. Two alternatives were considered
and rejected, so neither is re-proposed: quarantining on a second trailer
(any commenter could then hold any ticket), and a second `comment-list` read
to cut the exact suffix (a network read and a race path that #953 deletes).

Stdout: `trailers <k>` (k = every trailer-shaped heading after the header,
comments included; pull notes k > 1 after PASS). Exit 0 ok · 2 usage · 3
layout defect, whose stderr is exactly one of `line 1`, `line 2`,
`header line <n>`, `header keys`, `no header rule`, `no comments heading` —
never a ticket byte. Both streams are written as bytes with b"\\n"
(trust_policy.py's rule), so a CRLF host never adds a CR.
"""

from __future__ import annotations

import os
import re
import sys

HEADER_KEYS = (b"State", b"Author", b"Labels", b"URL")
OPTIONAL_KEY = b"Created"
HEADER_LINE = re.compile(rb"- ([A-Za-z]+):")
HEADING = re.compile(rb"## Comments \(([0-9]{1,9})\)")
CONTROL = re.compile(rb"[\x00-\x1f\x7f]")


class Layout(Exception):
    """The fetched text is not in fetch's layout; rc 3."""


def _escape(b: bytes) -> bytes:
    return CONTROL.sub(lambda m: b"<U+%04X>" % m.group(0)[0], b)


def _split(data: bytes) -> list:
    """[(content, ending)]: content without its trailing CRs, ending = those
    CRs plus the LF (b"" for a last line with no LF)."""
    parts = data.split(b"\n")
    lines = []
    for i, p in enumerate(parts):
        last = i == len(parts) - 1
        if last and p == b"":
            break
        c = p.rstrip(b"\r")
        lines.append((c, p[len(c):] + (b"" if last else b"\n")))
    return lines


def _is_trailer(lines: list, i: int, body: int) -> bool:
    return (i - 3 >= body and HEADING.fullmatch(lines[i][0]) is not None
            and lines[i - 1][0] == b"" and lines[i - 2][0] == b"---" and lines[i - 3][0] == b"")


def render(data: bytes, repo: bytes, num: bytes) -> tuple:
    """(candidate bytes, trailer count)."""
    lines = _split(data)
    prefix = b"# " + repo + b"#" + num + " — ".encode()
    if not lines or not lines[0][0].startswith(prefix):
        raise Layout("line 1")
    if len(lines) < 2 or lines[1][0] != b"":
        raise Layout("line 2")
    out = [prefix + _escape(lines[0][0][len(prefix):]) + lines[0][1], lines[1][0] + lines[1][1]]
    keys = []
    i = 2
    while i < len(lines) and lines[i][0] != b"":
        m = HEADER_LINE.match(lines[i][0])
        if m is None:
            raise Layout(f"header line {i + 1}")
        keys.append(m.group(1))
        head = m.group(0)
        out.append(head + _escape(lines[i][0][len(head):]) + lines[i][1])
        i += 1
    if tuple(keys) not in (HEADER_KEYS, HEADER_KEYS + (OPTIONAL_KEY,)):
        raise Layout("header keys")
    if i + 2 >= len(lines) or lines[i][0] != b"" or lines[i + 1][0] != b"---" or lines[i + 2][0] != b"":
        raise Layout("no header rule")
    body = i + 3
    first = None
    count = 0
    for j in range(body, len(lines)):
        if _is_trailer(lines, j, body):
            count += 1
            if first is None:
                first = j
    if first is None:
        raise Layout("no comments heading")
    out += [c + e for c, e in lines[i:first + 1]]
    n = int(HEADING.fullmatch(lines[first][0]).group(1))
    if n > 0:
        eol = lines[first][1] or b"\n"
        if not lines[first][1]:
            out[-1] += eol
        out.append(eol + b"Comments not rendered under trust: " + str(n).encode("ascii") + eol)
    return b"".join(out), count


def main(argv: list) -> int:
    if len(argv) != 4:
        sys.stderr.buffer.write(b"usage: staging_render.py <raw> <out> <repo> <num>\n")
        return 2
    raw, out, repo, num = argv
    with open(raw, "rb") as fh:
        data = fh.read()
    try:
        text, count = render(data, os.fsencode(repo), os.fsencode(num))
    except Layout as e:
        sys.stderr.buffer.write(str(e).encode("ascii") + b"\n")
        return 3
    with open(out, "wb") as fh:
        fh.write(text)
    sys.stdout.buffer.write(b"trailers " + str(count).encode("ascii") + b"\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
