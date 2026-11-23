#!/usr/bin/env python3
"""chars.py -- the pulled-text character check (#923; spec section 9.3).

Callables (bytes in, bytes out where the name says so):

  chars_scan(field, raw_bytes, allowlist) -> [(field, line, token)]
  chars_escape(text, allowlist) -> str
  chars_escape_bytes(raw_bytes, allowlist) -> bytes
  mixed_record(field, text) -> [{"field": ..., "line": n, "word_scripts": [...]}]
  mixed_record_bytes(field, raw_bytes) -> [...]
  candidate_scan(candidate_bytes, allowlist) -> [(field, line, token)]
  load_allowlist(path_or_None) -> frozenset

The set is chars_table.SET (Unicode 16.0.0; chars_gen.py says what it holds).
Every Unicode property comes from chars_table: nothing here asks the runtime
(no unicodedata, no str.is* predicate, no \\w \\d \\s class, no str.splitlines),
so the answer does not move with the Python that runs it.

Lines. A field's bytes are split into lines: a line ends at an LF together
with every CR directly before it, or else at a lone CR (CR CR LF is one
ending). U+000C, U+0085, U+2028 and U+2029 never end a line. Lines count from
1. Each line is decoded strictly as UTF-8; a line that does not decode is one
hit, `0xHH` (its first invalid byte), and its other characters are not
scanned.

Hits. A run is a maximal sequence of consecutive set code points on one line.
A set code point is passable when it is in the allowlist and its run is at most
two long; every other set code point is a hit, `U+XXXX`. `allowlist` is
required (a set of one-code-point strings): none means nothing passes.

Escape. Each passable code point becomes `<U+XXXX>`; a line that does not
decode is copied; nothing else changes. So scanning the escape with the empty
allowlist gives the hits of scanning the original with the allowlist.

Mixed-script record. A word is a maximal run of General_Category L* or M*
code points on one line. Each character contributes its Script_Extensions set
(its Script when it has none); a set of only Common or Inherited is ignored;
UTS #39 section 5.1's augmentation applies (Han adds Hanb, Jpan and Kore;
Hiragana and Katakana add Jpan; Hangul adds Kore; Bopomofo adds Hanb). A word
is mixed when a character is not ignored and the intersection is empty. Its
entry lists the sorted distinct Script values of its characters.

CLI (bytes, LF; run as `python3 -I -X utf8 chars.py ...`):

  chars.py scan   <field> <file> [--allow <json-file>] [--max <n>]
  chars.py scan   --candidate <file> [--allow <json-file>] [--max <n>]
  chars.py escape <file> [--allow <json-file>]
  chars.py mixed  <field> <file>

`scan` prints `hits <total>`, then the first min(total, max) hits as
`<field> line <n> <token>` (max defaults to 20). Candidate mode reads a
rendered issue.md: the title (line 1 after its first ` U+2014 `), the body,
and the Labels, State and Author values, reported in the order title, body,
label, state, author. `<json-file>` holds a JSON array of one-code-point
strings (the policy's allowed_chars); no --allow is the empty allowlist. The
allowlist never travels in argv or the environment.

Exit 0 ran (hits or none) - 2 usage - 3 could not run (an unreadable file or
table, a malformed allow file, a candidate outside the fetch layout). Never 1
on purpose: that is a traceback's code.
"""

import bisect
import importlib.util
import json
import os
import re
import sys


