#!/usr/bin/env bash
# tests/tools/no-superpowers-session.sh — run a devAgent session with the superpowers
# plugin ABSENT, scoped to this invocation only (#585).
#
# Why this exists: Issue-541 made superpowers RECOMMENDED, not required, and gave
# draft/implement/review built-in fallbacks — but the only evidence was three
# per-wrapper smokes run inside a GLOBAL `claude plugin disable` window with a
# `trap … EXIT` restore. That shape mutates the operator's environment, is not safely
# repeatable, and could not carry a full traversal.
#
# Mechanism (measured — analysis/2026-08-27-draft-probes.md P1, CLI 2.1.211):
# `--settings` with an `enabledPlugins` map MERGES per key. Setting the one superpowers
# key false removed exactly its 14 slash commands (120 -> 106) and left devagent's 58,
# code-review and frontend-design untouched. No global state changes, so there is
# nothing to restore and no failure mode where a crashed run leaves the operator's
# plugins disabled.
#
# The emitted map names ONLY the superpowers key. Listing the others would freeze a
# snapshot of one machine's plugin set into a committed tool.
#
# The result is version-bound: a CLI that changes enabledPlugins merge semantics under
# --settings falsifies the mechanism. Re-run the P1 discriminator (the system/init
# event's slash_commands array under --output-format stream-json --verbose) after a
# CLI upgrade. Never ask the model whether a skill is available — probe P1a measured
# that answer as identical with and without the flag.
#
# Usage:
#   no-superpowers-session.sh --emit-settings <path>      # write the JSON, exit 0
#   no-superpowers-session.sh [claude args…]              # exec claude with it
#   no-superpowers-session.sh --emit-settings <path> [claude args…]
#
# Examples:
#   no-superpowers-session.sh                             # interactive traversal session
#                                                         # (ZERO args LAUNCHES; only
#                                                         #  --emit-settings ALONE emits)
#   no-superpowers-session.sh -p --output-format stream-json --verbose --max-turns 1 hi
set -euo pipefail

SP_KEY='superpowers@claude-plugins-official'
settings=""
emit_only=0

if [ "${1:-}" = --emit-settings ]; then
  [ $# -ge 2 ] || { echo "no-superpowers-session.sh: --emit-settings needs a path" >&2; exit 2; }
  settings="$2"; shift 2
  mkdir -p "$(dirname "$settings")"
  # Emit-only means `--emit-settings <path>` was the WHOLE invocation. Keying on
  # `$# -eq 0` alone would make a bare invocation — the command that runs the whole
  # traversal — print a path and exit 0 without ever launching claude.
  [ $# -eq 0 ] && emit_only=1
else
  # FIXED name, not `mktemp`: this script `exec`s, so no trap can ever clean up, and a
  # per-invocation temp file would accumulate forever under a header that advertises
  # having nothing to restore. One file, overwritten each run.
  settings="${TMPDIR:-/tmp}/no-superpowers-session.json"
fi

# Write atomically. The default path is fixed and shared, so two concurrent launches
# (or `bats -j`) would otherwise race; identical content makes the race benign but a
# reader could still see a partial file.
printf '{"enabledPlugins":{"%s":false}}\n' "$SP_KEY" > "$settings.tmp.$$"
mv -f "$settings.tmp.$$" "$settings"

[ "$emit_only" -eq 1 ] && { echo "$settings"; exit 0; }

# A missing CLI must refuse loudly. Without this the exec below exits 127, and a caller
# under `|| true` reads that as a session that simply found nothing (#316) — the same
# class as a negative assertion satisfied by an absent function.
command -v claude >/dev/null 2>&1 \
  || { echo "no-superpowers-session.sh: no \`claude\` on PATH — refusing (a 127 here is indistinguishable from an empty session)" >&2; exit 127; }

exec claude --settings "$settings" "$@"
