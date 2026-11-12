#!/usr/bin/env python3
"""Read and write the disk issue file format (#1008).

One issue per file, `<folder>/<N>.md`. This module is the one parser and the
one writer that the disk issue backend, doctor, `wbs init --from-tracker` and
the publish/import converters share, so they can never disagree about what a
file means. The format is documented in docs/disk-issues.md.

    disk-issue.py parse <file>
    disk-issue.py list <folder>
    disk-issue.py check <file>...
    disk-issue.py set <file> key=value... [--unset key]... [--comment <text>] [--date <YYYY-MM-DD>]
    disk-issue.py create <folder> <N> <title> <prompt-file> [key=value...]

Exit codes: 0 ok; 1 an I/O failure, or the file changed underneath; 2 usage, or
a refused value or prompt; 3 `create` found the file already there; 4 the file
fails the check (and was not written).

Python 3.8 floor, stdlib only.
"""
from __future__ import annotations

import datetime
import json
import os
import re
import stat
import sys
import tempfile

KEYS = ("state", "status", "parent", "labels", "github")
MAX_UNCLOSED = 1000
_IS_WINDOWS = os.name == "nt"
_LOCK_WAIT_S = 5.0
_REPLACE_RETRY_S = 1.0

EXIT_OK, EXIT_IO, EXIT_USAGE, EXIT_EXISTS, EXIT_FAULTY = 0, 1, 2, 3, 4

USAGE = (
    "usage: disk-issue.py parse <file>\n"
    "       disk-issue.py list <folder>\n"
    "       disk-issue.py check <file>...\n"
    "       disk-issue.py set <file> key=value... [--unset key]... [--comment <text>] [--date <YYYY-MM-DD>]\n"
    "       disk-issue.py create <folder> <N> <title> <prompt-file> [key=value...]\n"
)

_ISSUE_NAME_RE = re.compile(r"^[1-9][0-9]*\.md$")


class Fail(Exception):
    """A failure with its exit code; main prints `disk-issue: <msg>` to stderr."""

    def __init__(self, code: int, msg: str = "", usage: bool = False):
        super().__init__(msg)
        self.code = code
        self.msg = msg
        self.usage = usage


def _usage_error(msg: str) -> Fail:
    return Fail(EXIT_USAGE, msg, usage=True)


def _err(text: str) -> None:
    sys.stderr.write(text)
    sys.stderr.flush()


def _out(text: str) -> None:
    sys.stdout.buffer.write(text.encode("utf-8"))
    sys.stdout.buffer.flush()


def _issue_file_arg(arg: str) -> str:
    if not _ISSUE_NAME_RE.match(os.path.basename(arg)):
        raise _usage_error(f'file name must be <N>.md, got "{arg}"')
    return arg


# ------------------------------------------------------------------ reader

_BOM = b"\xef\xbb\xbf"
_KEY_RE = re.compile(r"^(state|status|parent|labels|github):(.*)$")
_PARENT_RE = re.compile(r"^#?([1-9][0-9]{0,17})$")
_GITHUB_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[1-9][0-9]{0,17}$")
PROMPT_H, COMMENTS_H = "## Prompt", "## Comments"
HINT = "; if this line is prose, put a blank line above it"


def _lines(data: bytes) -> list:
    """Split on b"\\n" only, keeping each line's terminator.

    `str.splitlines` would also split on a lone CR, \\x0c, U+2028 and more, and
    the writer must reproduce every untouched byte."""
    out = []
    start = 0
    while True:
        k = data.find(b"\n", start)
        if k < 0:
            if start < len(data):
                out.append(data[start:])
            return out
        out.append(data[start:k + 1])
        start = k + 1


def _body(raw: bytes) -> str:
    """A line without its terminator: remove the LF, then one CR."""
    s = raw.decode("utf-8")
    if s.endswith("\n"):
        s = s[:-1]
        if s.endswith("\r"):
            s = s[:-1]
    return s


def _term(raw: bytes) -> bytes:
    if raw.endswith(b"\r\n"):
        return b"\r\n"
    if raw.endswith(b"\n"):
        return b"\n"
    return b""


