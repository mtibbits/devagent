#!/usr/bin/env bash
# scripts/lib/potholes.sh — #611 two-layer pothole register.
#
# bash >= 4.4: namerefs (local -n) and empty-array expansion under set -u. The
# resolver sources this lib unconditionally, so the floor is plugin-wide
# (README states it); fail with the cause named rather than a cryptic
# `local: -n: invalid option` from inside a sourced lib.
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  echo "potholes.sh: bash >= 4.4 required (found ${BASH_VERSION}) — devAgent's scripts need a modern bash (Git Bash, WSL and Linux all provide 5.x)" >&2
  # A `return` is swallowed by callers without set -e (doctor, template.sh) and
  # the next call then misreports a config fault; exit unless sourced interactively.
  case "$-" in *i*) return 1 ;; *) exit 1 ;; esac
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

# Citation grammar (#612), in ONE place: a line ends `(<tok>[; <tok>]*).` where
# <tok> is `(<project> )?Issue-N` (N: [0-9]+ or Fork-[0-9]+). The per-layer
# token FORM is potholes_line_cite_ok's business (project: bare; workflow:
# project-qualified); POTHOLES_CITE_TAIL_RE only recognises the shape (sed -E /
# grep -E). potholes_cite_re builds the layer-aware CHECK match, the own token
# anywhere in the list: the SHARED workflow file must carry the project token (a
# bare (Issue-42) moved there by the #613 migration would otherwise satisfy
# EVERY project's Issue-42), and so must the SEED for every project except the
# one whose source_dir IS the plugin — the seed's bare (Issue-N) citations are
# that project's own history (red-team #611). The project layer and temp files
# accept the bare form. Every consumer — potholes_cited_union (--check and the
# post-apply postcondition), the --add/--amend/--retire end-rule, the body-strip,
# the union-read dedupe — reads these constants; none re-spells them (a guard
# and its probe share one predicate, Issue-585). Two unions: the READ union
# (potholes_show_union) EXCLUDES each layer's Retired section; the CHECK union
# (potholes_cited_union) reads the layer FILES, Retired included.
POTHOLES_PROJ_RE='[A-Za-z0-9_-]+'
POTHOLES_ISSUE_RE='Issue-(Fork-)?[0-9]+'     # #613: tightened from Issue-[A-Za-z0-9-]+
POTHOLES_TOK_RE="(${POTHOLES_PROJ_RE} )?${POTHOLES_ISSUE_RE}"
# shellcheck disable=SC2034  # consumed by scripts that source this lib (promote-potholes.sh _body)
POTHOLES_CITE_TAIL_RE=" *\\(${POTHOLES_TOK_RE}(; ${POTHOLES_TOK_RE})*\\)\\.\$"
POTHOLES_RETIRED_HEADING='## Retired (mechanised)'   # written only by --retire; excluded from the READ union
# shellcheck disable=SC2034  # consumed by promote-potholes.sh (--add warn-cap) and tests/potholes-seed-canary.bats
POTHOLES_SECTION_CAP=25                              # --add warns at >= this many bullets in the target LAYER FILE's section
# shellcheck disable=SC2034  # consumed by tests/potholes-seed-canary.bats and the Issue-613 migration
POTHOLES_SEED_TOTAL_CAP=100                          # the curated seed's hard bullet ceiling (#613)
# Retired-line SHAPE — written by #612's _retire_result; #613's potholes_file_check polices WHERE it may sit.
POTHOLES_RETIRED_LINE_RE='^- \[[^]]+\] .* — mechanised by '
# _potholes_plugin_name <dir> — the "name" in <dir>/.claude-plugin/plugin.json, or "".
_potholes_plugin_name() {
  [ -f "$1/.claude-plugin/plugin.json" ] || return 1
  # first "name" key wins — the manifest's top-level name precedes author.name
  sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1/.claude-plugin/plugin.json" | head -1
}
_POTHOLES_OWNER_MEMO=""   # "<project>=yes|no"
# _potholes_owns_seed <project> — does the project DEVELOP the plugin whose seed
# is being read? Keyed on PROVENANCE, not filesystem identity: the seed's own
# tree (dirname of the seed, up one) and the project's source_dir must both
# carry a .claude-plugin/plugin.json with the same "name". The installed copy
# under ~/.claude/plugins/cache and the source checkout then agree (red-team r2:
# a plugin_root() comparison was true only when run from the source tree).
_potholes_owns_seed() {
  local sd seed_root sn pn
  if [ -n "$_POTHOLES_OWNER_MEMO" ] && [ "${_POTHOLES_OWNER_MEMO%%=*}" = "$1" ]; then
    [ "${_POTHOLES_OWNER_MEMO#*=}" = yes ]; return
  fi
  _POTHOLES_OWNER_MEMO="$1=no"
  sd="$(config_get_project_field "$1" source_dir 2>/dev/null || true)"
  seed_root="$(dirname "$(dirname "$(potholes_seed_path)")")"
  [ -n "$sd" ] && [ -d "$sd" ] || return 1
  sn="$(_potholes_plugin_name "$seed_root" || true)"; pn="$(_potholes_plugin_name "$sd" || true)"
  if [ -n "$sn" ] && [ "$sn" = "$pn" ]; then _POTHOLES_OWNER_MEMO="$1=yes"; return 0; fi
  return 1
}
potholes_cite_re() {   # <project> <issue_id> <layer> — the own token may sit anywhere in the list
  local tok
  case "$3" in
    workflow) tok="$1 $2" ;;                                        # the shared file always names the project
    seed)     if _potholes_owns_seed "$1"; then tok="($1 )?$2"; else tok="$1 $2"; fi ;;
    *)        tok="($1 )?$2" ;;
  esac
  printf '\\(([^)]*; )?%s(; [^)]*)?\\)\n' "$tok"
}

