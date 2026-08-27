#!/usr/bin/env bash
# scripts/lib/potholes.sh — #611 two-layer pothole register.
#
# bash >= 4.4: namerefs (local -n) and empty-array expansion under set -u. The
# resolver sources this lib unconditionally, so the floor is plugin-wide
# (README states it); fail with the cause named rather than a cryptic
# `local: -n: invalid option` from inside a sourced lib.
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  echo "potholes.sh: bash >= 4.4 required (found ${BASH_VERSION}) — devAgent's scripts need a modern bash (Git Bash, WSL and Linux all provide 5.x)" >&2
  return 1 2>/dev/null || exit 1
fi
# Requires template_resolve.sh (which sources paths/io/config) sourced FIRST;
# template_resolve.sh sources this file at its end, so any consumer of the
# resolver gets these for free.
#
# Layers, in READ order (the first copy of a deduped line wins):
#   seed      <plugin>/templates/potholes.md — public, never written by the workflow
#   workflow  [project.<p>.paths].potholes_workflow, else global [paths].potholes_workflow
#             — private, shared by every project; cites (<project> Issue-N)
#   project   [project.<p>.paths].potholes, else <devdoc_dir>/templates/potholes.md
#             — private, one per project; cites (Issue-N)
# "Present" = the file exists AND is non-empty (-s, not -f: a zero-byte file
# would desynchronise the awk FNR==1 layer markers in potholes_show_union).
# The workflow/project paths are printed even when the file does not exist
# yet: promote-potholes.sh --apply bootstraps them.

# Citation grammar, in ONE place. POTHOLES_CITE_TAIL_RE strips a trailing
# citation (sed -E); potholes_cite_re builds the layer-aware match: the SHARED
# workflow file must carry the project token (a bare (Issue-42) moved there by
# the distribute capture would otherwise satisfy EVERY project's Issue-42), and
# so must the SEED for every project except the one whose source_dir IS the
# plugin — the seed's 60 bare (Issue-N) citations are that project's own
# history and would otherwise satisfy any project's Issue-N (red-team #611).
# The project layer and temp files accept the bare form.
# shellcheck disable=SC2034  # consumed by scripts that source this lib (promote-potholes.sh _body)
POTHOLES_CITE_TAIL_RE=' *\(([A-Za-z0-9_-]+ )?Issue-[A-Za-z0-9-]+\)\.$'
_POTHOLES_OWNER_MEMO=""   # "<project>=yes|no"
_potholes_owns_seed() {   # <project> — is the project's source_dir the plugin root?
  local sd
  if [ -n "$_POTHOLES_OWNER_MEMO" ] && [ "${_POTHOLES_OWNER_MEMO%%=*}" = "$1" ]; then
    [ "${_POTHOLES_OWNER_MEMO#*=}" = yes ]; return
  fi
  sd="$(config_get_project_field "$1" source_dir 2>/dev/null || true)"
  if [ -n "$sd" ] && [ -d "$sd" ] && [ "$(cd "$sd" && pwd -P)" = "$(cd "$(plugin_root)" && pwd -P)" ]; then
    _POTHOLES_OWNER_MEMO="$1=yes"; return 0
  fi
  _POTHOLES_OWNER_MEMO="$1=no"; return 1
}
potholes_cite_re() {   # <project> <issue_id> <layer>
  case "$3" in
    workflow) printf '\\(%s %s\\)\n' "$1" "$2" ;;
    seed)     if _potholes_owns_seed "$1"; then printf '\\((%s )?%s\\)\n' "$1" "$2"; else printf '\\(%s %s\\)\n' "$1" "$2"; fi ;;
    *)        printf '\\((%s )?%s\\)\n' "$1" "$2" ;;
  esac
}

potholes_seed_path() { printf '%s\n' "$(template_plugin_dir)/potholes.md"; }

# The workflow/project paths cost 1-2 config reads (python3 spawns) each, and
# one script run asks for them several times — memoised per project. The memo
# runs in the CALLER's shell (never inside a `$( )` or `< <( )`), so a lookup
# failure dies loudly here instead of vanishing with a subshell (#611 review).
_POTHOLES_MEMO_PROJECT=""; _POTHOLES_MEMO_WF=""; _POTHOLES_MEMO_PR=""
_potholes_memo() {
  local project="$1" d
  [ "$_POTHOLES_MEMO_PROJECT" = "$project" ] && [ -n "$_POTHOLES_MEMO_PROJECT" ] && return 0
  _POTHOLES_MEMO_WF="$(template_project_paths_override "$project" potholes_workflow)" \
    || die "potholes: workflow register lookup failed for '$project' — see above"
  _POTHOLES_MEMO_PR="$(template_project_paths_override "$project" potholes)" \
    || die "potholes: project register lookup failed for '$project' — see above"
  if [ -z "$_POTHOLES_MEMO_PR" ]; then
    d="$(template_devdoc_dir "$project")"
    [ -n "$d" ] && _POTHOLES_MEMO_PR="${d%/}/templates/potholes.md"
  fi
  _POTHOLES_MEMO_PROJECT="$project"
}
potholes_workflow_path() { _potholes_memo "$1"; printf '%s\n' "$_POTHOLES_MEMO_WF"; }
potholes_project_path()  { _potholes_memo "$1"; printf '%s\n' "$_POTHOLES_MEMO_PR"; }