def _blank(body: str) -> bool:
    return body.strip(" \t") == ""


def _heading(body: str):
    """`## Prompt` / `## Comments` (trailing spaces tolerated, case-sensitive)."""
    r = body.rstrip(" \t")
    return r if r in (PROMPT_H, COMMENTS_H) else None


def _validate(key: str, raw: str):
    """The one value rule, shared by the reader and the writer. `raw` is
    already trimmed. Returns the normalised value or raises ValueError."""
    if raw == "":
        raise ValueError(f'empty value for "{key}"')
    if key == "state":
        if raw not in ("open", "closed"):
            raise ValueError(f'state must be "open" or "closed", got "{raw}"')
        return raw
    if key == "parent":
        m = _PARENT_RE.match(raw)
        if not m:
            raise ValueError(f'parent must be an issue number such as 3 or #3, got "{raw}"')
        return int(m.group(1))
    if key == "labels":
        parts = [p.strip(" \t") for p in raw.split(",")]
        if any(not p for p in parts):
            raise ValueError(f'labels must be a comma-separated list with no empty label, got "{raw}"')
        return parts
    if key == "github":
        if not _GITHUB_RE.match(raw):
            raise ValueError(f'github must be owner/name#N, got "{raw}"')
        return raw
    return raw   # status: free text


# Copied verbatim from wbs-parser.py's _FENCE_RE: the same fence predicate.
_FENCE_RE = re.compile(r"^[ \t]*(?P<run>`{3,}|~{3,})(?P<info>.*)$")


def _is_continuation(body: str) -> bool:
    """A comment entry's continuation line: it starts with two spaces. Also the
    shape of every continuation line the writer emits (the fence barrier)."""
    return body.startswith("  ")


def classify_fences(bodies: list, start: int) -> tuple:
    """Pair code fences in bodies[start:] in linear time.

    Pairs exactly as wbs-parser.py's `_classify_lines` does (an opener takes
    the first later closer of its character with a run at least its own and no
    info; an opener with no closer is not a fence, #701; scanning resumes after
    a closer), without its quadratic rescans. Barrier (#1008 Q1, option a): a
    pairing i→j is rejected, leaving i unclosed, when a column-0 `## Comments`
    lies between them and line j is indented two spaces, so a fence in an
    added comment can never turn earlier text into code.

    Returns (in_code per line, unclosed-opener count, index of opener number
    MAX_UNCLOSED+1 or None).
    """
    n = len(bodies)
    is_opener = [False] * n
    next_closer: list = [None] * n
    next_comments: list = [None] * n
    # One stack per fence character of (run, index) closer candidates, nearest
    # on top, runs strictly increasing downward: a farther candidate whose run
    # is no longer than a nearer one's can never be the first match.
    stacks: dict = {"`": [], "~": []}
    comments_after = None
    for i in range(n - 1, start - 1, -1):
        body = bodies[i]
        next_comments[i] = comments_after
        m = _FENCE_RE.match(body)
        if m:
            run = m.group("run")
            char, length, info = run[0], len(run), m.group("info")
            st = stacks[char]
            if not (char == "`" and "`" in info):
                is_opener[i] = True
                # Scan down from the top for the first run >= length. The
                # entries passed have runs < length, strictly increasing from
                # 3, so at most length-3 of them: linear in the input's bytes.
                k = len(st) - 1
                while k >= 0 and st[k][0] < length:
                    k -= 1
                next_closer[i] = st[k][1] if k >= 0 else None
            if not info.strip():
                while st and st[-1][0] <= length:
                    st.pop()
                st.append((length, i))
        if _heading(body) == COMMENTS_H:
            comments_after = i

    in_code = [False] * n
    unclosed = 0
    over = None
    i = start
    while i < n:
        if not is_opener[i]:
            i += 1
            continue
        j = next_closer[i]
        if (j is not None and next_comments[i] is not None and next_comments[i] < j
                and _is_continuation(bodies[j])):
            j = None
        if j is None:
            unclosed += 1
            if unclosed == MAX_UNCLOSED + 1:
                over = i
            i += 1
            continue
        for k in range(i, j + 1):
            in_code[k] = True
        i = j + 1
    return in_code, unclosed, over


