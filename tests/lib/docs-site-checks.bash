# tests/lib/docs-site-checks.bash — #997: the onboarding site's FACT checks.
#
# Loaded by tests/docs-site.bats and tests/build-docs-site.bats. Each check
# takes its subject files as arguments, so a mutation leg can run the SAME
# function on a broken temp copy and watch it fail.
#
# Return contract, for every check_* function:
#   0  the fact holds;
#   1  the fact is broken, with a one-line reason on stderr;
#   2  the check cannot run (a missing file, an unreadable list).
# Mutation legs assert exactly 1, so a missing function (127) or a grep error
# (2) can never pass for "broken". The functions never rely on errexit (bats
# `run` clears it): every failure is an explicit return.
#
# The ONE page list is the index's own top-level list (index.html's one-line
# <li><a href> entries), the list the build reads for its nav
# (scripts/build-docs-site.sh nav_entries). site_pages reads it; check_page_set
# holds the directory to it. Later children add a page by adding one entry there.
#
# PAGE PINS — owned by later children. These facts can only be checked through
# a sentence today; the child that rewrites the page owns the pin:
#   #998 (landing, index.md -> index.html): site_pages reads index.md only and
#        returns 2 naming #998 on an index.html; check_step_headline and
#        check_numbering_claim read the index; a check_install_block home if the
#        landing shows the commands; README.md's docs-site/index.md pointer; the
#        comment in tests/skills-no-bang-exec.bats naming docs-site/index.md; the
#        permanent-ID mutation leg, which edits a copy of index.md.
#   #999 (install): check_platform_tokens; the bash-floor presence; the "You
#        need:" .. "- Contributors additionally" region, which #999 moves to
#        CONTRIBUTING.md and which two checks read: check_prereqs_trace (the region,
#        through the contributors bullet's wrapped lines, names all ten
#        PREREQ_TOOLS) and the shellcheck user statement in check_shellcheck_homes;
#        the install-block, userConfig, grant and version homes; the comment in
#        tests/generic-templates.bats naming docs-site/install.md's tool list.
#   #1000 (replaces Quickstart): check_quickstart_forms; a moved.txt line for
#        quickstart; check_command_arity's subject floor (>= 1 /devagent: line);
#        the arity mutation leg, which edits a copy of quickstart.md.
#   #1001 (how it works): the "| N | `cmd`" row shape; "numbered 0-24 in";
#        /devagent:mergemr and WAITING (#885); the 21-step mutation leg, which
#        edits a copy of workflow.md.
#   #1002: none beyond its bullet in the one list.

# #338: every loaded setup layer sources the shared hermetic-env guard (#322).
. "$(dirname "${BASH_SOURCE[0]}")/hermetic-env.bash"   # idempotent (#322)

# The step count the workflow table and the headline derive from
# templates/checklist-standard.md. The literal keeps the derived count honest:
# a template that silently reads fewer steps cannot pass.
STEP_COUNT=25
# The verified Claude Code version. A deliberate literal, not derived from
# README: a version bump must be a CONSCIOUS edit here too, because it is the
# trigger for re-running the plugin-root-grant-automatch smoke rung (#548).
VERIFIED_CC=2.1.223
# The reference documents that left the site for docs/ (#997), repo-relative.
CONFIG_REL=docs/configuration.md
CONCURRENCY_REL=docs/concurrency.md
REFERENCE_DOCS=("$CONFIG_REL" "$CONCURRENCY_REL")
# Every document docs-site/reference.md links: the moved ones plus the spec.
# shellcheck disable=SC2034  # read by the bats files that load this library
REFERENCE_LINKS=("${REFERENCE_DOCS[@]}" docs/specs/2026-05-19-devagent-plugin-design.md docs/requirements.md)
# The forge home of a repo file: the build's own default --blob-base, read from
# scripts/build-docs-site.sh so the two cannot drift.
BLOB_BASE="$(sed -n 's/^blob_base="\(.*\)"$/\1/p' "$(dirname "${BASH_SOURCE[0]}")/../../scripts/build-docs-site.sh")"

# The landing page's HTML reader (stdlib html.parser), next to this library.
LANDING_CHECK="$(dirname "${BASH_SOURCE[0]}")/landing-check.py"

# landing_py <subcommand> <arg>... — run landing-check.py (0 ok, 1 a structural
# absence, 2 usage or an unreadable file; diagnostics on stderr).
landing_py() { python3 -I -X utf8 "$LANDING_CHECK" "$@"; }

