#!/usr/bin/env bats

bats_require_minimum_version 1.5.0   # #803: run --separate-stderr for wbs_order_config

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  install_fixture_config config-twoproject.toml
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
}

teardown() { teardown_tmp_devagent_home; }

@test "config_load passes on a good file" {
  run config_load
  [ "$status" -eq 0 ]
}

@test "config_load dies on a missing file" {
  rm "$DA_HOME/config.toml"
  run config_load
  [ "$status" -ne 0 ]
}

@test "config_get reads a default" {
  run config_get defaults.checklist_template
  [ "$status" -eq 0 ]
  [ "$output" = "standard" ]
}

@test "config_get_project_field reads a nested field" {
  run config_get_project_field volk issue_source.repo
  [ "$status" -eq 0 ]
  [ "$output" = "gnuradio/volk" ]
}

@test "config_list_projects lists both" {
  run config_list_projects
  [ "$status" -eq 0 ]
  [[ "$output" == *"volk"* ]]
  [[ "$output" == *"toy"*  ]]
}

@test "config_is_project true/false" {
  run config_is_project volk
  [ "$status" -eq 0 ]
  run config_is_project nope
  [ "$status" -ne 0 ]
}

@test "config_active_project dies on multi-project file" {
  run config_active_project
  [ "$status" -ne 0 ]
}

@test "config_active_project echoes the one project on single-project file" {
  install_fixture_config config-onproject.toml
  run config_active_project
  [ "$status" -eq 0 ]
  [ "$output" = "volk" ]
}

@test "config_require_project lists projects and suggests init on unknown" {
  run config_require_project nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found in config.toml"* ]]
  [[ "$output" == *"configured projects:"* ]]
  [[ "$output" == *"/devagent:init nonexistent"* ]]
}

@test "config_require_project says 'did you mean' with one configured project" {
  install_fixture_config config-onproject.toml
  run config_require_project typo
  [ "$status" -eq 1 ]
  [[ "$output" == *"did you mean 'volk'"* ]]
}

@test "config_require_project returns 0 for a known project" {
  run config_require_project volk
  [ "$status" -eq 0 ]
}

# --- #82: tilde expansion ---------------------------------------------------

@test "expand_tilde: ~/x -> \$HOME/x [#82]" {
  run expand_tilde '~/x'
  [ "$output" = "$HOME/x" ]
}
@test "expand_tilde: bare ~ -> \$HOME [#82]" {
  run expand_tilde '~'
  [ "$output" = "$HOME" ]
}
@test "expand_tilde: ~root/x -> root's passwd home + /x (not \${HOME}root) [#82]" {
  local rh; rh="$(getent passwd root | cut -d: -f6)"
  run expand_tilde '~root/x'
  [ "$output" = "${rh}/x" ]
}
@test "expand_tilde: unknown user left untouched, never mangled [#82]" {
  run expand_tilde '~no_such_user_zzq/x'
  [ "$output" = '~no_such_user_zzq/x' ]
}
@test "expand_tilde: absolute path untouched [#82]" {
  run expand_tilde '/a/b'
  [ "$output" = '/a/b' ]
}
@test "expand_tilde: mid-string tilde untouched (only leading) [#82]" {
  run expand_tilde '/a/~b'
  [ "$output" = '/a/~b' ]
}

@test "config_get_project_field expands ~ in a path field (devdoc_dir) [#82]" {
  run config_get_project_field volk devdoc_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/src/devDoc/volk" ]   # fixture has '~/src/devDoc/volk'
}
@test "config_get_project_field expands ~ in source_dir too [#82]" {
  run config_get_project_field volk source_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/src/volk" ]
}
@test "config_get_project_field does NOT expand a non-path field [#82]" {
  run config_get_project_field volk default_baseline
  [ "$status" -eq 0 ]
  [ "$output" = "origin/main" ]             # git ref, untouched
}

# --- #246: public project_devdoc_dir resolver (moved here from depends.sh) ---
# Sourcing ONLY the config trio (paths/io/config, per setup) proves the resolver
# genuinely lives in config.sh — not depends.sh. Preserves the #78 fail-loud +
# DEVAGENT_TEST_DEVDOC behavior. Hermetic bash -c with its own DA_HOME.

@test "project_devdoc_dir resolves from config via config.sh alone [#246]" {
  local tmp_home; tmp_home="$(mktemp -d)"
  mkdir -p "${tmp_home}/devdoc-target"
  printf '[project.cfgproj]\ndevdoc_dir = "%s/devdoc-target"\n' "${tmp_home}" > "${tmp_home}/config.toml"
  run env -u DEVAGENT_TEST_DEVDOC DA_HOME="${tmp_home}" bash -c \
    "source '$PLUGIN_ROOT/scripts/lib/paths.sh'; source '$PLUGIN_ROOT/scripts/lib/io.sh'; source '$PLUGIN_ROOT/scripts/lib/config.sh'; project_devdoc_dir cfgproj"
  local expected="${tmp_home}/devdoc-target"
  rm -rf "${tmp_home}"
  [ "$status" -eq 0 ]
  [ "$output" = "${expected}" ]
}