def _sibling(name):
    """Load scripts/lib/<name>.py by absolute path (never through sys.path)."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


LOAD_ERROR = None
try:
    _T = _sibling("chars_table")
    _L = _sibling("staging_layout")
except Exception as _e:  # noqa: BLE001 - any load failure is "could not run"
    _T = _L = None
    LOAD_ERROR = _e

FIELDS = ("title", "body", "label", "state", "author")
_ID_OK = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
_EOL_B = re.compile(rb"\r*\n|\r")
_EOL_S = re.compile("\r*\n|\r")
_TITLE_SEP = b" \xe2\x80\x94 "
_IGNORED = frozenset(("Common", "Inherited"))
_AUGMENT = {
    "Han": ("Hanb", "Jpan", "Kore"),
    "Hiragana": ("Jpan",),
    "Katakana": ("Jpan",),
    "Hangul": ("Kore",),
    "Bopomofo": ("Hanb",),
}


def _need_tables():
    if LOAD_ERROR is not None:
        raise RuntimeError("chars tables could not load")


class _Ranges:
    """Membership or value lookup over sorted inclusive ranges, memoised."""

    def __init__(self, ranges, valued, default):
        self.lo = [r[0] for r in ranges]
        self.hi = [r[1] for r in ranges]
        self.val = [r[2] for r in ranges] if valued else None
        self.default = default
        self.memo = {}

    def get(self, cp):
        v = self.memo.get(cp, self)
        if v is self:
            i = bisect.bisect_right(self.lo, cp) - 1
            if i >= 0 and cp <= self.hi[i]:
                v = self.val[i] if self.val is not None else True
            else:
                v = self.default
            self.memo[cp] = v
        return v


if _T is not None:
    _SET = _Ranges(_T.SET, False, False)
    _LM = _Ranges(_T.LM, False, False)
    _SC = _Ranges(_T.SCRIPTS, True, "Unknown")
    _SCX = _Ranges(_T.SCX, True, None)
    # The ASCII members of the set, as one bytes class: an ASCII line is
    # checked with one search.
    _ASCII_MEMBERS = bytes(cp for cp in range(0x80) if _SET.get(cp))
    _ASCII_HIT = re.compile(b"[" + b"".join(b"\\x%02x" % b for b in _ASCII_MEMBERS) + b"]") \
        if _ASCII_MEMBERS else None


def _field(field):
    if field in FIELDS:
        return field
    if isinstance(field, str) and field.startswith("comment:"):
        cid = "".join(ch if ch in _ID_OK else "_" for ch in field[len("comment:"):])[:64]
        if cid:
            return "comment:" + cid
    raise ValueError("unknown field")


def _lines_b(raw):
    """[(content, ending)] by B's rule; ending is b"" for a last line with no
    end. An empty input is no line."""
    out = []
    pos = 0
    for m in _EOL_B.finditer(raw):
        out.append((raw[pos:m.start()], m.group(0)))
        pos = m.end()
    if pos < len(raw):
        out.append((raw[pos:], b""))
    return out


def _lines_s(text):
    out = []
    pos = 0
    for m in _EOL_S.finditer(text):
        out.append((text[pos:m.start()], m.group(0)))
        pos = m.end()
    if pos < len(text):
        out.append((text[pos:], ""))
    return out


def _decode(line):
    """(str, None) or (None, first invalid byte)."""
    try:
        return line.decode("utf-8"), None
    except UnicodeDecodeError as e:
        return None, line[e.start]


def _line_verdicts(s, allowlist):
    """[(index, passable)] for every set code point of the decoded line s."""
    members = [ch for ch in set(s) if _SET.get(ord(ch))]
    if not members:
        return []
    members = frozenset(members)
    out = []
    i, n = 0, len(s)
    while i < n:
        if s[i] in members:
            j = i
            while j < n and s[j] in members:
                j += 1
            short = j - i <= 2
            for k in range(i, j):
                out.append((k, short and s[k] in allowlist))
            i = j
        else:
            i += 1
    return out


def _scan_line(line, allowlist):
    """Tokens of the hits on one line's bytes."""
    if line.isascii() and (_ASCII_HIT is None or _ASCII_HIT.search(line) is None):
        return []
    s, bad = _decode(line)
    if s is None:
        return ["0x%02X" % bad]
    return ["U+%04X" % ord(s[k]) for k, ok in _line_verdicts(s, allowlist) if not ok]


def chars_scan(field, raw_bytes, allowlist):
    """[(field, line, token)] for the hits in raw_bytes, in line order."""
    _need_tables()
    f = _field(field)
    hits = []
    for n, (line, _end) in enumerate(_lines_b(raw_bytes), 1):
        for tok in _scan_line(line, allowlist):
            hits.append((f, n, tok))
    return hits


