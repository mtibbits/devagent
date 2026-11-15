#!/usr/bin/env python3
"""family-check.py — test helper for the docs-site family files (#996).

Usage: family-check.py <subcommand> <file>...

Each subcommand prints one line per violation,
    family-check: <file>:<line>: <reason>
then a count line,
    family-check: <subcommand>: <N> subjects, <V> violations
and exits 0 when clean, 1 on any violation, 2 on a usage error. The count line
is what the bats legs pin: a subject set that silently empties shows as a low
N, never as a pass.

Subcommands:
  header   <file>...               line 1 of each file names "family vX.Y", all the same
  tokens   <family.css>            the palette reads per theme: a light and a dark
                                   literal set with the same suffixes, and an active
                                   set that points at one or the other
  literals <family.css> <page>     page holds no family colour, defines no custom
                                   property, and uses only family tokens family.css
                                   defines
  contrast <family.css> [<css-or-html>...]
                                   WCAG AA (4.5:1) for the listed pairs in both
                                   themes; prints one row per pair. Every further
                                   file is read for rules that put --family-board
                                   behind text (only html and body may).
  contract <family.js>             the header's key, class, control and exports
                                   lines name what the code uses; prints
                                   "header key=.. class=.. control=.. exports=.."
  contract <live.txt> <filler>     each "# example: <input> -> <output>" header
                                   line renders as written (<N>: a positive count)
  fragment <family.css> <filled>... a filled partial is a standalone fragment:
                                   no placeholder left, balanced, one root, no
                                   document/script/style tags or on*= handlers,
                                   every class defined in family.css
  scope   <page> <partial>...     no page rule reaches family markup: a selector
                                   whose last compound is a bare element the
                                   partials use, with nothing scoping it, or a
                                   class the partials use
"""
import html.parser
import re
import sys

PROG = "family-check"
VERSION_RE = re.compile(r"\bfamily v([0-9]+)\.([0-9]+)\b")
SUFFIXES_MIN = 12
FG = ("ink", "accent-ink", "ink-soft")
AA = 4.5


class Report:
    def __init__(self, sub):
        self.sub = sub
        self.subjects = 0
        self.violations = 0

    def bad(self, path, line, reason):
        self.violations += 1
        print(f"{PROG}: {path}:{line}: {reason}")

    def done(self):
        print(f"{PROG}: {self.sub}: {self.subjects} subjects, {self.violations} violations")
        return 1 if self.violations else 0


def usage(msg):
    print(f"{PROG}: {msg}", file=sys.stderr)
    print(f"{PROG}: usage: family-check.py <header|tokens|literals|contrast|scope|contract> <file>...", file=sys.stderr)
    sys.exit(2)


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8")
    except OSError as e:
        usage(f"cannot read {path}: {e.strerror}")


# ------------------------------------------------------------------ CSS reader

class Rule:
    """One style rule: the at-rule preludes around it, its selector text, and
    its declarations as (property, value, line)."""

    def __init__(self, ctx, sel, decls, line):
        self.ctx = ctx
        self.sel = sel
        self.decls = decls
        self.line = line


def strip_comments(text):
    # Comments become the newlines they held, so line numbers survive.
    return re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)


def _scan_to(text, i, end, stops):
    """Index of the first char in stops at or after i (outside quotes and
    parentheses), or -1."""
    q = None
    depth = 0
    while i < end:
        c = text[i]
        if q:
            if c == "\\":
                i += 2
                continue
            if c == q:
                q = None
        elif c in "\"'":
            q = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth = max(0, depth - 1)
        elif depth == 0 and c in stops:
            return i
        i += 1
    return -1


def _match_brace(text, i, end):
    depth = 0
    q = None
    j = i
    while j < end:
        c = text[j]
        if q:
            if c == "\\":
                j += 2
                continue
            if c == q:
                q = None
        elif c in "\"'":
            q = c
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return end


def parse_decls(text, a, b, lineno):
    out = []
    i = a
    while i < b:
        j = _scan_to(text, i, b, ";")
        if j < 0:
            j = b
        part = text[i:j]
        k = part.find(":")
        if k > 0:
            lead = len(part) - len(part.lstrip())
            prop = part[:k].strip().lower()
            val = part[k + 1:].strip()
            if prop:
                out.append((prop, val, lineno(i + lead)))
        i = j + 1
    return out