# potholes_cite_tokens <line> — the tokens of a line's citation, one per line;
# rc 1 when the line does not end in a well-formed tail. potholes_cite_join is
# its inverse (tokens on stdin → the "; "-joined list), so no caller re-spells
# the separator.
potholes_cite_tokens() {
  local t
  printf '%s' "$1" | grep -qE -- "$POTHOLES_CITE_TAIL_RE" || return 1
  t="${1##*(}"; t="${t%).}"            # tokens carry no '(' so the LAST '(' opens the citation
  printf '%s\n' "$t" | sed 's/; /\n/g'
}
potholes_cite_join() { paste -sd ';' | sed 's/;/; /g'; }
# potholes_tokens_has <tokens> <tok> — is <tok> in the newline-separated
# <tokens> (case-insensitive)? Pure bash — the callers loop over tokens.
potholes_tokens_has() {
  local t
  while IFS= read -r t; do [ "${t,,}" = "${2,,}" ] && return 0; done <<< "$1"
  return 1
}

# potholes_own_token <project> <issue_id> <layer> — the calling issue's token in
# the layer's form (workflow: project-qualified; any other layer: bare).
potholes_own_token() { case "$3" in workflow) printf '%s %s' "$1" "$2" ;; *) printf '%s' "$2" ;; esac; }

# potholes_layer_form <layer> — the token FORM regex for a layer (workflow:
# '<project> Issue-N'; any other layer: bare 'Issue-N'). ONE spelling, shared by
# potholes_line_cite_ok (staging rails) and potholes_file_check (the file
# contract, #613) — a guard and its probe share a predicate (Issue-585).
potholes_layer_form() {
  case "$1" in
    workflow) printf '^%s %s$\n' "$POTHOLES_PROJ_RE" "$POTHOLES_ISSUE_RE" ;;
    *)        printf '^%s$\n' "$POTHOLES_ISSUE_RE" ;;
  esac
}
# potholes_token_form_reason <layer> <tok> — the diagnostic for a token outside
# the layer's form; <tok> may be a printf '%s' placeholder (potholes_file_check
# hands the format to awk's sprintf).
potholes_token_form_reason() {
  case "$1" in
    workflow) printf "workflow-layer token '%s' must be '<project> Issue-N' — the shared register cites the project\n" "$2" ;;
    *)        printf "%s-layer token '%s' must be bare 'Issue-N'\n" "$1" "$2" ;;
  esac
}

