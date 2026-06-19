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
# #229: breadcrumb support. io.sh + log.sh live in the shared scripts/lib (not
# capture/lib); io.sh (die) must precede log.sh, which calls die at runtime.
# shellcheck source=../lib/io.sh
source "${SCRIPT_DIR}/../lib/io.sh"
# shellcheck source=../lib/log.sh
source "${SCRIPT_DIR}/../lib/log.sh"

usage() {
  cat <<'USAGE' >&2
Usage: reap.sh [--dry-run] [--decisions <file>]

Scans <devdoc>/Issue-*/ and <devdoc>/Issue-Fork-*/ for follow-up
candidates and drafts them into <devdoc>/Captures/<slug>/draft.md.
Idempotent via content hashes in
${DEVAGENT_STATE_DIR}/${DEVAGENT_PROJECT}.reaped.toml.

  --dry-run        enumerate candidates without writing; each row is
                   "<hash>\t<subtype>\t<source>\t<title>".
  --decisions <f>  apply per-candidate decisions (#111). TSV rows keyed by the
                   dry-run <hash>: "<hash>\t<action>\t<subtype>\t<title>" where
                   action is keep|discard. keep applies the subtype/title
                   overrides (empty ⇒ heuristic); discard is not drafted and is
                   recorded in the [discarded] table (skipped on future runs,
                   re-triageable by deleting its line). No decision for a
                   candidate ⇒ keep (so a plain run drafts everything).

Sources:
  imPlan-potentialFutureEnhancements.md  — every "- " bullet
  STUCK files                            — full body
  actualWork.md                          — ### Follow-up sections
                                         — lines with "should be its own issue"
  lessonsLearned.md                      — lines tagged [actionable]
USAGE
}

DRY=0
DECISIONS_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --decisions) DECISIONS_FILE="${2:?--decisions requires a file}"; shift 2 ;;
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

# SEEN = every hash to skip on the scan (drafted OR discarded). DRAFTED feeds the
# [hashes] table, DISCARDED the [discarded] table (#111) — both preserved across
# runs so a discard stays remembered (not re-drafted) yet is re-triageable by
# deleting its [discarded] line.
declare -A SEEN DRAFTED DISCARDED
if [[ -f "${STATE_FILE}" ]]; then
  _section=""
  # `|| [[ -n "${line}" ]]` so a final line with no trailing newline (e.g. a
  # hand edit during re-triage) is still processed, not silently dropped.
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      "[hashes]")    _section="hashes";    continue ;;
      "[discarded]") _section="discarded"; continue ;;
      "["*"]")        _section="";          continue ;;
    esac
    h="${line%% *}"
    [[ "${h}" =~ ^[0-9a-f]{12}$ ]] || continue
    SEEN["${h}"]=1
    case "${_section}" in
      discarded) DISCARDED["${h}"]=1 ;;
      *)         DRAFTED["${h}"]=1 ;;   # [hashes] or legacy section-less line
    esac
  done < "${STATE_FILE}"
fi

