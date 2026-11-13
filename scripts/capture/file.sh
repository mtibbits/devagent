#!/usr/bin/env bash
# scripts/capture/file.sh — file a capture draft as a tracker issue.
# Honors the push_mr permission gate (spec §8).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
source "${SCRIPT_DIR}/lib/paths.sh"
# shellcheck source=lib/draft.sh
source "${SCRIPT_DIR}/lib/draft.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/trust.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/permission.sh"

usage() {
  cat <<'USAGE' >&2
Usage: file.sh --slug <slug> --target {origin|fork} [--yes] [--refile]

Reads <devdoc>/Captures/<slug>/draft.md, calls
$DEVAGENT_ISSUE_BACKEND_DIR/<backend>.sh create <repo> <title> <body-file>,
writes returned issue number + URL to filed.toml.

Permission gate: DEVAGENT_PERMISSION_PUSH_MR=true|false
  false (default) → must pass --yes to proceed

Env:
  DEVAGENT_DEVDOC_DIR            required
  DEVAGENT_ISSUE_BACKEND         optional; unset → from the config of the project
                                 that owns DEVAGENT_DEVDOC_DIR, else github
  DEVAGENT_ISSUE_BACKEND_DIR     path to issue/ backends (required unless the
                                 backend came from config: then this plugin's)
  DEVAGENT_REPO_ORIGIN           for --target origin (unset → from that config)
  DEVAGENT_REPO_FORK             for --target fork (unset → from that config)
  DEVAGENT_PERMISSION_PUSH_MR    true|false (default false; a disk target asks none)
USAGE
}

SLUG=""; TARGET=""; YES=0; REFILE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug) SLUG="${2:?}"; shift 2 ;;
    --target) TARGET="${2:?}"; shift 2 ;;
    --yes) YES=1; shift ;;
    --refile) REFILE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "${SLUG}" ]] || { echo "--slug required" >&2; exit 2; }
case "${TARGET}" in origin|fork) ;; *) echo "--target must be origin|fork" >&2; exit 2 ;; esac

cap_dir="$(devagent_capture_dir "${SLUG}")"
draft="${cap_dir}/draft.md"
filed="${cap_dir}/filed.toml"

pending="${cap_dir}/.pending"

[[ -f "${draft}" ]] || { echo "missing draft.md at ${draft}" >&2; exit 3; }
if [[ -e "${filed}" && "${REFILE}" -ne 1 ]]; then
  echo "already filed: ${filed} (use --refile to re-file)" >&2
  exit 3
fi
# #113: a .pending marker with no filed.toml means a prior run died between the
# remote create and the filed.toml write — the remote issue may already exist.
# Refuse rather than file a duplicate.
if [[ -e "${pending}" && ! -e "${filed}" && "${REFILE}" -ne 1 ]]; then
  cat >&2 <<EOF
A previous filing left a pending marker but no filed.toml:
  ${pending}
The remote issue may already exist. Verify the tracker, then re-run with
--refile (or remove the marker) to proceed.
EOF
  exit 3
fi
# #713: pinned before the check, so its whoami runs through the backend dir
# the filing uses.
trust_locate_host || true   # a defect refuses inside the check
[[ "${TRUST_HOST}" != 1 ]] || DEVAGENT_ISSUE_BACKEND_DIR="$(plugin_root)/scripts/issue"
trust_entry_check_devdoc "capture/file" "${DEVAGENT_DEVDOC_DIR:-}"

# #713: with a trust policy on the host, the backend and repos come from the
# config of the project that owns DEVAGENT_DEVDOC_DIR — the one the scope was
# decided for — whether or not it is in scope; the DEVAGENT_ISSUE_BACKEND* /
# DEVAGENT_REPO_* env is overwritten, never read (an unscoped devdoc must not
# file onto a scoped repo). In scope the policy also decides the gate: its
# `file` gate replaces push_mr (DEVAGENT_PERMISSION_PUSH_MR is ignored) and
# --yes is refused.
gate_name=push_mr
if [[ "${TRUST_HOST:-0}" == 1 ]]; then
  _section=issue_source
  [[ "${TARGET}" == fork ]] && _section=issue_source_fork
  DEVAGENT_ISSUE_BACKEND="$(config_get_project_field "${TRUST_PROJECT}" "${_section}.backend" 2>/dev/null || true)"
  DEVAGENT_REPO_ORIGIN="$(config_get_project_field "${TRUST_PROJECT}" issue_source.repo 2>/dev/null || true)"
  DEVAGENT_REPO_FORK="$(config_get_project_field "${TRUST_PROJECT}" issue_source_fork.repo 2>/dev/null || true)"
  [[ -n "${DEVAGENT_ISSUE_BACKEND}" ]] || { echo "${_section}.backend not configured for ${TRUST_PROJECT}" >&2; exit 2; }
