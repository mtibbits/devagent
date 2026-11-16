#!/usr/bin/env python3
"""landing-check.py — test helper: read facts out of the landing page (#998).

Usage:
  landing-check.py text [--scripts-off] [--no-svg] [--article] [--within <id>] <html>
      one visible text node per line, entities decoded, whitespace collapsed
      and trimmed, empty nodes dropped. Never read: comments, attributes, and
      the contents of <script>, <style>, <template>.
      --scripts-off  also drops: elements carrying `hidden`; elements whose
                     style= sets display:none or visibility:hidden; the content
                     of a <details> without `open`, except its <summary>.
      --no-svg       drops every <svg> subtree.
      --article      reads only the first <article> (the whole document when
                     there is none, as in a source page).
      --within <id>  reads only the subtree of the element with that id.
  landing-check.py codes [--article] <html>
      the text content of each <code> element, one line per line of it, in
      document order.
  landing-check.py links --within <id> <html>
      the href of each <a> in that subtree, one per line, in document order.
  landing-check.py linked-coming [--article] <html>
      the text of each <span class="family-coming"> that sits inside an <a>,
      one per line, in document order (a not-live item must never link).
  landing-check.py loop <html>
      TSV, one row per phase in document order, inside the element id=loop:
        svg<TAB><id><TAB><name><TAB><steps-label>
            for each <g data-phase="<id>"> in the <svg>: the text of its
            <text class="loop-name"> and of its <text class="loop-steps">
        list<TAB><id><TAB><open:yes|no><TAB><start><TAB><summary><TAB><s1 s2 ...>
            for each <li id="phase-<id>">: its <details>' open attribute, the
            start= of its <ol> (absent -> 1), the <summary> text, and the text
            of each <li> of that <ol>

Exit: 0 ok; 1 a structural absence (named on stderr); 2 usage or an
unreadable file. Diagnostics go to stderr only (stdout is data).

Parse model (stdlib html.parser): void elements and self-closing tags
(<rect/>) are never pushed; an end tag pops the stack down to its matching
open element, and a stray end tag is ignored. CSS hiding rules in stylesheets
are not modelled here: tests/lib/family-check.py `hidden` owns that.
"""
import html.parser
import re
import sys

PROG = "landing-check"
VOID = frozenset("area base br col embed hr img input link meta source track wbr".split())
NEVER_READ = frozenset(("script", "style", "template"))
HIDING_STYLE = re.compile(r"display\s*:\s*none|visibility\s*:\s*hidden", re.I)


class Usage(Exception):
    pass


class Absent(Exception):
    pass


class Node:
    __slots__ = ("tag", "attrs", "children")

    def __init__(self, tag, attrs):
        self.tag = tag
        self.attrs = attrs
        self.children = []

    def has_class(self, name):
        return name in (self.attrs.get("class") or "").split()


