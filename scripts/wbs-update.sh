#!/usr/bin/env bash
# wbs-update: reconcile WBS leaf glyphs against the issue tracker, then
# against issue checklist truth (#703).
#
# For every leaf in <devdoc>/WBS.md that carries `{issue: <id>}` meta, the
# glyph comes from the shared tracker's issue state first and from
# <devdoc>/<id>/checklist.md only where the tracker gives no signal.
#
# Tracker sources. A source is configured when its `backend`, `repo` and
# `dir_prefix` are all set: `issue_source_fork` and `issue_source`. A leaf
# belongs to the source whose dir_prefix its id carries (the longest match
# wins: `Issue-Fork-` before `Issue-`); the rest of the id is looked up (GitHub/GitLab: digits; JIRA:
# digits N read as key `<pk>-N`, pk = DEVAGENT_JIRA_PROJECT_KEY else the
# repo, or a key verbatim). An id that fits no configured source is no
# signal. Each source's backend
# (${DEVAGENT_ISSUE_BACKEND_DIR:-scripts/issue}/<backend>.sh) is asked once
# per run, `state-list <repo>` (spec §9.1), for every issue's class. Cost:
# one call per source per run, ceil(N/100) list pages (GitHub: one
# `gh issue list`); a rate limit fails the call like any other error.
#
# Precedence (scripts/lib/wbs-tracker.py `resolve`, used by reconcile and
# auto-add alike):
#   tracker done          -> `[x]`
#   tracker not_planned   -> `[-]`
#   tracker in_progress   -> `[~]`, but a hand-set `[P]` `[!]` `[?]` is kept
#   tracker open          -> the checklist rule below, except that an
#                            all-done checklist gives `[~]`; with no
#                            checklist signal, a leaf whose status_src is
#                            `tracker` (closed, then reopened) gives `[~]`
#                            unless its glyph is a hand-set `[P]` `[!]` `[?]`
#   tracker other, or no lookup for the source, or no source configured
#                         -> the checklist rule below
#   id not in the list    -> unchanged, reported once
#                            (`<id> not found on <backend> <repo>`)
#
# Checklist rule:
#   - the ACTIVE revision has step rows, all `[x]` or `[-]` -> `[x]` (done)
#   - else any step row anywhere `[x]` or `[~]`             -> `[~]` (in progress)
#   - else (step rows, no progress)                         -> `[ ]` (pending)
#   - no checklist, or no step rows                         -> unchanged (no signal)
#
# `[x]` is checklist_current_step's `done` (scripts/lib/checklist.sh, the #74
# rule): the active revision is the rows after the LAST `## Revision` heading,
# or the whole file when there is none, and rows are matched as
# `_checklist_line_re` matches them. A row that only an earlier revision
# carries never blocks `[x]` (#700). The `Active revision:` header line is
# not read; revise.sh never updates it.
#
# One deliberate difference (#700): a final row with no trailing newline is
# counted here, while checklist_current_step's `read` loop drops it. Python's
# line split also breaks on a few control characters bash does not, and the
# whitespace between glyph, number and name is ASCII-only here where bash's
# [[:space:]] also takes Unicode spaces; no checklist carries either.
#
# No signal leaves the leaf's glyph as it is, including a hand-set one,
# because a devbox usually lacks most issues' checklists (#702).
#
# Provenance: whenever a leaf's glyph is resolved, its `status_src` meta is
# set to `tracker` or `checklist`, even when the glyph is unchanged; no
# signal leaves the meta untouched.
#
# Lookup failure never fails the run. A backend that exits 78 (not
# implemented) or 2 (unknown verb), has no script, or whose CLI is not on
# PATH is "no lookup": its leaves use local checklists, noted once per
# source. Any other non-zero exit, or output outside the grammar, aborts the
# tracker phase for the whole run: no leaf is reconciled, one WARNING names
# `--offline`, and the exit status is 0.
#
# Plus: if the project's active_issue is set and is not yet present in
# the WBS, append it under a synthetic "Unassigned" top-level node so
# newly-pulled issues auto-appear. Its glyph goes through the same
# precedence (local checklist only when the tracker phase aborted); with no
# signal it is written as `[ ]` with no status_src.
#
# Reconciliation derives from the tracker and the checklist (the
# authoritative sources), not from state.last_step. Safe to run any time,
# idempotent.
#
# The write is line-local (#701). Unchanged lines (prose, headings,
# comments, fenced blocks), meta formatting, line endings and the
# final-newline state are kept byte for byte. Only a changed glyph
# character and the `status_src` value are rewritten, new nodes are
# inserted as whole lines, and the file is not rewritten when nothing
# changed.
#
# Flags:
#   --if-exists   exit 0 silently when <devdoc>/WBS.md does not exist
#                 (used by cleanup.sh and other auto-call sites)
#   --offline     no tracker lookup; reconcile from local checklists only.
#                 DEVAGENT_WBS_OFFLINE=1 does the same (cleanup.sh's call
#                 cannot take a flag).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/paths.sh
source "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/io.sh
source "$SCRIPT_DIR/lib/io.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/active.sh
source "$SCRIPT_DIR/lib/active.sh"

