#!/usr/bin/env python3
# scripts/docs-site/check-fetches.py — #1030.
#
# The docs site's fetch policy, checked over the BUILT site: every file in the
# output is accounted for (scanned, a listed binary type, or vendored), and no
# scanned file names a remote URL where a browser could fetch it.
#
# Usage: check-fetches.py [--] <out-dir>
#   exactly one <out-dir>; an optional first '--' ends options. No argument,
#   two, or a leading '-' without '--' is a usage error.
#
# Exit codes (build-docs-site.sh maps them; it never parses this prose):
#   0  clean; stdout:
#        check-fetches: ok: <T> files: <S> scanned, <B> binary, <V> vendored
#   3  violations; stderr, sorted by path then line, one per violation:
#        check-fetches: <relpath>:<line>: <reason>
#      then
#        check-fetches: <N> violation(s) in <F> file(s)
#      <relpath> is /-separated, relative to <out-dir>; <line> is 1-based, or
#      0 for a reason about the whole file.
#   2  usage, or <out-dir> missing, not a directory, or holding no files; the
#      last stderr line is the usage line
#   any other status (Python's uncaught-exception 1 included): the scan did
#      not complete. There is no broad except: a fault is never a pass.
#
# Every file, in sorted walk order (symlinks never followed):
#   1. not a regular file (a symlink to a file or directory, a FIFO): refused;
#   2. under the vendored folder: #1003 adds that class; until then such a file
#      is scanned like any other and <V> is 0;
#   3. a hidden name (".x") or a name with no extension: refused;
#   4. by extension, case-blind: .html .htm .svg are markup, .js .mjs are
#      JavaScript, .css is CSS; BINARY_EXT are counted and never opened; any
#      other extension is refused;
#   5. a scanned file must be strict UTF-8;
#   6. no scanned file may hold the words "private preview" (any case, any
#      whitespace between).
import os
import re
import stat
import sys

USAGE = "usage: check-fetches.py [--] <out-dir>"

BINARY_EXT = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".ico", ".bmp",
    ".woff", ".woff2", ".ttf", ".otf", ".glb", ".bin",
}
MARKUP_EXT = {".html", ".htm", ".svg"}
JS_EXT = {".js", ".mjs"}
CSS_EXT = {".css"}

PREVIEW_RE = re.compile(r"private\s+preview", re.I)

# ---------------------------------------------------------------- remote URLs
#
# remote(value, ctx, where) -> reason or None. ctx is one of
#   attr  an attribute value whose URL a browser may fetch (src=, href= on
#         <link>, background=, any attribute not listed below): no exemption
#         but data: and blob:
#   ns    an xmlns or xmlns:* value: exactly one of NAMESPACES passes
#   nav   href= on <a> or <area>: navigation is not a fetch; only
#         javascript: is refused
#   js    a JS string literal or template chunk
#   css   a CSS string or unquoted url() argument
# The value is first normalised as a browser's URL parser does (WHATWG URL
# preprocessing): leading and trailing C0 controls and spaces stripped, tab
# and newline deleted, "\" read as "/".
NAMESPACES = (
    "http://www.w3.org/2000/svg",
    "http://www.w3.org/1999/xhtml",
    "http://www.w3.org/1999/xlink",
    "http://www.w3.org/1998/Math/MathML",
    "http://www.w3.org/XML/1998/namespace",
    "http://www.w3.org/2000/xmlns/",
)
# In a JS string a namespace URI is deleted only where no URL continues it
# (createElementNS("…/svg", …), an inline '<svg xmlns="…">'), so "…/svg/x"
# keeps its URI and is refused.
NS_IN_JS_RE = re.compile(
    "(?:" + "|".join(re.escape(n) for n in NAMESPACES) + ")(?![A-Za-z0-9/._~%?#&=+-])")
C0_SPACE = "".join(chr(i) for i in range(0x21))
# Every alternative is left-anchored on a non-scheme character, so a long run
# of scheme characters is matched once, not once per start position.
SCHEME = r"(?<![A-Za-z0-9+.\-])"
REMOTE_RE = re.compile(
    SCHEME + r"[A-Za-z][A-Za-z0-9+.\-]*://"           # any <scheme>://
    r"|" + SCHEME + r"(?:https?|wss?|ftp|file):"      # listed schemes, slashes optional
    r"|" + SCHEME + r"javascript:", re.I)
JS_RE = re.compile(SCHEME + r"javascript:", re.I)      # the nav-context check


def normalise(value):
    value = value.strip(C0_SPACE)
    value = re.sub(r"[\t\n\r]", "", value)
    return value.replace("\\", "/")


def remote(value, ctx, where):
    v = normalise(value)
    if ctx == "nav":
        return ("javascript: URL in %s" % where) if JS_RE.search(v) else None
    if ctx in ("ns", "css") and v in NAMESPACES:
        return None
    if ctx == "js":
        v = NS_IN_JS_RE.sub("", v)
    elif v[:5].lower() == "data:" or v[:5].lower() == "blob:":
        return None
    if v.startswith("//"):
        return "remote URL in %s" % where
    m = REMOTE_RE.search(v)
    if not m:
        return None
    if m.group(0).lower() == "javascript:":
        return "javascript: URL in %s" % where
    return "remote URL in %s" % where


