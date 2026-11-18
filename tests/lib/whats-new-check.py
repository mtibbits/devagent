#!/usr/bin/env python3
"""whats-new-check.py — test helper: the What's new page's facts (#1002).

Usage:
  whats-new-check.py shipped <page.md> <sources.txt> <CHANGELOG.md> <tags-file>
      Every item under the page's "## Shipped since 1.0" heading is tied, via
      the sources sidecar, to an Added or Changed bullet of a released
      CHANGELOG section newer than 1.0.0, and links the GitHub release of the
      first tag that contains it. <tags-file> is `git tag` output.
  whats-new-check.py roadmap <page.md>
      The "## What's next" section has at least 3 themes, each saying
      "coming", and carries no issue number, no target date and no family
      site name (the one "last checked" line is exempt from the date rule).
  whats-new-check.py checked <page.md> <CHANGELOG.md>
      The page shows exactly one "last checked" date, after the roadmap's
      themes and outside them, a real date not before the newest release.
  whats-new-check.py tag-lane <test.yml>
      The workflow's `bats` job (the lane that runs tests/docs-site.bats)
      checks out with fetch-depth: 0 or fetch-tags: true.
  whats-new-check.py recheck <README.md> <docs-site/README.md>
      README's "Cutting a release" steps re-derive the What's new roadmap and
      its "last checked" date before the publish step (the release PR), and
      re-check the What's new page after it; the drift policy says so.

Exit: 0 the fact holds; 1 broken, one-line reason on stderr; 2 cannot run
(usage, unreadable file). Never raises: a crash would read as "broken".

Parse model, Markdown: a section is a "## " heading up to the next "## "
heading (or EOF). A list item starts at a column-0 "- " line and runs to a
blank line, the next column-0 "- " line, or a heading — gfm list extent, so a
line placed directly after an item with no blank line is part of that item.
CHANGELOG: sections are "## [<v>]" blocks; a bullet is a column-0 "- " line up
to the next one; it counts only when it starts "- **Added" or "- **Changed".
Versions compare as integer tuples, never as strings.
"""

import collections
import datetime
import re
import sys

REL_URL = "https://github.com/mtibbits/devagent/releases/tag/"
REL_RE = re.compile(re.escape(REL_URL) + r"([^\s)\]>]+)")
TAG_RE = re.compile(r"^devagent--v(\d+)\.(\d+)\.(\d+)$")
VER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
DATE_RE = re.compile(r"\b(\d{4}-\d{2}-\d{2})\b")
FLOOR = (1, 0, 0)
MONTHS = ("January February March April May June July August September "
          "October November December").split()
YEAR_RE = re.compile(r"\b(19|20)\d{2}\b")
MONTH_RE = re.compile(r"\b(" + "|".join(MONTHS) + r")\b")
QUARTER_RE = re.compile(r"\bQ[1-4]\b")
# The same issue-number rule as _ISSUE_NUM_ERE in docs-site-checks.bash.
ISSUE_RE = re.compile(r"#[0-9]|Issue-[0-9]")
FAMILY_RE = re.compile(r"journeyman|gantry|curriculum|blazeahead", re.I)
COMING_RE = re.compile(r"\bcoming\b", re.I)
CHECKED_RE = re.compile(r"last checked", re.I)
LABEL_RE = re.compile(r"^- \*\*(.+?)\.\*\*")


class Broken(Exception):
    """The fact is broken: exit 1 with this reason."""


class CannotRun(Exception):
    """The check cannot run: exit 2 with this reason."""


def read(path):
    try:
        with open(path, encoding="utf-8", newline=None) as f:
            return f.read().split("\n")
    except OSError as e:
        raise CannotRun(f"cannot read {path}: {e.strerror}")
    except UnicodeDecodeError:
        raise CannotRun(f"cannot read {path}: not UTF-8")


def ws(s):
    return " ".join(s.split())


def section(lines, heading, path):
    """(start, lines) of the '## <heading>' section, heading line excluded."""
    for i, line in enumerate(lines):
        if line.rstrip() == "## " + heading:
            out = []
            for j in range(i + 1, len(lines)):
                if lines[j].startswith("## "):
                    break
                out.append(lines[j])
            return i + 1, out
    raise Broken(f"{path}: no '## {heading}' heading")


def items(lines):
    """[(first_index, last_index, joined_text)] of the column-0 list items."""
    out, cur = [], None
    for i, line in enumerate(lines):
        if line.startswith("- "):
            if cur:
                out.append(cur)
            cur = [i, i, line]
        elif cur and line.strip() and not line.lstrip().startswith("#"):
            cur[1] = i
            cur[2] += " " + line.strip()
        else:
            if cur:
                out.append(cur)
            cur = None
    if cur:
        out.append(cur)
    return [(a, b, ws(t)) for a, b, t in out]