if_exists=0
offline=0
[[ "${DEVAGENT_WBS_OFFLINE:-}" == 1 ]] && offline=1
project_arg=""
for arg in "$@"; do
  case "$arg" in
    --if-exists) if_exists=1 ;;
    --offline) offline=1 ;;
    --*) warn "wbs update: ignoring unknown flag '$arg'" ;;
    *)
      if [[ -z "$project_arg" ]]; then
        project_arg="$arg"
      else
        warn "wbs update: ignoring extra arg '$arg'"
      fi
      ;;
  esac
done

active_resolve_project_try "$project_arg"
project="$ACTIVE_RESOLVED_PROJECT"
config_is_project "$project" || die "wbs update: unknown project '$project'"
active_guard_scope "wbs update"
devdoc_dir="$(expand_tilde "$(config_get_project_field "$project" devdoc_dir)")"
[[ -n "$devdoc_dir" ]] || die "wbs update: devdoc_dir not configured for $project"

wbs="$devdoc_dir/WBS.md"
if [[ ! -f "$wbs" ]]; then
  if (( if_exists == 1 )); then
    exit 0
  fi
  die "wbs update: $wbs missing; run /devagent:wbs init first"
fi

parser="$PLUGIN_ROOT/scripts/lib/wbs-parser.py"
[[ -f "$parser" ]] || die "wbs-parser.py not found at $parser"
tracker_lib="$PLUGIN_ROOT/scripts/lib/wbs-tracker.py"
[[ -f "$tracker_lib" ]] || die "wbs-tracker.py not found at $tracker_lib"

active_issue="$(active_resolve_issue "$project" 2>/dev/null || true)"
if [[ "$active_issue" == "null" || "$active_issue" == '""' ]]; then
  active_issue=""
fi

# --- tracker fetch (#703) ----------------------------------------------------
# Runs only past the scope guard, the --if-exists exit and the parser check.
# Each source hands the Python reconcile WBS_TRK_<S>_* (S = ORIGIN | FORK):
# STATUS off|nolookup|ok|failed, PREFIX, BACKEND, REPO, KEYPREFIX (jira),
# FILE (state-list stdout) and DETAIL (why nolookup / failed).
backend_dir="${DEVAGENT_ISSUE_BACKEND_DIR:-$PLUGIN_ROOT/scripts/issue}"
trk_tmp="$(mktemp -d)"
trap 'rm -rf "$trk_tmp"' EXIT
trk_env=()