# ------------------------------------------------------------------ tokenizers
#
# Two hand tokenizers that find only boundaries: where strings, templates,
# url() arguments and comments begin and end. They never decode escapes.
# Each returns (tokens, errors): tokens are (value, line, kind), errors
# (reason, line).
JS_REGEX_AFTER = {
    "return", "typeof", "instanceof", "in", "of", "new", "delete", "void",
    "throw", "case", "do", "else", "yield", "await",
}
JS_IDENT_RE = re.compile(r"[A-Za-z_$\u0080-￿][A-Za-z0-9_$\u0080-￿]*")
JS_NUMBER_RE = re.compile(r"\.?[0-9][A-Za-z0-9_.]*")


def _quoted(text, i, line, toks, errs, kind):
    """A '…' or "…" literal opening at text[i]: a backslash skips the next
    character (a line continuation included); a raw line break ends it as
    unterminated. Returns (next index, line)."""
    q, n, j, start = text[i], len(text), i + 1, line
    while j < n:
        ch = text[j]
        if ch == "\\":
            if text.startswith("\r\n", j + 1):
                j += 3
                line += 1
                continue
            if j + 1 < n and text[j + 1] in "\n\r":
                line += 1
            j += 2
            continue
        if ch == q:
            toks.append((text[i + 1:j], start, kind))
            return j + 1, line
        if ch in "\n\r":
            break
        j += 1
    errs.append(("unterminated string", start))
    return n, line


def js_tokens(text, line0=1):
    toks, errs = [], []
    i, n, line = 0, len(text), line0
    regex_ok = True
    depth = 0
    tmpl = []  # one (outer brace depth, opening line) per open ${ … }

    def template_chunk(j, line):
        """Read a template chunk from text[j]; returns (index, line, ended)."""
        start, k = line, j
        while k < n:
            ch = text[k]
            if ch == "\\":
                if k + 1 < n and text[k + 1] == "\n":
                    line += 1
                k += 2
                continue
            if ch == "`":
                toks.append((text[j:k], start, "string"))
                return k + 1, line, True
            if ch == "$" and text.startswith("${", k):
                toks.append((text[j:k], start, "string"))
                return k + 2, line, False
            if ch == "\n":
                line += 1
            k += 1
        errs.append(("unterminated template", start))
        return n, line, True

    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c.isspace():
            i += 1
            continue
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            if j < 0:
                errs.append(("unterminated comment", line))
                break
            line += text.count("\n", i, j)
            i = j + 2
            continue
        if c in "'\"":
            i, line = _quoted(text, i, line, toks, errs, "string")
            regex_ok = False
            continue
        if c == "`":
            start = line
            i, line, ended = template_chunk(i + 1, line)
            if not ended:
                tmpl.append((depth, start))
                depth = 0
                regex_ok = True
            else:
                regex_ok = False
            continue
        if c == "/" and regex_ok:
            j, cls, start = i + 1, False, line
            while j < n:
                ch = text[j]
                if ch == "\\":
                    j += 2
                    continue
                if ch in "\n\r":
                    j = n
                    break
                if cls:
                    if ch == "]":
                        cls = False
                elif ch == "[":
                    cls = True
                elif ch == "/":
                    break
                j += 1
            if j >= n:
                errs.append(("unterminated regex", start))
                break
            i = j + 1
            while i < n and (text[i].isalnum() or text[i] == "_"):
                i += 1
            regex_ok = False
            continue
        m = JS_IDENT_RE.match(text, i)
        if m:
            regex_ok = m.group(0) in JS_REGEX_AFTER
            i = m.end()
            continue
        m = JS_NUMBER_RE.match(text, i)
        if m:
            regex_ok = False
            i = m.end()
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            if depth == 0 and tmpl:
                depth = tmpl.pop()[0]
                i, line, ended = template_chunk(i + 1, line)
                if not ended:
                    tmpl.append((depth, line))
                    depth = 0
                    regex_ok = True
                else:
                    regex_ok = False
                continue
            depth = max(depth - 1, 0)
        regex_ok = c not in ")]}"
        i += 1
    for _, start in tmpl:
        errs.append(("unterminated template", start))
    return toks, errs


CSS_URL_RE = re.compile(r"url\(", re.I)


