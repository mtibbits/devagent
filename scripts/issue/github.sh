#!/usr/bin/env bash
# scripts/issue/github.sh — GitHub issue backend.
# Backend contract: implements all five issue verbs per spec §9.1
# (fetch, create, transition, state, comment-list), plus the optional
# state-list that `wbs update` reads (#703).
# Output shape conforms to spec §9.3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_die() { echo "$*" >&2; exit 1; }
_need() { command -v "$1" >/dev/null 2>&1 || _die "$1 not found on PATH"; }

# _gh_view <repo> <num> <json-fields>
# Runs `gh issue view` and prints ONLY its stdout (the JSON). gh writes notices
# (update nags, deprecation warnings) to stderr even on success; capturing them
# with 2>&1 would prefix the JSON and break the downstream jq (#86, same class as
# the #27 fix in cmd_create). Stderr is kept separate and surfaced only when gh
# exits non-zero.
_gh_view() {
  local repo="$1" num="$2" fields="$3"
  local out err
  err="$(mktemp)"
  if ! out="$(gh issue view "$num" --repo "$repo" --json "$fields" 2>"$err")"; then
    echo "gh issue view failed: $(cat "$err")" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  printf '%s' "$out"
}

cmd_fetch() {
  local repo="${1:?repo required}"
  local num="${2:?issue number required}"
  _need gh
  _need jq

  local json
  json="$(_gh_view "$repo" "$num" 'title,state,author,labels,url,body,comments,createdAt')" || return 1

  printf '%s' "$json" | jq -r --arg repo "$repo" --arg num "$num" '
    def label_csv:
      if (.labels|length) == 0 then "" else
        (.labels | map(.name) | join(", "))
      end;
    def comment_block:
      .comments | map(
        "### @" + (.author.login // "unknown")
        + " · " + ((.createdAt // "") | split("T")[0])
        + "\n\n" + (.body // "")
      ) | join("\n\n");

    "# " + $repo + "#" + $num + " — " + (.title // "(no title)") + "\n\n"
    + "- State: " + ((.state // "unknown") | ascii_downcase) + "\n"
    + "- Author: @" + (.author.login // "unknown") + "\n"
    + "- Labels: " + label_csv + "\n"
    + "- URL: " + (.url // "") + "\n"
    + "- Created: " + ((.createdAt // "") | split("T")[0]) + "\n\n"
    + "---\n\n"
    + (.body // "") + "\n\n"
    + "---\n\n"
    + "## Comments (" + ((.comments | length) | tostring) + ")\n"
    + (if (.comments | length) > 0 then "\n" + comment_block + "\n" else "" end)
  '
}

cmd_state() {
  local repo="${1:?repo required}"
  local num="${2:?issue number required}"
  _need gh
  _need jq
  local json
  json="$(_gh_view "$repo" "$num" 'state')" || return 1
  printf '%s' "$json" | jq -r '.state | ascii_downcase'
}

cmd_comment_list() {
  local repo="${1:?repo required}"
  local num="${2:?issue number required}"
  _need gh
  _need jq
  local json
  json="$(_gh_view "$repo" "$num" 'comments')" || return 1
  printf '%s' "$json" | jq -r '
    def comment_block:
      .comments | map(
        "### @" + (.author.login // "unknown")
        + " · " + ((.createdAt // "") | split("T")[0])
        + "\n\n" + (.body // "")
      ) | join("\n\n");
    "## Comments (" + ((.comments | length) | tostring) + ")\n"
    + (if (.comments | length) > 0 then "\n" + comment_block + "\n" else "" end)
  '
}

cmd_create() {
  local repo="${1:?repo required}"
  local title="${2:?title required}"
  local body_file="${3:-}"
  _need gh
  if [ "$#" -ge 3 ]; then shift 3; else shift "$#"; fi
  local args=(--repo "$repo" --title "$title")
  # #89: a non-empty body_file must exist — otherwise gh would file the literal
  # path string as the body. Empty body_file keeps github's inline-body leniency.
  if [ -n "${body_file}" ]; then
    [ -f "${body_file}" ] || { echo "github.sh: body file not found: ${body_file}" >&2; return 2; }
    args+=(--body-file "${body_file}")
  else
    args+=(--body "")
  fi
  # #89: honor repeatable --label (custom.sh contract; gitlab/jira parity) and
  # reject unknown args instead of silently dropping them.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --label)
        [ -n "${2:-}" ] || { echo "github.sh: --label needs a value" >&2; return 2; }
        args+=(--label "$2"); shift 2 ;;
      *) echo "github.sh: unknown create arg: $1" >&2; return 2 ;;
    esac
  done
  local out
  # Capture gh's STDOUT only — do NOT add 2>&1 here (unlike the other verbs):
  # gh writes tips/notices/warnings to stderr, and they must not pollute the
  # URL we parse the issue number from below (#27).
  out="$(gh issue create "${args[@]}")" || return
  # gh prints the new issue's URL (…/issues/N); the backend contract (file.sh,
  # gitlab.sh, the mock) is a bare number. Emit the trailing path segment, but
  # fail loudly if it isn't numeric so a future gh output change surfaces
  # instead of silently corrupting filed.toml (the #27 bug class).
  local num="${out##*/}"
  case "$num" in
    ''|*[!0-9]*) echo "github.sh: could not parse issue number from gh output: $out" >&2; return 1 ;;
  esac
  printf '%s\n' "$num"
}

# Resolve the GitHub label for a semantic stage, or empty if the stage has none.
# Precedence (parity with gitlab.sh / jira.sh):
#   1. DEVAGENT_GITHUB_LABEL_<STAGE> env override
#   2. per-project `github_labels.<stage>` config (gitlab/jira parity)
#   3. built-in defaults: in_progress → "in progress", done → "done",
#      blocked → "blocked"
#   4. otherwise empty — the stage has no mapped label (e.g. on_ship / on_merge
#      with nothing configured). Empty is the fail-safe-skip signal for
#      cmd_transition; it is also the Option-3 seam where a default label name
#      would be resolved later (#87).
_stage_label() {
  local stage="$1"
  local var="DEVAGENT_GITHUB_LABEL_${stage^^}"
  local label="${!var:-}"
  if [ -z "$label" ] && [ -n "${DEVAGENT_PROJECT:-}" ]; then
    # shellcheck source=../lib/paths.sh
    source "${SCRIPT_DIR}/../lib/paths.sh"
    # shellcheck source=../lib/io.sh
    source "${SCRIPT_DIR}/../lib/io.sh"
    # shellcheck source=../lib/config.sh
    source "${SCRIPT_DIR}/../lib/config.sh"
    label="$(config_get_project_field "$DEVAGENT_PROJECT" "github_labels.${stage}" 2>/dev/null || true)"
  fi
  if [ -z "$label" ]; then
    case "$stage" in
      in_progress) label="in progress" ;;
      done)        label="done" ;;
      blocked)     label="blocked" ;;
    esac
  fi
  printf '%s' "$label"
}

cmd_transition() {
  local repo="${1:?repo required}"
  local num="${2:?issue number required}"
  local stage="${3:?semantic stage required}"
  _need gh
  local label
  label="$(_stage_label "$stage")"
  # Fail-safe skip (#87): a stage with no env/config/built-in label (e.g.
  # on_ship / on_merge unconfigured) skips the label step entirely — no
  # `gh issue edit` call. Previously this fell through to `--add-label <stage>`,
  # which failed on every ship/sync because no such label exists in the repo
  # (degraded to warning-spam). Option-3 seam: a default name resolves in
  # _stage_label above.
  [ -n "$label" ] || return 0
  # gh accepts repeated --add-label; idempotent because GitHub silently ignores
  # re-adding the same label. A configured-but-missing label makes gh fail;
  # treat that as a fail-safe skip (not a hard error) so ship/sync still succeed
  # without warning-spam. Option-3 seam: `gh label create "$label"` + retry
  # slots into this failure branch later.
  gh issue edit "$num" --repo "$repo" --add-label "$label" >/dev/null 2>&1 || return 0
}

# state-list <repo> (#703, spec §9.1 MAY): every issue of <repo>, one
# `<number>` TAB `<class>` line each, for `wbs update`. One `gh issue list`
# call (gh pages internally). Classes:
#   CLOSED + COMPLETED                 -> done
#   CLOSED + NOT_PLANNED / DUPLICATE   -> not_planned
#   CLOSED + any other reason          -> other
#   OPEN + the in_progress label       -> in_progress (_stage_label above;
#                                         matched case-insensitively, as GitHub
#                                         names labels)
#   OPEN                               -> open
# Exit: 0 ok; 1 gh failure or no repo arg; 5 a record with an unrecognised
# state or unreadable JSON (fail closed: a renamed field must not read as a
# class). Never 2, which means "unknown verb" to `wbs update`.
cmd_state_list() {
  local repo="${1:-}"
  [ -n "$repo" ] || _die "issue/github.sh state-list: repo required"
  _need gh
  _need jq
  local ip json err n
  ip="$(_stage_label in_progress)"
  err="$(mktemp)"
  if ! json="$(gh issue list --repo "$repo" --state all --limit 5000 \
      --json number,state,stateReason,labels 2>"$err")"; then
    echo "gh issue list failed: $(cat "$err")" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  n="$(printf '%s' "$json" | jq length | tr -d '\r')" || {
    echo "issue/github.sh state-list: gh issue list returned unreadable JSON" >&2
    return 5
  }
  if [ "$n" = 5000 ]; then
    echo "github.sh: state-list returned the --limit of 5000 issues; older issues are missing" >&2
  fi
  printf '%s' "$json" | jq -r --arg ip "$ip" '
    .[] | "\(.number)\t\(
      if .state == "CLOSED" then
        (if .stateReason == "COMPLETED" then "done"
         elif .stateReason == "NOT_PLANNED" or .stateReason == "DUPLICATE" then "not_planned"
         else "other" end)
      elif .state == "OPEN" then
        (if $ip != "" and any(.labels[]?; (.name | ascii_downcase) == ($ip | ascii_downcase))
         then "in_progress" else "open" end)
      else error("unrecognised state \(.state) on #\(.number)") end)"' || return 5
}

main() {
  local verb="${1:-}"
  if [ -z "$verb" ]; then
    echo "issue/github.sh: verb required" >&2
    exit 2
  fi
  shift
  case "$verb" in
    fetch)         cmd_fetch        "$@" ;;
    state)         cmd_state        "$@" ;;
    comment-list)  cmd_comment_list "$@" ;;
    create)        cmd_create       "$@" ;;
    transition)    cmd_transition   "$@" ;;
    state-list)    cmd_state_list   "$@" ;;
    *)
      echo "issue/github.sh: unknown verb '$verb'" >&2
      exit 2
      ;;
  esac
}

main "$@"
