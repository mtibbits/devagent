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
# #597: --body-file's H1 gate and --on-collision's #252 content hash.
# shellcheck source=lib/draft.sh
source "${SCRIPT_DIR}/lib/draft.sh"
# shellcheck source=lib/hash.sh
source "${SCRIPT_DIR}/lib/hash.sh"

usage() {
  cat <<'USAGE' >&2
Usage: capture.sh --type {issue|epic} [--subtype {bug|feature|docs|perf|chore}]
                  --title <title> [--source <citation>] [--slug-suffix <s>]
                  [--body-file <path>] [--on-collision {fail|suffix}] [--force]

Writes <devdoc>/Captures/<slug>/draft.md from the resolved template — or, with
--body-file, that file's bytes verbatim. Prints the FINAL slug on stdout.

--body-file <path>      write <path> as draft.md instead of rendering the
                        template. Its H1 (the first "# " line, read exactly as
                        file.sh reads it) MUST be "<title>" for --type issue
                        and "Epic: <title>" for --type epic, else exit 5.
                        --source is ignored (the body is written verbatim).
--on-collision fail     default: exit 3 when the slug's draft already exists.
--on-collision suffix   on collision, retry ONCE at a slug carrying the #252
                        content-derived suffix (first six hex of the body's
                        content hash, the form reap.sh uses). A
                        content-identical (whitespace/case-insensitive) re-run
                        prints the existing slug and writes nothing. Requires
                        --body-file; cannot be combined with --slug-suffix.

Exit: 0 ok | 2 usage | 3 draft exists (collision unresolved) | 5 body H1 does
not match --title

Env:
  DEVAGENT_DEVDOC_DIR   required
  DEVAGENT_PLUGIN_DIR   required
  DEVAGENT_PROJECT      optional ({{project}} substitution + [project.<name>.paths]
                        template override; reap.sh REQUIRES it)
  DEVAGENT_DATE_OVERRIDE  optional (test-only)
USAGE
}

TYPE=""; SUBTYPE="bug"; TITLE=""; SOURCE=""; FORCE=0; SLUG_SUFFIX=""
BODY_FILE=""; ON_COLLISION="fail"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) TYPE="${2:?}"; shift 2 ;;
    --subtype) SUBTYPE="${2:?}"; shift 2 ;;
    --title) TITLE="${2:?}"; shift 2 ;;
    --source) SOURCE="${2:?}"; shift 2 ;;
    # #252: optional disambiguator appended past devagent_slug's 60-char cap.
    --slug-suffix) SLUG_SUFFIX="${2:?}"; shift 2 ;;
    # #597: write this file's bytes as draft.md instead of the template.
    --body-file) BODY_FILE="${2:?}"; shift 2 ;;
    # #597: fail (default, exit 3) | suffix (#252 content-derived retry).
    --on-collision) ON_COLLISION="${2:?}"; shift 2 ;;
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

case "${ON_COLLISION}" in
  fail|suffix) ;;
  *) echo "--on-collision must be fail|suffix (got: ${ON_COLLISION})" >&2; exit 2 ;;
esac
if [[ "${ON_COLLISION}" == "suffix" ]]; then
  if [[ -z "${BODY_FILE}" ]]; then
    echo "--on-collision suffix requires --body-file (the suffix is the body's content hash)" >&2
    exit 2
  fi
  if [[ -n "${SLUG_SUFFIX}" ]]; then
    echo "--slug-suffix and --on-collision suffix are mutually exclusive (both set the slug suffix)" >&2
    exit 2
  fi
fi

if [[ -n "${BODY_FILE}" ]]; then
  [[ -f "${BODY_FILE}" ]] || { echo "--body-file not found: ${BODY_FILE}" >&2; exit 2; }
  [[ -r "${BODY_FILE}" ]] || { echo "--body-file not readable: ${BODY_FILE}" >&2; exit 2; }
  [[ -z "${SOURCE}" ]] || echo "warn: --source is ignored with --body-file" >&2
  expected_h1="${TITLE}"
  if [[ "${TYPE}" == "epic" ]]; then
    expected_h1="Epic: ${TITLE}"       # the epic template's own H1 convention (A2)
  fi
  # The SAME function file.sh files the title with. `if ! v="$(...)"` captures
  # the rc: a bare assignment is silent under set -e (register: Issue-589).
  if ! body_h1="$(devagent_draft_h1 "${BODY_FILE}")"; then
    echo "could not read ${BODY_FILE}" >&2; exit 2
  fi
  if [[ -z "${body_h1}" ]]; then
    { echo "body has no '# ' H1 heading: ${BODY_FILE}"
      echo "  expected: # ${expected_h1}"; } >&2
    exit 5
  fi
  if [[ "${body_h1}" != "${expected_h1}" ]]; then
    { echo "body H1 does not match --title (file.sh would file a title the slug disagrees with)"
      if [[ "${body_h1}" == *$'\r' ]]; then echo "  note: the body has CRLF line endings"; fi
      echo "  H1:       ${body_h1}"
      echo "  expected: ${expected_h1}"; } >&2
    exit 5
  fi
fi

slug="$(devagent_slug "${TITLE}" "${SLUG_SUFFIX}")"
dir="$(devagent_ensure_capture_dir "${slug}")"
draft="${dir}/draft.md"
if [[ -e "${draft}" && "${FORCE}" -ne 1 ]]; then
  echo "draft already exists: ${draft} (use --force to overwrite)" >&2
  exit 3
fi

if [[ -n "${BODY_FILE}" ]]; then
  if [[ "${BODY_FILE}" -ef "${draft}" ]]; then
    echo "--body-file is the destination draft: ${draft}" >&2; exit 2
  fi
  cat "${BODY_FILE}" >"${draft}"
else
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
fi

printf '%s\n' "${slug}"