# _blob_base_ok — return 2 (naming the scrape) unless BLOB_BASE read as a URL.
_blob_base_ok() {
  [[ "$BLOB_BASE" == https://*/ ]] && return 0
  echo "cannot read blob_base=\"https://.../\" from scripts/build-docs-site.sh (got '$BLOB_BASE')" >&2
  return 2
}

# _need <file>... — return 2 (with a reason) unless every file is readable.
_need() {
  local f
  for f in "$@"; do
    [ -f "$f" ] && [ -r "$f" ] || { echo "cannot read $f" >&2; return 2; }
  done
}

# _has <file> <literal> <reason> — 0 if the file contains the literal, else 1.
_has() {
  grep -qF -- "$2" "$1" && return 0
  echo "$1: $3" >&2
  return 1
}

# site_content <site-dir> — the content pages (*.md and *.html other than
# README.*), full paths.
site_content() {
  local f
  for f in "$1"/*.md "$1"/*.html; do
    [ -e "$f" ] || continue
    case "${f##*/}" in README.*) continue ;; esac
    printf '%s\n' "$f"
  done
}

# moved_pairs <site-dir> — moved.txt's data lines as "<old> <home>".
moved_pairs() {
  awk '!/^[ \t]*(#|$)/ { print $1, $2 }' "$1/moved.txt"
}

# The build's non-content region reader (comments, <pre>, <code>, <script>,
# <style>, <template>, <textarea>), read from scripts/build-docs-site.sh so
# site_pages's index.html branch skips exactly what the build skips.
_NC_AWK="$(sed -n "/^nc_awk='\$/,/^'\$/p" "$(dirname "${BASH_SOURCE[0]}")/../../scripts/build-docs-site.sh" | sed '1d;$d')"

# site_pages <site-dir> — the names the index's own top-level list links, in
# list order, deduplicated, index itself excluded. Copied from
# scripts/build-docs-site.sh nav_entries: for index.md its fence rule and bullet
# regex; for index.html its one-line '<li><a href="page.html">' entry regex
# over the build's own nc_awk (a lone <li> whose next non-blank line opens such
# an <a> returns 2, as the build exits 4). tests/build-docs-site.bats compares
# this reader to the built nav, so the copies must agree on the real site.
site_pages() {
  local dir="$1"
  if [ -f "$dir/index.md" ]; then
    awk '/^(```|~~~)/ { fence = !fence; next }
         !fence && match($0, /^- \[[^]]*\]\(\.\/[A-Za-z0-9_-]+\.(md|html)\)/) {
           s = substr($0, RSTART, RLENGTH)
           sub(/^.*\]\(\.\//, "", s); sub(/\.(md|html)\)$/, "", s)
           if (s != "index" && !seen[s]++) print s
         }' "$dir/index.md" || { echo "site_pages: cannot read $dir/index.md" >&2; return 2; }
  elif [ -f "$dir/index.html" ]; then
    [ -n "$_NC_AWK" ] || { echo "site_pages: cannot read nc_awk from scripts/build-docs-site.sh" >&2; return 2; }
    awk -v f="$dir/index.html" "$_NC_AWK"'
         { s = nc($0); l = tolower(s) }
         lone {
           if (l ~ /^[ \t]*$/) next
           if (l ~ /^[ \t]*<a([ \t][^>]*)?[ \t]href="(\.\/)?[a-z0-9_-]+\.html"/) {
             printf "site_pages: %s:%d: <li> and its <a href> must share a line\n", f, lone > "/dev/stderr"
             rc = 2; exit
           }
           lone = 0
         }
         match(l, /^[ \t]*<li([ \t][^>]*)?>[ \t]*<a([ \t][^>]*)?[ \t]href="(\.\/)?[a-z0-9_-]+\.html"/) {
           m = substr(s, RSTART, RLENGTH)
           sub(/\.[Hh][Tt][Mm][Ll]"$/, "", m); sub(/^.*"/, "", m); sub(/^\.\//, "", m)
           if (m != "index" && !seen[m]++) print m
           next
         }
         l ~ /^[ \t]*<li([ \t][^>]*)?>[ \t]*$/ { lone = NR }
         END { exit rc }' "$dir/index.html" || return 2
  else
    echo "site_pages: no index.md or index.html in $dir" >&2
    return 2
  fi
}

# check_page_set <site-dir> — the content pages (*.md and *.html other than
# README.*) are exactly index plus the pages the index's list names, and the
# directory's README.md policy file is present. The build tolerates an
# unlisted page (it appends it to the nav); this check does not.
check_page_set() {
  local dir="$1" listed f b p bad=0
  local -A want=() have=()
  listed="$(site_pages "$dir")" || return 2
  want[index]=1
  while IFS= read -r p; do [ -n "$p" ] && want[$p]=1; done <<<"$listed"
  while IFS= read -r f; do
    b="${f##*/}"; have[${b%.*}]=1
  done < <(site_content "$dir")
  for p in "${!have[@]}"; do
    [ -n "${want[$p]:-}" ] || { echo "$dir: page $p is not in the index's list (the one page list)" >&2; bad=1; }
  done
  for p in "${!want[@]}"; do
    [ -n "${have[$p]:-}" ] || { echo "$dir: the index's list names $p but there is no $p.md or $p.html" >&2; bad=1; }
  done
  [ -f "$dir/README.md" ] || { echo "$dir: no README.md (the drift policy)" >&2; bad=1; }
  return "$bad"
}

# check_reference_stubs <site-dir> <root> <doc>... — each reference document
# (root-relative) keeps its 1.0 site URL: moved.txt holds exactly one line
# "<doc's base name> <its forge URL>", and every forge home moved.txt names
# exists under <root> (a stub must not point at a file that is gone).
check_reference_stubs() {
  local dir="$1" root="$2" d want n old home rel; shift 2
  [ "$#" -gt 0 ] || { echo "check_reference_stubs: no documents" >&2; return 2; }
  _blob_base_ok || return 2
  _need "$dir/moved.txt" || return 2
  for d in "$@"; do
    want="$(basename "$d" .md) $BLOB_BASE$d"
    n="$(grep -cxF -- "$want" "$dir/moved.txt" || true)"
    [ "$n" -eq 1 ] || { echo "$dir/moved.txt: $n lines '$want', want 1" >&2; return 1; }
  done
  while read -r old home; do
    case "$home" in
      "$BLOB_BASE"*)
        rel="${home#"$BLOB_BASE"}"; rel="${rel%%#*}"
        [ -e "$root/$rel" ] || { echo "$dir/moved.txt: $old's home $rel does not exist" >&2; return 1; } ;;
    esac
  done < <(moved_pairs "$dir")
}

# check_reference_links <page> <doc>... — the page links each root-relative
# document as '](../<doc>)', the form links.lua renders to its forge URL.
check_reference_links() {
  local page="$1" d; shift
  [ "$#" -gt 0 ] || { echo "check_reference_links: no documents" >&2; return 2; }
  _need "$page" || return 2
  for d in "$@"; do
    _has "$page" "](../$d)" "does not link $d" || return 1
  done
}

# check_derived_from <root> <page>... — each page's line 1 is
# "<!-- derived-from: <src>... -->" with a non-empty list, and every source
# exists under <root>.
check_derived_from() {
  local root="$1" p line srcs s; shift
  [ "$#" -gt 0 ] || { echo "check_derived_from: no pages" >&2; return 2; }
  _need "$@" || return 2
  for p in "$@"; do
    line="$(head -1 "$p")"
    [[ "$line" == "<!-- derived-from: "*" -->" ]] || { echo "$p: line 1 is not a derived-from header" >&2; return 1; }
    srcs="${line#<!-- derived-from: }"; srcs="${srcs% -->}"
    [ -n "${srcs// /}" ] || { echo "$p: derived-from header names no source" >&2; return 1; }
    for s in $srcs; do
      [ -e "$root/$s" ] || { echo "$p: derived-from source $s does not exist" >&2; return 1; }
    done
  done
}

# check_install_block <file> — the three install commands; the official
# marketplace-add line DIRECTLY before the superpowers install (#465 r2
# walkthrough finding A: it is not configured on a fresh install); the shared
# comment line that carries the version the negative was measured on.
check_install_block() {
  local f="$1"
  _need "$f" || return 2
  _has "$f" 'claude plugin marketplace add mtibbits/devagent' 'no marketplace-add command' || return 1
  _has "$f" 'claude plugin install devagent@devagent' 'no devagent install command' || return 1
  _has "$f" 'claude plugin install superpowers@claude-plugins-official' 'no superpowers install command' || return 1
  grep -A1 -F 'claude plugin marketplace add anthropics/claude-plugins-official' "$f" \
    | grep -qF 'claude plugin install superpowers@claude-plugins-official' || {
      echo "$f: the official marketplace-add line is not directly before the superpowers install" >&2
      return 1
    }
  _has "$f" '# Not configured on a fresh install' 'no fresh-install comment line' || return 1
}

# check_userconfig_notice <file> — the install's userConfig notice is explained
# (#465 r2 finding B). The option names are pinned over whitespace-normalised
# text, so the paragraph may wrap anywhere.
check_userconfig_notice() {
  local f="$1"
  _need "$f" || return 2
  _has "$f" '`userConfig` options not yet set' 'no userConfig notice sentence' || return 1
  tr -s '[:space:]' ' ' <"$f" | grep -qF 'options not yet set (`devdoc_root`, `default_project`)' || {
    echo "$f: the userConfig notice does not name devdoc_root and default_project" >&2
    return 1
  }
}

# check_verified_version <file> — the literal VERIFIED_CC (see its comment).
check_verified_version() {
  _need "$1" || return 2
  _has "$1" "$VERIFIED_CC" "does not name the verified Claude Code version $VERIFIED_CC" || return 1
}

# check_permission_grant <file> — #548 permissions-caveat parity: the
# load-bearing lines are byte-shared.
check_permission_grant() {
  local f="$1"
  _need "$f" || return 2
  _has "$f" 'Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)' \
    'no two-form plugin-root grant' || return 1
  _has "$f" 'Never widen to bare `Bash`' 'no "Never widen to bare `Bash`" warning' || return 1
}

# template_steps <template> — "N cmd" per step line of a checklist template.
template_steps() {
  _need "$1" || return 2
  sed -n 's/^- \[.\] *\([0-9]*\)\. \(.*\)$/\1 \2/p' "$1"
}

# _step_n <template> — the template's step count, or return 2.
_step_n() {
  local steps
  steps="$(template_steps "$1")" || return 2
  [ -n "$steps" ] || { echo "$1: no step lines" >&2; return 2; }
  grep -c . <<<"$steps"
}

# phase_split <phases-file> — docs-site/phases.txt's data lines as
# "<Name> <step>..." (colon dropped), one per line. Comment and blank lines are
# skipped; any other line that is not "<Name>: <step> <step>..." returns 2
# naming it, and so does a Name given twice.
phase_split() {
  _need "$1" || return 2
  awk -v f="$1" '
    /^[ \t]*(#|$)/ { next }
    !/^[A-Z][a-z]+: [a-z]+( [a-z]+)*$/ {
      printf "%s:%d: expected '\''<Name>: <step> <step>...'\''\n", f, NR > "/dev/stderr"; rc = 2; exit
    }
    {
      n = $1; sub(/:$/, "", n)
      if (seen[n]++) { printf "%s:%d: phase %s is listed twice\n", f, NR, n > "/dev/stderr"; rc = 2; exit }
      sub(/:/, ""); print
    }
    END { exit rc }' "$1"
}

# check_phase_split <template> <phases-file> — the phases hold every template
# step exactly once, in template order, and nothing else. Subject floor: the
# template yields STEP_COUNT steps.
check_phase_split() {
  local tmpl="$1" ph="$2" n split steps num cmd s i=0 last=-1
  local -a flat=()
  local -A pos=() seen=()
  _need "$tmpl" "$ph" || return 2
  n="$(_step_n "$tmpl")" || return 2
  [ "$n" -eq "$STEP_COUNT" ] || { echo "$tmpl: $n steps, want $STEP_COUNT" >&2; return 1; }
  split="$(phase_split "$ph")" || return 2
  steps="$(template_steps "$tmpl")" || return 2
  while read -r num cmd; do pos[$cmd]=$i; i=$((i + 1)); done <<<"$steps"
  # shellcheck disable=SC2086  # word-split each phase line into its steps
  while read -r _ cmd; do flat+=($cmd); done <<<"$split"
  for s in "${flat[@]}"; do
    [ -n "${pos[$s]+x}" ] || { echo "$ph: step $s is not a step of $tmpl" >&2; return 1; }
  done
  for s in "${flat[@]}"; do
    [ -z "${seen[$s]+x}" ] || { echo "$ph: step $s appears in more than one place" >&2; return 1; }
    seen[$s]=1
  done
  while read -r num cmd; do
    [ -n "${seen[$cmd]+x}" ] || { echo "$ph: step $cmd of $tmpl is in no phase" >&2; return 1; }
  done <<<"$steps"
  for s in "${flat[@]}"; do
    [ "${pos[$s]}" -gt "$last" ] || { echo "$ph: step $s is out of template order" >&2; return 1; }
    last="${pos[$s]}"
  done
}

# check_step_headline <template> <file> — "<N>-step workflow", N derived.
check_step_headline() {
  local n
  _need "$2" || return 2
  n="$(_step_n "$1")" || return 2
  _has "$2" "${n}-step workflow" "no '${n}-step workflow' headline (N from $1)" || return 1
}

# check_numbering_claim <template> <file> — the live #558 claim "numbered
# 0–<N-1> in", N derived (the steps are numbered in execution order).
check_numbering_claim() {
  local n
  _need "$2" || return 2
  n="$(_step_n "$1")" || return 2
  _has "$2" "numbered 0–$((n - 1)) in" "no 'numbered 0–$((n - 1)) in' claim (N from $1)" || return 1
}

# check_step_table <template> <page> — the page tables every template step as
# "| N | `cmd`", one row per step, and the template has STEP_COUNT steps.
check_step_table() {
  local tmpl="$1" page="$2" steps num cmd count=0 rows
  _need "$tmpl" "$page" || return 2
  steps="$(template_steps "$tmpl")" || return 2
  while read -r num cmd; do
    [ -n "$num" ] || continue
    grep -qE "^\| ${num} *\| \`${cmd}\`" "$page" || { echo "$page: no table row for step $num ($cmd)" >&2; return 1; }
    count=$((count + 1))
  done <<<"$steps"
  [ "$count" -eq "$STEP_COUNT" ] || { echo "$tmpl: $count steps, want $STEP_COUNT" >&2; return 1; }
  rows="$(grep -c '^| [0-9]' "$page" || true)"
  [ "$rows" -eq "$count" ] || { echo "$page: $rows numbered rows, want $count" >&2; return 1; }
}

# check_backend_verbs <file> — every backend verb, backtick-anchored
# (substring-proof: `state` must not ride on `mr-state`).
check_backend_verbs() {
  local f="$1" v
  _need "$f" || return 2
  for v in fetch create transition state comment-list state-list issue-list state-exists state-class \
           events comment-records whoami \
           push-branch create-mr mr-state mr-comments merge-mr issue-mrs mr-checks mr-view; do
    _has "$f" "\`$v\`" "backend verb \`$v\` is not named" || return 1
  done
}

# check_absent <grep-flags> <regex> <file>... — no file matches. The flags are
# required (-F for a literal, -iE for a case-blind ERE). grep 1 -> 0 (absent),
# 0 -> 1 (found, files named), 2 -> 2 (a missing file or a bad pattern).
check_absent() {
  local flags="$1" re="$2" out rc=0; shift 2
  [ "$#" -gt 0 ] || { echo "check_absent: no files" >&2; return 2; }
  out="$(grep -l "$flags" -e "$re" -- "$@")" || rc=$?
  case "$rc" in
    1) return 0 ;;
    0) echo "'$re' appears in: $(tr '\n' ' ' <<<"$out")" >&2; return 1 ;;
    *) echo "check_absent: grep failed (status $rc)" >&2; return 2 ;;
  esac
}

