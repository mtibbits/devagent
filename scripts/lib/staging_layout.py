"""staging_layout.py -- fetch's issue.md layout, read once for the trust
render and the character check (#715, #923).

A leaf module: it loads no sibling. staging_render.py (the render) and
chars.py (the candidate scan) both load it by absolute path, so the render and
the floor read the same layout (spec section 9.3). Bytes only.

    # <repo>#<num> -- <title>          (the separator is U+2014, spaced)
    <blank>
    - State: ...  - Author: ...  - Labels: ...  - URL: ...  [- Created: ...]
    <blank>
    ---
    <blank>
    <body>
    <blank>
    ---
    <blank>
    ## Comments (N)

See staging_render.py for the rules; layout() is the header walk and the
first-trailer search taken out of its render().
"""

import re

HEADER_KEYS = (b"State", b"Author", b"Labels", b"URL")
OPTIONAL_KEY = b"Created"
HEADER_LINE = re.compile(rb"- ([A-Za-z]+):")
HEADING = re.compile(rb"## Comments \(([0-9]{1,9})\)")


class Layout(Exception):
    """The fetched text is not in fetch's layout; rc 3."""


def _split(data):
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


def _is_trailer(lines, i, body):
    return (i - 3 >= body and HEADING.fullmatch(lines[i][0]) is not None
            and lines[i - 1][0] == b"" and lines[i - 2][0] == b"---" and lines[i - 3][0] == b"")


def layout(lines):
    """(body, first, count) for _split() lines whose line 1 the caller has
    checked: lines[2:body - 3] are the header lines, lines[body:first - 3]
    the body, lines[first] the first trailer's heading, and count the number
    of trailer-shaped headings. Indexes only; raises Layout."""
    if len(lines) < 2 or lines[1][0] != b"":
        raise Layout("line 2")
    keys = []
    i = 2
    while i < len(lines) and lines[i][0] != b"":
        m = HEADER_LINE.match(lines[i][0])
        if m is None:
            raise Layout("header line %d" % (i + 1))
        keys.append(m.group(1))
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
    return body, first, count