fi
# #1009: with no policy and no DEVAGENT_ISSUE_BACKEND handed in, the project
# that owns DEVAGENT_DEVDOC_DIR names the backend, and fills in each repo and
# the backend dir (this plugin's) that the env leaves unset: an exported value
# still wins. Its push_mr gate is still the env's.
if [[ "${TRUST_HOST:-0}" != 1 && -z "${DEVAGENT_ISSUE_BACKEND:-}" ]]; then
  _proj="$(trust_project_for_devdoc "${DEVAGENT_DEVDOC_DIR:-}")"
  if [[ -n "${_proj}" ]]; then
    _section=issue_source
    [[ "${TARGET}" == fork ]] && _section=issue_source_fork
    DEVAGENT_ISSUE_BACKEND="$(config_get_project_field "${_proj}" "${_section}.backend" 2>/dev/null || true)"
    : "${DEVAGENT_REPO_ORIGIN:=$(config_get_project_field "${_proj}" issue_source.repo 2>/dev/null || true)}"
    : "${DEVAGENT_REPO_FORK:=$(config_get_project_field "${_proj}" issue_source_fork.repo 2>/dev/null || true)}"
    : "${DEVAGENT_ISSUE_BACKEND_DIR:=$(plugin_root)/scripts/issue}"
  fi
fi
backend="${DEVAGENT_ISSUE_BACKEND:-github}"
# A disk backend (any case) files into a folder on this machine, and no record
# ever names the folder (#1009). Nothing leaves the machine, so no push_mr gate
# is asked (under a policy, trust already refused it), but only when the script
# that will run is this plugin's own disk.sh: one of that name in another
# backends dir may send the issue anywhere, and is gated like any other.
is_disk=0
gate_exempt=0
if issue_backend_is_disk "${backend}"; then
  is_disk=1
  [[ ! "${DEVAGENT_ISSUE_BACKEND_DIR:-}/${backend}.sh" -ef "$(plugin_root)/scripts/issue/disk.sh" ]] || gate_exempt=1
fi

if [[ "${TRUST_IN_SCOPE:-0}" == 1 ]]; then
  [[ "${YES}" -ne 1 ]] || refuse yes-refused
  gate_name="file"
  DEVAGENT_PERMISSION_PUSH_MR="$(permission_value "${TRUST_PROJECT}" file)"
fi

gate="${DEVAGENT_PERMISSION_PUSH_MR:-false}"
if [[ "${gate_exempt}" -ne 1 && "${gate}" != "true" && "${YES}" -ne 1 ]]; then
  case "${TARGET}" in
    origin) _repo="${DEVAGENT_REPO_ORIGIN:-<not set>}" ;;
    fork)   _repo="${DEVAGENT_REPO_FORK:-<not set>}" ;;
  esac
  if [[ "${gate_name}" == file ]]; then
    _gate_line="Permission gate: file=${gate} (trust policy)"
    _remedy="The trust policy's file gate is closed; only the policy (${TRUST_FILE}) can open it."
  else
    _gate_line="Permission gate: push_mr=${gate}"
    _remedy="Re-run with --yes to proceed, or set
[project.<name>.permissions].push_mr = true in config.toml."
  fi
  cat >&2 <<EOF
${_gate_line}

Plan:
  backend: ${DEVAGENT_ISSUE_BACKEND:-github}
  repo:    ${_repo}
  title:   $(head -n1 "${draft}" | sed 's/^# *//')
  body:    ${draft}

${_remedy}
EOF
  exit 4
fi

case "${TARGET}" in
  origin) repo="${DEVAGENT_REPO_ORIGIN:-}" ;;
  fork)   repo="${DEVAGENT_REPO_FORK:-}" ;;