class Issue:
    """A parsed issue plus the line layout the writer edits."""

    def __init__(self) -> None:
        self.title = None
        self.keys: dict = {"state": "open"}
        self.prompt = ""
        self.comments: list = []
        self.faults: list = []
        self.warnings: list = []
        # layout
        self.bom = False
        self.eol = b"\n"
        self.lines: list = []
        self.bodies: list = []
        self.title_idx = None
        self.title_hashed = False
        self.header: dict = {}
        self.header_end = None
        self.prompt_idx = None
        self.comments_idx = None
        self.in_code: list = []


def read_issue(data: bytes) -> Issue:
    iss = Issue()
    if data.startswith(_BOM):
        iss.bom = True
        data = data[len(_BOM):]
    lines = _lines(data)
    iss.lines = lines
    for raw in lines:
        if raw.endswith(b"\n"):
            iss.eol = _term(raw)
            break
    bodies = []
    for i, raw in enumerate(lines):
        try:
            bodies.append(_body(raw))
        except UnicodeDecodeError:
            iss.faults.append((i + 1, "not valid UTF-8"))
            return iss
    iss.bodies = bodies
    n = len(lines)

    # Title: the first non-blank line.
    t = next((i for i, b in enumerate(bodies) if not _blank(b)), None)
    if t is None:
        iss.faults.append((1, "no title line"))
        return iss
    tb = bodies[t]
    iss.title_hashed = tb.startswith("# ")
    title = (tb[2:] if iss.title_hashed else tb).rstrip(" \t")
    if not title.strip(" \t"):
        iss.faults.append((t + 1, "no title line"))
        return iss
    iss.title = title
    iss.title_idx = t

    # Header: known-key lines directly under the title.
    i = t + 1
    while i < n:
        m = _KEY_RE.match(bodies[i])
        if not m:
            break
        key = m.group(1)
        if key in iss.header:
            iss.faults.append((i + 1, f'duplicate key "{key}" (first at line {iss.header[key] + 1})'))
        else:
            iss.header[key] = i
            try:
                iss.keys[key] = _validate(key, m.group(2).strip(" \t"))
            except ValueError as e:
                iss.faults.append((i + 1, str(e) + (HINT if i == t + 1 else "")))
        i += 1
    start = iss.header_end = i

    in_code, _unclosed, over = classify_fences(bodies, start)
    iss.in_code = in_code
    if over is not None:
        iss.faults.append((over + 1, f"more than {MAX_UNCLOSED} unclosed code fence openers ({_unclosed} found)"))

    # W1: a valid header line just after the blank line that ends the header block.
    j = start
    while j < n and _blank(bodies[j]):
        j += 1
    if start < j < n:
        m = _KEY_RE.match(bodies[j])
        if m:
            try:
                _validate(m.group(1), m.group(2).strip(" \t"))
            except ValueError:
                pass
            else:
                shown = bodies[j].rstrip(" \t")
                iss.warnings.append((j + 1, f'"{shown}" is read as prose because a blank line is above it; '
                                            "delete the blank line if it is a header line"))

    # Sections.
    first_text = None
    for i in range(start, n):
        b = bodies[i]
        h = None if in_code[i] else _heading(b)
        if h == PROMPT_H:
            if iss.prompt_idx is None:
                iss.prompt_idx = i
                if first_text is not None:
                    iss.faults.append((first_text + 1, "text between the header and ## Prompt"))
            else:
                iss.faults.append((i + 1, f"second ## Prompt (first at line {iss.prompt_idx + 1})"))
        elif h == COMMENTS_H:
            iss.comments_idx = i
            break
        elif first_text is None and iss.prompt_idx is None and not _blank(b):
            first_text = i

    end = iss.comments_idx if iss.comments_idx is not None else n
    ps = iss.prompt_idx + 1 if iss.prompt_idx is not None else start
    iss.prompt = "\n".join(_trim_blank(bodies[ps:end]))
    if iss.comments_idx is not None:
        _read_comments(iss)
    return iss


