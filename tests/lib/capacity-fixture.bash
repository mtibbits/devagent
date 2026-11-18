# tests/lib/capacity-fixture.bash
# Config builders for the capacity reader's tests (#743): tests/capacity.bats and
# tests/doctor-capacity.bats. Every builder writes $DA_HOME/config.toml, so load
# AFTER lib/bats-helpers and call setup_tmp_devagent_home first.

. "$(dirname "${BASH_SOURCE[0]}")/hermetic-env.bash"   # idempotent (#322); census: tests/lib_setup_layers.bats

# cap_config — stdin becomes the config, under a [defaults] header.
cap_config() {
  { printf '[defaults]\n'; cat; } > "$DA_HOME/config.toml"
}

# cap_config_raw — stdin is the whole config, no header added (for a top-level key
# that must come before any table).
cap_config_raw() {
  cat > "$DA_HOME/config.toml"
}

# cap_append — stdin is appended to the config.
cap_append() {
  { printf '\n'; cat; } >> "$DA_HOME/config.toml"
}

# cap_projects <name>... — one [project.<name>] table each, holding one key that is
# not capacity (source_dir), so no project is capacity-only.
cap_projects() {
  local name
  for name in "$@"; do
    printf '\n[project.%s]\nsource_dir = "%s/%s"\n' "$name" "$BATS_TEST_TMPDIR" "$name" \
      >> "$DA_HOME/config.toml"
  done
}

# cap_shared [key=<toml literal>]... [-key]... — append a [capacity] table holding the
# six required keys (20, 40, 3, 500000000, 60000000, 10), in table order. `key=` replaces
# a key in place or adds one at the end; `-key` drops one.
cap_shared() {
  local keys=(operator_hours_per_week lane_hours_per_week max_lanes tokens_per_week tokens_per_window windows_per_week)
  local -A val=([operator_hours_per_week]=20 [lane_hours_per_week]=40 [max_lanes]=3
                [tokens_per_week]=500000000 [tokens_per_window]=60000000 [windows_per_week]=10)
  local arg k i
  for arg in "$@"; do
    if [[ "$arg" == -* ]]; then
      k="${arg#-}"
      for i in "${!keys[@]}"; do [[ "${keys[$i]}" == "$k" ]] && unset 'keys[i]'; done
      keys=("${keys[@]}")
      unset 'val[$k]'
    else
      k="${arg%%=*}"
      [[ -v "val[$k]" ]] || keys+=("$k")
      val[$k]="${arg#*=}"
    fi
  done
  {
    printf '\n[capacity]\n'
    for k in "${keys[@]}"; do printf '%s = %s\n' "$k" "${val[$k]}"; done
  } >> "$DA_HOME/config.toml"
}

# cap_healthy_projects <n> — n projects (p01, p02, ...) each well-formed enough for
# doctor's per-project checks to pass: its own source and devdoc directories, and a
# state file.
cap_healthy_projects() {
  local n="$1" i name
  # shellcheck source=/dev/null
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  # shellcheck source=/dev/null
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  # shellcheck source=/dev/null
  source "$PLUGIN_ROOT/scripts/lib/state.sh"
  for (( i = 1; i <= n; i++ )); do
    printf -v name 'p%02d' "$i"
    mkdir -p "$DA_HOME/src-$name" "$DA_HOME/devdoc-$name"
    state_init "$name"
    cat >> "$DA_HOME/config.toml" <<TOML

[project.$name]
source_dir = "$DA_HOME/src-$name"
devdoc_dir = "$DA_HOME/devdoc-$name"
default_baseline = "origin/main"

[project.$name.issue_source]
backend    = "github"
repo       = "example/$name"
dir_prefix = "Issue-"

[project.$name.code_source]
backend  = "github"
upstream = "example/$name"
fork     = "fork/$name"
TOML
  done
}

# cap_doc_tables <file> — a doc home's two commented capacity tables, uncommented: each
# `# [capacity]` or `# [project.<x>.capacity]` header line and the contiguous
# `# key = value` lines under it, with the leading `# ` removed.
cap_doc_tables() {
  awk '
    /^# \[(capacity|project\.[^]]*\.capacity)\][[:space:]]*$/ { on = 1; sub(/^# /, ""); print; next }
    on && /^# [A-Za-z_]+[[:space:]]*=/ { sub(/^# /, ""); print; next }
    { on = 0 }
  ' "$1"
}
