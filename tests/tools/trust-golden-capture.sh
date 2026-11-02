#!/usr/bin/env bash
# Re-capture the #713 no-policy goldens (tests/fixtures/trust-golden/).
#
# Usage: bash tests/tools/trust-golden-capture.sh
#
# Runs tests/trust-golden.bats in capture mode: each comparison test writes its
# fixture instead of diffing, stamped `captured-at <HEAD>` on line 1. Refuses
# when scripts/ differs from HEAD, so the stamp always names the code that
# produced the output. Capture in the WSL clone (the suite's home); see the
# header of tests/trust-golden.bats for when a re-capture is legitimate.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
if ! git diff --quiet HEAD -- scripts || [ -n "$(git ls-files --others --exclude-standard scripts)" ]; then
  echo "trust-golden-capture: scripts/ differs from HEAD; commit or stash first so the stamp names the code" >&2
  exit 1
fi
sha="$(git rev-parse HEAD)"
mkdir -p tests/fixtures/trust-golden
TRUST_GOLDEN_CAPTURE_SHA="$sha" bats tests/trust-golden.bats < /dev/null
echo "trust-golden-capture: wrote tests/fixtures/trust-golden/ at $sha"