# The prerequisite tools README names (#579). The install page's own list is
# derived from its "You need:" region; every tool there must be in README.
PREREQ_TOOLS=(bash python3 jq git gh glab curl tomli bats shellcheck)

# _you_need_region <page> <with-contributors 0|1> — the install page's
# "You need:" list, optionally through its "- Contributors additionally" bullet
# (with its wrapped lines, so a reflow cannot drop a tool).
_you_need_region() {
  awk -v c="$2" '
    /You need:$/ { f = 1; next }
    /^- Contributors additionally/ { if (!f || !c) exit; print; g = 1; next }
    g { if (/^$/ || /^- /) exit; print; next }
    f' "$1"
}

# check_prereqs_trace <page> <readme> — the page's toolchain (the backticked
# single words in its "You need:" region, through the contributors line) names
# every PREREQ_TOOLS entry, README names each, every page tool is in README, and
# neither side claims the repo is private.
check_prereqs_trace() {
  local page="$1" readme="$2" region tools t f rc
  _need "$page" "$readme" || return 2
  region="$(_you_need_region "$page" 1)"
  [ -n "$region" ] || { echo "$page: no 'You need:' region" >&2; return 1; }
  tools="$(grep -oE '`[a-z][a-z0-9]*`' <<<"$region" | tr -d '`' | sort -u)"
  for t in "${PREREQ_TOOLS[@]}"; do
    grep -qx -- "$t" <<<"$tools" || { echo "$page: the toolchain list does not name \`$t\`" >&2; return 1; }
  done
  while IFS= read -r t; do
    # RECORDED EXEMPTION: `tomllib` is the stdlib module the `tomli` fallback
    # stands in for, named to explain the fallback; it is not something to install.
    case "$t" in ''|tomllib) continue ;; esac
    _has "$readme" "\`$t\`" "does not name \`$t\`, which $page lists as a prerequisite" || return 1
  done <<<"$tools"
  for f in "$page" "$readme"; do
    rc=0; grep -qiE 'repo(sitory)? is private|private-repo access' "$f" || rc=$?
    case "$rc" in
      1) ;;
      0) echo "$f: claims the repo is private" >&2; return 1 ;;
      *) return 2 ;;
    esac
  done
}

