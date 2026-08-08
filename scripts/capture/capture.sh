#!/usr/bin/env bash
# scripts/capture/capture.sh — write a Captures/<slug>/draft.md from a template.
# Invoked by /devagent:capture (script half of capture command).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slug.sh
source "${SCRIPT_DIR}/lib/slug.sh"
# shellcheck source=lib/paths.sh
source "${SCRIPT_DIR}/lib/paths.sh"
# shellcheck source=lib/template.sh
source "${SCRIPT_DIR}/lib/template.sh"

usage() {
  cat <<'USAGE' >&2
Usage: capture.sh --type {issue|epic} [--subtype {bug|feature|docs|perf|chore}]
                  --title <title> [--source <citation>] [--slug-suffix <s>] [--force]

Writes <devdoc>/Captures/<slug>/draft.md from the resolved template.
Prints the slug on stdout.

Env:
  DEVAGENT_DEVDOC_DIR   required
  DEVAGENT_PLUGIN_DIR   required
  DEVAGENT_PROJECT      optional ({{project}} substitution + [project.<name>.paths]
                        template override; reap.sh REQUIRES it)
  DEVAGENT_DATE_OVERRIDE  optional (test-only)
USAGE
}

TYPE=""; SUBTYPE="bug"; TITLE=""; SOURCE=""; FORCE=0; SLUG_SUFFIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) TYPE="${2:?}"; shift 2 ;;
    --subtype) SUBTYPE="${2:?}"; shift 2 ;;
    --title) TITLE="${2:?}"; shift 2 ;;
    --source) SOURCE="${2:?}"; shift 2 ;;
    # #252: optional disambiguator appended past devagent_slug's 60-char cap.
    --slug-suffix) SLUG_SUFFIX="${2:?}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "${TITLE}" ]] || { echo "--title required" >&2; exit 2; }

case "${TYPE}" in
  issue)
    case "${SUBTYPE}" in
      bug|feature|docs|perf|chore) ;;
      *) echo "unknown subtype: ${SUBTYPE}" >&2; exit 2 ;;
    esac
    template_name="issue_template-${SUBTYPE}"
    ;;
  epic)
    template_name="epic_template"
    ;;
  *) echo "--type must be issue|epic" >&2; exit 2 ;;
esac

slug="$(devagent_slug "${TITLE}" "${SLUG_SUFFIX}")"
dir="$(devagent_ensure_capture_dir "${slug}")"
draft="${dir}/draft.md"
if [[ -e "${draft}" && "${FORCE}" -ne 1 ]]; then
  echo "draft already exists: ${draft} (use --force to overwrite)" >&2
  exit 3
fi

template_path="$(devagent_resolve_template "${template_name}")"

python3 - "${template_path}" "${draft}" "${TITLE}" "${DEVAGENT_PROJECT:-}" "${SOURCE:-}" <<'PY'
import sys, pathlib
src, dst, title, project, source = sys.argv[1:6]
text = pathlib.Path(src).read_text()
text = text.replace("{{title}}", title)
text = text.replace("{{project}}", project)
text = text.replace("{{source}}", source if source else "(none)")
pathlib.Path(dst).write_text(text)
PY

printf '%s\n' "${slug}"
