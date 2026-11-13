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
#
# Scan contexts (remote() has the per-context rules):
#   .html/.htm  html.parser: every attribute value (style= as CSS, on*= as JS,
#               srcset/imagesrcset per candidate, ping per token, href on <a>
#               and <area> as navigation, xmlns as a namespace), <script> bodies
#               as JS (import maps included), <style> bodies as CSS; refused
#               elements; the parse-divergence guards; the CSP rule.
#   .svg        expat (entities expanded, script and style text decoded): the
#               same attribute rules; no DOCTYPE internal subset, no processing
#               instruction, well-formed XML only.
#   .js/.mjs    every string literal and static template chunk.
#   .css        every string and unquoted url() argument.
# Text content and comments are not checked: they cannot fetch.
#
# Known blind spots. In a document the CSP meta still blocks the fetch; on the
# surfaces with no CSP (below) nothing does, so these are accepted there as
# shapes nobody writes by accident:
#   - JS and CSS escapes are not decoded: "https\x3a//other.host" and
#     u\rl(//other.host) pass;
#   - URLs assembled at run time ("https" + ":/" + "/" + host, atob(…)) pass;
#   - text content a script reads and fetches passes;
#   - the JS tokenizer guesses regex versus division after ")" and "}" as
#     division: "if (x) /'/.test(s); var u = '//h'" can hide a string;
#   - a data: URL in an attribute or CSS is exempt whole: its payload is not
#     decoded, so a data: stylesheet's @import passes (in a JS string a data:
#     URL is scanned like any other text);
#   - a namespace URI exactly (xmlns values, CSS @namespace, a JS string) may
#     name w3.org: fetch("http://www.w3.org/2000/svg") passes;
#   - html.parser divergences from a browser other than the refused shapes.
#     The guards are measured against parsers that carry the 2025 html.parser
#     security fixes (python 3.10.12 Ubuntu, 3.13.14); an unpatched parser
#     ends a script only at "</script>" with optional spaces, so
#     "</script x>" can hide markup from it.
# Surfaces with no CSP: an .svg file opened on its own, and an .html fragment
# (a deeper file with no <html>, <head>, <body> or <script> tag). They may carry
# no <script> (.svg, any namespace prefix) and no on*= handler (both).
# Known over-refusals (measured; rephrase rather than fight them):
#   - a remote URL in an attribute that does not navigate: title=, alt=,
#     aria-label=, data-*=, <meta content=…>, a "file: x" mention included;
#   - a JS string that is just "https:";
#   - inline JS that builds a '<script' or '<!--' string;
#   - "&" in an inline <svg> or <math> <script> or <style>, and markup ("<"
#     then a letter, "/", "!" or "?") in any element this parser reads as text
#     inside <svg> or <math> (<title>, <textarea>, <script>, <style>, …);
#   - "//" then a host character after a quote, space, "(", "=", "," or ";"
#     in any string or attribute value ("see //h" in a title=);
#   - a <![CDATA[ section in an .html file, inline SVG included;
#   - a non-JS <script type> whose body has an unbalanced quote.
import html.parser as _hp
import os
import re
import stat
import sys
import xml.parsers.expat as expat
from html.parser import HTMLParser

USAGE = "usage: check-fetches.py [--] <out-dir>"

# The site's Content-Security-Policy, byte for byte. It has four homes, edited
# together in one reviewed change: this constant, the <meta> in
# scripts/docs-site/page.html, the stub writer in scripts/build-docs-site.sh,
# and CSP in tests/build-docs-site.bats (which never reads it from the others).
POLICY = (
    "default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; "
    "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; "
    "font-src 'self' data:; connect-src 'self' data: blob:; worker-src 'self' blob:; "
    "media-src 'self' data: blob:; object-src 'none'; frame-src 'none'; "
    "base-uri 'none'; form-action 'none'"
)

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
# "//host" after a delimiter, inside a value: markup or CSS built in a string
# ('<img src="//h/x">'), url(//h/x), a values= list.
PROTO_REL_RE = re.compile(r"(?:^|[\s\"'(=,;])//[^/\s]")


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
    if PROTO_REL_RE.search(v):
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
JS_IDENT_RE = re.compile(r"[A-Za-z_$\u0080-\uffff][A-Za-z0-9_$\u0080-\uffff]*")
JS_NUMBER_RE = re.compile(r"\.?[0-9][A-Za-z0-9_.]*")
JS_LINE_END_RE = re.compile("[\n\r\u2028\u2029]")
JS_LINE_ENDS = "\n\r\u2028\u2029"


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
        # A line comment: "//", and (Annex B, classic scripts) "<!--" anywhere
        # and "-->" first on its line. It ends at any JS line terminator.
        if text.startswith("//", i) or text.startswith("<!--", i) or (
                text.startswith("-->", i)
                and not text[max(text.rfind(t, 0, i) for t in JS_LINE_ENDS) + 1:i].strip()):
            m = JS_LINE_END_RE.search(text, i)
            i = n if m is None else m.start()
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
        if c in "+-" and text.startswith(c + c, i):
            # postfix after an operand (a "/" next is division); prefix otherwise
            i += 2
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


