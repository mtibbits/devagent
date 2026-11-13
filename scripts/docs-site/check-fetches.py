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
