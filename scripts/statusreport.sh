#!/usr/bin/env bash
# /devagent:statusreport — generate per-project status report (spec §14).
#
# Pin (last-report timestamp) lives in the project's state file under
# the `statusreport_last_pin` key. (Pre-refactor versions used a
# separate <project>.statusreport.toml file; that file is no longer
# read or written. Operators with a pre-refactor pin file may delete
# it manually.)
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
# shellcheck source=lib/template_resolve.sh
source "$SCRIPT_DIR/lib/template_resolve.sh"

no_pin=0
window_weeks=4
project_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pin)       no_pin=1; shift ;;
    --window-weeks) window_weeks="${2:?statusreport: --window-weeks needs a value}"; shift 2 ;;
    --*) warn "statusreport: ignoring unknown flag '$1'"; shift ;;
    *)
      if [[ -z "$project_arg" ]]; then
        project_arg="$1"
      else
        warn "statusreport: ignoring extra arg '$1'"
      fi
      shift
      ;;
  esac
done

project="$(active_resolve_project "$project_arg")"
config_is_project "$project" || die "statusreport: unknown project '$project'"
devdoc_dir="$(expand_tilde "$(config_get_project_field "$project" devdoc_dir)")"
[[ -n "$devdoc_dir" ]] || die "statusreport: devdoc_dir not configured for $project"
commit_devdoc="$(config_get_project_field "$project" permissions.commit_devdoc 2>/dev/null || echo false)"

# Resolve the template through the §12 registry (lib/template_resolve.sh) so a
# [project.<name>.paths].statusreport_template override (layer 1) is honored — not
# just devdoc (2) / plugin (3), which the previous hand-rolled loop was limited to.
# Mirrors the #341 wbs-init fix. The `if …; then` captures the rc so `set -e` cannot
# swallow the die on a genuine no-template case (template_resolve returns 1 when no
# layer matches). A configured-but-missing override warns via template_resolve, then
# falls through to the defaults.
template=""
if resolved="$(template_resolve "$project" statusreport_template)"; then
  template="$(printf '%s\n' "$resolved" | sed -n 's/^path=//p')"
fi
[[ -n "$template" ]] || die "no statusreport_template.md found for '$project' (checked project paths, devdoc, plugin)"

# Ensure state file exists so state_get/set work even on first run.
state_init "$project"
prev_pin="$(state_get "$project" statusreport_last_pin 2>/dev/null || true)"
now_iso="$(date -u +'%Y-%m-%dT%H:%M:%S+00:00')"
report_date="$(date -u +'%Y-%m-%d')"
report_dir="$devdoc_dir/StatusReports"
report_path="$report_dir/${report_date}.md"
mkdir -p "$report_dir"

parser="$PLUGIN_ROOT/scripts/lib/wbs-parser.py"
detect="$PLUGIN_ROOT/scripts/lib/statusreport-detect.py"
velocity_lib="$PLUGIN_ROOT/scripts/lib/statusreport-velocity.py"

DEVDOC_DIR="$devdoc_dir" \
PROJECT="$project" \
TEMPLATE_PATH="$template" \
PREV_PIN="$prev_pin" \
NOW_ISO="$now_iso" \
WINDOW_WEEKS="$window_weeks" \
PARSER_PATH="$parser" \
DETECT_PATH="$detect" \
VELOCITY_PATH="$velocity_lib" \
python3 <<'PY' > "$report_path"
import importlib.util
import os
import re
from datetime import datetime
from pathlib import Path


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


wbs_parser = load("wbs_parser", os.environ["PARSER_PATH"])
detect = load("sr_detect", os.environ["DETECT_PATH"])
velocity = load("sr_vel", os.environ["VELOCITY_PATH"])

devdoc = Path(os.environ["DEVDOC_DIR"])
project = os.environ["PROJECT"]
template = Path(os.environ["TEMPLATE_PATH"]).read_text(encoding="utf-8")
prev_pin = os.environ["PREV_PIN"]
now_iso = os.environ["NOW_ISO"]
window_weeks = int(os.environ["WINDOW_WEEKS"])

issue_re = re.compile(r"^Issue(-Fork)?-\d+$")
issue_dirs = sorted(
    d for d in devdoc.iterdir() if d.is_dir() and issue_re.match(d.name)
)

stuck, failed_rt, idle_list, poorly, completed = [], [], [], [], []
inline_arts = []
rejects = []           # #438: per-issue dispatch-lint reject counts
completion_ts = []
for d in issue_dirs:
    entries = detect._parse_log_entries(d / "checklist.md")
    if not entries:
        continue
    last_step = 23 if any(e["step"] == "cleanup" for e in entries) else 7

    # #438: aggregate dispatch-lint rejects archived under analysis/rejected/
    # (#360). Zero-reject issues are omitted entirely — no added noise.
    _nrej = len(list((d / "analysis" / "rejected").glob("*.md")))
    if _nrej:
        rejects.append(f"{d.name} ({_nrej})")

    if detect.is_stuck(d):
        stuck.append(d.name)
    if detect.failed_redteam(d):
        failed_rt.append(d.name)
    if detect.poorly_scoped(d):
        poorly.append(d.name)
    if detect.is_idle(d, last_step=last_step):
        idle_list.append(d.name)
    if detect.is_completed(d):
        completed.append(d.name)
        ts = detect.completion_timestamp(d)
        if ts:
            completion_ts.append(ts)
    ia = detect.inline_artifacts(d)
    if ia:
        inline_arts.append(f"{d.name}: " + ", ".join(ia))

