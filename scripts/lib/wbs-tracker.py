#!/usr/bin/env python3
"""Tracker state for `wbs update` (#703): the line grammar and precedence.

An issue backend's `state-list <repo>` verb prints one line per issue:
`<id>` TAB `<class>`, where `<class>` is one of done, not_planned,
in_progress, open or other (spec section 9.1). `parse_state_list` reads
that output; `resolve` decides a leaf's glyph from the tracker class and
the local checklist. Reconcile and auto-add both call `resolve`, so the
two entry points cannot drift. `mr_effect` is the MR phase's rule (#704):
it applies a leaf's linked-MR state (scripts/lib/mr-link.py) on top of
the tracker phase's result.

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
LINE_RE = re.compile(rf"^([^\t]+)\t({'|'.join(CLASSES)})$")

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
    current: str, cls: str, local: str | None, cur_src: str | None = None,
    *, mr_hold: bool = True,
) -> tuple[str, str] | None:
    """Return (glyph, status_src) for a leaf, or None to leave it untouched.

    current  the leaf's glyph now
    cls      a state-list class, or `none` (no lookup for this leaf),
             `missing` (absent from a successful list) or `unmatched`
             (the id fits no configured source)
    local    the glyph the issue's checklist implies, None for no signal
    cur_src  the leaf's current `status_src` meta value, if any
    mr_hold  hold a `status_src: mr` glyph unless the tracker closed the
             issue (#704): only the MR phase moves it. False when the
             project has no code backend, so such a leaf falls through.
    """
    if mr_hold and cur_src == "mr" and cls in ("open", "in_progress", "none"):
        return None
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


def mr_effect(
    glyph: str, src: str | None, cls: str, local: str | None, mr: str | None
) -> tuple[str, str | None, str | None] | None:
    """The MR phase's effect on a leaf (#704), or None to leave it untouched.

    glyph, src  the leaf's glyph and `status_src` after the tracker phase
    cls, local  as for `resolve`
    mr          the issue's aggregated MR state (open, draft, merged, none,
                missing), None when it was not looked up

    Returns (glyph, status_src, mr), where a None status_src or mr means
    remove that meta key.
    """
    if cls in ("done", "not_planned", "other"):
        return (glyph, src, None)  # the issue is not open: only mr: goes
    if cls not in ("open", "in_progress") or mr in (None, "missing"):
        return None
    if mr in ("open", "draft", "merged"):
        if glyph in HAND_SET:
            return (glyph, src, mr)
        return ("~", "mr", mr)
    # mr == "none": no MR links the issue (any more)
    if src != "mr":
        return (glyph, src, None)
    got = resolve(glyph, cls, local, None)
    if got is not None:
        return (*got, None)
    if glyph in HAND_SET:
        return (glyph, src, None)
    # No #703 signal: an abandoned MR is not work in progress. Removing
    # status_src (not `tracker`) is the fixed point: resolve() gives None.
    return (" ", None, None)


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