# check_platform_tokens <file> — the #579 platform posture tokens.
check_platform_tokens() {
  local f="$1"
  _need "$f" || return 2
  _has "$f" 'developed and tested on **Linux**' 'no Linux posture token' || return 1
  _has "$f" 'macOS is currently untested' 'no macOS posture token' || return 1
  _has "$f" 'readlink -f' 'no readlink -f token' || return 1
}

# check_command_arity <page>... — no line is a bare /devagent:(init|pull|file|
# capture) (each takes arguments: init.sh exits 2 bare; pull takes <project>
# <num>; file takes <slug>; capture takes text). Subject floor: at least one
# /devagent: command line across all the pages, so an emptied set cannot pass.
check_command_arity() {
  local subjects=0 p n rc
  [ "$#" -gt 0 ] || { echo "check_command_arity: no pages" >&2; return 2; }
  _need "$@" || return 2
  for p in "$@"; do
    rc=0; grep -nE '^/devagent:(init|pull|file|capture) *$' "$p" >&2 || rc=$?
    case "$rc" in
      0) echo "$p: a bare command line (the verb needs its arguments)" >&2; return 1 ;;
      1) ;;
      *) return 2 ;;
    esac
    n="$(grep -c '^/devagent:' "$p" || true)"
    subjects=$((subjects + n))
  done
  [ "$subjects" -ge 1 ] || { echo "no /devagent: command line in any page (the subject floor)" >&2; return 1; }
}