class Tree(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("#document", {})
        self.stack = [self.root]

    def _attrs(self, attrs):
        return {k.lower(): ("" if v is None else v) for k, v in attrs}

    def handle_starttag(self, tag, attrs):
        node = Node(tag.lower(), self._attrs(attrs))
        self.stack[-1].children.append(node)
        if node.tag not in VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.stack[-1].children.append(Node(tag.lower(), self._attrs(attrs)))

    def handle_endtag(self, tag):
        tag = tag.lower()
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return

    def handle_data(self, data):
        self.stack[-1].children.append(data)


def parse(path):
    try:
        with open(path, "rb") as f:
            text = f.read().decode("utf-8")
    except (OSError, UnicodeDecodeError) as e:
        raise Usage(f"cannot read {path}: {e}")
    t = Tree()
    t.feed(text)
    t.close()
    return t.root


def walk(node):
    """Every element under node (node included), in document order."""
    yield node
    for c in node.children:
        if isinstance(c, Node):
            yield from walk(c)


def find(node, pred):
    for n in walk(node):
        if pred(n):
            return n
    return None


def collapse(s):
    return " ".join(s.split())


def raw_text(node, skip=NEVER_READ):
    """node's text content, uncollapsed, with the elements in skip excluded."""
    return "".join(c if isinstance(c, str) else "" if c.tag in skip else raw_text(c, skip)
                   for c in node.children)


def text_of(node):
    """The collapsed text content of node (never-read elements excluded)."""
    return collapse(raw_text(node))


def by_id(root, ident):
    n = find(root, lambda n: n.attrs.get("id") == ident)
    if n is None:
        raise Absent(f"no element id={ident}")
    return n


def article(root):
    return find(root, lambda n: n.tag == "article") or root


def visible_text(node, scripts_off, no_svg, out):
    for c in node.children:
        if isinstance(c, str):
            s = collapse(c)
            if s:
                out.append(s)
            continue
        if c.tag in NEVER_READ or (no_svg and c.tag == "svg"):
            continue
        if scripts_off:
            if "hidden" in c.attrs or HIDING_STYLE.search(c.attrs.get("style", "")):
                continue
            if c.tag == "details" and "open" not in c.attrs:
                for s in c.children:
                    if isinstance(s, Node) and s.tag == "summary":
                        visible_text(s, scripts_off, no_svg, out)
                continue
        visible_text(c, scripts_off, no_svg, out)


def cmd_text(args):
    scripts_off = no_svg = use_article = False
    within = None
    while args and args[0].startswith("--"):
        a = args.pop(0)
        if a == "--scripts-off":
            scripts_off = True
        elif a == "--no-svg":
            no_svg = True
        elif a == "--article":
            use_article = True
        elif a == "--within" and args:
            within = args.pop(0)
        else:
            raise Usage(f"text: unknown or incomplete option {a}")
    if len(args) != 1:
        raise Usage("text takes one <html>")
    node = parse(args[0])
    if use_article:
        node = article(node)
    if within is not None:
        node = by_id(node, within)
    out = []
    visible_text(node, scripts_off, no_svg, out)
    return out


def cmd_codes(args):
    use_article = False
    if args and args[0] == "--article":
        args.pop(0)
        use_article = True
    if len(args) != 1:
        raise Usage("codes takes [--article] <html>")
    node = parse(args[0])
    if use_article:
        node = article(node)
    return [ln.strip() for n in walk(node) if n.tag == "code"
            for ln in raw_text(n, skip=()).split("\n") if ln.strip()]


def cmd_linked_coming(args):
    use_article = False
    if args and args[0] == "--article":
        args.pop(0)
        use_article = True
    if len(args) != 1:
        raise Usage("linked-coming takes [--article] <html>")
    node = parse(args[0])
    if use_article:
        node = article(node)
    return [text_of(s) for a in walk(node) if a.tag == "a"
            for s in walk(a) if s.tag == "span" and s.has_class("family-coming")]


def cmd_links(args):
    if len(args) != 3 or args[0] != "--within":
        raise Usage("links takes --within <id> <html>")
    node = by_id(parse(args[2]), args[1])
    return [n.attrs["href"] for n in walk(node) if n.tag == "a" and "href" in n.attrs]


def cmd_loop(args):
    if len(args) != 1:
        raise Usage("loop takes one <html>")
    loop = by_id(parse(args[0]), "loop")
    rows = []
    for n in walk(loop):
        if n.tag == "g" and "data-phase" in n.attrs:
            pid = n.attrs["data-phase"]
            name = find(n, lambda m: m.tag == "text" and m.has_class("loop-name"))
            steps = find(n, lambda m: m.tag == "text" and m.has_class("loop-steps"))
            if name is None or steps is None:
                raise Absent(f"phase {pid}: the svg group lacks a loop-name or loop-steps <text>")
            rows.append(f"svg\t{pid}\t{text_of(name)}\t{text_of(steps)}")
        elif n.tag == "li" and n.attrs.get("id", "").startswith("phase-"):
            pid = n.attrs["id"][len("phase-"):]
            det = find(n, lambda m: m.tag == "details")
            if det is None:
                raise Absent(f"phase {pid}: the list item has no <details>")
            summ = find(det, lambda m: m.tag == "summary")
            ol = find(det, lambda m: m.tag == "ol")
            if summ is None or ol is None:
                raise Absent(f"phase {pid}: the <details> lacks a <summary> or an <ol>")
            items = [text_of(c) for c in ol.children if isinstance(c, Node) and c.tag == "li"]
            rows.append("\t".join(("list", pid, "yes" if "open" in det.attrs else "no",
                                   ol.attrs.get("start") or "1", text_of(summ), " ".join(items))))
    return rows


COMMANDS = {"text": cmd_text, "codes": cmd_codes, "links": cmd_links,
            "linked-coming": cmd_linked_coming, "loop": cmd_loop}


def main(argv):
    try:
        if len(argv) < 2 or argv[1] not in COMMANDS:
            raise Usage("usage: landing-check.py text|codes|links|linked-coming|loop ... <html>")
        out = COMMANDS[argv[1]](argv[2:])
    except (Usage, Absent) as e:
        print(f"{PROG}: {e}", file=sys.stderr)
        return 2 if isinstance(e, Usage) else 1
    for line in out:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
