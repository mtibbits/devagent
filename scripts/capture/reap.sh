#!/usr/bin/env bash
# scripts/capture/reap.sh — harvest follow-up candidates into Captures/.
# Spec §15. Idempotent via content hashes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slug.sh
source "${SCRIPT_DIR}/lib/slug.sh"
# shellcheck source=lib/paths.sh
source "${SCRIPT_DIR}/lib/paths.sh"
# shellcheck source=lib/template.sh
source "${SCRIPT_DIR}/lib/template.sh"
# shellcheck source=lib/hash.sh
source "${SCRIPT_DIR}/lib/hash.sh"

usage() {
  cat <<'USAGE' >&2
Usage: reap.sh [--dry-run]

Scans <devdoc>/Issue-*/ and <devdoc>/Issue-Fork-*/ for follow-up
candidates and drafts them into <devdoc>/Captures/<slug>/draft.md.
Idempotent via content hashes in
${DEVAGENT_STATE_DIR}/${DEVAGENT_PROJECT}.reaped.toml.

Sources:
  imPlan-potentialFutureEnhancements.md  — every "- " bullet
  STUCK files                            — full body
  actualWork.md                          — ### Follow-up sections
                                         — lines with "should be its own issue"
  lessonsLearned.md                      — lines tagged [actionable]
USAGE
}

DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "${DEVAGENT_PROJECT:-}" ]] || { echo "DEVAGENT_PROJECT not set" >&2; exit 2; }
[[ -n "${DEVAGENT_DEVDOC_DIR:-}" ]] || { echo "DEVAGENT_DEVDOC_DIR not set" >&2; exit 2; }
[[ -n "${DEVAGENT_PLUGIN_DIR:-}" ]] || { echo "DEVAGENT_PLUGIN_DIR not set" >&2; exit 2; }

STATE_DIR="${DEVAGENT_STATE_DIR:-${HOME}/.claude/devagent/state}"
mkdir -p "${STATE_DIR}"
STATE_FILE="${STATE_DIR}/${DEVAGENT_PROJECT}.reaped.toml"

declare -A SEEN
if [[ -f "${STATE_FILE}" ]]; then
  while IFS= read -r line; do
    h="${line%% *}"
    [[ "${h}" =~ ^[0-9a-f]{12}$ ]] && SEEN["${h}"]=1
  done < <(grep -E '^[0-9a-f]{12} = ' "${STATE_FILE}" || true)
fi

# emit_candidates prints TAB-separated rows: subtype \t title \t source \t body
# body has internal whitespace flattened to spaces (so the hash and the
# capture title don't accidentally contain literal tabs/newlines).
emit_candidates() {
  local devdoc="$1"
  shopt -s nullglob
  local d
  for d in "${devdoc}"/Issue-* "${devdoc}"/Issue-Fork-*; do
    [[ -d "${d}" ]] || continue
    local issue_name
    issue_name="$(basename "${d}")"

    # 1. imPlan-potentialFutureEnhancements.md
    local f="${d}/imPlan-potentialFutureEnhancements.md"
    if [[ -f "${f}" ]]; then
      local lineno=0
      while IFS= read -r line; do
        lineno=$((lineno + 1))
        if [[ "${line}" =~ ^-\ (.+)$ ]]; then
          local body="${BASH_REMATCH[1]}"
          local title="${body%%.*}"
          printf 'feature\t%s\t%s/imPlan-potentialFutureEnhancements.md line %d\t%s\n' \
            "${title}" "${issue_name}" "${lineno}" "${body}"
        fi
      done <"${f}"
    fi

    # 2. STUCK file
    local s="${d}/STUCK"
    if [[ -f "${s}" ]]; then
      local reason
      reason="$(awk '/^Reason:/{sub(/^Reason:[ ]*/,""); print; exit}' "${s}")"
      [[ -z "${reason}" ]] && reason="${issue_name} STUCK"
      local body
      body="$(tr '\n' ' ' <"${s}" | tr -s ' ')"
      printf 'chore\t%s\t%s/STUCK\t%s\n' \
        "STUCK: ${reason}" "${issue_name}" "${body}"
    fi

    # 3a. actualWork.md ### Follow-up
    local a="${d}/actualWork.md"
    if [[ -f "${a}" ]]; then
      awk -v iss="${issue_name}" '
        /^### Follow-up$/ { inflw = 1; next }
        /^### / && inflw { inflw = 0 }
        inflw && /^- / {
          line=$0; sub(/^- */,"",line);
          title=line; sub(/\..*$/,"",title);
          printf "feature\t%s\t%s/actualWork.md (### Follow-up)\t%s\n", title, iss, line;
        }
      ' "${a}"
      # 3b. "should be its own issue"
      grep -nE 'should be its own issue' "${a}" 2>/dev/null | while IFS=: read -r lineno line; do
        local trimmed="${line# }"
        trimmed="${trimmed#- }"
        local title="${trimmed%%.*}"
        printf 'feature\t%s\t%s/actualWork.md line %s\t%s\n' \
          "${title}" "${issue_name}" "${lineno}" "${trimmed}"
      done
    fi

    # 4. lessonsLearned.md [actionable]
    local l="${d}/lessonsLearned.md"
    if [[ -f "${l}" ]]; then
      grep -nE '\[actionable\]' "${l}" 2>/dev/null | while IFS=: read -r lineno line; do
        local trimmed="${line# }"
        trimmed="${trimmed#- }"
        trimmed="${trimmed#\[actionable\] }"
        local title="${trimmed%%.*}"
        printf 'chore\t%s\t%s/lessonsLearned.md line %s\t%s\n' \
          "${title}" "${issue_name}" "${lineno}" "${trimmed}"
      done
    fi
  done
}

new_count=0
declare -a NEW_LABELS
while IFS=$'\t' read -r subtype title source body; do
  [[ -z "${body}" ]] && continue
  h="$(devagent_hash_text "${body}")"
  if [[ -n "${SEEN[${h}]:-}" ]]; then
    continue
  fi
  if [[ "${DRY}" -eq 1 ]]; then
    printf '%s\t%s\t%s\n' "${subtype}" "${source}" "${title}"
    SEEN["${h}"]=1
    continue
  fi

  if ! "${SCRIPT_DIR}/capture.sh" \
        --type issue --subtype "${subtype}" \
        --title "${title}" --source "${source}" --force \
        >/dev/null; then
    echo "warn: capture.sh failed for: ${title}" >&2
    continue
  fi
  SEEN["${h}"]=1
  NEW_LABELS+=("${title}")
  new_count=$((new_count + 1))
done < <(emit_candidates "${DEVAGENT_DEVDOC_DIR%/}")

if [[ "${DRY}" -eq 1 ]]; then
  exit 0
fi

{
  printf '# Written by scripts/capture/reap.sh\n'
  printf '# project = %s\n' "${DEVAGENT_PROJECT}"
  printf '[hashes]\n'
  for h in "${!SEEN[@]}"; do
    printf '%s = "seen"\n' "${h}"
  done
} >"${STATE_FILE}"

printf 'reap: %d new draft(s)\n' "${new_count}"
for t in "${NEW_LABELS[@]}"; do
  printf '  + %s\n' "${t}"
done
