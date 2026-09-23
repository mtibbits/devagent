#!/usr/bin/env bash
# scripts/capture/file.sh — file a capture draft as a tracker issue.
# Honors the push_mr permission gate (spec §8).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
source "${SCRIPT_DIR}/lib/paths.sh"
# shellcheck source=lib/draft.sh
source "${SCRIPT_DIR}/lib/draft.sh"

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
  DEVAGENT_ISSUE_BACKEND_DIR     required (path to issue/ backends)
  DEVAGENT_ISSUE_BACKEND         optional (default: github)
  DEVAGENT_REPO_ORIGIN           required if --target origin
  DEVAGENT_REPO_FORK             required if --target fork
  DEVAGENT_PERMISSION_PUSH_MR    true|false (default false)
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

gate="${DEVAGENT_PERMISSION_PUSH_MR:-false}"
if [[ "${gate}" != "true" && "${YES}" -ne 1 ]]; then
  case "${TARGET}" in
    origin) _repo="${DEVAGENT_REPO_ORIGIN:-<not set>}" ;;
    fork)   _repo="${DEVAGENT_REPO_FORK:-<not set>}" ;;
  esac
  cat >&2 <<EOF
Permission gate: push_mr=${gate}

Plan:
  backend: ${DEVAGENT_ISSUE_BACKEND:-github}
  repo:    ${_repo}
  title:   $(head -n1 "${draft}" | sed 's/^# *//')
  body:    ${draft}

Re-run with --yes to proceed, or set
[project.<name>.permissions].push_mr = true in config.toml.
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

backend="${DEVAGENT_ISSUE_BACKEND:-github}"
backend_script="${DEVAGENT_ISSUE_BACKEND_DIR:?DEVAGENT_ISSUE_BACKEND_DIR not set}/${backend}.sh"
[[ -x "${backend_script}" ]] || { echo "backend not executable: ${backend_script}" >&2; exit 3; }

# #113: mark the create→filed.toml window. If the script dies after the remote
# create but before filed.toml is written, this marker survives and blocks a
# duplicate re-file (see the guard above). Cleared once filed.toml is written.
: >"${pending}"

issue_num="$("${backend_script}" create "${repo}" "${title}" "${draft}")"
[[ -n "${issue_num}" ]] || { echo "backend returned empty issue number" >&2; exit 3; }

# #199: validate the identifier's SHAPE at the consumer boundary (defense-in-depth
# complementing #27's producer-side github fix). A backend that violates its contract
# — e.g. returns a full URL — would otherwise be written verbatim into filed.toml
# (malformed issue_num, doubled url) and break downstream parsers silently. Fail
# closed instead. The .pending marker is intentionally NOT cleared here: the remote
# create already ran, so the issue may exist, and #113's marker must keep blocking a
# silent duplicate re-file.
case "${backend}" in
  github|gitlab) [[ "${issue_num}" =~ ^[0-9]+$ ]] ;;
  jira)          [[ "${issue_num}" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] ;;
  *)             # custom/unknown: reject a URL-shaped value, accept an opaque token
                 [[ "${issue_num}" != *[/:[:space:]]* && "${issue_num}" != http* ]] ;;
esac || {
  cat >&2 <<EOF
backend '${backend}' returned a malformed issue identifier:
  '${issue_num}'
Expected a bare issue id (numeric for github/gitlab; KEY-123 for jira). Refusing to
write a corrupt filed.toml. The remote issue may already have been created — verify
the tracker, then re-run with --refile if appropriate (.pending marker left in place).
EOF
  exit 3
}

# #113: build the canonical URL from the active backend instead of hardcoding
# github for every backend (which recorded dead links for gitlab/jira).
case "${backend}" in
  github) url="https://github.com/${repo}/issues/${issue_num}" ;;
  gitlab) url="${DEVAGENT_GITLAB_API:-https://gitlab.com/api/v4}"
          url="${url%/api/v4}/${repo}/-/issues/${issue_num}" ;;
  jira)   url="${DEVAGENT_JIRA_BASE:-https://jira.example}/browse/${issue_num}" ;;
  *)      url="https://github.com/${repo}/issues/${issue_num}" ;;
esac

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