def _escape_str(s, allowlist):
    verdicts = [k for k, ok in _line_verdicts(s, allowlist) if ok]
    if not verdicts:
        return s
    chars = list(s)
    for k in verdicts:
        chars[k] = "<U+%04X>" % ord(chars[k])
    return "".join(chars)


def chars_escape(text, allowlist):
    """text with each passable code point written as <U+XXXX>."""
    _need_tables()
    return "".join(_escape_str(c, allowlist) + e for c, e in _lines_s(text))


def chars_escape_bytes(raw_bytes, allowlist):
    """chars_escape on bytes, line by line, endings kept; a line that does not
    decode is copied."""
    _need_tables()
    out = []
    for line, end in _lines_b(raw_bytes):
        if line.isascii() and (_ASCII_HIT is None or _ASCII_HIT.search(line) is None):
            out.append(line + end)
            continue
        s, _bad = _decode(line)
        if s is None:
            out.append(line + end)
        else:
            out.append(_escape_str(s, allowlist).encode("utf-8") + end)
    return b"".join(out)


def _char_sets(cp):
    """(augmented script-extension set, or None when ignored)."""
    scx = _SCX.get(cp)
    names = scx if scx is not None else (_SC.get(cp),)
    if all(nm in _IGNORED for nm in names):
        return None
    out = set(names)
    for nm in names:
        out.update(_AUGMENT.get(nm, ()))
    return out


if _T is not None:
    # An ASCII-only line cannot hold a mixed word when every ASCII letter
    # resolves to the same script set (it does: Latin), judged from the table.
    _ASCII_SETS = {frozenset(_char_sets(cp) or ()) for cp in range(0x80) if _LM.get(cp)}
    _ASCII_UNMIXED = len(_ASCII_SETS) <= 1 and frozenset() not in _ASCII_SETS


def _mixed_line(s):
    """[sorted word_scripts] for each mixed word of the decoded line s."""
    out = []
    i, n = 0, len(s)
    while i < n:
        if not _LM.get(ord(s[i])):
            i += 1
            continue
        j = i
        common = None
        seen = False
        scripts = set()
        while j < n and _LM.get(ord(s[j])):
            cp = ord(s[j])
            scripts.add(_SC.get(cp))
            sets = _char_sets(cp)
            if sets is not None:
                seen = True
                common = set(sets) if common is None else common & sets
            j += 1
        if seen and not common:
            out.append(sorted(scripts))
        i = j
    return out


def _mixed(field, lines):
    f = _field(field)
    out = []
    for n, s in lines:
        if s is None:
            continue
        if _ASCII_UNMIXED and s.isascii():
            continue
        for ws in _mixed_line(s):
            out.append({"field": f, "line": n, "word_scripts": ws})
    return out


def mixed_record(field, text):
    """The mixed-script words of text, in line and position order."""
    _need_tables()
    return _mixed(field, [(n, c) for n, (c, _e) in enumerate(_lines_s(text), 1)])


def mixed_record_bytes(field, raw_bytes):
    """mixed_record on bytes; a line that does not decode is skipped."""
    _need_tables()
    return _mixed(field, [(n, _decode(c)[0]) for n, (c, _e) in enumerate(_lines_b(raw_bytes), 1)])


def record_json(entries):
    """The record file's bytes: compact JSON, ASCII, sorted keys, then LF."""
    return json.dumps(entries, ensure_ascii=True, separators=(",", ":"), sort_keys=True).encode("ascii") + b"\n"


def load_allowlist(path):
    """frozenset of one-code-point strings from a JSON array file; None is the
    empty allowlist. Raises ValueError on anything else."""
    if path is None:
        return frozenset()
    try:
        with open(path, "rb") as fh:
            data = json.loads(fh.read().decode("utf-8"))
    except (OSError, UnicodeDecodeError) as e:
        raise ValueError("allow file unreadable") from e
    if not isinstance(data, list) or not all(isinstance(x, str) and len(x) == 1 for x in data):
        raise ValueError("allow file is not a JSON array of one-code-point strings")
    return frozenset(data)


