#!/usr/bin/env python3
"""fill-placeholders.py — fill the family's build-time placeholders (#996).

Usage:
  fill-placeholders.py --settings <live.txt> [--static <dir>] --check
  fill-placeholders.py --settings <live.txt> [--] <html>...

--check reads the live settings file and the two family partials in --static
(default: the static/ folder next to this script). It refuses a malformed
settings file, and one that lacks a live key a partial uses.
Without --check it rewrites each <html> in place, filling every placeholder.

The placeholder syntax and the settings format are part of the family
contract (family v1.0); docs-site/live.txt's header documents both, with a
rendered example of each kind. In short:
  {{live:<key>|<label>}}  <a href="URL">LABEL</a> when <key> is live,
                          <span class="family-coming">LABEL <small>coming</small></span>
                          when it is not
  {{count:<key>}}         the number of lines of the count's source file that
                          match its regex, in decimal; a zero is refused
A candidate is "{{", a non-space character, then anything but braces, "<", ">"
and '"' up to "}}"; it may span lines (pandoc wraps a long label), and a
label's whitespace is collapsed. A label is plain text: markup in it leaves
the placeholder unclosed, which is refused, so an unclosed placeholder can
never swallow the markup up to a later "}}". A placeholder inside a tag (an
attribute value) is refused too. "${{ x }}" (a space after "{{") is text.
Placeholders are filled over the whole page, <head> and code included: v1.0
has no escape.

Files are read and written as bytes through a strict UTF-8 decode with no
newline translation, so CRLF and non-ASCII text outside a placeholder survive.
Nothing is written unless every file filled.

Exit codes:
  0  ok; stdout: "fill-placeholders: settings ok: <L> live, <C> count" (--check)
                 or "fill-placeholders: filled <P> placeholders in <F> files"
  2  usage
  4  settings missing or malformed:
       "fill-placeholders: <settings>:<n>: <reason>" (<n> is 0 for a missing
       file or a missing required key)
  5  a placeholder could not be filled: "fill-placeholders: <file>: <reason>"
  any other status: the fill did not complete
"""
import os
import re
import sys

PROG = "fill-placeholders"

CANDIDATE = re.compile(r"\{\{(?=\S)([^{}<>\"]*)\}\}")
LIVE = re.compile(r"live:([a-z0-9][a-z0-9-]*)\|([^{}|<>\"]+)")
COUNT = re.compile(r"count:([a-z0-9][a-z0-9-]*)")
LEFTOVER = re.compile(r"\{\{(live|count):")

BLANK_LINE = re.compile(r"[ \t]*(#.*)?")
LIVE_LINE = re.compile(
    r"live[ \t]+([a-z0-9][a-z0-9-]*)[ \t]+(yes|no)[ \t]+"
    r"(https://[^\s\"'<>]+|[A-Za-z0-9_-]+\.html(?:#[A-Za-z0-9_-]*)?)")
COUNT_LINE = re.compile(r"count[ \t]+([a-z0-9][a-z0-9-]*)[ \t]+(\S+)[ \t]+(\S.*)")
EXPECTED = "expected 'live <key> yes|no <url>' or 'count <key> <path> <regex>'"
PARTIALS = ("family-topbar.html", "family-footer.html")


class Refusal(Exception):
    def __init__(self, rc, msg):
        super().__init__(msg)
        self.rc = rc


def usage(msg):
    print(f"{PROG}: {msg}", file=sys.stderr)
    print(f"{PROG}: usage: fill-placeholders.py --settings <live.txt> [--static <dir>] --check", file=sys.stderr)
    print(f"{PROG}:        fill-placeholders.py --settings <live.txt> [--] <html>...", file=sys.stderr)
    sys.exit(2)