# potholes_layer_files <project> — "<layer> <path>" per PRESENT file, seed first.
potholes_layer_files() {
  local project="$1" s
  _potholes_memo "$project"
  s="$(potholes_seed_path)"; [ -s "$s" ] && printf 'seed %s\n' "$s"
  [ -n "$_POTHOLES_MEMO_WF" ] && [ -s "$_POTHOLES_MEMO_WF" ] && printf 'workflow %s\n' "$_POTHOLES_MEMO_WF"
  [ -n "$_POTHOLES_MEMO_PR" ] && [ -s "$_POTHOLES_MEMO_PR" ] && printf 'project %s\n' "$_POTHOLES_MEMO_PR"
  return 0
}

# _potholes_layers_into <project> <layers-array> <paths-array> — fill two
# parallel arrays (layer names, paths) with the PRESENT layers, seed first.
_potholes_layers_into() {
  local project="$1" line
  local -n _l="$2" _p="$3"
  _l=(); _p=()
  _potholes_memo "$project"          # in THIS shell, before the process substitution below
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _l+=("${line%% *}"); _p+=("${line#* }")
  done < <(potholes_layer_files "$project")
}

# potholes_union_headings <project> — every '## ' heading across the present layers.
potholes_union_headings() {
  local -a _layers files
  _potholes_layers_into "$1" _layers files
  [ "${#files[@]}" -gt 0 ] || return 0
  grep -h '^## ' -- "${files[@]}" | sort -u
}

# potholes_cited_union <project> <issue_id> [file…] — does ANY present layer (or an
# extra file, e.g. a temp copy about to be written, matched with the bare-form
# grammar) cite the issue? Closing paren load-bearing (Issue-1 must not match
# Issue-10)); the per-layer grammar is potholes_cite_re's.
potholes_cited_union() {
  local project="$1" issue_id="$2"; shift 2
  local -a files=("$@") lnames=() layers paths
  [ "${#files[@]}" -eq 0 ] || lnames=("${files[@]/*/extra}")   # every extra file uses the bare-form grammar
  _potholes_layers_into "$project" layers paths
  files+=("${paths[@]}"); lnames+=("${layers[@]}")
  local i
  for i in "${!files[@]}"; do
    [ -s "${files[i]}" ] || continue
    grep -qiE -- "$(potholes_cite_re "$project" "$issue_id" "${lnames[i]}")" "${files[i]}" && return 0
  done
  return 1
}

# potholes_show_union <project> — seed + workflow + project. '# layer:' markers
# ONLY when >1 layer is present (rc 1 and no output otherwise, so template_show
# falls back to the single-layer form — byte-identical to pre-#611 output).
# Bullets are deduped by their citation-STRIPPED text: the seed cites (Issue-N)
# where the workflow layer cites (<project> Issue-N) for the same lesson.
potholes_show_union() {
  local project="$1"
  local -a layers paths
  _potholes_layers_into "$project" layers paths
  [ "${#paths[@]}" -gt 1 ] || return 1
  printf '# === template potholes (layers=%s) ===\n' "$(IFS=,; printf '%s' "${layers[*]}")"
  LAYERS="${layers[*]}" awk '
    BEGIN { split(ENVIRON["LAYERS"], L, " ") }
    FNR == 1 { i++; if (i > 1) print ""; printf "# layer: %s\n# source: %s\n\n", L[i], FILENAME }
    /^- / {
      k = $0
      sub(/ *\(([A-Za-z0-9_-]+ )?Issue-[A-Za-z0-9-]+\)\.$/, "", k)
      if (k in seen) next
      seen[k] = 1
    }
    { print }' "${paths[@]}"
}

# Fixture-list parsers shared by doctor and the suite canary (one grammar):
# '#' comments, one '# public: <name>…' allowlist line, one private name per line.
potholes_fixture_private_names() { grep -v '^#' "$1" | sed '/^[[:space:]]*$/d'; }
potholes_fixture_public()        { sed -n 's/^# public: *//p' "$1"; }

# potholes_private_name_hits <seed> <name>… — ONE predicate shared by the suite
# canary (tests/potholes-seed-canary.bats) and doctor (register: a guard and its
# probe share a predicate, Issue-585). Prints "<name> citations=<n> words=<m>"
# per name with any hit; rc 1 iff any. Case-insensitive; the citation form
# "(<name> Issue-" is primary, a word-bounded bare mention secondary. The public
# allowlist is the CALLER's filter — this predicate knows nothing of it.
potholes_private_name_hits() {
  local seed="$1"; shift
  local name c w rc=0 grc
  for name in "$@"; do
    # grep -c: rc 0 hits, rc 1 none (prints 0), rc >= 2 could not run — the
    # last must never read as "clean" (Issue-316). -F on both: names are
    # literals, never patterns.
    grc=0; c="$(grep -ciF -- "(${name} Issue-" "$seed")" || grc=$?
    [ "$grc" -le 1 ] || { echo "potholes_private_name_hits: cannot read $seed (grep rc $grc)" >&2; return 2; }
    grc=0; w="$(grep -ciwF -- "${name}" "$seed")" || grc=$?
    [ "$grc" -le 1 ] || { echo "potholes_private_name_hits: cannot read $seed (grep rc $grc)" >&2; return 2; }
    if [ "${c:-0}" -gt 0 ] || [ "${w:-0}" -gt 0 ]; then
      printf '%s citations=%s words=%s\n' "$name" "$c" "$w"; rc=1
    fi
  done
  return $rc
}
