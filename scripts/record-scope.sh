#!/usr/bin/env bash
# scripts/record-scope.sh — #268. Auto-populate $issue_dir/.devagent-scope from the
# files this issue edited, so #251's commit_autostage can stage exactly them with no
# hand-written manifest. Opt-in: runs only when commit_autostage=true. Deterministic
# (git-derived, not LLM-recalled). Fails LOUD if a genuinely-edited path is a #251
# reject vector — never silently drops it (that would stage nothing for it, the exact
# half-staged-commit hazard #251 guards). Regenerates the full edited set each run, so
# it converges across revision passes (reverted files drop out; no double-count). Will
# NOT clobber an operator-authored manifest (one lacking the auto-scope marker line).
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=lib/paths.sh
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
# shellcheck source=lib/io.sh
. "$DEVAGENT_ROOT/scripts/lib/io.sh"
# shellcheck source=lib/config.sh
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
# shellcheck source=lib/state.sh
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
# shellcheck source=lib/active.sh
. "$DEVAGENT_ROOT/scripts/lib/active.sh"

: "${DEVAGENT_GIT:=git}"

# Default to the active project when no arg, so the implement step can call us bare.
project="$(active_resolve_project "${1:-}" 2>/dev/null || true)"
[ -n "$project" ] || die "project required (no arg and no active project)"
config_is_project "$project" || die "unknown project '$project'"

# Opt-in: no-op unless commit_autostage=true (the #251 consumer flag — recording is
# pointless, and must change nothing, when autostage is off).
autostage="$(config_get_project_field "$project" commit_autostage 2>/dev/null || echo false)"
[ "$autostage" = "true" ] || exit 0

issue_dir="$(issue_context_dir "$project" 2>/dev/null || true)"
[ -d "$issue_dir" ] || die "issue_dir not set or missing"
baseline_sha="$(state_ctx_get "$project" baseline_sha 2>/dev/null || true)"
[ -n "$baseline_sha" ] || die "baseline_sha not set (run branch first)"
source_dir="$(config_get_project_field "$project" source_dir)"

scope_file="$issue_dir/.devagent-scope"
# The manifest must contain ONLY path lines: #251's autostage_in_scope reads every
# non-blank line as a path (it skips blanks but NOT '#' comments), so an in-file marker
# would be fed to `git add` and break staging. Track auto-vs-operator authorship with a
# sibling sentinel file instead.
sentinel="$scope_file.auto"

# Clobber-guard: only (re)write a manifest WE generated. A manifest present WITHOUT the
# sentinel is operator-authored → leave it untouched (auto-population augments hand
# authoring, it does not silently overwrite it).
if [ -e "$scope_file" ] && [ ! -e "$sentinel" ]; then
    warn "$scope_file is operator-authored (no auto-scope sentinel) — leaving it untouched"
    exit 0
fi

# Edited set: tracked diffs of working-tree vs baseline (committed OR uncommitted —
# `diff <baseline>` with no `..` compares baseline→worktree, so files committed in an
# earlier revision pass are still captured) ∪ new untracked files. NUL-delimited so
# special-char paths survive (no porcelain quoting / rename-arrow parsing).
declare -a raw=()
while IFS= read -r -d '' p; do raw+=("$p"); done < <(
    "$DEVAGENT_GIT" -C "$source_dir" diff --name-only -z "$baseline_sha" 2>/dev/null || true
    "$DEVAGENT_GIT" -C "$source_dir" ls-files --others --exclude-standard -z 2>/dev/null || true
)

declare -A seen=()
declare -a paths=()
for p in "${raw[@]}"; do
    [ -n "$p" ] || continue
    [ -n "${seen[$p]:-}" ] && continue
    seen[$p]=1
    # A genuinely-edited path that is a #251 reject vector must FAIL LOUD (never be
    # dropped). Mirrors commit.sh:autostage_in_scope so producer ⊆ consumer-accepts.
    case "$p" in
        -*)                    die "edited path '$p' starts with '-' (flag-injection vector) — cannot record as an in-scope entry; stage manually." ;;
        :*)                    die "edited path '$p' starts with ':' (pathspec-magic) — cannot record." ;;
        /*)                    die "edited path '$p' is absolute — cannot record." ;;
        .|..|../*|*/..|*/../*) die "edited path '$p' has parent-traversal — cannot record." ;;
        *'*'*|*'?'*|*'['*)     die "edited path '$p' contains a glob metacharacter — cannot record; stage manually." ;;
    esac
    paths+=("$p")
done

if [ "${#paths[@]}" -gt 0 ]; then
    mapfile -t paths < <(printf '%s\n' "${paths[@]}" | LC_ALL=C sort -u)
fi

# Atomic rewrite: one validated file path per line, paths only (no marker — see above).
# Full regenerate so the manifest converges on the current edited set across re-runs.
# Note: #251's reader ltrims/rtrims each line, so a pathological filename with leading/
# trailing whitespace would die loud at autostage (fail-safe — never a silent skip),
# not stage; acceptable for such exotic names.
tmp="$(mktemp)"
if [ "${#paths[@]}" -gt 0 ]; then printf '%s\n' "${paths[@]}" > "$tmp"; else : > "$tmp"; fi
mv "$tmp" "$scope_file"
: > "$sentinel"   # authorship marker (sibling file, never a path line in the manifest)
info "recorded ${#paths[@]} in-scope path(s) → $scope_file"
