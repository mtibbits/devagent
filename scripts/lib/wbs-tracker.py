#!/usr/bin/env python3
"""Tracker state for `wbs update` (#703): the line grammar and precedence.

An issue backend's `state-list <repo>` verb prints one line per issue:
`<id>` TAB `<class>`, where `<class>` is one of done, not_planned,
in_progress, open or other (spec section 9.1). `parse_state_list` reads
that output; `resolve` decides a leaf's glyph from the tracker class and
the local checklist, which `checklist_state` reads (shared by `wbs update`
and `wbs init --from-tracker`, #706). Reconcile and auto-add both call `resolve`, so the
two entry points cannot drift. `mr_effect` is the MR phase's rule (#704):
it applies a leaf's linked-MR state (scripts/lib/mr-link.py) on top of
the tracker phase's result. `leaf_for` and `parse_leaf` are the one rule
between a WBS leaf's `issue` id and a tracker issue (#792): `wbs init`
writes leaves with the first, and it and `wbs update` read them with the
second.

CLI:
  wbs-tracker.py check   read state-list output on stdin; print the issue
                         count and exit 0, or name the first malformed line
                         on stderr and exit 1. The backend contract tests
                         use it, so they and `wbs update` share one predicate.
"""
from __future__ import annotations

import re
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path

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


# --- the leaf <-> issue-id codec (#792) -----------------------------------------
# A source is any mapping with `prefix` (its dir_prefix), `backend` and
# `keyprefix` (the Jira key prefix; "" off Jira).
DIGITS_RE = re.compile(r"[0-9]+")                    # used with fullmatch
JIRA_KEY_RE = re.compile(r"[A-Z][A-Z0-9_]*-[0-9]+")  # used with fullmatch


def jira_keyprefix(env: Mapping[str, str], repo: str) -> str:
    """The Jira key prefix a source's bare numbers stand for: the
    DEVAGENT_JIRA_PROJECT_KEY variable when it is set and non-empty, else
    the source's repo. This is the rule scripts/issue/jira.sh uses when it
    creates an issue. The caller passes its environment in, so nothing is
    read at import time."""
    return env.get("DEVAGENT_JIRA_PROJECT_KEY") or repo


def leaf_for(source: Mapping[str, str], record_id: str) -> str:
    """The leaf id a writer gives a tracker record: the source's dir_prefix
    and the record id. On Jira, a key `<keyprefix>-N` is written as the
    number N alone (the Jira backend's internal id convention, #756).

    The map is not injective across sources: an origin record `F1` under
    `Issue-` and a fork record `1` under `Issue-F` both give `Issue-F1`.
    That is why callers that ask "is this record present" also accept an
    exact leaf match.
    """
    kp = source.get("keyprefix") or ""
    if source["backend"] == "jira" and kp and re.fullmatch(re.escape(kp) + r"-[0-9]+", record_id):
        return f"{source['prefix']}{int(record_id.rsplit('-', 1)[1])}"
    return f"{source['prefix']}{record_id}"


def parse_leaf(
    sources: Sequence[Mapping[str, str]], iid: str
) -> tuple[Mapping[str, str], str] | None:
    """The (source, record id) a leaf id names, or None (#792).

    A dir_prefix is required: a bare number or key names nothing, and a
    source with an empty dir_prefix is never matched. Prefixes are tried
    longest first, and the rest of the id must have the source backend's
    shape: GitHub and GitLab take digits; Jira takes digits N as the key
    `<keyprefix>-N`, or a key verbatim; any other backend takes any rest.
    A rest of the wrong shape falls through to the next shorter prefix, so
    `Issue-FOO-1` passes a GitHub fork `Issue-F` and reaches a Jira origin
    `Issue-`. No prefix left gives None. The source returned is the very
    mapping passed in. Sources with equal prefixes keep their input order,
    so callers list the origin first.
    """
    for src in sorted((s for s in sources if s["prefix"]), key=lambda s: -len(s["prefix"])):
        prefix = src["prefix"]
        if len(iid) <= len(prefix) or not iid.startswith(prefix):
            continue
        rest = iid[len(prefix):]
        backend = src["backend"]
        if backend in ("github", "gitlab"):
            if DIGITS_RE.fullmatch(rest):
                return (src, rest)
        elif backend == "jira":
            if DIGITS_RE.fullmatch(rest):
                return (src, f"{src['keyprefix']}-{rest}")
            if JIRA_KEY_RE.fullmatch(rest):
                return (src, rest)
        else:
            return (src, rest)
    return None


# Step row `- [<glyph>] <num>. <name>`: _checklist_line_re
# (scripts/lib/checklist.sh); the full rule is in wbs-update.sh's header.
ROW_RE = re.compile(r"^- \[(.)\][ \t\n\r\f\v]+([0-9]+)\.[ \t\n\r\f\v]+[A-Za-z][A-Za-z0-9_-]*")
DONE_GLYPHS = {"x", "-"}
PROGRESS_GLYPHS = {"x", "~"}


def checklist_state(devdoc_dir: Path, issue_id: str) -> str | None:
    """Return the glyph an issue's checklist step rows imply.

    `[x]` reads the active revision block only, and an empty one is not
    done (#700). Progress deliberately reads every row in the file: the
    leaf rolls up the whole issue, so a just-started revision stays `[~]`.

    Returns None when the checklist is missing or has no step rows (no
    signal).
    """
    cl = Path(devdoc_dir) / issue_id / "checklist.md"
    if not cl.exists():
        return None
    glyphs = []
    active = []  # rows after the last `## Revision ` heading
    for line in cl.read_text(encoding="utf-8").splitlines():
        if line.startswith("## Revision "):
            active = []
        m = ROW_RE.match(line)
        if m:
            glyphs.append(m.group(1))
            active.append(m.group(1))
    if not glyphs:
        return None
    if active and all(g in DONE_GLYPHS for g in active):
        return "x"
    if any(g in PROGRESS_GLYPHS for g in glyphs):
        return "~"
    return " "


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
