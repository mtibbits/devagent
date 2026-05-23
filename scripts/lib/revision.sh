# Revision helpers for devAgent Phase 6.
#
# All functions are pure (no global mutation). Source-only file: do not
# execute directly.

: "${DEVAGENT_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# revision_current <project>
revision_current() {
  local project="$1"
  local state="$HOME/.claude/devagent/state/${project}.toml"
  local n
  if [[ -f "$state" ]]; then
    n=$(awk -F'=' '
      $1 ~ /^[[:space:]]*revision[[:space:]]*$/ {
        gsub(/[[:space:]"]/, "", $2)
        print $2
        exit
      }
    ' "$state")
  fi
  if [[ -z "$n" ]]; then
    n=1
  fi
  printf '%s\n' "$n"
}

# revision_dir <issue-dir> <N>
revision_dir() {
  local issue_dir="$1"
  local n="$2"
  printf '%s/revisions/r%s\n' "$issue_dir" "$n"
}

# revision_block_text <N>
revision_block_text() {
  local n="$1"
  local tmpl="$DEVAGENT_ROOT/templates/revision_block.md"
  if [[ ! -f "$tmpl" ]]; then
    printf 'revision_block_text: template not found: %s\n' "$tmpl" >&2
    return 1
  fi
  sed "s/{{N}}/${n}/g" "$tmpl"
}