_trk_fetch() {
  local S="$1" table="$2"
  local backend repo prefix status=off file="" detail="" keyprefix="" sh cli rc err
  (( offline == 0 )) || return 0  # no WBS_TRK_<S>_* vars: the source is off
  backend="$(config_get_project_field "$project" "$table.backend" 2>/dev/null || true)"
  repo="$(config_get_project_field "$project" "$table.repo" 2>/dev/null || true)"
  prefix="$(config_get_project_field "$project" "$table.dir_prefix" 2>/dev/null || true)"
  if [[ -n "$backend" && -n "$repo" && -n "$prefix" ]]; then
    [[ "$backend" == jira ]] && keyprefix="${DEVAGENT_JIRA_PROJECT_KEY:-$repo}"
    sh="$backend_dir/$backend.sh"
    case "$backend" in
      github) cli=gh ;;
      gitlab|jira) cli=curl ;;  # both state-list paths are REST via curl
      *) cli="" ;;
    esac
    if [[ ! -f "$sh" || ! -x "$sh" ]]; then
      status=nolookup detail="no script"
    elif [[ -n "$cli" ]] && ! command -v "$cli" >/dev/null 2>&1; then
      status=nolookup detail="$cli not on PATH"
    else
      file="$trk_tmp/$S.out" err="$trk_tmp/$S.err"
      if DEVAGENT_PROJECT="$project" "$sh" state-list "$repo" >"$file" 2>"$err"; then
        rc=0
      else
        rc=$?
      fi
      case "$rc" in
        0) status=ok ;;
        2|78) status=nolookup detail="exit $rc" ;;
        *)
          status=failed
          detail="exit $rc: $(grep -v '^[[:space:]]*$' "$err" | tail -n 1 | tr -d '\r' || true)"
          ;;
      esac
    fi
  fi
  trk_env+=("WBS_TRK_${S}_STATUS=$status" "WBS_TRK_${S}_PREFIX=$prefix"
            "WBS_TRK_${S}_BACKEND=$backend" "WBS_TRK_${S}_REPO=$repo"
            "WBS_TRK_${S}_KEYPREFIX=$keyprefix" "WBS_TRK_${S}_FILE=$file"
            "WBS_TRK_${S}_DETAIL=$detail")
}

_trk_fetch ORIGIN issue_source
_trk_fetch FORK issue_source_fork

env ${trk_env[@]+"${trk_env[@]}"} \
WBS_PATH="$wbs" \
PARSER_PATH="$parser" \
WBS_TRACKER_LIB="$tracker_lib" \
DEVDOC_DIR="$devdoc_dir" \
ACTIVE_ISSUE="$active_issue" \
python3 <<'PY'
import importlib.util
import os
import re
import sys
from pathlib import Path

wbs_path     = os.environ["WBS_PATH"]
parser_path  = os.environ["PARSER_PATH"]
devdoc_dir   = Path(os.environ["DEVDOC_DIR"])
active_issue = os.environ.get("ACTIVE_ISSUE", "") or ""


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mod = _load("wbs_parser", parser_path)
trk = _load("wbs_tracker", os.environ["WBS_TRACKER_LIB"])

tree = mod.parse_file(wbs_path)


def say(msg: str) -> None:
    # ASCII only: a cp1252 stderr must not crash the write.
    print(msg.encode("ascii", "replace").decode("ascii"), file=sys.stderr)


# Step row `- [<glyph>] <num>. <name>`: _checklist_line_re (see header).
ROW_RE = re.compile(r"^- \[(.)\][ \t\n\r\f\v]+([0-9]+)\.[ \t\n\r\f\v]+[A-Za-z][A-Za-z0-9_-]*")
DONE_GLYPHS = {"x", "-"}
PROGRESS_GLYPHS = {"x", "~"}


def checklist_state(issue_id: str) -> "str | None":
    """Return the glyph an issue's checklist step rows imply.

    `[x]` reads the active revision block only, and an empty one is not
    done (#700). Progress deliberately reads every row in the file: the
    leaf rolls up the whole issue, so a just-started revision stays `[~]`.

    Returns None when the checklist is missing or has no step rows (no
    signal).
    """
    cl = devdoc_dir / issue_id / "checklist.md"
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


# --- tracker sources ---------------------------------------------------------
sources = []
for S in ("FORK", "ORIGIN"):
    env = {k: os.environ.get(f"WBS_TRK_{S}_{k}", "") for k in
           ("STATUS", "PREFIX", "BACKEND", "REPO", "KEYPREFIX", "FILE", "DETAIL")}
    if env["STATUS"] in ("", "off"):
        continue
    sources.append(env)
# Longest dir_prefix first: "Issue-" is a prefix of "Issue-Fork-".
sources.sort(key=lambda src: len(src["PREFIX"]), reverse=True)

aborted = None  # (source, detail) of the first failed source
for src in sources:
    if src["STATUS"] == "nolookup":
        say(f"wbs update: {src['BACKEND']} has no state-list ({src['DETAIL']}); "
            f"{src['PREFIX']} leaves use local checklists")
for src in sources:
    if src["STATUS"] == "failed":
        aborted = aborted or (src, src["DETAIL"])
    elif src["STATUS"] == "ok":
        try:
            text = Path(src["FILE"]).read_bytes().decode("utf-8", "replace")
            src["classes"] = trk.parse_state_list(text)
        except ValueError as e:
            aborted = aborted or (src, str(e))