def parse_css(text, base_line=1, ctx0=()):
    """(rules, keyframes): rules as Rule; keyframes as (name, line) — their
    bodies are not rules and are never read as such."""
    text = strip_comments(text)
    rules, keyframes = [], []

    def lineno(pos):
        return base_line + text.count("\n", 0, pos)

    def block(i, end, ctx):
        while i < end:
            j = _scan_to(text, i, end, "{;}")
            if j < 0:
                return
            prelude = text[i:j]
            start = i + (len(prelude) - len(prelude.lstrip()))
            prelude = prelude.strip()
            if text[j] != "{":
                i = j + 1
                continue
            k = _match_brace(text, j, end)
            if prelude.startswith("@"):
                name = prelude.split()[0].lower() if prelude.split() else "@"
                if name in ("@media", "@supports", "@layer", "@container", "@document"):
                    block(j + 1, k, ctx + (" ".join(prelude.split()).lower(),))
                elif name.endswith("keyframes"):
                    keyframes.append((prelude, lineno(start)))
                else:
                    rules.append(Rule(ctx, prelude, parse_decls(text, j + 1, k, lineno), lineno(start)))
            else:
                rules.append(Rule(ctx, " ".join(prelude.split()), parse_decls(text, j + 1, k, lineno), lineno(start)))
            i = k + 1

    block(0, len(text), ctx0)
    return rules, keyframes


STYLE_EL_RE = re.compile(r"<style\b[^>]*>(.*?)</style\s*>", re.I | re.S)


def html_styles(text):
    """[(css_text, base_line)] for each <style> element of an html text."""
    out = []
    for m in STYLE_EL_RE.finditer(text):
        out.append((m.group(1), 1 + text.count("\n", 0, m.start(1))))
    return out


def css_of(path, text):
    """Every rule of a .css file, or of the <style> elements of an html file."""
    if path.lower().endswith(".css"):
        return parse_css(text)[0]
    rules = []
    for css, base in html_styles(text):
        rules += parse_css(css, base)[0]
    return rules


# ------------------------------------------------------------------ selectors

def split_top(s, sep):
    out, depth, cur, q = [], 0, "", None
    for c in s:
        if q:
            cur += c
            if c == q:
                q = None
            continue
        if c in "\"'":
            q = c
        elif c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        if c == sep and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += c
    out.append(cur)
    return [x.strip() for x in out if x.strip()]


def compounds(sel):
    """The compound selectors of one complex selector, left to right."""
    out, depth, cur, q = [], 0, "", None
    for c in sel:
        if q:
            cur += c
            if c == q:
                q = None
            continue
        if c in "\"'":
            q = c
        elif c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        if depth == 0 and (c.isspace() or c in ">+~"):
            if cur:
                out.append(cur)
            cur = ""
        else:
            cur += c
    if cur:
        out.append(cur)
    return out


def compound_parts(comp):
    """(element or '', classes, has_id, has_attr)."""
    has_attr = "[" in comp
    c = re.sub(r"\[[^\]]*\]", "", comp)
    c = re.sub(r"::?[A-Za-z-]+(\([^)]*\))?", "", c)
    m = re.match(r"([A-Za-z][A-Za-z0-9-]*|\*)", c)
    el = m.group(1).lower() if m else ""
    classes = set(re.findall(r"\.([A-Za-z0-9_-]+)", c))
    has_id = bool(re.search(r"#[A-Za-z_-]", c))
    return el, classes, has_id, has_attr


# ------------------------------------------------------------------ html reader

