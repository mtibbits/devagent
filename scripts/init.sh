#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/scripts/lib/paths.sh"
source "$PLUGIN_ROOT/scripts/lib/io.sh"
source "$PLUGIN_ROOT/scripts/lib/state.sh"
source "$PLUGIN_ROOT/scripts/lib/secrets.sh"

usage() {
  echo "usage: init.sh <project>" >&2
  exit 2
}

[[ $# -eq 1 && -n "$1" ]] || usage
project="$1"

# Validate project name: lowercase alnum, dash, underscore.
# (Dots forbidden: they'd produce nested TOML tables, breaking config discovery.)
[[ "$project" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "bad project name '$project' (must be lowercase alnum/-/_)"

cfg="$(config_path)"
home="$(devagent_home)"
mkdir -p "$home/state"
chmod 700 "$home" 2>/dev/null || true
secrets_bootstrap

# Refuse overwrite.
if [[ -f "$cfg" ]] && grep -qE "^\[project\.${project}\]" "$cfg"; then
  die "[project.$project] already exists in $cfg"
fi

# Gather answers. Env vars short-circuit prompts (for tests/CI).
ask() {
  local var="$1" prompt="$2" default="${3:-}" envvar="$4" answer=""
  if [[ -n "${!envvar:-}" ]]; then
    answer="${!envvar}"
  elif is_tty; then
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [$default]: " answer
      [[ -z "$answer" ]] && answer="$default"
    else
      read -r -p "$prompt: " answer
    fi
  else
    [[ -n "$default" ]] || die "missing answer for $var (set $envvar)"
    answer="$default"
  fi
  printf -v "$var" '%s' "$answer"
}

ask source_dir    "source repo dir" ""               DA_INIT_SOURCE_DIR
ask devdoc_dir    "devdoc dir"      ""               DA_INIT_DEVDOC_DIR
ask issue_backend "issue backend"   "github"         DA_INIT_ISSUE_BACKEND
ask issue_repo    "issue repo (org/name)" ""         DA_INIT_ISSUE_REPO
ask code_backend  "code backend"    "$issue_backend" DA_INIT_CODE_BACKEND
ask code_upstream "code upstream (org/name)" "$issue_repo" DA_INIT_CODE_UPSTREAM
ask code_fork     "code fork (org/name)"     ""      DA_INIT_CODE_FORK

# Render skeleton.
skel="$PLUGIN_ROOT/templates/config.toml.skel"
rendered="$(mktemp)"
sed -e "s|{{PROJECT}}|$project|g" \
    -e "s|{{SOURCE_DIR}}|$source_dir|g" \
    -e "s|{{DEVDOC_DIR}}|$devdoc_dir|g" \
    -e "s|{{ISSUE_BACKEND}}|$issue_backend|g" \
    -e "s|{{ISSUE_REPO}}|$issue_repo|g" \
    -e "s|{{CODE_BACKEND}}|$code_backend|g" \
    -e "s|{{CODE_UPSTREAM}}|$code_upstream|g" \
    -e "s|{{CODE_FORK}}|$code_fork|g" \
    "$skel" > "$rendered"

if [[ ! -f "$cfg" ]]; then
  install -m 644 "$rendered" "$cfg"
else
  # Append only the project-specific blocks (skip the [defaults] header,
  # which already exists in the file).
  awk 'BEGIN{p=0} /^\[project\./{p=1} p{print}' "$rendered" >> "$cfg"
fi
rm -f "$rendered"

state_init "$project"

info "bootstrapped $project"
info "  config:  $cfg"
info "  state:   $(state_path "$project")"
info "  secrets: $(secrets_dir)/"
info "next: run /devagent:doctor $project"