# check_quickstart_forms <page> — the runnable forms and the push_mr gate.
check_quickstart_forms() {
  local f="$1"
  _need "$f" || return 2
  _has "$f" '/devagent:init myproj' 'no runnable init form' || return 1
  _has "$f" '/devagent:pull myproj 42' 'no runnable pull form' || return 1
  _has "$f" '/devagent:file <slug>' 'no runnable file form' || return 1
  _has "$f" 'permissions.push_mr' 'no push_mr gate warning' || return 1
}

# check_bash_floor <page> <readme> <guard> — the page states ONE bash floor,
# equal to README's and to the potholes.sh guard's (#611), and no stale "≥ 4".
check_bash_floor() {
  local page="$1" readme="$2" guard="$3" r p g rc=0
  _need "$page" "$readme" "$guard" || return 2
  r="$(grep -oE 'bash`? \(?≥ [0-9]+\.[0-9]+' "$readme" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  p="$(grep -oE 'bash`? ≥ [0-9]+\.[0-9]+' "$page" | grep -oE '[0-9]+\.[0-9]+' | sort -u)"
  g="$(grep -oE 'bash >= [0-9]+\.[0-9]+' "$guard" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  [ -n "$r" ] || { echo "$readme: no bash floor" >&2; return 1; }
  [ "$r" = "$g" ] || { echo "bash floor: README $r, guard ${g:-none}" >&2; return 1; }
  [ -n "$p" ] || { echo "$page: no bash floor" >&2; return 1; }
  [ "$(printf '%s\n' "$p" | wc -l)" -eq 1 ] || { echo "$page: several bash floors: $(tr '\n' ' ' <<<"$p")" >&2; return 1; }
  [ "$p" = "$r" ] || { echo "bash floor: page $p, README $r" >&2; return 1; }
  grep -nE 'bash`? ≥ 4\b[^.]' "$page" >/dev/null || rc=$?
  case "$rc" in
    1) ;;
    0) echo "$page: a stale 'bash ≥ 4' remains" >&2; return 1 ;;
    *) return 2 ;;
  esac
}