class Markup(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tags = set()
        self.classes = set()

    def handle_starttag(self, tag, attrs):
        self.tags.add(tag)
        for k, v in attrs:
            if k == "class" and v:
                self.classes.update(v.split())


# A {{live:...}} placeholder renders as <a href> (live) or as
# <span class="family-coming">LABEL <small>coming</small></span> (not live).
LIVE_RENDERS = ({"a", "span", "small"}, {"family-coming"})


def markup_of(text):
    p = Markup()
    p.feed(text)
    p.close()
    tags, classes = set(p.tags), set(p.classes)
    if "{{live:" in text:
        tags |= LIVE_RENDERS[0]
        classes |= LIVE_RENDERS[1]
    return tags, classes


# ------------------------------------------------------------------ colours

HEX_RE = re.compile(r"#[0-9a-fA-F]{3,8}\b")
RGBA_RE = re.compile(r"rgba?\([^)]*\)", re.I)


def colour_literals(text):
    found = []
    for m in HEX_RE.finditer(text):
        found.append(m.group(0))
    for m in RGBA_RE.finditer(text):
        found.append(m.group(0))
    return {re.sub(r"\s+", "", c.lower()) for c in found}


def parse_colour(v):
    """(r, g, b, a) floats, r/g/b in 0..255; None when v is no single colour."""
    v = v.strip()
    m = re.fullmatch(r"#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})", v)
    if m:
        h = m.group(1)
        if len(h) == 3:
            h = "".join(ch * 2 for ch in h)
        return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), 1.0)
    m = re.fullmatch(r"rgba?\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)\s*(?:,\s*([0-9.]+)\s*)?\)", v, re.I)
    if m:
        a = float(m.group(4)) if m.group(4) is not None else 1.0
        return (float(m.group(1)), float(m.group(2)), float(m.group(3)), a)
    return None


def over(top, under):
    a = top[3]
    return tuple(a * top[i] + (1 - a) * under[i] for i in range(3)) + (1.0,)


def luminance(c):
    def ch(x):
        x = x / 255.0
        return x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4
    return 0.2126 * ch(c[0]) + 0.7152 * ch(c[1]) + 0.0722 * ch(c[2])


def ratio(fg, bg):
    a, b = luminance(fg), luminance(bg)
    hi, lo = max(a, b), min(a, b)
    return (hi + 0.05) / (lo + 0.05)


def hexof(c):
    return "#%02X%02X%02X" % tuple(int(round(x)) for x in c[:3])


# ------------------------------------------------------------------ palette

TOKEN_RE = re.compile(r"--family-([a-z0-9-]+)")


def palette(path, text):
    """light, dark, active, dark_active, outside_media_ok, problems — read from
    the top-level :root and the prefers-color-scheme: dark :root."""
    rules = parse_css(text)[0]
    light, dark, active, dark_active = {}, {}, {}, {}
    problems = []
    for r in rules:
        is_root = r.sel.strip() == ":root"
        dark_ctx = len(r.ctx) == 1 and re.fullmatch(r"@media \(prefers-color-scheme: ?dark\)", r.ctx[0])
        for prop, val, line in r.decls:
            m = re.fullmatch(r"--family-(light|dark)-([a-z0-9-]+)", prop)
            if m:
                if r.ctx or not is_root:
                    problems.append((line, f"{prop} is defined inside {' '.join(r.ctx) or r.sel}; theme sets are top-level :root literals"))
                    continue
                (light if m.group(1) == "light" else dark)[m.group(2)] = (val, line)
                continue
            m = re.fullmatch(r"--family-([a-z0-9-]+)", prop)
            if m and is_root:
                if not r.ctx:
                    active[m.group(1)] = (val, line)
                elif dark_ctx:
                    dark_active[m.group(1)] = (val, line)
    return light, dark, active, dark_active, problems


def cmd_header(files):
    rep = Report("header")
    first = None
    for path in files:
        rep.subjects += 1
        line1 = read(path).split("\n", 1)[0]
        m = VERSION_RE.search(line1)
        if not m:
            rep.bad(path, 1, "line 1 names no family version (want 'family vX.Y')")
            continue
        v = f"v{m.group(1)}.{m.group(2)}"
        if first is None:
            first = (v, path)
        elif v != first[0]:
            rep.bad(path, 1, f"family version {v} differs from {first[0]} ({first[1]})")
    return rep.done()


