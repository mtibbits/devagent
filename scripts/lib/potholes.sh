#!/usr/bin/env bash
# scripts/lib/potholes.sh — #611 two-layer pothole register.
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

potholes_seed_path() { printf '%s\n' "$(template_plugin_dir)/potholes.md"; }

potholes_workflow_path() { template_project_paths_override "$1" potholes_workflow; }

potholes_project_path() {
  local p d
  p="$(template_project_paths_override "$1" potholes)"
  if [ -z "$p" ]; then
    d="$(template_devdoc_dir "$1")"
    [ -n "$d" ] && p="${d%/}/templates/potholes.md"
  fi
  printf '%s\n' "$p"
}

# potholes_layer_files <project> — "<layer> <path>" per PRESENT file, seed first.
potholes_layer_files() {
  local project="$1" s w p
  s="$(potholes_seed_path)";                [ -s "$s" ] && printf 'seed %s\n' "$s"
  w="$(potholes_workflow_path "$project")"; [ -n "$w" ] && [ -s "$w" ] && printf 'workflow %s\n' "$w"
  p="$(potholes_project_path "$project")";  [ -n "$p" ] && [ -s "$p" ] && printf 'project %s\n' "$p"
  return 0
}

# _potholes_paths_into <project> <array-name> — fill an array with present layer paths.
_potholes_paths_into() {
  local project="$1" line
  local -n _out="$2"
  _out=()
  while IFS= read -r line; do
    [ -n "$line" ] && _out+=("${line#* }")
  done < <(potholes_layer_files "$project")
}

# potholes_union_headings <project> — every '## ' heading across the present layers.
potholes_union_headings() {
  local -a files
  _potholes_paths_into "$1" files
  [ "${#files[@]}" -gt 0 ] || return 0
  grep -h '^## ' -- "${files[@]}" | sort -u
}

# potholes_cited_union <project> <issue_id> [file…] — does ANY present layer (or an
# extra file, e.g. a temp copy about to be written) cite the issue? Closing paren
# load-bearing (Issue-1 must not match Issue-10)). The SHARED workflow file must
# carry the project token — a bare (Issue-42) moved there by the distribute
# capture would otherwise satisfy EVERY project's Issue-42; the seed, the
# project layer and extra files accept the bare form and this project's token.
potholes_cited_union() {
  local project="$1" issue_id="$2"; shift 2
  local -a files=("$@") layers
  _potholes_paths_into "$project" layers
  files+=("${layers[@]}")
  local f re wf
  wf="$(potholes_workflow_path "$project")"
  for f in "${files[@]}"; do
    [ -s "$f" ] || continue
    re="\\((${project} )?${issue_id}\\)"
    [ -n "$wf" ] && [ "$f" = "$wf" ] && re="\\(${project} ${issue_id}\\)"
    grep -qiE -- "$re" "$f" && return 0
  done
  return 1
}

# potholes_show_union <project> — seed + workflow + project. '# layer:' markers
# ONLY when >1 layer is present (rc 1 and no output otherwise, so template_show
# falls back to the single-layer form — byte-identical to pre-#611 output).
# Bullets are deduped by their citation-STRIPPED text: the seed cites (Issue-N)
# where the workflow layer cites (<project> Issue-N) for the same lesson.
potholes_show_union() {
  local project="$1" line
  local -a layers=() paths=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    layers+=("${line%% *}"); paths+=("${line#* }")
  done < <(potholes_layer_files "$project")
  [ "${#paths[@]}" -gt 1 ] || return 1
  printf '# === template potholes (layers=%s) ===\n' "$(IFS=,; printf '%s' "${layers[*]}")"
  LAYERS="${layers[*]}" awk '
    BEGIN { split(ENVIRON["LAYERS"], L, " ") }
    FNR == 1 { i++; if (i > 1) print ""; printf "# layer: %s\n# source: %s\n\n", L[i], FILENAME }
    /^- / {
      k = $0
      sub(/ *\(([A-Za-z-]+ )?Issue-[A-Za-z0-9-]+\)\.$/, "", k)
      if (k in seen) next
      seen[k] = 1
    }
    { print }' "${paths[@]}"
}

# potholes_private_name_hits <seed> <name>… — ONE predicate shared by the suite
# canary (tests/potholes-seed-canary.bats) and doctor (register: a guard and its
# probe share a predicate, Issue-585). Prints "<name> citations=<n> words=<m>"
# per name with any hit; rc 1 iff any. Case-insensitive; the citation form
# "(<name> Issue-" is primary, a word-bounded bare mention secondary. The public
# allowlist is the CALLER's filter — this predicate knows nothing of it.
potholes_private_name_hits() {
  local seed="$1"; shift
  local name c w rc=0
  for name in "$@"; do
    c="$(grep -ciE "\\(${name} Issue-" -- "$seed")" || true      # grep -c prints 0 on no match
    w="$(grep -ciwF -- "${name}" "$seed")" || true
    if [ "${c:-0}" -gt 0 ] || [ "${w:-0}" -gt 0 ]; then
      printf '%s citations=%s words=%s\n' "$name" "$c" "$w"; rc=1
    fi
  done
  return $rc
}
