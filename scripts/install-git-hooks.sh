#!/usr/bin/env bash
# scripts/install-git-hooks.sh — opt-in installer for the repo's local git hooks (#250).
#
# Points git at the tracked .githooks/ directory via core.hooksPath, enabling the
# pre-push SC2314 bats gate (a local mirror of .github/workflows/shellcheck.yml).
# Opt-in by design: a fresh clone runs no hooks until a contributor runs this.
# Tracked hooks update with the repo; no per-hook copy to keep in sync.
#
# Enable:   scripts/install-git-hooks.sh
# Disable:  git config --unset core.hooksPath
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if [ ! -d .githooks ]; then
  echo "install-git-hooks: no .githooks/ directory in $repo_root — nothing to install." >&2
  exit 1
fi

git config core.hooksPath .githooks
echo "git hooks enabled: core.hooksPath -> .githooks"
echo "  pre-push now runs the SC2314 bats gate locally (mirrors CI)."
echo "  disable with: git config --unset core.hooksPath"
echo "  bypass once with: git push --no-verify"