def cmd_tokens(files):
    if len(files) != 1:
        usage("tokens takes one file: family.css")
    path = files[0]
    rep = Report("tokens")
    light, dark, active, dark_active, problems = palette(path, read(path))
    for line, reason in problems:
        rep.bad(path, line, reason)
    for s in sorted(set(light) - set(dark)):
        rep.bad(path, light[s][1], f"dark twin missing: --family-light-{s} has no --family-dark-{s}")
    for s in sorted(set(dark) - set(light)):
        rep.bad(path, dark[s][1], f"light twin missing: --family-dark-{s} has no --family-light-{s}")
    suffixes = sorted(set(light) | set(dark))
    rep.subjects = len(suffixes)
    for s in suffixes:
        for name, store in (("light", light), ("dark", dark)):
            if s in store and ("var(" in store[s][0] or not store[s][0]):
                rep.bad(path, store[s][1], f"--family-{name}-{s} is not a literal: {store[s][0]}")
        want = f"var(--family-light-{s})"
        got = active.get(s)
        if not got or got[0].replace(" ", "") != want:
            rep.bad(path, got[1] if got else 0, f"--family-{s} is not {want} at the top level")
        want = f"var(--family-dark-{s})"
        got = dark_active.get(s)
        if not got or got[0].replace(" ", "") != want:
            rep.bad(path, got[1] if got else 0, f"--family-{s} is not {want} in the prefers-color-scheme: dark block")
    # An active token pointing at a theme set must have its suffix in both.
    for s, (val, line) in sorted(active.items()):
        m = re.fullmatch(r"var\(--family-(light|dark)-([a-z0-9-]+)\)", val.replace(" ", ""))
        if m and m.group(2) not in suffixes:
            rep.bad(path, line, f"--family-{s} points at an undefined theme token")
    if rep.subjects < SUFFIXES_MIN:
        rep.bad(path, 0, f"only {rep.subjects} palette suffixes; want at least {SUFFIXES_MIN}")
    return rep.done()


def cmd_literals(files):
    if len(files) != 2:
        usage("literals takes two files: family.css page.html")
    css_path, page_path = files
    rep = Report("literals")
    css = strip_comments(read(css_path))
    colours = colour_literals(css)
    rep.subjects = len(colours)
    page = read(page_path)
    flat = re.sub(r"\s+", "", page.lower())
    for c in sorted(colours):
        if c in flat:
            idx = page.lower().find(c)
            line = page.count("\n", 0, idx) + 1 if idx >= 0 else 0
            rep.bad(page_path, line, f"holds family colour {c} (it belongs in {css_path})")
    defined = set(re.findall(r"(--family-[a-z0-9-]+)\s*:", css))
    for css_text, base in html_styles(page):
        clean = strip_comments(css_text)
        for m in re.finditer(r"(--[A-Za-z0-9-]+)\s*:", clean):
            rep.bad(page_path, base + clean.count("\n", 0, m.start()), f"defines custom property {m.group(1)} (tokens live in family.css)")
    for m in re.finditer(r"var\(\s*(--[A-Za-z0-9-]+)", page):
        line = page.count("\n", 0, m.start()) + 1
        name = m.group(1)
        if not name.startswith("--family-"):
            rep.bad(page_path, line, f"var({name}) is not a family token")
        elif name not in defined:
            rep.bad(page_path, line, f"var({name}) is not defined in {css_path}")
    if rep.subjects < 2 * SUFFIXES_MIN:
        rep.bad(css_path, 0, f"only {rep.subjects} colour literals; want at least {2 * SUFFIXES_MIN}")
    return rep.done()


def cmd_contrast(files):
    if not files:
        usage("contrast takes family.css, then any files to read for --family-board backgrounds")
    path = files[0]
    rep = Report("contrast")
    light, dark, _, _, _ = palette(path, read(path))
    for theme, store in (("light", light), ("dark", dark)):
        col = {}
        for s in ("ground", "nav-bg", "grid-minor", "grid-major") + FG:
            c = parse_colour(store[s][0]) if s in store else None
            if c is None:
                rep.bad(path, 0, f"{theme}: --family-{theme}-{s} is missing or not a colour")
            col[s] = c
        if None in col.values():
            continue
        grid = over(col["grid-major"], over(col["grid-minor"], col["ground"]))
        bgs = (("ground", col["ground"]), ("grid", grid), ("nav-bg", col["nav-bg"]))
        for fg in FG:
            for bgname, bg in bgs:
                rep.subjects += 1
                r = ratio(col[fg], bg)
                print(f"{theme} {fg}/{bgname} {hexof(col[fg])} {hexof(bg)} {r:.2f}")
                if r < AA:
                    rep.bad(path, store[fg][1], f"{theme} {fg} on {bgname} is {r:.2f}:1, below {AA}:1")
    # No text sits on --family-board: only html and body may paint it.
    for other in files:
        for rule in css_of(other, read(other)):
            for prop, val, line in rule.decls:
                if prop in ("background", "background-color") and "--family-board" in val:
                    sels = {s.strip() for s in split_top(rule.sel, ",")}
                    if not sels <= {"html", "body"}:
                        rep.bad(other, line, f"{rule.sel} paints --family-board behind text (only html and body may)")
    return rep.done()


