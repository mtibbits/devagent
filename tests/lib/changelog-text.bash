# tests/lib/changelog-text.bash — the one reader of devAgent's changelog entries (#1127).
#
# A changelog entry lives in changelog.d/<key>.md until a release moves it into
# CHANGELOG.md (scripts/changelog.py). A test that reads entries reads them through
# changelog_text, so its pin passes before and after the release that moves the entry
# (CONTRIBUTING.md). A pin on an entry already in a dated section may read CHANGELOG.md
# directly: released entries never move again.
#
# changelog_text <root>: <root>/CHANGELOG.md, then each regular, non-symlink
# <root>/changelog.d/*.md in glob (byte) order, each ending in a newline.
# A missing changelog.d/ reads as empty; a missing CHANGELOG.md fails.
#
# The universe is the filesystem listing, as scripts/changelog.py's is: an entry file
# counts whether or not it is committed yet.
#
# Consumers: capture with a declared-then-assigned variable
#     local cl; cl="$(changelog_text "$REPO")"
# or redirect to a file. Never pipe it into `grep -q`: grep exits at the first match,
# the helper's next write dies of SIGPIPE, and pipefail reports that as a failure.
#
# Source it with `. "${BATS_TEST_DIRNAME}/lib/changelog-text.bash"`, never `load`: it is
# a pure function layer with no setup, so it does not source hermetic-env.bash itself,
# and tests/lib_setup_layers.bats's canary for `load`-ed setup layers does not apply.

changelog_text() {
  local f LC_ALL=C   # byte order for the glob, whatever the caller's locale
  _changelog_cat "$1/CHANGELOG.md" || return 1
  for f in "$1"/changelog.d/*.md; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    _changelog_cat "$f" || return 1
  done
}

# _changelog_cat <file>: the file's bytes, plus a newline when they do not end in one.
_changelog_cat() { cat -- "$1" || return 1; [ -z "$(tail -c 1 -- "$1")" ] || printf '\n'; }