@test "project_devdoc_dir honors DEVAGENT_TEST_DEVDOC override [#246]" {
  run env DEVAGENT_TEST_DEVDOC=/tmp/devdoc-override-xyz bash -c \
    "source '$PLUGIN_ROOT/scripts/lib/paths.sh'; source '$PLUGIN_ROOT/scripts/lib/io.sh'; source '$PLUGIN_ROOT/scripts/lib/config.sh'; project_devdoc_dir anyproj"
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/devdoc-override-xyz" ]
}

@test "project_devdoc_dir dies loudly when devdoc_dir cannot be resolved [#246/#78]" {
  local tmp_home; tmp_home="$(mktemp -d)"
  printf '[project.otherproj]\ndevdoc_dir = "%s/x"\n' "${tmp_home}" > "${tmp_home}/config.toml"
  run env -u DEVAGENT_TEST_DEVDOC DA_HOME="${tmp_home}" bash -c \
    "source '$PLUGIN_ROOT/scripts/lib/paths.sh'; source '$PLUGIN_ROOT/scripts/lib/io.sh'; source '$PLUGIN_ROOT/scripts/lib/config.sh'; project_devdoc_dir missingproj"
  rm -rf "${tmp_home}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot resolve devdoc_dir"* ]]
}

@test "project_devdoc_dir dies loudly when devdoc_dir resolves empty [#246/#78]" {
  local tmp_home; tmp_home="$(mktemp -d)"
  printf '[project.emptyproj]\ndevdoc_dir = ""\n' > "${tmp_home}/config.toml"
  run env -u DEVAGENT_TEST_DEVDOC DA_HOME="${tmp_home}" bash -c \
    "source '$PLUGIN_ROOT/scripts/lib/paths.sh'; source '$PLUGIN_ROOT/scripts/lib/io.sh'; source '$PLUGIN_ROOT/scripts/lib/config.sh'; project_devdoc_dir emptyproj"
  rm -rf "${tmp_home}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"resolved empty"* ]]
}

# --- #611: global [paths] + _toml.py get-list -------------------------------

@test "_toml.py get-list prints one element per line; rc 3 on a non-array; rc 1 missing [#611]" {
  f="$BATS_TEST_TMPDIR/c.toml"
  printf '[project.p.paths]\npotholes_domain_nouns = ["law", "matter id"]\npotholes = "x.md"\n' > "$f"
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get-list "$f" project.p.paths.potholes_domain_nouns
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "law" ]
  [ "${lines[1]}" = "matter id" ]
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get-list "$f" project.p.paths.potholes
  [ "$status" -eq 3 ]
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get-list "$f" project.p.paths.nope
  [ "$status" -eq 1 ]
}

@test "config_get_global_path reads [paths] with tilde expansion; rc 1 when absent [#611]" {
  printf '[paths]\npotholes_workflow = "~/wf.md"\n' > "$DA_HOME/config.toml"
  run config_get_global_path potholes_workflow
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/wf.md" ]
  printf '[defaults]\n' > "$DA_HOME/config.toml"
  run config_get_global_path potholes_workflow
  [ "$status" -ne 0 ]
}

@test "_toml.py get-list refuses an element holding a line break (rc 3), and a plain list still reads [#654]" {
  f="$BATS_TEST_TMPDIR/n.toml"
  printf '[project.p]\nevidence_platforms = ["os=Linux\\nfs=ext4"]\nok = ["a", "b"]\n' > "$f"
  grep -qF 'os=Linux\nfs=ext4' "$f"                  # the TOML carries the escape, not a newline
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get-list "$f" project.p.evidence_platforms
  [ "$status" -eq 3 ]
  [[ "$output" == *"line break"* ]]
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" get-list "$f" project.p.ok
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "b" ]
}

# _wbs_cfg <toml lines>: a fresh fixture config plus a [project.toy.wbs] table.
_wbs_cfg() {
  install_fixture_config config-twoproject.toml
  printf '\n[project.toy.wbs]\n%s\n' "$1" >> "$DA_HOME/config.toml"
}