SCOPE_NEUTRAL = {"html", "body", "*", ""}


def cmd_scope(files):
    if len(files) < 2:
        usage("scope takes page.html, then one or more partials")
    page_path, partials = files[0], files[1:]
    rep = Report("scope")
    ptags, pclasses, where = set(), set(), {}
    for p in partials:
        tags, classes = markup_of(read(p))
        for t in tags:
            where.setdefault(t, p)
        ptags |= tags
        pclasses |= classes
    for rule in css_of(page_path, read(page_path)):
        for sel in split_top(rule.sel, ","):
            rep.subjects += 1
            comps = compounds(sel)
            if not comps:
                continue
            el, classes, has_id, has_attr = compound_parts(comps[-1])
            hit = sorted(classes & pclasses)
            if hit:
                rep.bad(page_path, rule.line, f"'{sel}' styles family markup (.{hit[0]})")
                continue
            if classes or has_id or has_attr or el not in ptags:
                continue
            scoped = False
            for c in comps[:-1]:
                e, cl, i, at = compound_parts(c)
                if i or at or (cl - pclasses and not all(x.startswith("family-") for x in cl - pclasses)):
                    scoped = True
                elif e and e not in ptags and e not in SCOPE_NEUTRAL:
                    scoped = True
            if not scoped:
                rep.bad(page_path, rule.line, f"'{sel}' reaches family markup (<{el}> in {where.get(el, 'a partial')})")
    return rep.done()


JS_CONTRACT = ("key", "class", "control", "exports")


def contract_js(path, text, rep):
    """family.js's header names key, class, control and exports; each must be
    what the code uses: the key, class and control as string literals in the
    code below the header, each export assigned on window."""
    m = re.match(r"\s*((?:/\*.*?\*/\s*)+)", text, re.S)
    header = m.group(1) if m else ""
    code = text[len(m.group(0)):] if m else text
    base = text.count("\n", 0, len(m.group(0))) if m else 0
    found = {}
    for i, line in enumerate(header.split("\n"), 1):
        hm = re.match(r"\s*\*?\s*(key|class|control|exports):\s*(\S.*?)\s*$", line)
        if hm and hm.group(1) not in found:
            found[hm.group(1)] = (hm.group(2), i)
    for name in JS_CONTRACT:
        rep.subjects += 1
        if name not in found:
            rep.bad(path, 0, f"the header names no '{name}:' line")
            continue
        val, line = found[name]
        if name == "exports":
            for ex in [x.strip() for x in val.split(",")]:
                if not re.search(r"\bwindow\." + re.escape(ex) + r"\s*=", code):
                    rep.bad(path, line, f"header exports {ex}, which the code never assigns on window")
        elif not re.search(r"(['\"])" + re.escape(val) + r"\1", code):
            rep.bad(path, line, f"header {name} {val} is not a string literal in the code")
    print("header " + " ".join(f"{k}={found.get(k, ('?', 0))[0].replace(' ', '')}" for k in JS_CONTRACT))
    if base == 0:
        rep.bad(path, 0, "no header comment")


EXAMPLE_RE = re.compile(r"#\s+example:\s+(.*?)\s+->\s+(.*?)\s*$")