# check_cc_version_homes <root> <path>... — every live Claude Code version home
# under the given root-relative paths (files or directories) names README's
# verified-against pin. A line carrying a historical measurement marker
# ("measured at/on", "unmeasured", "re-verified on") is exempt: it states what was
# observed on a named past version. CHANGELOG, docs/specs, evals/ and tests/ are
# history or floor claims and are never passed as roots. Floor: 5 live tokens
# (README x2, install.md x2, the bug-report placeholder).
check_cc_version_homes() {
  local root="$1" pin hits rc=0 hit text v live=0 stale=""; shift
  [ "$#" -gt 0 ] || { echo "check_cc_version_homes: no roots" >&2; return 2; }
  _need "$root/README.md" || return 2
  pin="$(grep -oE 'verified against Claude Code \*\*[0-9]+\.[0-9]+\.[0-9]+\*\*' "$root/README.md" \
          | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  [ -n "$pin" ] && [ "$(printf '%s\n' "$pin" | wc -l)" -eq 1 ] \
    || { echo "README.md: not exactly one verified-against pin" >&2; return 1; }
  hits="$(cd "$root" && grep -rnHIE '[0-9]+\.[0-9]+\.[0-9]{3}' -- "$@")" || rc=$?
  [ "$rc" -le 1 ] || { echo "check_cc_version_homes: grep failed (status $rc; a missing root?)" >&2; return 2; }
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    text="${hit#*:*:}"
    [[ "$text" =~ measured|re-verified ]] && continue
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      live=$((live + 1))
      [ "$v" = "$pin" ] || stale+="${hit}"$'\n'
    done < <(grep -oE '[0-9]+\.[0-9]+\.[0-9]{3}' <<<"$text")
  done <<<"$hits"
  if [ -n "$stale" ]; then
    echo "live Claude Code version home disagrees with the README pin ($pin):" >&2
    printf '%s' "$stale" >&2
    return 1
  fi
  [ "$live" -ge 5 ] || { echo "only $live live version tokens, want >= 5 (an emptied sweep)" >&2; return 1; }
}