@test "wbs_order_config: defaults, true/false, an invalid value, an unknown key (#803)" {
  run --separate-stderr wbs_order_config toy 'wbs order'
  [ "$status" -eq 0 ]
  [ "$output" = "WBS_ORDER=1 WBS_COMPLETED_LAST=0" ]
  [ "$stderr" = "" ]

  _wbs_cfg $'order_on_update = false\ncompleted_last = true'
  run --separate-stderr wbs_order_config toy 'wbs order'
  [ "$status" -eq 0 ]
  [ "$output" = "WBS_ORDER=0 WBS_COMPLETED_LAST=1" ]
  [ "$stderr" = "" ]

  _wbs_cfg 'order_on_update = "maybe"'
  run --separate-stderr wbs_order_config toy 'wbs order'
  [ "$status" -eq 3 ]
  [ "$output" = "WBS_ORDER=1 WBS_COMPLETED_LAST=0" ]
  [ "$stderr" = "wbs order: [project.toy.wbs] order_on_update must be true or false, got 'maybe'" ]

  _wbs_cfg $'completed_last = 1\norder_on_update = false'
  run --separate-stderr wbs_order_config toy 'wbs update' '; ordering skipped'
  [ "$status" -eq 3 ]
  [ "$output" = "WBS_ORDER=0 WBS_COMPLETED_LAST=0" ]
  [ "$stderr" = "wbs update: [project.toy.wbs] completed_last must be true or false, got '1'; ordering skipped" ]

  _wbs_cfg $'order_on_updates = false\nauto_import_below_pct = 30'
  run --separate-stderr wbs_order_config toy 'wbs update'
  [ "$status" -eq 0 ]
  [ "$output" = "WBS_ORDER=1 WBS_COMPLETED_LAST=0" ]
  [ "$stderr" = "wbs update: [project.toy.wbs] unknown key 'order_on_updates' ignored" ]
}

@test "#1016 code_backend_is_local takes only the exact name local, CR stripped" {
  local n=0 v
  for v in local $'local\r'; do
    run code_backend_is_local "$v"; [ "$status" -eq 0 ] || { echo "'$v': $status" >&2; false; }; n=$((n + 1))
  done
  for v in Local LOCAL github '' locale ' local'; do
    run code_backend_is_local "$v"; [ "$status" -eq 1 ] || { echo "'$v': $status" >&2; false; }; n=$((n + 1))
  done
  [ "$n" -eq 8 ]
}

@test "#1016 config_code_is_local reads code_source.backend, and a missing key is quietly not local" {
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/config.toml" project.volk.code_source.backend '"local"'
  run --separate-stderr config_code_is_local volk
  [ "$status" -eq 0 ]
  run --separate-stderr config_code_is_local nosuch
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  # Under set -e the absent key neither kills the caller nor prints.
  run --separate-stderr bash -c 'set -euo pipefail; . "$1/scripts/lib/paths.sh"; . "$1/scripts/lib/io.sh"; . "$1/scripts/lib/config.sh"
    if config_code_is_local nosuch; then echo local; else echo other; fi' _ "$PLUGIN_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = other ]
  [ -z "$stderr" ]
}

# #1050: the worktree-root shapes (projects a-g), for the trust pin.
_worktree_config() {
  cat > "$DA_HOME/config.toml" <<'TOML'
[project.a]
devdoc_dir = "/d/a"
source_dir = "/s/a"
worktree_root = "/w/a"

[project.b]
source_dir = "/s/b"

[project.c]
source_dir = "/s/c"
worktree_root = ""

[project.d]
devdoc_dir = "/d/d"

[project.e]
worktree_root = ""

[project.f]
source_dir = "~/s/f"

[project.g]
devdoc_dir = "/d/g"
TOML
}

@test "worktree_root_rule: set, unset or empty, no source_dir (#1050)" {
  local wt src want
  while IFS='|' read -r wt src want; do
    run --separate-stderr worktree_root_rule "$wt" "$src"
    echo "[$wt|$src]: status=$status output=[$output] stderr=[$stderr]"
    [ "$status" -eq 0 ]
    [ "$output" = "$want" ]
    [ -z "$stderr" ]
  done <<'ROWS'
/w/a|/s/a|/w/a
/w/x||/w/x
|/s/b|/s/b-wt
ROWS
  run --separate-stderr worktree_root_rule "" ""
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "_trust_forbid_roots output is unchanged by worktree_root_rule (#1050)" {
  _worktree_config
  source "$PLUGIN_ROOT/scripts/lib/trust.sh"
  run _trust_forbid_roots
  [ "$status" -eq 0 ]
  local want
  want="$(printf '%s\n' --forbid "$DA_HOME" --forbid "$PLUGIN_ROOT" \
    --forbid /d/a --forbid /s/a --forbid /w/a \
    --forbid /s/b --forbid /s/b-wt \
    --forbid /s/c --forbid /s/c-wt \
    --forbid /d/d \
    --forbid "$HOME/s/f" --forbid "$HOME/s/f-wt" \
    --forbid /d/g)"
  diff <(printf '%s\n' "$output") <(printf '%s\n' "$want")
}

# --- #966: the leak gate's two user-level keys --------------------------------
# auto_post_owners (a top-level array) and [paths] denylist_path are read from
# the top level of the user config only; a [project.<name>] copy is never read.

@test "config_get_global_list: prints a top-level array, one element per line" {
  printf 'auto_post_owners = ["github:acme", "gitlab:grp/sub"]\n\n[defaults]\n' > "$DA_HOME/config.toml"
  run --separate-stderr config_get_global_list auto_post_owners
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "github:acme" ]
  [ "${lines[1]}" = "gitlab:grp/sub" ]
}

