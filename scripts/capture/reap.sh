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

# #109: flatten internal tabs/newlines to single spaces so a literal tab in a
# source bullet (pasted code, aligned text) can't shift the TAB-separated fields
# the consumer reads. Applied to EVERY emitted title/body, not just STUCK.
_rf() { printf '%s' "$1" | tr '\n\t' '  ' | tr -s ' '; }

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
            "$(_rf "${title}")" "${issue_name}" "${lineno}" "$(_rf "${body}")"
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
        "STUCK: $(_rf "${reason}")" "${issue_name}" "$(_rf "${body}")"
    fi

    # 3a. actualWork.md ### Follow-up
    local a="${d}/actualWork.md"
    if [[ -f "${a}" ]]; then
      awk -v iss="${issue_name}" '
        /^### Follow-up$/ { inflw = 1; next }
        /^### / && inflw { inflw = 0 }
        inflw && /^- / {
          line=$0; sub(/^- */,"",line);
          gsub(/\t/, " ", line); gsub(/  +/, " ", line);   # #109: flatten tabs
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
          "$(_rf "${title}")" "${issue_name}" "${lineno}" "$(_rf "${trimmed}")"
      done
    fi

    # 4. lessonsLearned.md [actionable]
    # #112: the canonical format is a '### <claim>' heading + '- Tags: [actionable]'
    # bullet, so grepping the tag line titled every draft 'Tags: [actionable]' and
    # lost the claim; commented <!-- example --> tag lines were harvested too. Lift
    # the enclosing heading for tag-list lines, skip comment blocks, and keep the
    # flat inline '- [actionable] <claim>' path (byte-identical body → same hash).
    local l="${d}/lessonsLearned.md"
    if [[ -f "${l}" ]]; then
      awk -v iss="${issue_name}" '
        /<!--/ { incomment = 1 }
        incomment { if ($0 ~ /-->/) incomment = 0; next }
        /^### / { heading = $0; sub(/^### */, "", heading); next }
        /\[actionable\]/ {
          line = $0; sub(/^[ \t]*-[ \t]*/, "", line);   # strip a leading bullet
          if (line ~ /^\[actionable\]/) {               # flat inline: "- [actionable] <claim>"
            sub(/^\[actionable\][ ]*/, "", line); claim = line;
          } else if (line ~ /^Tags:/ || line ~ /^\[/) { # tag-list line → use the heading
            claim = heading;
          } else {                                      # actionable embedded mid-line
            claim = (heading != "" ? heading : line);
          }
          if (claim == "") next;
          gsub(/\t/, " ", claim); gsub(/  +/, " ", claim);
          title = claim; sub(/\..*$/, "", title);
          printf "chore\t%s\t%s/lessonsLearned.md line %d\t%s\n", title, iss, NR, claim;
        }
      ' "${l}"
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

  # #108: do NOT pass --force. capture.sh exit 3 means a draft already exists at
  # this slug (a same-day title-kebab collision, or a pre-existing hand-edited
  # draft). Forcing would silently overwrite it AND mark this body seen, losing
  # the other candidate permanently. Instead retry once with a short hash suffix
  # appended to the title, which slugs to a distinct dir. ${h} is the body hash,
  # already computed above; distinct bodies → distinct suffixes, and identical
  # bodies are deduped by SEEN before we ever reach here.
  rc=0
  "${SCRIPT_DIR}/capture.sh" \
    --type issue --subtype "${subtype}" \
    --title "${title}" --source "${source}" \
    >/dev/null 2>&1 || rc=$?
  if [[ "${rc}" -eq 3 ]]; then
    rc=0
    # A title whose kebab already exceeds slug.sh's 60-char cap truncates the
    # suffix away, so the retry can still collide → falls through to the warn
    # path below and is deferred (not lost), to be retried next run.
    "${SCRIPT_DIR}/capture.sh" \
      --type issue --subtype "${subtype}" \
      --title "${title} ${h:0:6}" --source "${source}" \
      >/dev/null 2>&1 || rc=$?
  fi
  if [[ "${rc}" -ne 0 ]]; then
    # Leave the body unmarked so it is retried on the next reap run.
    echo "warn: capture.sh failed (rc=${rc}) for: ${title}" >&2
    continue
  fi
  SEEN["${h}"]=1
  NEW_LABELS+=("${title}")
  new_count=$((new_count + 1))
done < <(emit_candidates "${DEVAGENT_DEVDOC_DIR%/}")

if [[ "${DRY}" -eq 1 ]]; then
  exit 0
fi

# Write atomically: a bare > redirect truncates the state file in place, so a
# crash mid-write leaves it truncated. Stage into a temp file in the same dir
# (same filesystem → atomic rename) then mv into place, like lib/secrets.sh.
tmp="$(mktemp "${STATE_DIR}/.${DEVAGENT_PROJECT}.reaped.XXXXXX")"
{
  printf '# Written by scripts/capture/reap.sh\n'
  printf '# project = %s\n' "${DEVAGENT_PROJECT}"
  printf '[hashes]\n'
  for h in "${!SEEN[@]}"; do
    printf '%s = "seen"\n' "${h}"
  done
} >"${tmp}"
mv -f "${tmp}" "${STATE_FILE}"

printf 'reap: %d new draft(s)\n' "${new_count}"
for t in "${NEW_LABELS[@]}"; do
  printf '  + %s\n' "${t}"
done