wbs_path = devdoc / "WBS.md"
remaining_leaves = 0
wbs_rollup = "(no WBS.md found — run /devagent:wbs init)"
if wbs_path.exists():
    tree = wbs_parser.parse_file(wbs_path)
    leaves = wbs_parser.leaves(tree)
    remaining_leaves = sum(
        1 for leaf in leaves if leaf["state"] not in ("done", "skipped")
    )
    wbs_rollup = "\n".join(
        f"- {n['text']} ({n.get('meta', {}).get('milestone', 'no milestone')})"
        for n in tree["children"]
    )

now_dt = datetime.fromisoformat(now_iso)
v = velocity.velocity_per_week(
    completion_ts, window_weeks=window_weeks, now=now_dt
)
pwc = velocity.per_week_counts(
    completion_ts, window_weeks=window_weeks, now=now_dt
)
est = velocity.estimate_completion(remaining_leaves, v, now=now_dt)
band = velocity.estimate_band_weeks(pwc)

if est is None:
    est_str = "n/a (no completions in window)"
    band_str = "—"
else:
    est_str = est.date().isoformat()
    band_str = f"{band:.1f}"


def render_list(items, prefix="- "):
    return "\n".join(f"{prefix}{x}" for x in items) if items else "_(none)_"


def pin_span(prev, now):
    if not prev:
        return "first report (no prior pin)"
    try:
        p = datetime.fromisoformat(prev)
        n = datetime.fromisoformat(now)
        d = n - p
        days, rem = divmod(int(d.total_seconds()), 86400)
        hours = rem // 3600
        return f"{days}d {hours}h"
    except Exception:
        return "(unparseable pin)"


filled = (
    template
    .replace("{{PROJECT}}", project)
    .replace("{{PIN_FROM}}", prev_pin or "(none)")
    .replace("{{PIN_TO}}", now_iso)
    .replace("{{PIN_FROM_DATE}}", (prev_pin or "")[:10] or "—")
    .replace("{{PIN_TO_DATE}}", now_iso[:10])
    .replace("{{PIN_SPAN}}", pin_span(prev_pin, now_iso))
    .replace("{{ACCOMPLISHED_LIST}}", render_list(completed))
    .replace("{{STUCK_COUNT}}", str(len(stuck)))
    .replace("{{STUCK_LIST}}", render_list(stuck))
    .replace("{{FAILED_REDTEAM_COUNT}}", str(len(failed_rt)))
    .replace("{{FAILED_REDTEAM_LIST}}", render_list(failed_rt))
    .replace("{{IDLE_COUNT}}", str(len(idle_list)))
    .replace("{{IDLE_LIST}}", render_list(idle_list))
    .replace("{{POORLY_SCOPED_COUNT}}", str(len(poorly)))
    .replace("{{POORLY_SCOPED_LIST}}", render_list(poorly))
    .replace("{{INLINE_ARTIFACTS_COUNT}}", str(len(inline_arts)))
    .replace("{{INLINE_ARTIFACTS_LIST}}", render_list(inline_arts))
    .replace("{{DISPATCH_REJECTS_COUNT}}", str(len(rejects)))
    .replace("{{DISPATCH_REJECTS_LIST}}", render_list(rejects))
    .replace("{{WBS_ROLLUP}}", wbs_rollup)
    .replace("{{VELOCITY_WINDOW_WEEKS}}", str(window_weeks))
    .replace("{{VELOCITY_PER_WEEK}}", f"{v:.1f}")
    .replace("{{MEDIAN_DAYS}}", "n/a")
    .replace("{{REMAINING_LEAVES}}", str(remaining_leaves))
    .replace("{{ESTIMATED_COMPLETION}}", est_str)
    .replace("{{ESTIMATE_BAND_WEEKS}}", band_str)
)
print(filled, end="")
PY

if [[ $no_pin -eq 0 ]]; then
  state_set_many "$project" str statusreport_last_pin "$now_iso" str statusreport_last_pin_by "${USER:-unknown}"
fi

if [[ "$commit_devdoc" == "true" ]]; then
  if command -v git >/dev/null && git -C "$devdoc_dir" rev-parse >/dev/null 2>&1; then
    git -C "$devdoc_dir" add "StatusReports/${report_date}.md" || true
    git -C "$devdoc_dir" commit -s -m "statusreport(${project}): ${report_date}" || true
  else
    warn "statusreport: commit requested but devdoc is not a git repo"
  fi
fi

echo "Status Report — $project — $report_date"
echo "  Written to: $report_path"
echo "  Pin: ${prev_pin:-(none)} → ${now_iso}"