_ENTRY_RE = re.compile(r"^- ([0-9]{4}-[0-9]{2}-[0-9]{2}) (.*)$")
_DATE_RE = re.compile(r"^([0-9]{4})-([0-9]{2})-([0-9]{2})$")


def _real_date(s: str) -> bool:
    """YYYY-MM-DD and a real calendar date (not fromisoformat: wider on 3.11+)."""
    m = _DATE_RE.match(s)
    if not m:
        return False
    try:
        datetime.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    except ValueError:
        return False
    return True


def _read_comments(iss: Issue) -> None:
    """Entries under `## Comments`. Fences here have no structural effect."""
    bodies = iss.bodies
    ci = iss.comments_idx
    cur = None
    seen_entry = False
    stray_reported = False

    def finish(entry) -> None:
        if entry is None:
            return
        text = "\n".join(_trim_blank(entry["parts"]))
        if not text:
            iss.faults.append((entry["line"], "comment entry has no text"))
        else:
            iss.comments.append({"date": entry["date"], "text": text, "line": entry["line"]})

    for i in range(ci + 1, len(bodies)):
        b = bodies[i]
        if _blank(b):
            if cur is not None:
                cur["blanks"] += 1   # kept only when an indented line follows
            continue
        h = _heading(b)
        fault = None
        if h == COMMENTS_H:
            fault = f"second ## Comments (first at line {ci + 1})"
        elif h == PROMPT_H:
            fault = "## Prompt after ## Comments"
        elif b.startswith("## "):
            fault = "heading inside ## Comments"
        else:
            m = _ENTRY_RE.match(b)
            if m:
                finish(cur)
                seen_entry = True
                if not _real_date(m.group(1)):
                    iss.faults.append((i + 1, f"comment date {m.group(1)} is not a real date"))
                cur = {"date": m.group(1), "line": i + 1, "parts": [m.group(2).rstrip()], "blanks": 0}
                continue
            if _is_continuation(b) and cur is not None:
                cur["parts"].extend([""] * cur["blanks"])
                cur["blanks"] = 0
                cur["parts"].append(b[2:].rstrip())
                continue
            if not seen_entry:
                if not stray_reported:
                    iss.faults.append((i + 1, "text between ## Comments and the first entry"))
                    stray_reported = True
                continue
            fault = ('unexpected line in ## Comments: an entry starts with "- YYYY-MM-DD " '
                     "and continues on lines indented two spaces")
        iss.faults.append((i + 1, fault))
        finish(cur)
        cur = None
    finish(cur)


def _trim_blank(seq: list) -> list:
    a, b = 0, len(seq)
    while a < b and _blank(seq[a]):
        a += 1
    while b > a and _blank(seq[b - 1]):
        b -= 1
    return seq[a:b]


def _issue_number(path: str) -> int:
    return int(os.path.basename(path)[:-3])


def _read_bytes(path: str) -> bytes:
    with open(path, "rb") as fh:
        return fh.read()


def _load(path: str) -> Issue:
    """Read and parse `path`; OSError propagates."""
    iss = read_issue(_read_bytes(path))
    if len(os.path.basename(path)) - 3 > 18:
        iss.faults.insert(0, (1, "issue number has more than 18 digits"))
    return iss


def _sorted(entries: list) -> list:
    return sorted(entries, key=lambda e: e[0])


def issue_json(n: int, iss: Issue) -> dict:
    warnings = [{"line": ln, "message": m} for ln, m in _sorted(iss.warnings)]
    if iss.faults:
        return {"n": n, "faults": [{"line": ln, "message": m} for ln, m in _sorted(iss.faults)],
                "warnings": warnings}
    return {
        "n": n,
        "title": iss.title,
        "keys": {k: iss.keys[k] for k in KEYS if k in iss.keys},
        "prompt": iss.prompt,
        "comments": [{"date": c["date"], "text": c["text"], "line": c["line"]} for c in iss.comments],
        "warnings": warnings,
    }