if aborted:
    src, detail = aborted
    say(f"wbs update: WARNING: tracker lookup failed for {src['BACKEND']} {src['REPO']} "
        f"({detail}); no glyph changed. Run 'wbs update --offline' (or set "
        f"DEVAGENT_WBS_OFFLINE=1) to reconcile from local checklists only.")

DIGITS = re.compile(r"^[0-9]+$")
JIRA_KEY = re.compile(r"^[A-Z][A-Z0-9_]*-[0-9]+$")


def leaf_class(iid: str) -> str:
    """The tracker class for a leaf id, or none / missing / unmatched."""
    if not sources:
        return "none"  # no tracker configured: the checklist rule
    for src in sources:
        prefix = src["PREFIX"]
        if not iid.startswith(prefix) or len(iid) == len(prefix):
            continue
        rest = iid[len(prefix):]
        backend = src["BACKEND"]
        if backend == "jira":
            if DIGITS.match(rest):
                key = f"{src['KEYPREFIX']}-{rest}"
            elif JIRA_KEY.match(rest):
                key = rest
            else:
                return "unmatched"
        elif backend in ("github", "gitlab"):
            if not DIGITS.match(rest):
                return "unmatched"
            key = rest
        else:
            key = rest
        if src["STATUS"] != "ok":
            return "none"  # no lookup for this source
        cls = src["classes"].get(key)
        if cls is None:
            say(f"wbs update: {iid} not found on {backend} {src['REPO']}; glyph unchanged")
            return "missing"
        return cls
    return "unmatched"


def resolve_leaf(iid: str, cls: str, glyph: str, cur_src):
    """trk.resolve for a leaf; the checklist is read only where it counts."""
    local = checklist_state(iid) if cls in ("open", "other", "none") else None
    return trk.resolve(glyph, cls, local, cur_src)


def visit(node, fn):
    fn(node)
    for child in node.get("children", []):
        visit(child, fn)


def reconcile(node):
    if node.get("children"):
        return  # not a leaf; parent glyphs aren't tracker/checklist-derived
    meta = node.get("meta", {})
    iid = meta.get("issue")
    if not iid:
        return
    got = resolve_leaf(iid, leaf_class(iid), node["glyph"], meta.get("status_src"))
    if got is None:
        return  # no signal: leave glyph and meta as set (#702)
    node["glyph"], meta["status_src"] = got
    node["state"] = mod.STATE_GLYPHS.get(node["glyph"], "pending")


if not aborted:
    for top in tree["children"]:
        visit(top, reconcile)


# Auto-add active_issue under "Unassigned" if not already in WBS anywhere.
def find_issue_node(node, issue):
    if node.get("meta", {}).get("issue") == issue:
        return node
    for k in node.get("children", []):
        r = find_issue_node(k, issue)
        if r is not None:
            return r
    return None


if active_issue:
    found = None
    for top in tree["children"]:
        found = find_issue_node(top, active_issue)
        if found is not None:
            break
    if found is None:
        unassigned = next(
            (n for n in tree["children"] if n["text"] == "Unassigned"),
            None,
        )
        if unassigned is None:
            unassigned = {
                "text": "Unassigned",
                "state": "pending",
                "glyph": " ",
                "depth": 1,
                "meta": {},
                "meta_unknown_keys": [],
                "children": [],
                "source_line": 0,
            }
            tree["children"].append(unassigned)
        cls = "none" if aborted else leaf_class(active_issue)
        got = resolve_leaf(active_issue, cls, " ", None)
        meta = {"issue": active_issue, "est": "?w"}
        if got is None:
            # A new leaf has no prior glyph to keep, so no signal means
            # pending (render would also fall back to `[ ]`).
            new_glyph = " "
        else:
            new_glyph, meta["status_src"] = got
        unassigned["children"].append({
            "text": active_issue,
            "state": mod.STATE_GLYPHS.get(new_glyph, "pending"),
            "glyph": new_glyph,
            "depth": 2,
            "meta": meta,
            "meta_unknown_keys": [],
            "children": [],
            "source_line": 0,
        })

mod.write_markdown(wbs_path, tree)
PY

info "wbs update: reconciled $wbs against the tracker and issue checklists"