def read_text(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8")


class Settings:
    def __init__(self, path):
        self.path = path
        self.base = os.path.dirname(os.path.abspath(path))
        self.live = {}    # key -> (is_live, url)
        self.counts = {}  # key -> (path, compiled regex)
        self._cache = {}
        try:
            text = read_text(path)
        except FileNotFoundError:
            raise Refusal(4, f"{path}:0: not found")
        except (OSError, UnicodeDecodeError) as e:
            raise Refusal(4, f"{path}:0: cannot read: {e}")
        for n, line in enumerate(text.split("\n"), 1):
            line = line.rstrip()
            if BLANK_LINE.fullmatch(line):
                continue
            m = LIVE_LINE.fullmatch(line)
            if m:
                key = m.group(1)
                if key in self.live:
                    raise Refusal(4, f"{path}:{n}: {key} is listed twice")
                self.live[key] = (m.group(2) == "yes", m.group(3))
                continue
            m = COUNT_LINE.fullmatch(line)
            if m:
                key, cpath, rx = m.group(1), m.group(2), m.group(3)
                if key in self.counts:
                    raise Refusal(4, f"{path}:{n}: {key} is listed twice")
                if cpath.startswith(("/", "\\")) or re.match(r"[A-Za-z]:", cpath):
                    raise Refusal(4, f"{path}:{n}: count path must be relative to this file: {cpath}")
                try:
                    compiled = re.compile(rx)
                except re.error as e:
                    raise Refusal(4, f"{path}:{n}: count regex does not compile: {e}")
                self.counts[key] = (cpath, compiled)
                continue
            raise Refusal(4, f"{path}:{n}: {EXPECTED}")

    def count(self, key):
        """The count for key; raises Refusal(5) for a missing source or a zero."""
        if key in self._cache:
            return self._cache[key]
        cpath, rx = self.counts[key]
        full = os.path.join(self.base, cpath)
        try:
            data = read_text(full)
        except FileNotFoundError:
            raise Refusal(5, f"count source not found: {cpath} (count {key})")
        except (OSError, UnicodeDecodeError) as e:
            raise Refusal(5, f"count source cannot be read: {cpath} (count {key}): {e}")
        lines = data.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        n = sum(1 for ln in lines if rx.search(ln[:-1] if ln.endswith("\r") else ln))
        if n == 0:
            raise Refusal(5, f"count {key} is zero in {cpath}; a zero is never published")
        self._cache[key] = n
        return n


def render(settings, body):
    """The rendered text of one placeholder body, or Refusal(5) text."""
    m = LIVE.fullmatch(body)
    if m:
        key, label = m.group(1), " ".join(m.group(2).split())
        if label and key in settings.live:
            is_live, url = settings.live[key]
            if is_live:
                return f'<a href="{url.replace("&", "&amp;")}">{label}</a>'
            return f'<span class="family-coming">{label} <small>coming</small></span>'
    m = COUNT.fullmatch(body)
    if m and m.group(1) in settings.counts:
        return str(settings.count(m.group(1)))
    raise Refusal(5, "unknown placeholder {{" + " ".join(body.split()) + "}}")


def fill(settings, text):
    """(filled text, placeholders filled); raises Refusal(5)."""
    def sub(m):
        s = m.string
        lt = s.rfind("<", 0, m.start())
        if lt > s.rfind(">", 0, m.start()):
            shown = "{{" + " ".join(m.group(1).split()) + "}}"
            if s.startswith("<!--", lt):
                raise Refusal(5, f"placeholder inside an HTML comment: {shown} (delete it, or break its braces)")
            raise Refusal(5, f"placeholder inside a tag: {shown} (an attribute cannot hold the rendered markup)")
        return render(settings, m.group(1))

    out, n = CANDIDATE.subn(sub, text)
    left = LEFTOVER.search(out)
    if left:
        raise Refusal(5, "unclosed placeholder starting {{" + left.group(1) + ":")
    return out, n


def required_keys(static):
    """{key: partial name} for each live key a family partial uses."""
    keys = {}
    for name in PARTIALS:
        p = os.path.join(static, name)
        try:
            text = read_text(p)
        except (OSError, UnicodeDecodeError):
            raise Refusal(4, f"{p}:0: not found (the top bar and footer partials name the required live keys)")
        for m in CANDIDATE.finditer(text):
            lm = LIVE.fullmatch(m.group(1))
            if lm:
                keys.setdefault(lm.group(1), name)
    return keys


def main(argv):
    settings_path = None
    static = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
    check = False
    files = []
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--":
            files += argv[i + 1:]
            break
        if a in ("--settings", "--static"):
            if i + 1 >= len(argv) or not argv[i + 1]:
                usage(f"{a} needs a value")
            if a == "--settings":
                settings_path = argv[i + 1]
            else:
                static = argv[i + 1]
            i += 2
            continue
        if a == "--check":
            check = True
        elif a.startswith("-"):
            usage(f"unknown argument: {a}")
        else:
            files.append(a)
        i += 1
    if settings_path is None:
        usage("--settings is required")
    if check and files:
        usage("--check takes no files")
    if not check and not files:
        usage("no files to fill")

    try:
        settings = Settings(settings_path)
    except Refusal as r:
        print(f"{PROG}: {r}", file=sys.stderr)
        return r.rc

    if check:
        try:
            for key, partial in required_keys(static).items():
                if key not in settings.live:
                    raise Refusal(4, f"{settings_path}:0: missing required key '{key}' (used by {partial})")
        except Refusal as r:
            print(f"{PROG}: {r}", file=sys.stderr)
            return r.rc
        print(f"{PROG}: settings ok: {len(settings.live)} live, {len(settings.counts)} count")
        return 0

    done, total, bad = [], 0, 0
    for path in files:
        try:
            try:
                text = read_text(path)
            except UnicodeDecodeError:
                raise Refusal(5, "is not UTF-8")
            out, n = fill(settings, text)
        except Refusal as r:
            print(f"{PROG}: {path}: {r}", file=sys.stderr)
            bad += 1
            continue
        total += n
        if out != text:
            done.append((path, out))
    if bad:
        return 5
    for path, out in done:
        with open(path, "wb") as f:
            f.write(out.encode("utf-8"))
    print(f"{PROG}: filled {total} placeholders in {len(files)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
