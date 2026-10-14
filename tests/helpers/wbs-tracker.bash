# Shared fixtures for the `wbs update` tracker phase (#703).
#
# wbs_tracker_install_stub <dir> [<backend>...]
#   copies tests/fixtures/wbs-tracker/stub-backend.sh into <dir> as
#   <backend>.sh, by default github, gitlab and jira (point
#   DEVAGENT_ISSUE_BACKEND_DIR at <dir>).
# wbs_mr_install_stub <dir>
#   copies the same stub into <dir> as github.sh and gitlab.sh, the code
#   backends of the #704 MR phase (point DEVAGENT_CODE_BACKEND_DIR at <dir>).
# wbs_tracker_install_shims <dir> <log>
#   writes gh, glab and curl shims into <dir> that append their argv to <log>
#   and exit 99, so a real backend call is caught instead of reaching the
#   network (prepend <dir> to PATH; assert <log> is absent at teardown).

wbs_tracker_install_stub() {
  local dir="$1" b
  shift
  (( $# > 0 )) || set -- github gitlab jira
  local src
  src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/fixtures/wbs-tracker/stub-backend.sh"
  mkdir -p "$dir"
  for b in "$@"; do
    cp "$src" "$dir/$b.sh"
    chmod +x "$dir/$b.sh"
  done
}

wbs_mr_install_stub() {
  wbs_tracker_install_stub "$1" github gitlab
}

wbs_tracker_install_shims() {
  local dir="$1" log="$2" c
  mkdir -p "$dir"
  for c in gh glab curl; do
    printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "%s"\nexit 99\n' \
      "$c" "$log" > "$dir/$c"
    chmod +x "$dir/$c"
  done
}
