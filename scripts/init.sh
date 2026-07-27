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

if [[ $# -eq 1 && -n "$1" ]]; then
  project="$1"
elif [[ $# -eq 0 && -n "${CLAUDE_PLUGIN_OPTION_DEFAULT_PROJECT:-}" ]]; then
  project="${CLAUDE_PLUGIN_OPTION_DEFAULT_PROJECT}"   # #459: userConfig SEED when no arg given
else
  usage
fi

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
ask devdoc_dir    "devdoc dir"      "${CLAUDE_PLUGIN_OPTION_DEVDOC_ROOT:-}" DA_INIT_DEVDOC_DIR   # #459: userConfig SEEDS the default
ask issue_backend "issue backend"   "github"         DA_INIT_ISSUE_BACKEND
ask issue_repo    "issue repo (org/name)" ""         DA_INIT_ISSUE_REPO
ask code_backend  "code backend"    "$issue_backend" DA_INIT_CODE_BACKEND
ask code_upstream "code upstream (org/name)" "$issue_repo" DA_INIT_CODE_UPSTREAM
ask code_fork     "code fork (org/name)"     ""      DA_INIT_CODE_FORK

# #352: offer the opt-in git-reflex guard (a global [defaults] flag). Per-flag
# typed approval — default stays OFF; only an explicit yes enables it.
ask git_guard_ans "Enable the git-reflex guard? (blocks reflexive stash/checkout--/restore/clean on a dirty tree; default off)" "n" DA_INIT_GIT_GUARD

# #437: ask the step-13 analyze family, and — ONLY when it is cmake — surface the
# analyze_timeout key so it is discoverable at init (previously only the skel
# comment named it). A large TSan ctest suite (e.g. volk-scale) can exceed the
# 1800s default and get silently killed mid-run; offering the key at init lets the
# operator raise it up front. shellcheck/none projects have no such leg, so the
# timeout is not offered for them.
analyze_ans=""   # declared so shellcheck sees the `ask` (printf -v) assignment (SC2154)
ask analyze_ans "analyze family (cmake | shellcheck | none)" "cmake" DA_INIT_ANALYZE
analyze_timeout_ans=""
if [ "$analyze_ans" = "cmake" ]; then
  ask analyze_timeout_ans "analyze_timeout seconds for the cmake configure/build/ctest legs (default 1800; raise for a large TSan ctest suite that could exceed it)" "1800" DA_INIT_ANALYZE_TIMEOUT
  [[ "$analyze_timeout_ans" =~ ^[0-9]+$ ]] || die "analyze_timeout must be a positive integer (got '$analyze_timeout_ans')"
fi

# Detect upstream's default branch for default_baseline. Falls back to main
# when gh is unavailable, unauthenticated, or offline.
default_branch="$(gh api "repos/$code_upstream" --jq '.default_branch' 2>/dev/null || true)"
[ -n "$default_branch" ] || default_branch="main"

# Render skeleton. Substitute placeholders with literal string replacement in
# Python: operator answers (paths, repo slugs) can contain sed metacharacters
# such as `&` (means "the matched text") or the `|` delimiter, which silently
# corrupted the rendered config under the old sed pipeline (audit A20).
skel="$PLUGIN_ROOT/templates/config.toml.skel"
rendered="$(mktemp)"
DA_RENDER_PROJECT="$project" \
DA_RENDER_SOURCE_DIR="$source_dir" \
DA_RENDER_DEVDOC_DIR="$devdoc_dir" \
DA_RENDER_ISSUE_BACKEND="$issue_backend" \
DA_RENDER_ISSUE_REPO="$issue_repo" \
DA_RENDER_CODE_BACKEND="$code_backend" \
DA_RENDER_CODE_UPSTREAM="$code_upstream" \
DA_RENDER_CODE_FORK="$code_fork" \
DA_RENDER_DEFAULT_BRANCH="$default_branch" \
python3 - "$skel" "$rendered" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
subst = {
    "{{PROJECT}}":        os.environ["DA_RENDER_PROJECT"],
    "{{SOURCE_DIR}}":     os.environ["DA_RENDER_SOURCE_DIR"],
    "{{DEVDOC_DIR}}":     os.environ["DA_RENDER_DEVDOC_DIR"],
    "{{ISSUE_BACKEND}}":  os.environ["DA_RENDER_ISSUE_BACKEND"],
    "{{ISSUE_REPO}}":     os.environ["DA_RENDER_ISSUE_REPO"],
    "{{CODE_BACKEND}}":   os.environ["DA_RENDER_CODE_BACKEND"],
    "{{CODE_UPSTREAM}}":  os.environ["DA_RENDER_CODE_UPSTREAM"],
    "{{CODE_FORK}}":      os.environ["DA_RENDER_CODE_FORK"],
    "{{DEFAULT_BRANCH}}": os.environ["DA_RENDER_DEFAULT_BRANCH"],
}
text = open(src, encoding="utf-8").read()
for k, v in subst.items():
    text = text.replace(k, v)
open(dst, "w", encoding="utf-8").write(text)
PY

# #437: surface the analyze family in the project block. For cmake, write the
# offered analyze_timeout (default 1800 or the operator's value) so the key is
# discoverable; for a non-default family (shellcheck/none) record `analyze`. The
# key is inserted right after the `[project.<name>]` header, inside the block.
if [ "$analyze_ans" = "cmake" ]; then
  _ana_line="analyze_timeout  = ${analyze_timeout_ans}"
else
  _ana_line="analyze          = \"${analyze_ans}\""
fi
awk -v hdr="[project.$project]" -v line="$_ana_line" '
  { print }
  $0 == hdr { print line }
' "$rendered" > "$rendered.tmp" && mv "$rendered.tmp" "$rendered"

# Validate the rendered TOML before touching the real config: an answer that
# breaks TOML quoting (e.g. a literal " in a repo/path) must fail loudly here
# rather than installing a corrupt config (audit A20).
if ! python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" validate "$rendered"; then
  rm -f "$rendered"
  die "rendered config is not valid TOML (bad character in an answer?); nothing installed"
fi

if [[ ! -f "$cfg" ]]; then
  install -m 644 "$rendered" "$cfg"
else
  # Append only the project-specific blocks (skip the [defaults] header,
  # which already exists in the file).
  awk 'BEGIN{p=0} /^\[project\./{p=1} p{print}' "$rendered" >> "$cfg"
fi
rm -f "$rendered"

# #352: if the operator opted in, set `git_guard = true` in the config's [defaults]
# section. A text-edit (NOT _toml.py, which refuses to mutate the comment-bearing
# config): replace an existing git_guard line, else insert one at the end of
# [defaults]. Works for both the fresh-install and append-to-existing paths.
# shellcheck disable=SC2154  # set indirectly by ask() via `printf -v` (like the other DA_INIT_* answers)
case "$git_guard_ans" in
  [yY]|[yY][eE][sS])
    gg_tmp="$(mktemp)"
    awk '
      /^\[defaults\]/ { print; in_def=1; next }
      /^\[/ { if (in_def && !done) { print "git_guard = true"; done=1 } in_def=0; print; next }
      in_def && /^[[:space:]]*git_guard[[:space:]]*=/ { print "git_guard = true"; done=1; next }
      { print }
      END { if (in_def && !done) print "git_guard = true" }
    ' "$cfg" > "$gg_tmp" && mv "$gg_tmp" "$cfg"
    echo "git-reflex guard: ENABLED ([defaults] git_guard = true)"
    ;;
esac

state_init "$project"

info "bootstrapped $project"
info "  config:  $cfg"
info "  state:   $(state_path "$project")"
info "  secrets: $(secrets_dir)/"
info "next: run /devagent:doctor $project"