# ---------------------------------------------------------------- markup rules
REFUSED_TAGS = {"iframe", "frame", "object", "embed"}
FOREIGN_TAGS = {"svg", "math"}
DOC_TAGS = {"html", "head", "body", "script"}
RESOURCE_TAGS = {"script", "link", "style", "img"}
# Elements a browser reads as text to their end tag. Where this Python's parser
# does not (it parses markup inside them), a comment it opens there can hide
# markup the browser runs, so such a comment is refused.
_RAW_IN_BROWSER = {"noscript", "textarea", "title", "xmp", "iframe", "noembed", "noframes"}
COMMENT_HIDES_IN = _RAW_IN_BROWSER - set(getattr(HTMLParser, "CDATA_CONTENT_ELEMENTS", ())) \
    - set(getattr(HTMLParser, "RCDATA_CONTENT_ELEMENTS", ()))
# Raw-source shapes a browser and html.parser end differently.
COMMENT_DIVERGE_RE = re.compile(r"<!---?>|--!>")
END_WS_RE = re.compile(r"</\s+(?:script|style)", re.I)
MARKED_RE = re.compile(r"<!\[")
SCRIPT_BODY_RE = re.compile(r"<!--|<script", re.I)
# Inside <svg>/<math> a browser parses markup in elements this parser reads as
# text (title, textarea, xmp, script, style, …), so such a body may hold none.
PARSED_AS_TEXT = set(getattr(HTMLParser, "CDATA_CONTENT_ELEMENTS", ("script", "style"))) \
    | set(getattr(HTMLParser, "RCDATA_CONTENT_ELEMENTS", ())) | {"script", "style"}
FOREIGN_MARKUP_RE = re.compile(r"<[A-Za-z/!?]")
# Start tags that keep <head> open; any other start tag, or text that is not
# whitespace, ends it in a browser (and a CSP meta after that point is ignored).
HEAD_OK = {"html", "head", "base", "basefont", "bgsound", "link", "meta", "noscript",
           "script", "style", "template", "title"}
INERT_TAGS = {"noscript", "template"}
HTML_WS = " \t\n\r\f"


