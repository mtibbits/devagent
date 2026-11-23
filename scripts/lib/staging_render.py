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
- Strict header: line 1 starts `# <repo>#<num> — ` (the title is one line:
  scripts/issue/github.sh turns a CR or LF in it into a space, so a title
  cannot forge the header below it); line 2 is blank; then
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

import importlib.util
import os
import re
import sys


def _sibling(name: str):
    """Load scripts/lib/<name>.py by absolute path (never through sys.path:
    the script runs under `python3 -I`)."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_layout = _sibling("staging_layout")
HEADER_LINE = _layout.HEADER_LINE
HEADING = _layout.HEADING
Layout = _layout.Layout
_split = _layout._split
CONTROL = re.compile(rb"[\x00-\x1f\x7f]")


def _escape(b: bytes) -> bytes:
    return CONTROL.sub(lambda m: b"<U+%04X>" % m.group(0)[0], b)


def render(data: bytes, repo: bytes, num: bytes) -> tuple:
    """(candidate bytes, trailer count)."""
    lines = _split(data)
    prefix = b"# " + repo + b"#" + num + " — ".encode()
    if not lines or not lines[0][0].startswith(prefix):
        raise Layout("line 1")
    body, first, count = _layout.layout(lines)
    out = [prefix + _escape(lines[0][0][len(prefix):]) + lines[0][1], lines[1][0] + lines[1][1]]
    for c, e in lines[2:body - 3]:
        head = HEADER_LINE.match(c).group(0)
        out.append(head + _escape(c[len(head):]) + e)
    out += [c + e for c, e in lines[body - 3:first + 1]]
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