def _json_line(obj: dict) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"


def _strerror(e: OSError) -> str:
    return e.strerror or str(e)


# ------------------------------------------------------------------ renderer

def _texts(comments: list) -> list:
    """Comments without their line numbers, which a header edit shifts."""
    return [(c["date"], c["text"]) for c in comments]


def _rank(key: str) -> int:
    return KEYS.index(key)


def render_set(data: bytes, iss: Issue, sets: dict, unsets: set, comment=None):
    """New bytes for a fault-free `iss` read from `data`, or None when nothing
    changes. `sets` holds trimmed values, written as given; `comment` is the
    already-rendered entry text lines (Task 7) or None. Untouched lines are
    copied byte for byte."""
    eol = iss.eol
    t = iss.title_idx
    header = [[iss.bodies[i].split(":", 1)[0], iss.lines[i]] for i in range(t + 1, iss.header_end)]
    keyed = {k: entry for k, entry in ((e[0], e) for e in header)}
    intended = dict(iss.keys)
    changed = False
    removals = set(unsets)
    for key in sorted(sets, key=_rank):
        value = sets[key]
        norm = _validate(key, value)
        if key == "state" and norm == "open":
            removals.add("state")
            continue
        intended[key] = norm
        line = f"{key}: {value}".encode("utf-8")
        if key in keyed:
            if iss.keys[key] == norm:
                continue
            keyed[key][1] = line + _term(keyed[key][1])
        else:
            pos = 0
            for idx, entry in enumerate(header):
                if _rank(entry[0]) < _rank(key):
                    pos = idx + 1
            entry = [key, line + eol]
            header.insert(pos, entry)
            keyed[key] = entry
        changed = True
    for key in removals:
        if key in keyed:
            header.remove(keyed.pop(key))
            changed = True
        if key == "state":
            intended["state"] = "open"
        else:
            intended.pop(key, None)
    if not changed and comment is None:
        return None

    lines = iss.lines
    n = len(lines)
    title_line = lines[t]
    if not iss.title_hashed:   # first write: the title gets "# "
        title_line = b"# " + iss.title.encode("utf-8") + _term(lines[t])
    out = list(lines[:t]) + [title_line] + [e[1] for e in header]
    end = iss.comments_idx if iss.comments_idx is not None else n
    first_prose = next((i for i in range(iss.header_end, end) if not _blank(iss.bodies[i])), None)
    if iss.prompt_idx is None and first_prose is not None:
        # first write: the existing prose goes under ## Prompt, byte for byte
        out += [eol, PROMPT_H.encode() + eol] + list(lines[first_prose:])
    else:
        out += list(lines[iss.header_end:])
    want_comments = _texts(iss.comments)
    if comment is not None:
        date, text_lines = comment
        entry = [f"- {date} {text_lines[0]}".encode("utf-8") + eol]
        entry += [(f"  {ln}".encode("utf-8") if ln else b"") + eol for ln in text_lines[1:]]
        if iss.comments_idx is not None:
            # after the last non-blank line of the comments section; `out`
            # ends with lines[comments_idx:] copied unchanged
            heading = len(out) - (n - iss.comments_idx)
            last = max(k for k in range(heading, len(out)) if not _blank(_body(out[k])))
            out[last + 1:last + 1] = entry
        else:
            if not _blank(_body(out[-1])):
                out.append(eol)
            out += [COMMENTS_H.encode() + eol] + entry
        want_comments = want_comments + [(date, "\n".join(text_lines))]
    for k in range(len(out) - 1):   # only an original last line can lack one
        if not out[k].endswith(b"\n"):
            out[k] += eol
    new = (_BOM if iss.bom else b"") + b"".join(out)

    back = read_issue(new)
    if (back.faults or back.title != iss.title or back.prompt != iss.prompt
            or back.keys != intended or _texts(back.comments) != want_comments):
        raise Fail(EXIT_IO, "internal error: result does not read back; file left unchanged")
    return new


# ------------------------------------------------------------------ safe writes

