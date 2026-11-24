#!/usr/bin/env python3
"""staging_render.py — the trust render of a fetched ticket (#715).

Run as `python3 -I -X utf8 staging_render.py <raw> <out> <repo> <num> [<allow-file>]`
(scripts/lib/staging.sh staging_render). <raw> is the backend's `fetch`
output; <out> receives the candidate issue.md that pull's floor checks and
staging_promote installs byte for byte, and <out>.mixed.json the mixed-script
record (#923). <allow-file> holds the trust policy's allowed_chars as a JSON
array (chars.load_allowlist); four arguments mean the empty allowlist. Bytes
in, bytes out.

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
- #923: each allowlisted set character whose run is at most two long, in the
  title and the State, Author and Labels values and in the body, becomes
  `<U+XXXX>` (chars.chars_escape_bytes); every other character is left for
  the floor's `chars` check. `URL`, `Created` and the layout lines are not
  touched.
- Then each byte 0x00-0x1F or 0x7F in the title or a header value becomes
  `<U+00HH>` (uppercase hex; #715). Nothing else is rewritten.
- <out>.mixed.json: chars.mixed_record_bytes over the unescaped title, then
  the body, as compact JSON plus LF (`[]` when no word is mixed). It is
  written after the candidate and before the `trailers` line, and lives and
  dies with the staged file (staging.sh).

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
comments included; pull notes k > 1 after PASS). Exit 0 ok · 2 usage · 4 a
malformed allow file, or chars.py cannot load (both streams empty, nothing
written) · 3 layout defect, whose stderr is exactly one of `line 1`, `line 2`,
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


try:
    _chars = _sibling("chars")
except Exception:  # noqa: BLE001 - main() reports exit 4
    _chars = None
# The layout chars.py loaded, so both read one module (main() exits 4 first
# when it is missing).
_layout = _chars._L if _chars is not None else None
CONTROL = re.compile(rb"[\x00-\x1f\x7f]")
CHARS_KEYS = (b"State", b"Author", b"Labels")


def _escape(b: bytes) -> bytes:
    return CONTROL.sub(lambda m: b"<U+%04X>" % m.group(0)[0], b)


def render(data: bytes, repo: bytes, num: bytes, allow=frozenset()) -> tuple:
    """(candidate bytes, trailer count, mixed-script record entries)."""
    lines = _layout._split(data)
    prefix = b"# " + repo + b"#" + num + " — ".encode()
    if not lines or not lines[0][0].startswith(prefix):
        raise _layout.Layout("line 1")
    body, first, count = _layout.layout(lines)
    title = lines[0][0][len(prefix):]
    out = [prefix + _escape(_chars.chars_escape_bytes(title, allow)) + lines[0][1], lines[1][0] + lines[1][1]]
    for c, e in lines[2:body - 3]:
        m = _layout.HEADER_LINE.match(c)
        head, value = m.group(0), c[len(m.group(0)):]
        if m.group(1) in CHARS_KEYS:
            value = _chars.chars_escape_bytes(value, allow)
        out.append(head + _escape(value) + e)
    text = b"".join(c + e for c, e in lines[body:first - 3])
    out += [c + e for c, e in lines[body - 3:body]]
    out.append(_chars.chars_escape_bytes(text, allow))
    out += [c + e for c, e in lines[first - 3:first + 1]]
    record = _chars.mixed_record_bytes("title", title) + _chars.mixed_record_bytes("body", text)
    n = int(_layout.HEADING.fullmatch(lines[first][0]).group(1))
    if n > 0:
        eol = lines[first][1] or b"\n"
        if not lines[first][1]:
            out[-1] += eol
        out.append(eol + b"Comments not rendered under trust: " + str(n).encode("ascii") + eol)
    return b"".join(out), count, record


def main(argv: list) -> int:
    if len(argv) not in (4, 5):
        sys.stderr.buffer.write(b"usage: staging_render.py <raw> <out> <repo> <num> [<allow-file>]\n")
        return 2
    raw, out, repo, num = argv[:4]
    if _chars is None or _chars.LOAD_ERROR is not None:
        return 4
    try:
        allow = _chars.load_allowlist(argv[4] if len(argv) == 5 else None)
    except ValueError:
        return 4
    with open(raw, "rb") as fh:
        data = fh.read()
    try:
        text, count, record = render(data, os.fsencode(repo), os.fsencode(num), allow)
    except _layout.Layout as e:
        sys.stderr.buffer.write(str(e).encode("ascii") + b"\n")
        return 3
    with open(out, "wb") as fh:
        fh.write(text)
    with open(out + ".mixed.json", "wb") as fh:
        fh.write(_chars.record_json(record))
    sys.stdout.buffer.write(b"trailers " + str(count).encode("ascii") + b"\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
