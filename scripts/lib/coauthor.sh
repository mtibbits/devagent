#!/usr/bin/env bash
# scripts/lib/coauthor.sh — strip Co-Authored-By trailer lines from a file in
# place. Used by commit.sh (step 12) and ship.sh (step 18) when a project sets
# include_coauthor = false (issue #31).
#
# Preserves Signed-off-by (DCO) and all other content. Matches the git trailer
# case-insensitively via GNU sed's `I` address flag (same precedent as
# commit.sh's "(1M context)" strip), tolerating optional leading whitespace.
#
# Known limitation (issue #31): line-based — also removes a Co-Authored-By line
# that happens to appear inside a fenced code block (e.g. an example commit
# message embedded in a PR body). Acceptable for the opt-out projects, which
# don't put such examples in their bodies.
#
# Requires io.sh sourced (for die).

strip_coauthor() {
    local file="$1"
    [ -n "$file" ] || die "strip_coauthor: file path required"
    [ -f "$file" ] || die "strip_coauthor: no such file: $file"
    sed -i '/^[[:space:]]*co-authored-by:/Id' "$file"
}