@test "config_get_global_list: absent is 1, a string or mixed array is 3, a broken config is 2" {
  printf '[defaults]\n' > "$DA_HOME/config.toml"
  run --separate-stderr config_get_global_list auto_post_owners
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  printf 'auto_post_owners = "github:acme"\n' > "$DA_HOME/config.toml"
  run --separate-stderr config_get_global_list auto_post_owners
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  printf 'auto_post_owners = ["github:acme", 7]\n' > "$DA_HOME/config.toml"
  run --separate-stderr config_get_global_list auto_post_owners
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  printf 'auto_post_owners = [\n' > "$DA_HOME/config.toml"
  run --separate-stderr config_get_global_list auto_post_owners
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  rm "$DA_HOME/config.toml"
  run --separate-stderr config_get_global_list auto_post_owners
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "config_get_global_list: a [project.<name>] key of the same name is not read" {
  printf '[project.p]\nauto_post_owners = ["github:acme"]\n' > "$DA_HOME/config.toml"
  run --separate-stderr config_get_global_list auto_post_owners
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # a dotted key would walk into a table: refused, never read.
  run --separate-stderr config_get_global_list project.p.auto_post_owners
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "config_get_global_path denylist_path: only the top-level [paths] table" {
  printf '[project.p.paths]\ndenylist_path = "/proj/list.txt"\n' > "$DA_HOME/config.toml"
  run --separate-stderr config_get_global_path denylist_path
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  printf '[paths]\ndenylist_path = "~/user/list.txt"\n\n[project.p.paths]\ndenylist_path = "/proj/list.txt"\n' > "$DA_HOME/config.toml"
  run --separate-stderr config_get_global_path denylist_path
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/user/list.txt" ]
}

@test "skel: both gate keys are commented in place and read back once uncommented" {
  local skel="$PLUGIN_ROOT/templates/config.toml.skel" owners defaults paths_hdr deny archive
  owners="$(grep -n -m1 -xF '# auto_post_owners = ["github:<login>"]' "$skel" | cut -d: -f1)"
  defaults="$(grep -n -m1 -xF '[defaults]' "$skel" | cut -d: -f1)"
  [ -n "$owners" ] && [ -n "$defaults" ]
  [ "$owners" -lt "$defaults" ]
  # the comment above the key says where it must sit.
  sed -n "1,${owners}p" "$skel" | grep -qF 'TOP-LEVEL'
  sed -n "1,${owners}p" "$skel" | grep -qF 'ignored under any table header'
  # denylist_path sits in the commented [paths] block, before the next block.
  paths_hdr="$(grep -n -m1 -E '^# \[paths\]' "$skel" | cut -d: -f1)"
  deny="$(grep -n -m1 -xF '# denylist_path = "~/.config/denylist.txt"' "$skel" | cut -d: -f1)"
  archive="$(grep -n -m1 -E '^# \[archive\]' "$skel" | cut -d: -f1)"
  [ -n "$paths_hdr" ] && [ -n "$deny" ] && [ -n "$archive" ]
  [ "$paths_hdr" -lt "$deny" ] && [ "$deny" -lt "$archive" ]
  [ -z "$(sed -n "${paths_hdr},${deny}p" "$skel" | grep -vE '^#')" ]   # one unbroken comment block
  # A rendered copy with both keys (and the [paths] header) uncommented is valid
  # TOML, and the two readers return the samples.
  sed -e 's/{{[A-Z_]*}}/x/g' \
      -e 's/^# \(auto_post_owners = \)/\1/' \
      -e 's/^# \(\[paths\]\)/\1/' \
      -e 's/^# \(denylist_path = \)/\1/' "$skel" > "$DA_HOME/config.toml"
  run python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" validate "$DA_HOME/config.toml"
  [ "$status" -eq 0 ]
  run --separate-stderr config_get_global_list auto_post_owners
  [ "$status" -eq 0 ]
  [ "$output" = "github:<login>" ]
  run --separate-stderr config_get_global_path denylist_path
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.config/denylist.txt" ]
}