# potholes_line_cite_ok <project> <issue_id> <layer> <line> — every token is in
# the LAYER's form and the caller's own token is present (case-insensitive).
# Reason on stderr, rc 1. Any layer other than workflow takes the bare form.
potholes_line_cite_ok() {
  local project="$1" issue_id="$2" layer="$3" line="$4" toks t own=0 want form
  toks="$(potholes_cite_tokens "$line")" \
    || { echo "line must end with a citation '(<tok>[; <tok>]*).': $line" >&2; return 1; }
  want="$(potholes_own_token "$project" "$issue_id" "$layer")"
  form="$(potholes_layer_form "$layer")"
  while IFS= read -r t; do
    if ! [[ "$t" =~ $form ]]; then
      potholes_token_form_reason "$layer" "$t" >&2
      return 1
    fi
    [ "${t,,}" = "${want,,}" ] && own=1
  done <<< "$toks"
  [ "$own" -eq 1 ] || { echo "citation lacks this issue's own token '$want': $line" >&2; return 1; }
}

# potholes_section_count <file> <heading> — bullets under that heading; 0 for an
# absent file. Shared by --add's warn-cap and the seed-cap canary.
potholes_section_count() {
  [ -f "$1" ] || { echo 0; return; }
  S="$2" awk '/^## /{in_=($0==ENVIRON["S"])} in_ && /^- /{c++} END{print c+0}' "$1"
}

# potholes_file_check <layer> <file> [<label>] — the register FILE contract (#613): ONE
# predicate for every writer and the suite. promote-potholes.sh --apply runs it on
# each temp copy before writing (so a pre-existing violation DEFERs, line quoted);
# the Issue-613 migration runs it on every file it writes; tests/potholes-
# postcondition.bats pins it. Layer: seed | project (bare tokens) | workflow
# (project-qualified tokens).
#   1  no bullet immediately before a '## ' heading
#   2  every '- ' line ends in the citation grammar (POTHOLES_CITE_TAIL_RE)
#   3  every token of every citation is in the layer's form (FORM only — the
#      seed's extra rule, no fork token, is potholes_seed_sweep's, not the form's)
#   4  retired-shaped lines only under POTHOLES_RETIRED_HEADING, and only those there
#   5  LF only — no CR byte anywhere
# One "<file>:<line>: <reason>" per violation on stderr — <label> (default: <file>)
# is the path printed, so a caller checking a temp copy names the real file; rc 1
# on any, 0 clean, 2 unreadable / unknown layer (never "clean", Issue-316).
potholes_file_check() {
  local layer="$1" f="$2" form rf
  [ -r "$f" ] || { echo "potholes_file_check: cannot read $f" >&2; return 2; }
  case "$layer" in
    seed|project|workflow) form="$(potholes_layer_form "$layer")"; rf="$(potholes_token_form_reason "$layer" '%s')" ;;
    *) echo "potholes_file_check: unknown layer '$layer' (seed|project|workflow)" >&2; return 2 ;;
  esac
  FORM="$form" RF="$rf" RH="$POTHOLES_RETIRED_HEADING" TAIL="$POTHOLES_CITE_TAIL_RE" \
  RL="$POTHOLES_RETIRED_LINE_RE" F="${3:-$f}" awk '
    function bad(reason) { printf "%s:%d: %s\n", ENVIRON["F"], FNR, reason > "/dev/stderr"; rc = 1 }
    BEGIN { rc = 0; prev = ""; retired = 0 }   # explicit: "never clean" AND "never spuriously dirty" are both load-bearing (Issue-316)
    /\r/   { bad("CR byte — register files are LF only") }
    /^## / { if (prev ~ /^- /) bad("bullet immediately before a ## heading"); retired = ($0 == ENVIRON["RH"]) }
    /^- /  {
      if ($0 !~ ENVIRON["TAIL"]) bad("bullet does not end in the citation grammar (<tok>[; <tok>]*).")
      else {
        t = $0; sub(/^.*\(/, "", t); sub(/\)\.$/, "", t); n = split(t, toks, "; ")   # potholes_cite_tokens, in awk
        for (i = 1; i <= n; i++) if (toks[i] !~ ENVIRON["FORM"]) bad(sprintf(ENVIRON["RF"], toks[i]))
      }
      isret = ($0 ~ ENVIRON["RL"])
      if (isret && !retired) bad("retired-shaped line outside the Retired section")
      if (!isret && retired) bad("non-retired line inside the Retired section")
    }
    { prev = $0 }
    END { exit rc }' "$f"
}