esac
[[ -n "${repo}" ]] || { echo "repo for target=${TARGET} not configured" >&2; exit 2; }

title="$(devagent_draft_h1 "${draft}")"
[[ -n "${title}" ]] || { echo "draft has no H1 title" >&2; exit 3; }

backend_script="${DEVAGENT_ISSUE_BACKEND_DIR:?DEVAGENT_ISSUE_BACKEND_DIR not set}/${backend}.sh"
[[ -x "${backend_script}" ]] || { echo "backend not executable: ${backend_script}" >&2; exit 3; }

# #113: mark the create→filed.toml window. If the script dies after the remote
# create but before filed.toml is written, this marker survives and blocks a
# duplicate re-file (see the guard above). Cleared once filed.toml is written.
: >"${pending}"

_rc=0
issue_num="$("${backend_script}" create "${repo}" "${title}" "${draft}")" || _rc=$?
if [[ "${_rc}" -ne 0 ]]; then
  [[ "${is_disk}" -eq 1 ]] || exit "${_rc}"
  # #1009: disk.sh exits 1 or 2 only when it wrote no issue file (a folder
  # fault, or a prompt the format refuses), so the marker is cleared and the
  # failure is a draft/state problem (3), never usage (2).
  [[ "${_rc}" -ne 1 && "${_rc}" -ne 2 ]] || rm -f "${pending}"
  echo "disk create failed (exit ${_rc})" >&2
  exit 3
fi
[[ -n "${issue_num}" ]] || { echo "backend returned empty issue number" >&2; exit 3; }

# #199: validate the identifier's SHAPE at the consumer boundary (defense-in-depth
# complementing #27's producer-side github fix). A backend that violates its contract
# — e.g. returns a full URL — would otherwise be written verbatim into filed.toml
# (malformed issue_num, doubled url) and break downstream parsers silently. Fail
# closed instead. The .pending marker is intentionally NOT cleared here: the remote
# create already ran, so the issue may exist, and #113's marker must keep blocking a
# silent duplicate re-file.
_shape="${backend}"
[[ "${is_disk}" -ne 1 ]] || _shape=disk
case "${_shape}" in
  github|gitlab) [[ "${issue_num}" =~ ^[0-9]+$ ]] ;;
  disk)          [[ "${issue_num}" =~ ^[1-9][0-9]*$ ]] ;;
  jira)          [[ "${issue_num}" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] ;;
  *)             # custom/unknown: reject a URL-shaped value, accept an opaque token
                 [[ "${issue_num}" != *[/:[:space:]]* && "${issue_num}" != http* ]] ;;
esac || {
  cat >&2 <<EOF
backend '${backend}' returned a malformed issue identifier:
  '${issue_num}'
Expected a bare issue id (numeric for github/gitlab/disk; KEY-123 for jira). Refusing to
write a corrupt filed.toml. The remote issue may already have been created — verify
the tracker, then re-run with --refile if appropriate (.pending marker left in place).
EOF
  exit 3
}

# #113: build the canonical URL from the active backend instead of hardcoding
# github for every backend (which recorded dead links for gitlab/jira).
case "${_shape}" in
  disk)   url="disk:${issue_num}" ;;
  github) url="https://github.com/${repo}/issues/${issue_num}" ;;
  gitlab) url="${DEVAGENT_GITLAB_API:-https://gitlab.com/api/v4}"
          url="${url%/api/v4}/${repo}/-/issues/${issue_num}" ;;
  jira)   url="${DEVAGENT_JIRA_BASE:-https://jira.example}/browse/${issue_num}" ;;
  *)      url="https://github.com/${repo}/issues/${issue_num}" ;;
esac
repo="$(issue_repo_label "${backend}" "${repo}")"   # filed.toml names a disk repo `disk`

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat >"${filed}" <<TOML
# Written by scripts/capture/file.sh
issue_num = "${issue_num}"
url = "${url}"
repo = "${repo}"
target = "${TARGET}"
backend = "${backend}"
filed_at = "${now}"
TOML

# #113: filing committed — clear the in-flight marker.
rm -f "${pending}"

printf '%s\n' "${url}"
