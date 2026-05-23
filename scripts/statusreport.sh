#!/usr/bin/env bash
# /devagent:statusreport — generate per-project status report (spec §14).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="${DEVAGENT_STUB_LIB:-$SCRIPT_DIR/lib}"

# shellcheck source=/dev/null
source "$LIB_DIR/log.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/config-loader.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/state.sh"
devagent_load_config

no_pin=0
window_weeks=4
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pin)       no_pin=1; shift ;;
    --window-weeks) window_weeks="$2"; shift 2 ;;
    *)              devagent_log warn "statusreport: ignoring '$1'"; shift ;;
  esac
done

template=""
for cand in \
  "$DEVAGENT_DEVDOC_DIR/templates/statusreport_template.md" \
  "$PLUGIN_ROOT/templates/statusreport_template.md"; do
  [[ -f "$cand" ]] && { template="$cand"; break; }
done
[[ -n "$template" ]] || { devagent_log err "no statusreport_template.md found"; exit 1; }

pin_file="$DEVAGENT_STATE_DIR/${DEVAGENT_PROJECT}.statusreport.toml"
prev_pin="$(state_get "$pin_file" last_pin || true)"
now_iso="$(date -u +'%Y-%m-%dT%H:%M:%S+00:00')"
report_date="$(date -u +'%Y-%m-%d')"
report_dir="$DEVAGENT_DEVDOC_DIR/StatusReports"
report_path="$report_dir/${report_date}.md"
mkdir -p "$report_dir"

parser="$PLUGIN_ROOT/scripts/lib/wbs-parser.py"
detect="$PLUGIN_ROOT/scripts/lib/statusreport-detect.py"
velocity_lib="$PLUGIN_ROOT/scripts/lib/statusreport-velocity.py"

DEVAGENT_DEVDOC_DIR="$DEVAGENT_DEVDOC_DIR" \
DEVAGENT_PROJECT="$DEVAGENT_PROJECT" \
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

devdoc = Path(os.environ["DEVAGENT_DEVDOC_DIR"])
project = os.environ["DEVAGENT_PROJECT"]
template = Path(os.environ["TEMPLATE_PATH"]).read_text(encoding="utf-8")
prev_pin = os.environ["PREV_PIN"]
now_iso = os.environ["NOW_ISO"]
window_weeks = int(os.environ["WINDOW_WEEKS"])

issue_re = re.compile(r"^Issue(-Fork)?-\d+$")
issue_dirs = sorted(
    d for d in devdoc.iterdir() if d.is_dir() and issue_re.match(d.name)
)

stuck, failed_rt, idle_list, poorly, completed = [], [], [], [], []
completion_ts = []
for d in issue_dirs:
    entries = detect._parse_log_entries(d / "checklist.md")
    if not entries:
        continue
    last_step = 20 if any(e["step"] == "cleanup" for e in entries) else 7

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
  state_set "$pin_file" last_pin "$now_iso"
  state_set "$pin_file" last_pin_by "${USER:-unknown}"
fi

if [[ "$DEVAGENT_PERM_COMMIT_DEVDOC" == "true" ]]; then
  if command -v git >/dev/null && git -C "$DEVAGENT_DEVDOC_DIR" rev-parse >/dev/null 2>&1; then
    git -C "$DEVAGENT_DEVDOC_DIR" add "StatusReports/${report_date}.md" || true
    git -C "$DEVAGENT_DEVDOC_DIR" commit -s -m "statusreport(${DEVAGENT_PROJECT}): ${report_date}" || true
  else
    devagent_log warn "statusreport: commit requested but devdoc is not a git repo"
  fi
fi

echo "Status Report — $DEVAGENT_PROJECT — $report_date"
echo "  Written to: $report_path"
echo "  Pin: ${prev_pin:-(none)} → ${now_iso}"