def contract_live(path, filler, rep):
    """Each '# example: <input> -> <output>' line of a live settings file
    renders as written through the real filler, with that file as settings.
    An output of <N> stands for a positive decimal (a count)."""
    import os
    import subprocess
    import tempfile
    text = read(path)
    for n, line in enumerate(text.split("\n"), 1):
        m = EXAMPLE_RE.match(line)
        if not m:
            continue
        rep.subjects += 1
        given, want = m.group(1), m.group(2)
        fd, tmp = tempfile.mkstemp(suffix=".html")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write((given + "\n").encode("utf-8"))
            r = subprocess.run([sys.executable, "-I", "-X", "utf8", filler, "--settings", path, tmp],
                               capture_output=True, text=True)
            got = read(tmp).rstrip("\n")
        finally:
            os.unlink(tmp)
        if r.returncode != 0:
            rep.bad(path, n, f"example {given} did not fill (exit {r.returncode}): {r.stderr.strip()}")
            continue
        ok = re.fullmatch(r"[1-9][0-9]*", got) if want == "<N>" else got == want
        if not ok:
            rep.bad(path, n, f"example {given} renders as {got}, not {want}")
    if rep.subjects == 0:
        rep.bad(path, 0, "no '# example: <input> -> <output>' line")


def cmd_contract(files):
    rep = Report("contract")
    if files[0].endswith(".txt"):
        if len(files) != 2:
            usage("contract <live.txt> takes the filler too: contract <live.txt> <fill-placeholders.py>")
        contract_live(files[0], files[1], rep)
        return rep.done()
    for path in files:
        text = read(path)
        if path.endswith(".js"):
            contract_js(path, text, rep)
        else:
            usage(f"contract reads family.js, or live.txt and the filler: {path}")
    return rep.done()


FORBIDDEN = {"html", "head", "body", "script", "style", "link", "meta"}
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}


class Fragment(html.parser.HTMLParser):
    def __init__(self, path, rep, classes):
        super().__init__(convert_charrefs=True)
        self.path, self.rep, self.classes = path, rep, classes
        self.stack = []
        self.roots = 0

    def _start(self, tag, attrs, void):
        line = self.getpos()[0]
        if not self.stack:
            self.roots += 1
        if tag in FORBIDDEN:
            self.rep.bad(self.path, line, f"<{tag}> is not allowed in a fragment")
        for k, v in attrs:
            if k.startswith("on"):
                self.rep.bad(self.path, line, f"{k}= is not allowed in a fragment")
            if k == "class" and v:
                for c in v.split():
                    if c not in self.classes:
                        self.rep.bad(self.path, line, f"class '{c}' is not defined in family.css")
        if not void:
            self.stack.append((tag, line))

    def handle_starttag(self, tag, attrs):
        self._start(tag, attrs, tag in VOID)

    def handle_startendtag(self, tag, attrs):
        self._start(tag, attrs, True)

    def handle_endtag(self, tag):
        line = self.getpos()[0]
        if tag in VOID:
            return
        if not self.stack:
            self.rep.bad(self.path, line, f"</{tag}> has no open element")
            return
        top = self.stack[-1][0]
        if top != tag:
            self.rep.bad(self.path, line, f"</{tag}> closes <{top}>")
            while self.stack and self.stack[-1][0] != tag:
                self.stack.pop()
        if self.stack:
            self.stack.pop()

    def handle_data(self, data):
        if not self.stack and data.strip():
            self.rep.bad(self.path, self.getpos()[0], "text outside the root element")


def cmd_fragment(files):
    if len(files) < 2:
        usage("fragment takes family.css, then one or more filled partials")
    css_path, frags = files[0], files[1:]
    rep = Report("fragment")
    classes = set()
    for rule in parse_css(read(css_path))[0]:
        classes |= set(re.findall(r"\.([A-Za-z0-9_-]+)", rule.sel))
    for path in frags:
        rep.subjects += 1
        text = read(path)
        i = text.find("{{")
        if i >= 0:
            rep.bad(path, text.count("\n", 0, i) + 1, "a placeholder is left (fill the partial first)")
        p = Fragment(path, rep, classes)
        p.feed(text)
        p.close()
        for tag, line in p.stack:
            rep.bad(path, line, f"<{tag}> is never closed")
        if p.roots != 1:
            rep.bad(path, 0, f"{p.roots} root elements (want 1)")
    return rep.done()


COMMANDS = {
    "contract": cmd_contract,
    "fragment": cmd_fragment,
    "header": cmd_header,
    "tokens": cmd_tokens,
    "literals": cmd_literals,
    "contrast": cmd_contrast,
    "scope": cmd_scope,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        usage("unknown or missing subcommand")
    if len(argv) < 3:
        usage(f"{argv[1]} needs at least one file")
    return COMMANDS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