def candidate_fields(cand):
    """[(field, raw bytes)] of a rendered issue.md, in report order. Raises
    ValueError when it is outside the fetch layout."""
    _need_tables()
    lines = _L._split(cand)
    if not lines:
        raise ValueError("empty candidate")
    first = lines[0][0]
    at = first.find(_TITLE_SEP)
    if at < 0:
        raise ValueError("line 1")
    try:
        body, trailer, _count = _L.layout(lines)
    except _L.Layout as e:
        raise ValueError(str(e)) from e
    values = {}
    for c, _e in lines[2:body - 3]:
        head = _L.HEADER_LINE.match(c)
        values[head.group(1)] = c[head.end():]
    return [
        ("title", first[at + len(_TITLE_SEP):]),
        ("body", b"".join(c + e for c, e in lines[body:trailer - 3])),
        ("label", values[b"Labels"]),
        ("state", values[b"State"]),
        ("author", values[b"Author"]),
    ]


def candidate_scan(cand, allowlist):
    """chars_scan over a rendered issue.md's five fields, in report order."""
    hits = []
    for f, raw in candidate_fields(cand):
        hits += chars_scan(f, raw, allowlist)
    return hits


# ---- the CLI ----------------------------------------------------------------

_MAX_RE = re.compile(r"[1-9][0-9]{0,8}\Z", re.ASCII)


class _Usage(Exception):
    pass


def _parse(args, flags):
    """(positionals, {flag: value}); raises _Usage."""
    pos, opts = [], {}
    i = 0
    while i < len(args):
        a = args[i]
        if a.startswith("--"):
            if a not in flags or a in opts or i + 1 >= len(args) or args[i + 1] == "":
                raise _Usage()
            opts[a] = args[i + 1]
            i += 2
        else:
            pos.append(a)
            i += 1
    return pos, opts


def _read(path):
    with open(path, "rb") as fh:
        return fh.read()


def _out(b):
    sys.stdout.buffer.write(b)


def main(argv):
    try:
        if not argv:
            raise _Usage()
        verb, rest = argv[0], argv[1:]
        if verb == "scan":
            pos, opts = _parse(rest, ("--allow", "--max", "--candidate"))
            if "--max" in opts and not _MAX_RE.match(opts["--max"]):
                raise _Usage()
            if "--candidate" in opts:
                if pos:
                    raise _Usage()
            elif len(pos) != 2:
                raise _Usage()
        elif verb == "escape":
            pos, opts = _parse(rest, ("--allow",))
            if len(pos) != 1:
                raise _Usage()
        elif verb == "mixed":
            pos, opts = _parse(rest, ())
            if len(pos) != 2:
                raise _Usage()
        else:
            raise _Usage()
        if verb in ("scan", "mixed") and "--candidate" not in opts:
            _field(pos[0])
    except (_Usage, ValueError):
        sys.stderr.buffer.write(b"usage: chars.py scan|escape|mixed ... (see the module docstring)\n")
        return 2
    if LOAD_ERROR is not None:
        sys.stderr.buffer.write(b"chars: the table could not load\n")
        return 3
    try:
        allow = load_allowlist(opts.get("--allow"))
        if verb == "scan":
            if "--candidate" in opts:
                hits = candidate_scan(_read(opts["--candidate"]), allow)
            else:
                hits = chars_scan(pos[0], _read(pos[1]), allow)
            limit = int(opts.get("--max", "20"))
            out = [b"hits %d\n" % len(hits)]
            out += [("%s line %d %s\n" % h).encode("ascii") for h in hits[:limit]]
            _out(b"".join(out))
        elif verb == "escape":
            _out(chars_escape_bytes(_read(pos[0]), allow))
        else:
            _out(record_json(mixed_record_bytes(pos[0], _read(pos[1]))))
    except (OSError, ValueError):
        sys.stderr.buffer.write(b"chars: could not run\n")
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