def srcset_urls(value):
    """The URL of each srcset candidate (WHATWG: skip whitespace and commas;
    the URL is the next non-whitespace run minus trailing commas; descriptors
    run to the next comma outside parentheses)."""
    urls, i, n = [], 0, len(value)
    while True:
        while i < n and (value[i] in HTML_WS or value[i] == ","):
            i += 1
        if i >= n:
            return urls
        j = i
        while j < n and value[j] not in HTML_WS:
            j += 1
        url = value[i:j]
        if url.endswith(","):
            urls.append(url.rstrip(","))
            i = j
            continue
        urls.append(url)
        depth, k = 0, j
        while k < n:
            ch = value[k]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth = max(depth - 1, 0)
            elif ch == "," and depth == 0:
                break
            k += 1
        i = k + 1


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
        elif ext == ".svg":
            self.svg(rel, text)
        else:
            self.html(rel, text)

    def attr(self, rel, tag, name, value, line):
        """One attribute, by its context (see remote())."""
        n = name.lower()
        where = "%s= on <%s>" % (name, tag)
        if n == "style":
            self.css(rel, value, line, " in " + where)
            return
        if n.startswith("on"):
            self.js(rel, value, line, " in " + where)
            return
        if n in ("srcset", "imagesrcset"):
            values, ctx = srcset_urls(value), "attr"
        elif n == "ping":
            values, ctx = value.split(), "attr"
        elif n == "href" and tag.lower() in ("a", "area"):
            values, ctx = [value], "nav"
        elif n == "xmlns" or n.startswith("xmlns:"):
            values, ctx = [value], "ns"
        else:
            values, ctx = [value], "attr"
        for v in values:
            r = remote(v, ctx, where)
            if r:
                self.refuse(rel, line, r)

    def body(self, rel, tag, text, line):
        """A <script> or <style> body."""
        if tag == "style":
            self.css(rel, text, line, "")
        else:
            self.js(rel, text, line)

    def html(self, rel, text):
        for rx, reason in ((COMMENT_DIVERGE_RE, "a comment the browser and the scanner may end differently"),
                           (END_WS_RE, 'an end tag with whitespace after "</"'),
                           (MARKED_RE, 'a "<![" section the browser and the scanner may end differently')):
            for m in rx.finditer(text):
                self.refuse(rel, line_at(text, m.start()), reason)
        p = _Html(self, rel, top_level="/" not in rel)
        p.feed(text)
        p.close()
        p.finish()

    def svg(self, rel, text):
        p = expat.ParserCreate()
        p.ordered_attributes = True
        pending = []  # the open <script>/<style>: [tag, line, chunks]

        def start(name, attrs):
            line = p.CurrentLineNumber
            # no namespace processing: "h:script" is a script, whatever its prefix
            low = name.rsplit(":", 1)[-1].lower()
            if low in REFUSED_TAGS:
                self.refuse(rel, line, "<%s> is refused" % name)
            if low == "script":
                self.refuse(rel, line, "<script> in an .svg file is refused (no CSP covers it)")
            for an, av in zip(attrs[0::2], attrs[1::2]):
                if an.lower().startswith("on"):
                    self.refuse(rel, line, "%s= in an .svg file is refused (no CSP covers it)" % an)
                self.attr(rel, name, an, av, line)
            if low in ("script", "style"):
                pending[:] = [low, None, []]

        def end(name):
            if pending and name.rsplit(":", 1)[-1].lower() == pending[0]:
                if pending[1] is not None:
                    self.body(rel, pending[0], "".join(pending[2]), pending[1])
                pending[:] = []

        def chars(data):
            if pending:
                if pending[1] is None:
                    pending[1] = p.CurrentLineNumber
                pending[2].append(data)

        def doctype(name, sysid, pubid, internal):
            if internal:
                self.refuse(rel, p.CurrentLineNumber, "a DOCTYPE with an internal subset")

        def pi(target, data):
            self.refuse(rel, p.CurrentLineNumber, "a processing instruction (<?%s)" % target)

        p.StartElementHandler = start
        p.EndElementHandler = end
        p.CharacterDataHandler = chars
        p.StartDoctypeDeclHandler = doctype
        p.ProcessingInstructionHandler = pi
        try:
            p.Parse(text.encode("utf-8"), True)
        except expat.ExpatError as e:
            self.refuse(rel, e.lineno, "not well-formed XML: %s" % expat.ErrorString(e.code))

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