# potholes_line_sha1 <line> — sha1 of the LF-normalised line (one trailing CR
# stripped, no newline appended): the #613 ledger key, defined here so a ledger
# reader can re-derive it (the Issue-613 migration mirrors it in Python). A CRLF
# and an LF copy of one line hash alike, so a row survives a line-ending accident.
potholes_line_sha1() { printf '%s' "${1%$'\r'}" | sha1sum | cut -d' ' -f1; }

# potholes_seed_sweep <file> [<word>…] — the #613 privacy sweep the curated seed
# must pass: ONE predicate for the migration (which passes the operator's
# usernames) and tests/potholes-seed-canary.bats (which passes the git e-mail
# local part). Universe, DECLARED: a fork-tracker token (Issue-Fork-);
# home paths (/home/, /Users/, ~/, /mnt/<drive>/) — drive forms like /c/ and c:/
# are NOT in it (they are lesson content, not locations); URLs and
# .local/.lan/.internal hosts; e-mail addresses; each <word> whole, case-
# insensitively. Project NAMES are potholes_private_name_hits' business.
# Prints "<line>: <kind>: <text>" per hit; rc 1 iff any; rc 2 when grep could
# not run (never "clean", Issue-316).
potholes_seed_sweep() {
  local seed="$1"; shift
  local -a kinds=(fork path host email)
  local -a pats=('Issue-Fork-' '(^|[^A-Za-z0-9_])(/home/|/Users/|~/|/mnt/[a-z]/)'
                 '([a-z]+://|[A-Za-z0-9-]+\.(local|lan|internal)\b)' '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
  local w i f out l grc rc=0
  [ -r "$seed" ] || { echo "potholes_seed_sweep: cannot read $seed" >&2; return 2; }
  for w in "$@"; do [ -n "$w" ] && { kinds+=("word:$w"); pats+=("$w"); }; done
  for i in "${!kinds[@]}"; do
    case "${kinds[i]}" in word:*) f=-iwF ;; *) f=-E ;; esac      # words are whole-word literals
    grc=0; out="$(grep -n "$f" -- "${pats[i]}" "$seed")" || grc=$?
    [ "$grc" -le 1 ] || { echo "potholes_seed_sweep: grep rc $grc on $seed" >&2; return 2; }
    [ -z "$out" ] && continue
    while IFS= read -r l; do printf '%s: %s: %s\n' "${l%%:*}" "${kinds[i]}" "${l#*:}"; done <<< "$out"; rc=1
  done
  return $rc
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
  grep -h '^## ' -- "${files[@]}" | grep -vxF -- "$POTHOLES_RETIRED_HEADING" | sort -u
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
  local i re
  _potholes_owns_seed "$project" || true     # memoise in THIS shell, not inside the $( ) below
  for i in "${!files[@]}"; do
    [ -s "${files[i]}" ] || continue
    re="$(potholes_cite_re "$project" "$issue_id" "${lnames[i]}")"
    grep -qiE -- "$re" "${files[i]}" && return 0
  done
  return 1
}

# potholes_show_union <project> — seed + workflow + project. '# layer:' markers
# ONLY when >1 layer is present (rc 1 and no output otherwise, so template_show
# falls back to the single-layer form — byte-identical to pre-#611 output).
# Bullets are deduped by their citation-STRIPPED text (the whole multi-token
# suffix, POTHOLES_CITE_TAIL_RE as a dynamic awk regex): the seed cites (Issue-N)
# where the workflow layer cites (<project> Issue-N; …) for the same lesson.
# Each layer's Retired section (#612) is skipped: this is the READ union —
# retired lines stop costing reads.
potholes_show_union() {
  local project="$1"
  local -a layers paths
  _potholes_layers_into "$project" layers paths
  [ "${#paths[@]}" -gt 1 ] || return 1
  printf '# === template potholes (layers=%s) ===\n' "$(IFS=,; printf '%s' "${layers[*]}")"
  LAYERS="${layers[*]}" RH="$POTHOLES_RETIRED_HEADING" RE="$POTHOLES_CITE_TAIL_RE" awk '
    BEGIN { split(ENVIRON["LAYERS"], L, " ") }
    FNR == 1 { i++; skip = 0; if (i > 1) print ""; printf "# layer: %s\n# source: %s\n\n", L[i], FILENAME }
    /^## / { skip = ($0 == ENVIRON["RH"]) }
    skip { next }
    /^- / {
      k = $0
      sub(ENVIRON["RE"], "", k)
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
