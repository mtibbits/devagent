#!/usr/bin/env python3
"""Tracker state for `wbs update` (#703): the line grammar and precedence.

An issue backend's `state-list <repo>` verb prints one line per issue:
`<id>` TAB `<class>`, where `<class>` is one of done, not_planned,
in_progress, open or other (spec section 9.1). `parse_state_list` reads
that output; `resolve` decides a leaf's glyph from the tracker class and
the local checklist. Reconcile and auto-add both call `resolve`, so the
two entry points cannot drift.

CLI:
  wbs-tracker.py check   read state-list output on stdin; print the issue
                         count and exit 0, or name the first malformed line
                         on stderr and exit 1. The backend contract tests
                         use it, so they and `wbs update` share one predicate.
"""
from __future__ import annotations

import re
import sys

CLASSES = ("done", "not_planned", "in_progress", "open", "other")
LINE_RE = re.compile(r"^([^\t]+)\t(done|not_planned|in_progress|open|other)$")

# Hand-set glyphs an in-progress tracker claim does not override.
HAND_SET = {"P", "!", "?"}


def parse_state_list(text: str) -> dict[str, str]:
    """Map issue id -> class. Blank lines are skipped; CRLF is absorbed.

    Raises ValueError("malformed line <n>: <line>") for a line outside the
    grammar, or for an id listed twice with different classes.
    """
    out: dict[str, str] = {}
    for n, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        m = LINE_RE.match(line)
        if not m:
            raise ValueError(f"malformed line {n}: {line}")
        iid, cls = m.group(1), m.group(2)
        if out.get(iid, cls) != cls:
            raise ValueError(f"malformed line {n}: {line}")
        out[iid] = cls
    return out


def resolve(
    current: str, cls: str, local: str | None, cur_src: str | None = None
) -> tuple[str, str] | None:
    """Return (glyph, status_src) for a leaf, or None to leave it untouched.

    current  the leaf's glyph now
    cls      a state-list class, or `none` (no lookup for this leaf),
             `missing` (absent from a successful list) or `unmatched`
             (the id fits no configured source)
    local    the glyph the issue's checklist implies, None for no signal
    cur_src  the leaf's current `status_src` meta value, if any
    """
    if cls == "done":
        return ("x", "tracker")
    if cls == "not_planned":
        return ("-", "tracker")
    if cls == "in_progress":
        if current in HAND_SET:
            return None
        return ("~", "tracker")
    if cls == "open":
        if local is None:
            # closed-then-reopened: a tracker-set glyph is stale, but a
            # hand-set one is the operator's (#702)
            if cur_src == "tracker" and current not in HAND_SET:
                return ("~", "tracker")
            return None
        if local == "x":
            # the tracker says open, so an all-done checklist is not done
            return ("~", "tracker")
        return (local, "checklist")
    if cls in ("other", "none"):
        return None if local is None else (local, "checklist")
    return None  # missing, unmatched


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] != "check":
        print("usage: wbs-tracker.py check < state-list-output", file=sys.stderr)
        return 2
    try:
        parsed = parse_state_list(sys.stdin.read())
    except ValueError as e:
        print(f"wbs-tracker: {e}", file=sys.stderr)
        return 1
    print(len(parsed))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