def _write_temp(folder: str, base: str, data: bytes, mode: int) -> str:
    """`.<N>.md.tmp-<random>` in `folder`, written, flushed, fsynced, chmod-ed
    (mkstemp creates at 0600)."""
    fd, tmp = tempfile.mkstemp(prefix="." + base + ".tmp-", dir=folder)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode)
    except BaseException:
        _unlink_quiet(tmp)
        raise
    return tmp


def _unlink_quiet(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


def _replace(tmp: str, path: str) -> None:
    os.replace(tmp, path)


def _write_atomic(path: str, new: bytes) -> None:
    folder = os.path.dirname(path) or "."
    mode = stat.S_IMODE(os.stat(path).st_mode)
    tmp = _write_temp(folder, os.path.basename(path), new, mode)
    try:
        _replace(tmp, path)
    except BaseException:
        _unlink_quiet(tmp)
        raise


# ------------------------------------------------------------------ CLI grammar

def _parse_kv(tokens: list, seen: dict) -> None:
    """Fold `key=value` tokens into `seen`; usage errors for the rest."""
    for tok in tokens:
        if "=" not in tok:
            raise _usage_error(f'expected key=value, got "{tok}"')
        key, value = tok.split("=", 1)
        if key not in KEYS:
            raise _usage_error(f'unknown key "{key}"')
        if key in seen:
            raise _usage_error(f'"{key}" given twice')
        if "\r" in value or "\n" in value:
            raise _usage_error(f'"{key}" value contains a line break')
        value = value.strip(" \t")
        if not value:
            raise _usage_error(f'empty value for "{key}"')
        seen[key] = value


def _parse_set_args(args: list) -> tuple:
    """`set <file> key=value... [--unset key]... [--comment t] [--date d]`."""
    if not args:
        raise _usage_error("set needs a file")
    path = _issue_file_arg(args[0])
    sets: dict = {}
    unsets: set = set()
    comment = None
    date = None
    kv: list = []
    i = 1
    while i < len(args):
        tok = args[i]
        if tok in ("--unset", "--comment", "--date"):
            if i + 1 >= len(args):
                raise _usage_error(f"{tok} needs a value")
            val = args[i + 1]          # taken verbatim, even if it starts with "-"
            if tok == "--unset":
                if val not in KEYS:
                    raise _usage_error(f'unknown key "{val}"')
                unsets.add(val)
            elif tok == "--comment":
                if comment is not None:
                    raise _usage_error('"--comment" given twice')
                comment = val
            else:
                if date is not None:
                    raise _usage_error('"--date" given twice')
                date = val
            i += 2
            continue
        if tok.startswith("--"):
            raise _usage_error(f'unknown option "{tok}"')
        kv.append(tok)
        i += 1
    _parse_kv(kv, sets)
    for key in sets:
        if key in unsets:
            raise _usage_error(f'"{key}" is both set and unset')
    if date is not None and comment is None:
        raise _usage_error("--date needs --comment")
    if not sets and not unsets and comment is None:
        raise _usage_error("nothing to change")
    return path, sets, unsets, comment, date


# ------------------------------------------------------------------ verbs

def cmd_parse(args: list) -> int:
    if len(args) != 1:
        raise _usage_error("parse takes one file")
    path = _issue_file_arg(args[0])
    try:
        iss = _load(path)
    except OSError as e:
        _err(f"{path}: cannot read: {_strerror(e)}\n")
        return EXIT_IO
    _out(_json_line(issue_json(_issue_number(path), iss)))
    return EXIT_FAULTY if iss.faults else EXIT_OK


def _check_lines(path: str, iss: Issue) -> list:
    entries = [(ln, f"{path}:{ln}: {m}") for ln, m in iss.faults]
    entries += [(ln, f"{path}:{ln}: warning: {m}") for ln, m in iss.warnings]
    return [text for _ln, text in _sorted(entries)]


def cmd_check(args: list) -> int:
    if not args:
        raise _usage_error("check needs at least one file")
    for a in args:
        _issue_file_arg(a)
    unreadable = faulty = False
    for path in args:
        try:
            iss = _load(path)
        except OSError as e:
            _out(f"{path}:1: cannot read: {_strerror(e)}\n")
            unreadable = True
            continue
        for text in _check_lines(path, iss):
            _out(text + "\n")
        faulty = faulty or bool(iss.faults)
    return EXIT_IO if unreadable else EXIT_FAULTY if faulty else EXIT_OK


def cmd_list(args: list) -> int:
    if len(args) != 1:
        raise _usage_error("list takes one folder")
    folder = args[0]
    try:
        names = os.listdir(folder)
    except OSError as e:
        _err(f"disk-issue: {folder}: cannot read folder: {_strerror(e)}\n")
        return EXIT_IO
    found = []
    for name in names:
        if not _ISSUE_NAME_RE.match(name):   # dot-named temp files, 0.md, 01.md, README.md
            continue
        path = os.path.join(folder, name)
        if not os.path.isfile(path):
            continue
        found.append((int(name[:-3]), path))
    unreadable = faulty = False
    for n, path in sorted(found):
        try:
            iss = _load(path)
        except OSError as e:
            iss = Issue()
            iss.faults.append((1, f"cannot read: {_strerror(e)}"))
            unreadable = True
        faulty = faulty or bool(iss.faults)
        _out(_json_line(issue_json(n, iss)))
    return EXIT_IO if unreadable else EXIT_FAULTY if faulty else EXIT_OK


def _today() -> str:
    """Today's local date, as `date_tag` in scripts/lib/io.sh gives it,
    honouring DEVAGENT_DATE_OVERRIDE (#338)."""
    override = os.environ.get("DEVAGENT_DATE_OVERRIDE", "")
    if override:
        if not _real_date(override):
            raise Fail(EXIT_USAGE, "DEVAGENT_DATE_OVERRIDE is not a YYYY-MM-DD date")
        return override
    return datetime.date.today().isoformat()


def _comment_lines(text: str) -> list:
    """Comment text as entry lines: LF line endings, each line right-stripped,
    no leading or trailing blank lines."""
    lines = [ln.rstrip() for ln in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
    lines = _trim_blank(lines)
    if not lines:
        raise Fail(EXIT_USAGE, "empty comment")
    return lines


def cmd_set(args: list) -> int:
    path, sets, unsets, comment, date = _parse_set_args(args)
    for key, value in sets.items():
        try:
            _validate(key, value)
        except ValueError as e:
            raise Fail(EXIT_USAGE, str(e))
    entry = None
    if comment is not None:
        text_lines = _comment_lines(comment)
        if date is not None:
            if not _real_date(date):
                raise Fail(EXIT_USAGE, "--date must be a real YYYY-MM-DD date")
        else:
            date = _today()
        entry = (date, text_lines)
    try:
        iss = _load(path)
    except OSError as e:
        raise Fail(EXIT_IO, f"{path}: cannot read: {_strerror(e)}")
    if iss.faults:
        for text in _check_lines(path, iss):
            _err(text + "\n")
        return EXIT_FAULTY
    data = (_BOM if iss.bom else b"") + b"".join(iss.lines)
    new = render_set(data, iss, sets, unsets, entry)
    if new is None:
        return EXIT_OK
    try:
        _write_atomic(path, new)
    except OSError as e:
        raise Fail(EXIT_IO, f"{path}: cannot write: {_strerror(e)}")
    return EXIT_OK


def cmd_create(args: list) -> int:
    raise Fail(EXIT_IO, "create: not implemented")


VERBS = {
    "parse": cmd_parse,
    "list": cmd_list,
    "check": cmd_check,
    "set": cmd_set,
    "create": cmd_create,
}


def main(argv: list) -> int:
    if not argv:
        _err(USAGE)
        return EXIT_USAGE
    verb, rest = argv[0], argv[1:]
    try:
        fn = VERBS.get(verb)
        if fn is None:
            raise _usage_error(f'unknown verb "{verb}"')
        return fn(rest)
    except Fail as e:
        if e.msg:
            _err(f"disk-issue: {e.msg}\n")
        if e.usage:
            _err(USAGE)
        return e.code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