# #111: load per-candidate decisions (TSV keyed by body hash). Tab is an
# IFS-whitespace char, so `IFS=$'\t' read` would COALESCE consecutive tabs and
# drop empty interior fields (an empty subtype with a title override would slide
# the title into the subtype slot). Split each line manually to preserve empty
# fields; `|| [[ -n "$line" ]]` keeps an unterminated last line.
declare -A DEC_ACTION DEC_SUBTYPE DEC_TITLE
_VALID_SUBTYPES=" bug feature docs perf chore "
if [[ -n "${DECISIONS_FILE}" ]]; then
  [[ -f "${DECISIONS_FILE}" ]] || { echo "decisions file not found: ${DECISIONS_FILE}" >&2; exit 2; }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    _s="${line}"
    dh="${_s%%$'\t'*}";      _s="${_s#"${dh}"}";      _s="${_s#$'\t'}"
    daction="${_s%%$'\t'*}"; _s="${_s#"${daction}"}"; _s="${_s#$'\t'}"
    dsub="${_s%%$'\t'*}";    _s="${_s#"${dsub}"}";    _s="${_s#$'\t'}"
    dtitle="${_s}"
    [[ "${dh}" =~ ^[0-9a-f]{12}$ ]] || continue
    # Normalize the action: trim surrounding spaces, lowercase, fail-loud (not
    # fail-open) on anything that isn't keep|discard so a typo can't silently
    # turn a discard into a draft.
    daction="${daction#"${daction%%[![:space:]]*}"}"
    daction="${daction%"${daction##*[![:space:]]}"}"
    daction="${daction,,}"
    case "${daction}" in
      keep|discard) ;;
      *) echo "warn: unknown action '${daction}' for ${dh}; treating as keep" >&2; daction="keep" ;;
    esac
    # Drop a bogus subtype override rather than letting capture.sh reject it and
    # lose the candidate; the heuristic subtype is used instead.
    if [[ -n "${dsub}" && "${_VALID_SUBTYPES}" != *" ${dsub} "* ]]; then
      echo "warn: ignoring invalid subtype override '${dsub}' for ${dh}" >&2
      dsub=""
    fi
    DEC_ACTION["${dh}"]="${daction}"
    DEC_SUBTYPE["${dh}"]="${dsub}"
    DEC_TITLE["${dh}"]="${dtitle}"
  done < "${DECISIONS_FILE}"
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
declare -A NEW_BY_ISSUE   # #229: source issue-name -> space-separated new slugs
while IFS=$'\t' read -r subtype title source body; do
  [[ -z "${body}" ]] && continue
  h="$(devagent_hash_text "${body}")"
  if [[ -n "${SEEN[${h}]:-}" ]]; then
    continue
  fi
  if [[ "${DRY}" -eq 1 ]]; then
    printf '%s\t%s\t%s\t%s\n' "${h}" "${subtype}" "${source}" "${title}"
    SEEN["${h}"]=1
    continue
  fi

  # #111: honor the operator's per-candidate decision. No decision (or no
  # --decisions file) ⇒ keep, so a plain run drafts everything (back-compat).
  if [[ "${DEC_ACTION[${h}]:-keep}" == "discard" ]]; then
    DISCARDED["${h}"]=1
    SEEN["${h}"]=1
    continue
  fi
  # keep: apply subtype/title overrides when the decision supplies them. Flatten
  # the title override through _rf for parity with the harvested fields (#109).
  [[ -n "${DEC_SUBTYPE[${h}]:-}" ]] && subtype="${DEC_SUBTYPE[${h}]}"
  [[ -n "${DEC_TITLE[${h}]:-}" ]] && title="$(_rf "${DEC_TITLE[${h}]}")"

  # #108: do NOT pass --force. capture.sh exit 3 means a draft already exists at
  # this slug (a same-day title-kebab collision, or a pre-existing hand-edited
  # draft). Forcing would silently overwrite it AND mark this body seen, losing
  # the other candidate permanently. Instead retry once with a short hash suffix
  # appended to the title, which slugs to a distinct dir. ${h} is the body hash,
  # already computed above; distinct bodies → distinct suffixes, and identical
  # bodies are deduped by SEEN before we ever reach here.
  rc=0
  slug_out="$("${SCRIPT_DIR}/capture.sh" \
    --type issue --subtype "${subtype}" \
    --title "${title}" --source "${source}" 2>/dev/null)" || rc=$?
  if [[ "${rc}" -eq 3 ]]; then
    rc=0
    # A title whose kebab already exceeds slug.sh's 60-char cap truncates the
    # suffix away, so the retry can still collide → falls through to the warn
    # path below and is deferred (not lost), to be retried next run.
    slug_out="$("${SCRIPT_DIR}/capture.sh" \
      --type issue --subtype "${subtype}" \
      --title "${title} ${h:0:6}" --source "${source}" 2>/dev/null)" || rc=$?
  fi
  if [[ "${rc}" -ne 0 ]]; then
    # Leave the body unmarked so it is retried on the next reap run.
    echo "warn: capture.sh failed (rc=${rc}) for: ${title}" >&2
    continue
  fi
  SEEN["${h}"]=1
  DRAFTED["${h}"]=1
  NEW_LABELS+=("${title}")
  # #229: record the actual slug (post-collision-suffix) for this issue's breadcrumb.
  [[ -n "${slug_out}" ]] && NEW_BY_ISSUE["${source%%/*}"]+=" ${slug_out}"
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
  for h in "${!DRAFTED[@]}"; do
    printf '%s = "seen"\n' "${h}"
  done
  printf '[discarded]\n'
  for h in "${!DISCARDED[@]}"; do
    printf '%s = "discarded"\n' "${h}"
  done
} >"${tmp}"
mv -f "${tmp}" "${STATE_FILE}"

# #229: stamp each source issue's checklist ## Log with what was harvested.
# Best-effort + read-only-on-sources: only the append-only ## Log journal is
# touched; a missing checklist or '## Log' heading is skipped; log_append runs in
# a subshell so its die() cannot abort the harvest under `set -e`.
for issue_name in "${!NEW_BY_ISSUE[@]}"; do
  issue_dir="${DEVAGENT_DEVDOC_DIR%/}/${issue_name}"
  [[ -f "${issue_dir}/checklist.md" ]] || continue
  grep -q '^## Log' "${issue_dir}/checklist.md" || continue
  read -ra _slugs <<< "${NEW_BY_ISSUE[${issue_name}]}"
  msg="harvested ${#_slugs[@]} follow-up(s) ->"
  for s in "${_slugs[@]}"; do msg="${msg} Captures/${s},"; done
  msg="${msg%,}"
  ( log_append "${issue_dir}" reap "${msg}" ) || true
done

printf 'reap: %d new draft(s)\n' "${new_count}"
for t in "${NEW_LABELS[@]}"; do
  printf '  + %s\n' "${t}"
done