Section = collections.namedtuple("Section", "version name date bullets text")


def changelog(path):
    """[Section] of the released ("## [x.y.z]") sections, any order."""
    secs, cur = [], None
    for line in read(path):
        m = re.match(r"^## \[([^\]]+)\]", line)
        if m:
            name = m.group(1)
            v = VER_RE.match(name)
            d = DATE_RE.search(line)
            cur = [tuple(map(int, v.groups())) if v else None, name,
                   d.group(1) if d else None, [], []]
            secs.append(cur)
            continue
        if cur is None:
            continue
        cur[4].append(line)
        if line.startswith("- "):
            cur[3].append(line)
        elif cur[3] and line.strip():
            cur[3][-1] += " " + line.strip()
    out = [Section(v, n, d, [ws(b) for b in bs], ws(" ".join(t)))
           for v, n, d, bs, t in secs if v is not None]
    if not out:
        raise CannotRun(f"{path}: no released sections")
    return out


def anchor_in(anchor, text):
    if anchor.startswith("#"):
        return re.search(re.escape(anchor) + r"(?!\d)", text) is not None
    return ws(anchor[3:]) in text


def vstr(v):
    return ".".join(map(str, v))


def cmd_shipped(page, sources, chlog, tagsfile):
    try:
        tag_lines = [t.strip() for t in read(tagsfile) if t.strip()]
    except CannotRun:
        tag_lines = []
    if not tag_lines:
        raise Broken("git tag is empty: fetch tags (git fetch --tags)")
    tags = {t: tuple(map(int, m.groups())) for t in tag_lines for m in [TAG_RE.match(t)] if m}

    src = {}
    for n, line in enumerate(read(sources), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if " | " not in s:
            raise Broken(f"{sources}:{n}: not '<label> | <anchor>'")
        label, anchor = (x.strip() for x in s.rsplit(" | ", 1))
        if not (re.fullmatch(r"#\d+", anchor) or re.fullmatch(r"kw:\S.*", anchor)):
            raise Broken(f"{sources}:{n}: bad anchor '{anchor}' (want #N or kw:<text>)")
        src[label] = anchor

    _, body = section(read(page), "Shipped since 1.0", page)
    its = items(body)
    if not its:
        raise Broken(f"{page}: no items under '## Shipped since 1.0'")
    page_items = {}
    for _, _, text in its:
        m = LABEL_RE.match(text)
        if not m:
            raise Broken(f"{page}: item has no bold label: {text[:60]}")
        page_items[m.group(1)] = text

    for label in page_items:
        if label not in src:
            raise Broken(f"no sources line for '{label}'")
    for label in src:
        if label not in page_items:
            raise Broken(f"no page item for '{label}'")

    released = changelog(chlog)
    by_version = sorted(tags.items(), key=lambda kv: kv[1])
    for label, text in page_items.items():
        links = REL_RE.findall(text)
        if len(links) != 1:
            raise Broken(f"'{label}': {len(links)} release links, want exactly one release link")
        tag = links[0]
        if tag not in tags:
            raise Broken(f"'{label}': {tag} not in git tag (git fetch --tags if this clone is behind)")
        anchor = src[label]
        added = [s.version for s in released if s.version > FLOOR
                 and any(b.startswith(("- **Added", "- **Changed")) and anchor_in(anchor, b)
                         for b in s.bullets)]
        if not added:
            raise Broken(f"'{label}': {anchor} not in an Added or Changed bullet of a released section newer than 1.0.0")
        anywhere = [s.version for s in released if anchor_in(anchor, s.text)]
        if min(anywhere) <= FLOOR:
            raise Broken(f"'{label}': {anchor} first appeared in 1.0.0 or earlier ({vstr(min(anywhere))})")
        first = min(added)
        want = next((t for t, v in by_version if v >= first), None)
        if want is None:
            raise Broken(f"'{label}': no tag at or after {vstr(first)}; not in git tag")
        if tag != want:
            raise Broken(f"'{label}': first added in {vstr(first)}, should link {want}, not {tag}")


def cmd_roadmap(page):
    _, body = section(read(page), "What's next", page)
    its = items(body)
    if len(its) < 3:
        raise Broken(f"{page}: {len(its)} roadmap themes, want at least 3: no themes")
    for _, _, text in its:
        if not COMING_RE.search(text):
            raise Broken(f"{page}: theme missing coming: {text[:60]}")
    for line in body:
        if ISSUE_RE.search(line):
            raise Broken(f"{page}: an issue number in What's next: {line.strip()[:60]}")
        if FAMILY_RE.search(line):
            raise Broken(f"{page}: What's next names a family site: {line.strip()[:60]}")
        if CHECKED_RE.search(line):
            continue
        if YEAR_RE.search(line) or MONTH_RE.search(line) or QUARTER_RE.search(line):
            raise Broken(f"{page}: a target date in What's next: {line.strip()[:60]}")


def cmd_checked(page, chlog):
    lines = read(page)
    hits = [i for i, l in enumerate(lines) if CHECKED_RE.search(l) and DATE_RE.search(l)]
    if not hits:
        raise Broken(f"{page}: no last-checked date")
    if len(hits) > 1:
        raise Broken(f"{page}: {len(hits)} last-checked lines, want exactly one")
    start, body = section(lines, "What's next", page)
    at = hits[0] - start
    its = items(body)
    if not (0 <= at < len(body)):
        raise Broken(f"{page}: the last-checked line is not in What's next")
    if its and at < its[-1][0]:
        raise Broken(f"{page}: the last-checked line is not after the roadmap themes")
    if any(a <= at <= b for a, b, _ in its):
        raise Broken(f"{page}: the last-checked line is inside a theme (add a blank line before it)")
    d = DATE_RE.search(lines[hits[0]]).group(1)
    try:
        when = datetime.date.fromisoformat(d)
    except ValueError:
        raise Broken(f"{page}: invalid date {d}")
    newest = max(changelog(chlog), key=lambda s: s.version)
    if not newest.date:
        raise Broken(f"{chlog}: newest release {newest.name} has no date")
    if when < datetime.date.fromisoformat(newest.date):
        raise Broken(f"{page}: roadmap last checked {d} predates release {newest.name} ({newest.date})")


def cmd_tag_lane(yml):
    lines = read(yml)
    start = next((i for i, l in enumerate(lines) if re.match(r"^  bats:\s*$", l)), None)
    if start is None:
        raise Broken(f"{yml}: no '  bats:' job; no tag fetch can be shown")
    job = []
    for l in lines[start + 1:]:
        if re.match(r"^  [A-Za-z0-9_-]+:\s*$", l) or re.match(r"^\S", l):
            break
        job.append(l)
    if not any(re.search(r"uses:\s*actions/checkout", l) for l in job):
        raise Broken(f"{yml}: the bats job has no actions/checkout step: no tag fetch")
    if not any(re.match(r"^\s+(fetch-depth:\s*0|fetch-tags:\s*true)\s*(#.*)?$", l) for l in job):
        raise Broken(f"{yml}: the bats job's checkout has no fetch-depth: 0 or fetch-tags: true: no tag fetch")


def steps(lines):
    """[(number, joined_text)] of the column-0 '<n>. ' list items."""
    out, open_ = [], False
    for line in lines:
        m = re.match(r"^(\d+)\. ", line)
        if m:
            out.append([int(m.group(1)), line])
            open_ = True
        elif open_ and line.startswith(" ") and line.strip():
            out[-1][1] += " " + line.strip()
        else:
            open_ = False
    return [(n, ws(t)) for n, t in out]


def cmd_recheck(readme, policy):
    _, body = section(read(readme), "Versioning & releases", readme)
    st = steps(body)
    pub = next((i for i, (_, t) in enumerate(st) if "gh release create" in t), None)
    if pub is None:
        raise Broken(f"{readme}: no release step ('gh release create') in Versioning & releases")
    low = [t.lower().replace("’", "'") for _, t in st]
    re_i = next((i for i, t in enumerate(low) if "re-check the what's new page" in t), None)
    if re_i is None:
        raise Broken(f"{readme}: no recheck step ('Re-check the What's new page')")
    if re_i <= pub:
        raise Broken(f"{readme}: the recheck step comes before the release step")
    if not any("what's new" in t and "last checked" in t for t in low[:pub]):
        raise Broken(f"{readme}: no step before the release step bumps the What's new 'last checked' date: no roadmap date step")
    text = "\n".join(read(policy))
    paras = [ws(p) for p in re.split(r"\n\s*\n", text)]
    if not any("whats-new.md" in p and "each release" in p.lower() for p in paras):
        raise Broken(f"{policy}: no recheck rule (a paragraph naming whats-new.md and each release)")


CMDS = {
    "shipped": (cmd_shipped, 4),
    "roadmap": (cmd_roadmap, 1),
    "checked": (cmd_checked, 2),
    "tag-lane": (cmd_tag_lane, 1),
    "recheck": (cmd_recheck, 2),
}


def main(argv):
    if len(argv) < 1 or argv[0] not in CMDS or len(argv) - 1 != CMDS[argv[0]][1]:
        print("usage: whats-new-check.py shipped|roadmap|checked|tag-lane|recheck <file>...",
              file=sys.stderr)
        return 2
    fn, _ = CMDS[argv[0]]
    try:
        fn(*argv[1:])
    except Broken as e:
        print(str(e), file=sys.stderr)
        return 1
    except CannotRun as e:
        print(str(e), file=sys.stderr)
        return 2
    except Exception as e:  # a crash never reads as "broken"
        print(f"whats-new-check.py: internal error: {type(e).__name__}: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