def css_tokens(text, line0=1):
    toks, errs = [], []
    i, n, line = 0, len(text), line0
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            if j < 0:
                errs.append(("unterminated comment", line))
                break
            line += text.count("\n", i, j)
            i = j + 2
            continue
        if c in "'\"":
            i, line = _quoted(text, i, line, toks, errs, "string")
            continue
        if c == "\\":
            i += 2
            continue
        if CSS_URL_RE.match(text, i) and (i == 0 or not re.match(r"[A-Za-z0-9_\-]", text[i - 1])):
            j = i + 4
            while j < n and text[j] in " \t\r\n\f":
                j += 1
            if j < n and text[j] in "'\"":
                line += text.count("\n", i, j)
                i = j  # a quoted argument is a string token
                continue
            start, k = line + text.count("\n", i, j), j
            while k < n and text[k] != ")":
                k += 2 if text[k] == "\\" else 1
            if k >= n:
                errs.append(("unterminated url()", start))
                break
            toks.append((text[j:k].strip(" \t\r\n\f"), start, "url()"))
            line += text.count("\n", i, k)
            i = k + 1
            continue
        i += 1
    return toks, errs


def usage_error(msg):
    sys.stderr.write("check-fetches: %s\n%s\n" % (msg, USAGE))
    sys.exit(2)


def line_at(text, offset):
    """1-based line of a character offset."""
    return text.count("\n", 0, offset) + 1


class Scan:
    def __init__(self, root):
        self.root = root
        self.violations = []  # (relpath, line, reason)
        self.total = self.scanned = self.binary = self.vendored = 0

    def refuse(self, rel, line, reason):
        self.violations.append((rel, line, reason))

    def walk(self):
        def onerror(err):
            raise err

        for top, dirs, files in os.walk(self.root, followlinks=False, onerror=onerror):
            dirs.sort()
            files.sort()
            keep = []
            for d in dirs:
                path = os.path.join(top, d)
                if os.path.islink(path):
                    # a directory symlink: counted, reported, never descended
                    self.total += 1
                    self.refuse(self.rel(path), 0, "not a regular file")
                else:
                    keep.append(d)
            dirs[:] = keep
            for f in files:
                self.total += 1
                self.file(os.path.join(top, f), f)

    def rel(self, path):
        return os.path.relpath(path, self.root).replace(os.sep, "/")

    def file(self, path, name):
        rel = self.rel(path)
        if not stat.S_ISREG(os.lstat(path).st_mode):
            self.refuse(rel, 0, "not a regular file")
            return
        if name.startswith("."):
            self.refuse(rel, 0, "a hidden file the scan cannot read")
            return
        ext = os.path.splitext(name)[1].lower()
        if not ext:
            self.refuse(rel, 0, "a file type the scan cannot read (no extension)")
            return
        if ext in BINARY_EXT:
            self.binary += 1
            return
        if ext not in MARKUP_EXT | JS_EXT | CSS_EXT:
            self.refuse(rel, 0, "a file type the scan cannot read (%s)" % ext)
            return
        self.scanned += 1
        with open(path, "rb") as fh:
            raw = fh.read()
        try:
            text = raw.decode("utf-8", errors="strict")
        except UnicodeDecodeError:
            self.refuse(rel, 0, "not UTF-8 text")
            return
        m = PREVIEW_RE.search(text)
        if m:
            self.refuse(rel, line_at(text, m.start()),
                        'the words "private preview" may not be published')
        if ext in JS_EXT:
            self.js(rel, text, 1)
        elif ext in CSS_EXT:
            self.css(rel, text, 1, "")

    def js(self, rel, text, line0, suffix=""):
        toks, errs = js_tokens(text, line0)
        for value, line, _ in toks:
            r = remote(value, "js", "a JS string" + suffix)
            if r:
                self.refuse(rel, line, r)
        for reason, line in errs:
            self.refuse(rel, line, reason + " (JS)" + suffix)

    def css(self, rel, text, line0, suffix):
        toks, errs = css_tokens(text, line0)
        for value, line, kind in toks:
            r = remote(value, "css", ("a CSS url()" if kind == "url()" else "a CSS string") + suffix)
            if r:
                self.refuse(rel, line, r)
        for reason, line in errs:
            self.refuse(rel, line, reason + " (CSS)" + suffix)

    def report(self):
        if self.violations:
            self.violations.sort(key=lambda v: (v[0], v[1]))
            for rel, line, reason in self.violations:
                sys.stderr.write("check-fetches: %s:%d: %s\n" % (rel, line, reason))
            files = len({v[0] for v in self.violations})
            sys.stderr.write("check-fetches: %d violation(s) in %d file(s)\n"
                             % (len(self.violations), files))
            sys.exit(3)
        sys.stdout.write("check-fetches: ok: %d files: %d scanned, %d binary, %d vendored\n"
                         % (self.total, self.scanned, self.binary, self.vendored))


def main(argv):
    args = argv[1:]
    if args and args[0] == "--":
        args = args[1:]
    elif args and args[0].startswith("-"):
        usage_error("unknown option: %s (an out-dir that starts with '-' follows '--')" % args[0])
    if len(args) != 1:
        usage_error("expected exactly one <out-dir>, got %d" % len(args))
    root = args[0]
    if not os.path.isdir(root):
        usage_error("not a directory: %s" % root)
    scan = Scan(root)
    scan.walk()
    if scan.total == 0:
        usage_error("no files in %s" % root)
    scan.report()


if __name__ == "__main__":
    main(sys.argv)