class _Html(HTMLParser):
    """One .html/.htm file: element and attribute rules, the parse-divergence
    guards that need the parser, and the CSP rule."""

    def __init__(self, scan, rel, top_level):
        super().__init__(convert_charrefs=True)
        self.s, self.rel = scan, rel
        self.is_doc = top_level
        self.foreign = 0          # open <svg>/<math> depth
        self.raw = []             # open elements in COMMENT_HIDES_IN
        self.pending = None       # the open <script>/<style>: [tag, line, chunks, in_foreign]
        self.on_attrs = []        # (line, name): refused at the end if a fragment
        self.head = self.head_closed = False
        self.in_title = False
        self.inert = []           # open <noscript>/<template>: a meta in them is ignored
        self.first_resource = None
        self.metas = []           # (line, content, in_head, after, inert parent)

    def refuse(self, line, reason):
        self.s.refuse(self.rel, line, reason)

    def attr_lines(self, count, line0):
        """Each attribute's own line, from the tag text tokenized with the
        parser's own patterns (k-th match = k-th attribute); the tag's line
        when they do not line up."""
        raw = self.get_starttag_text() or ""
        tagfind = getattr(_hp, "tagfind_tolerant", None)
        attrfind = getattr(_hp, "attrfind_tolerant", None)
        if tagfind and attrfind:
            m = tagfind.match(raw, 1)
            lines, k = [], m.end() if m else len(raw)
            while k < len(raw) and len(lines) < count:
                am = attrfind.match(raw, k)
                if not am or am.end() == k:
                    break
                lines.append(line0 + raw.count("\n", 0, am.start(1)))
                k = am.end()
            if len(lines) == count:
                return lines
        return [line0] * count

    def handle_starttag(self, tag, attrs):
        self.start(tag, attrs)

    def handle_startendtag(self, tag, attrs):
        self.start(tag, attrs)

    def start(self, tag, attrs):
        line0 = self.getpos()[0]
        attrs = [(n, "" if v is None else v) for n, v in attrs]
        closing = (self.get_starttag_text() or "").rstrip().endswith("/>")
        if tag in DOC_TAGS:
            self.is_doc = True
        if tag == "head":
            self.head = True
        elif self.head and tag not in HEAD_OK:
            self.head_closed = True
        if tag == "meta":
            equiv = next((v for n, v in attrs if n == "http-equiv"), "")
            # an enumerated value: matched case-blind but never trimmed
            if equiv.lower() == "content-security-policy":
                content = next((v for n, v in attrs if n == "content"), None)
                self.metas.append((line0, content, self.head and not self.head_closed,
                                   self.first_resource, self.inert[-1] if self.inert else None))
        if tag in RESOURCE_TAGS and self.first_resource is None:
            self.first_resource = tag
        if tag in REFUSED_TAGS:
            self.refuse(line0, "<%s> is refused" % tag)
        if tag == "script":
            t = next((v for n, v in attrs if n == "type"), "")
            if t.strip().lower() == "speculationrules":
                self.refuse(line0, '<script type="speculationrules"> is refused')
        if tag in ("script", "style") and closing and not self.foreign:
            self.refuse(line0, "a self-closing <script/> or <style/> outside <svg> or <math>")
        for (name, value), line in zip(attrs, self.attr_lines(len(attrs), line0)):
            if name.startswith("on"):
                self.on_attrs.append((line, name))
            self.s.attr(self.rel, tag, name, value, line)
        if closing:
            return
        if tag in FOREIGN_TAGS:
            self.foreign += 1
        if tag in COMMENT_HIDES_IN:
            self.raw.append(tag)
        if tag in INERT_TAGS:
            self.inert.append(tag)
        if tag == "title":
            self.in_title = True
        if tag in ("script", "style") or (self.foreign and tag in PARSED_AS_TEXT):
            self.pending = [tag, None, [], self.foreign > 0]

    def handle_endtag(self, tag):
        if self.pending and tag == self.pending[0]:
            self.flush()
        if tag in FOREIGN_TAGS and self.foreign:
            self.foreign -= 1
        if tag in self.raw:
            del self.raw[len(self.raw) - 1 - self.raw[::-1].index(tag):]
        if tag in self.inert:
            del self.inert[len(self.inert) - 1 - self.inert[::-1].index(tag):]
        if tag == "title":
            self.in_title = False
        if tag == "head":
            self.head_closed = True

    def handle_data(self, data):
        if self.pending:
            if self.pending[1] is None:
                self.pending[1] = self.getpos()[0]
            self.pending[2].append(data)
        elif (self.head and not self.head_closed and not self.in_title and not self.inert
              and data.strip(HTML_WS)):
            self.head_closed = True

    def handle_comment(self, data):
        if self.raw:
            self.refuse(self.getpos()[0], "a comment inside <%s>, which a browser reads as text" % self.raw[-1])

    def flush(self):
        tag, line, chunks, in_foreign = self.pending
        self.pending = None
        if line is None:
            return
        text = "".join(chunks)
        if in_foreign and FOREIGN_MARKUP_RE.search(text):
            self.refuse(line, "markup inside <%s> inside <svg> or <math> (a browser parses it as markup)" % tag)
        if tag not in ("script", "style"):
            return
        if tag == "script" and SCRIPT_BODY_RE.search(text):
            self.refuse(line, "a <script> body that opens an HTML comment or a nested <script>")
        if in_foreign and "&" in text:
            self.refuse(line, '"&" in a <script> or <style> body inside <svg> or <math>')
        self.s.body(self.rel, tag, text, line)

    def finish(self):
        if self.pending:
            self.flush()
        if not self.is_doc:
            for line, name in self.on_attrs:
                self.refuse(line, "%s= in a fragment is refused (no CSP covers it)" % name)
            return
        if not self.metas:
            self.refuse(0, "a document under an asset folder needs the Content-Security-Policy meta"
                        if "/" in self.rel else "no Content-Security-Policy meta")
            return
        line, content, in_head, after, inert = self.metas[0]
        for extra in self.metas[1:]:
            self.refuse(extra[0], "more than one Content-Security-Policy meta")
        if content != POLICY:
            self.refuse(line, "the Content-Security-Policy meta does not carry the site policy")
        if inert:
            self.refuse(line, "the Content-Security-Policy meta is inside <%s>, where a browser ignores it" % inert)
        elif not in_head:
            self.refuse(line, "the Content-Security-Policy meta is not inside <head>")
        elif after:
            self.refuse(line, "the Content-Security-Policy meta comes after a <%s>" % after)


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