# The live major-zero x.y.z tokens of stdin, one per line, on whitespace-normalised
# text. A token directly preceded by the stamp form is an exempt example and is
# dropped. An unreadable input (a directory) fails rather than reading as "no tokens".
_mz_live() {
  local text toks m rc=0
  text="$(tr -s '[:space:]' ' ')" || return 2
  toks="$(grep -oE '(analyzer: shellcheck |^|[^0-9.])0\.[0-9]+\.[0-9]+' <<<"$text")" || rc=$?
  [ "$rc" -le 1 ] || return 2   # 1 = no token (legal per home); 2 = grep error
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    [[ "$m" == "analyzer: shellcheck "* ]] && continue
    printf '%s\n' "${m##*[!0-9.]}"
  done <<<"$toks"
}

# check_shellcheck_homes <root> <install-page> <config-page> — #678: the
# version every shellcheck home names is the one CONTRIBUTING.md "What you need"
# names. The page arguments are root-relative. Homes: the user homes (README
# Prerequisites, the install page's "You need:" list, config.toml.skel, the
# configuration page), commands/analyze.md (the one home of the detail) and the
# contributor homes. Major zero isolates the shellcheck version from the Claude
# Code and bash versions in the same files. The user floor equals the
# contributor floor by the policy in the scripts/analyze-shellcheck.sh header.
# RECORDED EXEMPTION: a token in the stamp form `analyzer: shellcheck <version>`
# is an example of a measured value, not a claim, and is not counted.
check_shellcheck_homes() {
  local root="$1" install="$2" config="$3" floor vals v h live=0 stale="" region text msg n
  local -a homes
  local -A count=()
  _need "$root/CONTRIBUTING.md" || return 2
  floor="$(awk '/^## What you need$/{f=1; next} f && /^## /{exit} f' "$root/CONTRIBUTING.md" \
            | tr -s '[:space:]' ' ' \
            | grep -oE '`shellcheck` [0-9]+\.[0-9]+\.[0-9]+ or newer' \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  [ -n "$floor" ] || { echo "CONTRIBUTING.md 'What you need' no longer says \`shellcheck\` X.Y.Z or newer" >&2; return 1; }
  [[ "$floor" != *$'\n'* ]] || { echo "CONTRIBUTING.md names several shellcheck floors" >&2; return 1; }
  [[ "$floor" =~ ^0\. ]] || {
    echo "CONTRIBUTING.md names shellcheck $floor: a 1.x version needs a new token shape here" >&2
    return 1
  }

  homes=(README.md CONTRIBUTING.md "$install" "$config"
         templates/config.toml.skel commands/analyze.md .githooks/pre-push
         .github/workflows/shellcheck.yml)
  for h in "${homes[@]}"; do
    [ -f "$root/$h" ] || { echo "missing version home: $h" >&2; return 2; }
    vals="$(_mz_live <"$root/$h")" || return 2
    while IFS= read -r v; do
      [ -z "$v" ] || [ "$v" = "$floor" ] || stale+="$h: $v"$'\n'
    done <<<"$vals"
    count[$h]="$(grep -c . <<<"$vals" || true)"
    live=$((live + count[$h]))
  done
  if [ -n "$stale" ]; then
    echo "shellcheck version home disagrees with CONTRIBUTING.md ($floor):" >&2
    printf '%s' "$stale" >&2
    echo "A token that is not a shellcheck version is a new exemption for this check" >&2
    echo "(see RECORDED EXEMPTION); do not edit CONTRIBUTING.md for it" >&2
    return 1
  fi

  # Once per prescribed text in the homes that carry one statement each.
  for h in "$config" templates/config.toml.skel commands/analyze.md; do
    [ "${count[$h]}" -eq 1 ] || { echo "$h: ${count[$h]} live version tokens, want 1" >&2; return 1; }
  done

  # The user statements, scoped to their regions: a deleted user statement reddens
  # even with the contributor statements in the same file intact.
  n="$(grep -c '^- Contributors additionally' "$root/$install" || true)"
  [ "$n" -eq 1 ] || { echo "$install: $n '- Contributors additionally' lines, want 1" >&2; return 1; }
  for region in \
      "$(awk '/^\*\*Prerequisites\.\*\*/{f=1} f && /^$/{exit} f' "$root/README.md")" \
      "$(_you_need_region "$root/$install" 0)"; do
    [ -n "$region" ] || { echo "a user statement region is empty" >&2; return 1; }
    vals="$(_mz_live <<<"$region")" || return 2
    [ "$(grep -c . <<<"$vals" || true)" -eq 1 ] || {
      echo "user statement region lacks exactly one shellcheck version: ${region:0:60}..." >&2
      return 1
    }
    [[ "$(tr -s '[:space:]' ' ' <<<"$region")" == *'analyze = "shellcheck"'* ]] || {
      echo "user statement region does not scope itself to analyze = \"shellcheck\"" >&2
      return 1
    }
  done

  # commands/analyze.md carries the missing-binary message its producer dies with,
  # and the unattested consequence of an older version.
  msg="shellcheck not found on PATH"
  _need "$root/scripts/analyze-shellcheck.sh" "$root/commands/analyze.md" || return 2
  grep -qF "die \"$msg\"" "$root/scripts/analyze-shellcheck.sh" || {
    echo "the missing-binary die string moved in scripts/analyze-shellcheck.sh: re-point commands/analyze.md and this check" >&2
    return 1
  }
  text="$(tr -s '[:space:]' ' ' <"$root/commands/analyze.md")"
  [[ "$text" == *"$msg"* ]] || { echo "commands/analyze.md: no '$msg'" >&2; return 1; }
  [[ "$text" == *unattested* ]] || { echo "commands/analyze.md: no 'unattested'" >&2; return 1; }

  # Floor: 9 tokens at 4e3ca74 (README 1, CONTRIBUTING 1, install.md 1,
  # pre-push 3, shellcheck.yml 3) plus one per user statement (README, install
  # page, config.toml.skel, configuration page, commands/analyze.md). The pins
  # above catch a deleted user statement; this bound is the only guard on the
  # contributor tokens.
  [ "$live" -ge 14 ] || { echo "only $live live shellcheck version tokens, want >= 14" >&2; return 1; }
}

# check_merge_keys <skel> <config-page> <changelog> <workflow-page> — #885: the
# merge step's keys are documented where a new project copies its config from;
# the no-CI escape (`if-present`; the default stays `required`) is named in the
# skeleton, the configuration page and the CHANGELOG; the retired claim that no
# step merges the MR is gone; the workflow page names the merge step and WAITING.
check_merge_keys() {
  local skel="$1" config="$2" changelog="$3" workflow="$4" f rc=0
  _need "$skel" "$config" "$changelog" "$workflow" || return 2
  grep -qE '^# merge_checks = "required"' "$skel" || { echo "$skel: no merge_checks default" >&2; return 1; }
  grep -qE '^# merge_method = "squash"' "$skel" || { echo "$skel: no merge_method default" >&2; return 1; }
  for f in "$skel" "$config" "$changelog"; do
    _has "$f" 'merge_checks = "if-present"' 'no if-present escape' || return 1
  done
  grep -F 'no step merges the MR' "$config" "$skel" >&2 || rc=$?
  case "$rc" in
    1) ;;
    0) echo "the retired claim 'no step merges the MR' is back" >&2; return 1 ;;
    *) return 2 ;;
  esac
  _has "$workflow" '/devagent:mergemr' 'does not name /devagent:mergemr' || return 1
  _has "$workflow" 'WAITING' 'does not name WAITING' || return 1
}
