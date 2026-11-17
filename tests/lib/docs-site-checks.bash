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
#   #999 (install, rewritten): its "## Prerequisites" bullet list (_prereq_list;
#        read by check_prereqs_trace and the shellcheck user statement in
#        check_shellcheck_homes); its "**Supported platforms.**" paragraph label
#        (check_platform_sentence); the bash-floor form "`bash` ≥ X.Y"
#        (check_bash_floor); the install-block, userConfig and version homes.
#   #1000 (replaces Quickstart): check_quickstart_forms; a moved.txt line for
#        quickstart; check_command_arity's subject floor (>= 1 /devagent: line);
#        the arity mutation leg, which edits a copy of quickstart.md.
#   #1001 (how it works): the "| N | `cmd`" row shape; "numbered 0-24 in";
#        /devagent:mergemr and WAITING (#885); the 21-step mutation leg, which
#        edits a copy of workflow.md. Reuse docs-site/phases.txt unchanged;
#        check_phase_split and check_loop are the readers. The workflow page's
#        Phase column and README's step-group bullets ("The 25-step workflow":
#        Plan / Implement / Ship / Integrate & close) still use the 1.0 four-phase
#        split; move both to phases.txt's five phases, read from that file.
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

# landing_cmds [--article] <page> — the page's install commands (its <code>
# lines beginning "claude plugin "); 2 when the page cannot be read.
landing_cmds() {
  local c
  c="$(landing_py codes "$@")" || return 2
  grep '^claude plugin ' <<<"$c"
}
# The docs-site placeholder filler, the one count rule a page may show.
FILLER_PY="$(dirname "${BASH_SOURCE[0]}")/../../scripts/docs-site/fill-placeholders.py"

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
    [ -z "${seen[$s]+x}" ] || { echo "$ph: step $s appears in more than one place" >&2; return 1; }
    [ "${pos[$s]}" -gt "$last" ] || { echo "$ph: step $s is out of template order" >&2; return 1; }
    seen[$s]=1; last="${pos[$s]}"
  done
  while read -r num cmd; do
    [ -n "${seen[$cmd]+x}" ] || { echo "$ph: step $cmd of $tmpl is in no phase" >&2; return 1; }
  done <<<"$steps"
}

# check_loop <phases-file> <template> <page> — the landing page's loop (the
# element id=loop) shows the phases of the phase-split file, in its order, once
# in the SVG and once as lists: each svg group's name is the phase Name and its
# steps label is "<first> … <last>" (or <first> alone); each list item is an
# open <details> whose <summary> is the Name, whose <ol start> is the template
# number of the phase's first step, and whose steps are the phase's, in order.
check_loop() {
  local ph="$1" tmpl="$2" page="$3" split steps rows n c i np pid
  local id name label open start summ lsteps first last want
  local -a names=() stepsof=() svgrows=() listrows=()
  local -A num=()
  _need "$ph" "$tmpl" "$page" || return 2
  split="$(phase_split "$ph")" || return 2
  steps="$(template_steps "$tmpl")" || return 2
  [ -n "$split" ] || { echo "$ph: no phases read" >&2; return 2; }
  rows="$(landing_py loop "$page")" || return $?
  while read -r n c; do num[$c]=$n; done <<<"$steps"
  while read -r name c; do names+=("$name"); stepsof+=("$c"); done <<<"$split"
  np="${#names[@]}"
  mapfile -t svgrows < <(grep $'^svg\t' <<<"$rows")
  mapfile -t listrows < <(grep $'^list\t' <<<"$rows")
  [ "${#svgrows[@]}" -eq "$np" ] || { echo "$page: ${#svgrows[@]} svg phase groups, want $np" >&2; return 1; }
  [ "${#listrows[@]}" -eq "$np" ] || { echo "$page: ${#listrows[@]} phase lists, want $np" >&2; return 1; }
  for ((i = 0; i < np; i++)); do
    first="${stepsof[i]%% *}"; last="${stepsof[i]##* }"
    want="$first"; [ "$first" = "$last" ] || want="$first … $last"
    pid="${names[i],,}"
    IFS=$'\t' read -r _ id name label <<<"${svgrows[i]}"
    [ "$id" = "$pid" ] || { echo "phase $pid: svg row $((i + 1)) is phase '$id'" >&2; return 1; }
    [ "$name" = "${names[i]}" ] || { echo "phase $id: svg name '$name', want '${names[i]}'" >&2; return 1; }
    [ "$label" = "$want" ] || { echo "phase $id: svg steps-label '$label', want '$want'" >&2; return 1; }
    IFS=$'\t' read -r _ id open start summ lsteps <<<"${listrows[i]}"
    [ "$id" = "$pid" ] || { echo "phase $pid: list row $((i + 1)) is phase '$id'" >&2; return 1; }
    [ "$open" = yes ] || { echo "phase $id: list open=$open, want yes (nothing hidden without scripts)" >&2; return 1; }
    [ "$summ" = "${names[i]}" ] || { echo "phase $id: list summary '$summ', want '${names[i]}'" >&2; return 1; }
    [ "$lsteps" = "${stepsof[i]}" ] || { echo "phase $id: list steps '$lsteps', want '${stepsof[i]}'" >&2; return 1; }
    [ "$start" = "${num[$first]}" ] || { echo "phase $id: list start $start, want ${num[$first]} (the template number of $first)" >&2; return 1; }
  done
}

# check_install_pair <readme> <page> — the page's install commands (its <code>
# lines beginning "claude plugin ") are exactly the "claude plugin " lines of
# README's first fence after "## Install", in order, and nothing else.
check_install_pair() {
  local readme="$1" page="$2" r p cmd rc=0
  _need "$readme" "$page" || return 2
  r="$(awk '/^## Install$/ { s = 1; next }
            s && !f && /^## / { exit }
            s && !f && /^```/ { f = 1; next }
            f && /^```$/ { exit }
            f' "$readme" | grep '^claude plugin ')" || true
  [ -n "$r" ] || { echo "$readme: no 'claude plugin ' line in the first fence after ## Install" >&2; return 2; }
  p="$(landing_cmds "$page")" || rc=$?
  [ "$rc" -le 1 ] || return 2
  while IFS= read -r cmd; do
    grep -qxF -- "$cmd" <<<"$p" || { echo "$page: install command differs from README: $cmd" >&2; return 1; }
  done <<<"$r"
  while IFS= read -r cmd; do
    [ -z "$cmd" ] || grep -qxF -- "$cmd" <<<"$r" \
      || { echo "$page: carries an install command README's install block lacks: $cmd" >&2; return 1; }
  done <<<"$p"
  [ "$p" = "$r" ] || { echo "$page: the install commands are not README's, once each and in order" >&2; return 1; }
}

# check_hero_word <page> — the word "requirements" is visible text inside the
# element id=hero.
check_hero_word() {
  local t
  _need "$1" || return 2
  t="$(landing_py text --within hero "$1")" || return $?
  grep -qiw requirements <<<"$t" || { echo "$1: no 'requirements' in the hero section" >&2; return 1; }
}

# _article <html> — the lines between <article> and </article> of a built page;
# the whole file for a page with no <article> line (a filled source copy). The
# top bar and the footer sit outside the article, so they are never counted.
_article() {
  if grep -qx '<article>' "$1"; then
    awk '/^<\/article>$/ { f = 0 } f { print } /^<article>$/ { f = 1 }' "$1"
  else
    cat "$1"
  fi
}

# check_no_issue_numbers <page> — no visible text node holds an issue number:
# '#' and a digit, or the "Issue-" form and a digit. Attributes, styles,
# scripts, comments and SVG colour values are not text.
check_no_issue_numbers() {
  local t hits rc=0
  _need "$1" || return 2
  t="$(landing_py text "$1")" || return 2
  [ -n "$t" ] || { echo "$1: no visible text read" >&2; return 1; }
  hits="$(grep -E '#[0-9]|Issue-[0-9]' <<<"$t")" || rc=$?
  case "$rc" in
    1) return 0 ;;
    0) echo "$1: an issue number in visible text: $(tr '\n' ' ' <<<"$hits")" >&2; return 1 ;;
    *) return 2 ;;
  esac
}

# check_scripts_off <phases-file> <page> <cmd>... — as a reader with scripts off
# sees the page (no <svg>, no closed <details> body, nothing hidden), every
# phase Name, every step and every given command is a whole line of visible
# text. Subject floor: the names and steps number STEP_COUNT plus the phases.
check_scripts_off() {
  local ph="$1" page="$2" split t name steps s n=0 np=0; shift 2
  [ "$#" -gt 0 ] || { echo "check_scripts_off: no commands" >&2; return 2; }
  _need "$ph" "$page" || return 2
  split="$(phase_split "$ph")" || return 2
  t="$(landing_py text --scripts-off --no-svg "$page")" || return 2
  while read -r name steps; do
    np=$((np + 1))
    # shellcheck disable=SC2086  # the steps are one word each
    for s in "$name" $steps; do
      n=$((n + 1))
      grep -qxF -- "$s" <<<"$t" || { echo "$page: $s is not visible with scripts off" >&2; return 1; }
    done
  done <<<"$split"
  [ "$n" -eq $((STEP_COUNT + np)) ] || { echo "$ph: $n names and steps, want $((STEP_COUNT + np))" >&2; return 1; }
  for s in "$@"; do
    grep -qxF -- "$s" <<<"$t" || { echo "$page: $s is not visible with scripts off" >&2; return 1; }
  done
}

# check_live_items <live.txt> <source> <filled> — every {{live:K|L}} of the
# source page renders in the filled page's article as live.txt says, read
# from live.txt itself (never from the filler): not live, the coming span and
# no link; live, a link to its URL. The coming labels number exactly the
# not-live placeholders (none is hand-written). Each strip item (.landing-rungs,
# .landing-family) holds exactly one placeholder. Floors: 7 placeholders, at
# least one live and one not.
check_live_items() {
  local live="$1" src="$2" filled="$3" art ph k l state url yes=0 no=0 n=0 coming list items li linked
  _need "$live" "$src" "$filled" || return 2
  art="$(_article "$filled")" || return 2
  for list in landing-rungs landing-family; do
    items="$(awk -v c="class=\"$list\"" 'index($0, c) { f = 1; next } f && /^<\/(ol|ul)>/ { exit } f && /^<li>/' "$src")"
    [ -n "$items" ] || { echo "$src: no <li> items in .$list" >&2; return 1; }
    while IFS= read -r li; do
      [ "$(grep -o '{{live:' <<<"$li" | wc -l)" -eq 1 ] \
        || { echo "$src: a .$list item does not hold exactly one live placeholder: $li" >&2; return 1; }
    done <<<"$items"
  done
  while IFS= read -r ph; do
    [ -n "$ph" ] || continue
    n=$((n + 1))
    k="${ph#\{\{live:}"; k="${k%%|*}"
    l="${ph#*|}"; l="${l%\}\}}"
    read -r state url < <(awk -v k="$k" '$1 == "live" && $2 == k { print $3, $4 }' "$live")
    case "$state" in
      no)
        no=$((no + 1))
        grep -qF -- "<span class=\"family-coming\">$l <small>coming</small></span>" <<<"$art" \
          || { echo "$filled: live item $k ($l) is not live, but its coming label is not there" >&2; return 1; }
        ! grep -qF -- ">$l</a>" <<<"$art" \
          || { echo "$filled: live item $k ($l) is not live, but it links" >&2; return 1; } ;;
      yes)
        yes=$((yes + 1))
        grep -qF -- "<a href=\"${url//&/&amp;}\">$l</a>" <<<"$art" \
          || { echo "$filled: live item $k ($l) is live, but there is no link to $url" >&2; return 1; } ;;
      *) echo "$live: no live line for $k (used by $src)" >&2; return 1 ;;
    esac
  done < <(grep -oE '\{\{live:[a-z0-9-]+\|[^{}|<>"]+\}\}' "$src")
  coming="$(grep -o '<small>coming</small>' <<<"$art" | wc -l)"
  [ "$coming" -eq "$no" ] || { echo "$filled: $coming coming labels, but $no not-live placeholders" >&2; return 1; }
  linked="$(landing_py linked-coming --article "$filled")" || return 2
  [ -z "$linked" ] || { echo "$filled: a not-live item sits inside a link: ${linked//$'\n'/, }" >&2; return 1; }
  [ "$n" -ge 7 ] || { echo "$src: $n live placeholders, want >= 7" >&2; return 1; }
  [ "$yes" -ge 1 ] && [ "$no" -ge 1 ] || { echo "$src: want at least one live and one not-live item ($yes live, $no not)" >&2; return 1; }
}

# check_req_count <live.txt> <source> <filled> — the source shows the
# requirement count only through the placeholder (a literal would go stale),
# and the filled page shows the number the filler counts with live.txt's rule
# (tests/test_own_requirements.py pins that rule to the requirements reader).
check_req_count() {
  local live="$1" src="$2" filled="$3" got want probe
  _need "$live" "$src" "$filled" "$FILLER_PY" || return 2
  [ "$(grep -o 'class="landing-req-count">{{count:requirements}}<' "$src" | wc -l)" -eq 1 ] \
    || { echo "$src: the requirement count is not exactly one {{count:requirements}} placeholder (a literal goes stale)" >&2; return 1; }
  got="$(_article "$filled" | grep -oE 'class="landing-req-count">[0-9]+<' | grep -oE '[0-9]+')"
  [ -n "$got" ] && [[ "$got" != *$'\n'* ]] \
    || { echo "$filled: not exactly one filled landing-req-count: '$got'" >&2; return 1; }
  probe="$(mktemp)" || return 2
  printf 'n={{count:requirements}}\n' >"$probe"
  python3 -I -X utf8 "$FILLER_PY" --settings "$live" "$probe" >/dev/null || { rm -f "$probe"; return 2; }
  want="$(sed -n 's/^n=\([0-9][0-9]*\)$/\1/p' "$probe")"; rm -f "$probe"
  [ -n "$want" ] || return 2
  [ "$got" = "$want" ] || { echo "$filled: landing-req-count $got, but the filler counts $want" >&2; return 1; }
}

# check_install_only <page> — the landing page's visible text names no install
# detail beyond the commands (superpowers, userConfig, the official marketplace,
# prerequisites stay on the install page), and its install section links the
# install page.
check_install_only() {
  local page="$1" t hits links rc=0
  _need "$page" || return 2
  t="$(landing_py text --article "$page")" || return 2
  [ -n "$t" ] || { echo "$page: no visible text read" >&2; return 1; }
  hits="$(grep -oiE 'superpowers|userConfig|claude-plugins-official|prerequisite' <<<"$t")" || rc=$?
  case "$rc" in
    1) ;;
    0) echo "$page: install detail on the landing page: $(sort -u <<<"$hits" | tr '\n' ' ')" >&2; return 1 ;;
    *) return 2 ;;
  esac
  links="$(landing_py links --within install "$page")" || return $?
  grep -qxE '(\./)?install\.html' <<<"$links" || { echo "$page: the install section does not link install.html" >&2; return 1; }
}

# check_nav_section <site-dir> — the index's page list (site_pages, the build's
# nav) is exactly the page links of its id=next section, in order: a page link
# opening an <li> line anywhere earlier on the index would reorder the nav.
check_nav_section() {
  local dir="$1" want got
  _need "$dir/index.html" || return 2
  want="$(site_pages "$dir")" || return 2
  got="$(landing_py links --within next "$dir/index.html")" || return $?
  got="$(sed -nE 's#^(\./)?([a-z0-9_-]+)\.html$#\2#p' <<<"$got" | awk '$0 != "index" && !seen[$0]++')"
  [ -n "$want" ] || { echo "$dir/index.html: no page list read" >&2; return 2; }
  [ "$got" = "$want" ] || {
    echo "$dir/index.html: the nav list ($(tr '\n' ' ' <<<"$want")) is not the #next section's page links ($(tr '\n' ' ' <<<"$got"))" >&2
    return 1
  }
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

# _region <file> <start-ERE> <end-ERE> — the first line matching start, then
# every following line up to, not including, the next line matching end. The
# one region reader of the How it works checks: the pre-table region ('^# ' to
# the step-table header), the stop section, README's step-workflow section.
# Returns 1 naming the missing line. The EREs reach awk through the environment,
# so a '\|' is not an awk -v escape.
_region() {
  local f="$1" out rc=0
  out="$(_RS="$2" _RE="$3" awk '
    !f && $0 ~ ENVIRON["_RS"] { f = 1; print; next }
    f && $0 ~ ENVIRON["_RE"] { done = 1; exit }
    f { print }
    END { if (!f) exit 3; if (!done) exit 4 }' "$f")" || rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" ;;
    3) echo "$f: no line matches /$2/" >&2; return 1 ;;
    4) echo "$f: no line matches /$3/ after /$2/" >&2; return 1 ;;
    *) echo "_region: cannot read $f" >&2; return 2 ;;
  esac
}

# The step table's header line: its first cell is '#'.
_TABLE_HEAD='^\| *# *\|'

# _table_col <page> <name> — the 1-based '|'-split field index of the step-table
# header cell whose trimmed text is <name>. Columns are found by name, never by
# position, so a reordered table still checks the column it names.
_table_col() {
  local i
  i="$(_TH="$_TABLE_HEAD" awk -F'|' -v want="$2" '
    $0 ~ ENVIRON["_TH"] {
      for (i = 2; i < NF; i++) { c = $i; gsub(/^[ \t]+|[ \t]+$/, "", c); if (c == want) { print i; exit } }
      exit
    }' "$1")" || { echo "_table_col: cannot read $1" >&2; return 2; }
  [ -n "$i" ] || { echo "$1: no $2 column in the step table header" >&2; return 1; }
  printf '%s\n' "$i"
}

# check_phase_column <phases-file> <page> — #1001: each step row's Phase cell is
# the phase that holds the row's command in the phase-split file. The Phase and
# Command columns are found by header name, and only they are read, so the
# Command cell `implement` cannot read as the retired phase "Implement". A
# retired 1.0 phase name is named first. Floor, checked last: STEP_COUNT rows.
check_phase_column() {
  local ph="$1" page="$2" split pc cc name steps s rows num cmd phase want n=0
  local -A of=()
  _need "$ph" "$page" || return 2
  split="$(phase_split "$ph")" || return 2
  [ -n "$split" ] || { echo "$ph: no phases read" >&2; return 2; }
  while read -r name steps; do
    # shellcheck disable=SC2086  # the steps are one word each
    for s in $steps; do of[$s]="$name"; done
  done <<<"$split"
  pc="$(_table_col "$page" Phase)" || return $?
  cc="$(_table_col "$page" Command)" || return $?
  rows="$(awk -F'|' -v p="$pc" -v c="$cc" '
    /^\| *[0-9]+ *\|/ {
      n = $2; x = $c; y = $p
      gsub(/[ \t`]/, "", n); gsub(/[ \t`]/, "", x); gsub(/^[ \t]+|[ \t]+$/, "", y)
      printf "%s\037%s\037%s\n", n, x, y
    }' "$page")" || return 2
  while IFS=$'\037' read -r num cmd phase; do
    [ -n "$num" ] || continue
    n=$((n + 1))
    case "$phase" in
      Implement|"Integrate & close") echo "$page: retired phase name '$phase' at step $num" >&2; return 1 ;;
    esac
    want=""; [ -z "$cmd" ] || want="${of[$cmd]:-}"
    [ -n "$want" ] || { echo "$page: step $num ($cmd) is in no phase of $ph" >&2; return 1; }
    [ "$phase" = "$want" ] || { echo "$page: step $num ($cmd): Phase '$phase', want '$want'" >&2; return 1; }
  done <<<"$rows"
  [ "$n" -eq "$STEP_COUNT" ] || { echo "$page: $n step rows, want $STEP_COUNT" >&2; return 1; }
}

# check_why_column <template> <page> — #1001: the step table has a Why column
# (found by header name); every numbered row has the header's cell count (a '|'
# inside a cell, or a row split across lines, changes it); every row's Why cell
# is non-blank; and the Why cells number the template's steps.
check_why_column() {
  local tmpl="$1" page="$2" want wc out rc=0
  _need "$tmpl" "$page" || return 2
  want="$(_step_n "$tmpl")" || return 2
  wc="$(_table_col "$page" Why)" || return $?
  out="$(_TH="$_TABLE_HEAD" awk -F'|' -v w="$wc" '
    !h && $0 ~ ENVIRON["_TH"] { h = NF - 2; next }
    /^\| *[0-9]+ *\|/ {
      n = $2; gsub(/[ \t]/, "", n)
      if (NF - 2 != h) { printf "row %s: %d cells, header has %d\n", n, NF - 2, h; bad = 1; exit }
      c = $w; gsub(/[ \t]/, "", c)
      if (c == "") { printf "step %s: empty Why cell\n", n; bad = 1; exit }
      k++
    }
    END { if (bad) exit 1; print k + 0 }' "$page")" || rc=$?
  case "$rc" in
    0) ;;
    1) echo "$page: $out" >&2; return 1 ;;
    *) return 2 ;;
  esac
  [ "$out" -eq "$want" ] || { echo "$page: $out Why cells, want $want (the steps of $tmpl)" >&2; return 1; }
}

# check_pre_table <skel> <page> — #1001: before the step table (the H1 to the
# table header) the page shows no issue number and no config key name. The keys
# are read from the config skeleton: each dotted part that holds an underscore
# (merge_mr, phase_breaks, all_prs_branch ...). BLIND SPOT: single-word keys
# (analyze, branch, repo, backend ...) are also step names or plain English, so
# they are not checked. Floors: >= 20 keys read (cannot run otherwise), >= 3
# non-blank region lines.
check_pre_table() {
  local skel="$1" page="$2" region hits keys k n rc=0
  _need "$skel" "$page" || return 2
  region="$(_region "$page" '^# ' "$_TABLE_HEAD")" || return $?
  hits="$(grep -E '#[0-9]|Issue-[0-9]' <<<"$region")" || rc=$?
  case "$rc" in
    1) ;;
    0) echo "$page: an issue number before the step table: $(head -1 <<<"$hits")" >&2; return 1 ;;
    *) return 2 ;;
  esac
  keys="$(sed -nE 's/^#? ?([a-z][a-z0-9_.]*) +=.*/\1/p' "$skel" | tr '.' '\n' | grep '_' | sort -u)" || true
  n="$(grep -c . <<<"$keys" || true)"
  [ "$n" -ge 20 ] || { echo "$skel: $n underscore config keys read, want >= 20" >&2; return 2; }
  while IFS= read -r k; do
    rc=0; grep -qwF -- "$k" <<<"$region" || rc=$?
    case "$rc" in
      1) ;;
      0) echo "$page: config key $k before the step table" >&2; return 1 ;;
      *) return 2 ;;
    esac
  done <<<"$keys"
  n="$(grep -c '[^[:space:]]' <<<"$region" || true)"
  [ "$n" -ge 3 ] || { echo "$page: $n non-blank lines before the step table, want >= 3" >&2; return 1; }
}

# check_stop_section <page> <template> <next-sh> — #1001: the page's "## When it
# stops" section names, in this order: [?], the word waiting, the [?] label of
# the template's State key line, [!], the phase break, --through, and each
# default phase-break step as `<step>`. The defaults are read from the one
# printf line inside next.sh's phase_breaks() whose argument is a literal word
# list. Tokens are literals (grep -F): '[?]' is a bracket expression as a regex.
check_stop_section() {
  local page="$1" tmpl="$2" nextsh="$3" region label line re tok rc
  _need "$page" "$tmpl" "$nextsh" || return 2
  grep -qx '## When it stops' "$page" || { echo "$page: no \"## When it stops\" section" >&2; return 1; }
  region="$(_region "$page" '^## When it stops$' '^## ')" || return $?
  label="$(sed -n 's/^State key:.*\[?\] \([^ ]*\).*$/\1/p' "$tmpl" | head -1)"
  [ -n "$label" ] || { echo "$tmpl: cannot read the [?] label from its State key line" >&2; return 2; }
  re="printf '%s\\\\n' \"[a-z ]+\""
  line="$(sed -n '/^phase_breaks() {$/,/^}$/p' "$nextsh" | grep -E -- "$re")" || true
  [ -n "$line" ] && [[ "$line" != *$'\n'* ]] \
    || { echo "$nextsh: not exactly one line in phase_breaks() matches $re" >&2; return 2; }
  line="${line#*\"}"; line="${line%\"*}"
  for tok in '[?]' waiting "$label" '[!]' 'phase break' '--through'; do
    rc=0
    case "$tok" in
      waiting) grep -qiw -- "$tok" <<<"$region" || rc=$? ;;
      'phase break') grep -qi -- "$tok" <<<"$region" || rc=$? ;;
      *) grep -qF -- "$tok" <<<"$region" || rc=$? ;;
    esac
    [ "$rc" -le 1 ] || return 2
    [ "$rc" -eq 0 ] || { echo "$page: the When it stops section does not name $tok" >&2; return 1; }
  done
  for tok in $line; do
    grep -qF -- "\`$tok\`" <<<"$region" \
      || { echo "$page: the When it stops section does not name the default break \`$tok\`" >&2; return 1; }
  done
}

# _hint_fit <name> <hint> <arg>... — one example of /devagent:<name> fits the
# command's argument hint. The hint is tokenised with [ and ] spaced out;
# depth-0 tokens are required; a --flag followed by a <placeholder> in its group
# is a pair. R1 every argument is a hint token; R2 every required token is
# given; R3 a paired flag is directly followed by its placeholder.
_hint_fit() {
  local name="$1" hint="$2" sp t a i depth=0; shift 2
  local -a toks=() req=() args=("$@")
  local -A inh=() pair=()
  sp="${hint//\[/ [ }"; sp="${sp//\]/ ] }"
  read -r -a toks <<<"$sp"
  for ((i = 0; i < ${#toks[@]}; i++)); do
    t="${toks[i]}"
    case "$t" in
      '[') depth=$((depth + 1)); continue ;;
      ']') depth=$((depth - 1)); continue ;;
    esac
    inh[$t]=1
    [ "$depth" -ne 0 ] || req+=("$t")
    if [[ "$t" == --* ]] && [[ "${toks[i + 1]:-}" == \<*\> ]]; then pair[$t]="${toks[i + 1]}"; fi
  done
  for a in "${args[@]}"; do
    [ -n "${inh[$a]+x}" ] || { echo "/devagent:$name: '$a' is not in its argument hint $hint" >&2; return 1; }
  done
  for t in "${req[@]}"; do
    [[ " ${args[*]} " == *" $t "* ]] || { echo "/devagent:$name: missing required $t" >&2; return 1; }
  done
  for ((i = 0; i < ${#args[@]}; i++)); do
    a="${args[i]}"
    [ -n "${pair[$a]+x}" ] || continue
    [ "${args[i + 1]:-}" = "${pair[$a]}" ] || { echo "/devagent:$name: $a needs ${pair[$a]}" >&2; return 1; }
  done
}

# check_example_hints <page> <root> — #1001: every backticked span on the page
# that begins /devagent:<name> fits that command's argument-hint (the first
# argument-hint: line of <root>/commands/<name>.md, else
# <root>/skills/<name>/SKILL.md; one outer quote pair removed; no hint means no
# arguments). Spans are read per source line, so each sits on one line. Each
# example is checked (R1-R3, _hint_fit) in page order; the subject floor comes
# last: a /devagent:next example with --through, and a /devagent:unstuck one.
check_example_hints() {
  local page="$1" root="$2" spans span name f hint through=0 unstuck=0
  local -a w
  _need "$page" || return 2
  spans="$(grep -o '`[^`]*`' "$page" | tr -d '`' | grep '^/devagent:')" || true
  while IFS= read -r span; do
    [ -n "$span" ] || continue
    read -r -a w <<<"$span"
    name="${w[0]#/devagent:}"
    f="$root/commands/$name.md"
    [ -f "$f" ] || f="$root/skills/$name/SKILL.md"
    [ -f "$f" ] || { echo "$page: no command file for /devagent:$name" >&2; return 1; }
    hint="$(sed -n 's/^argument-hint: *//p' "$f" | head -1)"
    case "$hint" in
      \"*\") hint="${hint#\"}"; hint="${hint%\"}" ;;
      \'*\') hint="${hint#\'}"; hint="${hint%\'}" ;;
    esac
    _hint_fit "$name" "$hint" "${w[@]:1}" || return 1
    case "$name" in
      next) [[ " ${w[*]} " != *" --through "* ]] || through=$((through + 1)) ;;
      unstuck) unstuck=$((unstuck + 1)) ;;
    esac
  done <<<"$spans"
  [ "$through" -ge 1 ] || { echo "$page: subject floor: no /devagent:next example with --through" >&2; return 1; }
  [ "$unstuck" -ge 1 ] || { echo "$page: subject floor: no /devagent:unstuck example" >&2; return 1; }
}

# check_phase_bullets <phases-file> <template> <file> <start-ERE> <end-ERE> —
# #1001: inside the region, the phase bullets ("- **Name** — `step` · ..."; any
# bold name is read, so a retired one is caught) are the phase-split file's: in
# order (1) one bullet per phase, (2) the names in order, (3) each phase's steps
# in order (its `step` or `N step` tokens), (4) a number beside a step is its
# template number, (5) LAST the steps number STEP_COUNT. Each bullet sits on one
# line, and its trailing sentence backticks no single lowercase word (it would
# read as a step).
check_phase_bullets() {
  local ph="$1" tmpl="$2" file="$3" region split steps name got want tok num cmd i np total=0
  local -a bl=() names=() stepsof=()
  local -A tnum=()
  _need "$ph" "$tmpl" "$file" || return 2
  split="$(phase_split "$ph")" || return 2
  steps="$(template_steps "$tmpl")" || return 2
  [ -n "$split" ] || { echo "$ph: no phases read" >&2; return 2; }
  region="$(_region "$file" "$4" "$5")" || return $?
  while read -r num cmd; do tnum[$cmd]=$num; done <<<"$steps"
  while read -r name got; do names+=("$name"); stepsof+=("$got"); done <<<"$split"
  np="${#names[@]}"
  mapfile -t bl < <(grep -E '^- \*\*[^*]+\*\* — ' <<<"$region")
  [ "${#bl[@]}" -eq "$np" ] || { echo "$file: ${#bl[@]} bullets read, want $np" >&2; return 1; }
  for ((i = 0; i < np; i++)); do
    name="${bl[i]#- \*\*}"; name="${name%%\*\* — *}"
    [ "$name" = "${names[i]}" ] || { echo "$file: bullet $((i + 1)) is '$name', want '${names[i]}'" >&2; return 1; }
  done
  for ((i = 0; i < np; i++)); do
    got="$(grep -oE '`([0-9]+ )?[a-z]+`' <<<"${bl[i]}" | tr -d '`' | sed 's/^[0-9]* //' | tr '\n' ' ')"
    got="${got% }"
    [ "$got" = "${stepsof[i]}" ] \
      || { echo "$file: phase ${names[i]}: steps '$got', want '${stepsof[i]}'" >&2; return 1; }
  done
  for ((i = 0; i < np; i++)); do
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      total=$((total + 1))
      [[ "$tok" == *" "* ]] || continue
      num="${tok%% *}"; cmd="${tok#* }"
      [ "$num" = "${tnum[$cmd]:-}" ] \
        || { echo "$file: phase ${names[i]}: $num $cmd, template says ${tnum[$cmd]:-nothing}" >&2; return 1; }
    done < <(grep -oE '`([0-9]+ )?[a-z]+`' <<<"${bl[i]}" | tr -d '`')
  done
  [ "$total" -eq "$STEP_COUNT" ] || { echo "$file: $total steps in bullets, want $STEP_COUNT" >&2; return 1; }
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

# The floor of the install page's Prerequisites list (#999): the tools the
# page must list. The list may name more; each must be in README.
PAGE_PREREQ_TOOLS=(bash python3 jq git gh shellcheck timeout)

# _bold_para <file> <label> [normalise 0|1] — the paragraph that opens with the
# literal <label> (e.g. "**Prerequisites.**"), to its first blank line. With
# normalise=1 it is one line, whitespace runs squeezed (so a reflow or CRLF bytes
# compare equal) and edge-trimmed. Empty when the file has no such paragraph.
_bold_para() {
  awk -v l="$2" -v n="${3:-0}" '
    index($0, l) == 1 { f = 1 }
    f && /^$/ { exit }
    f { if (n) s = s " " $0; else print }
    END { if (n && s != "") { gsub(/[[:space:]]+/, " ", s); gsub(/^ | $/, "", s); print s } }' "$1"
}

# _readme_prereqs <readme> — README's "**Prerequisites.**" paragraph. The one
# reader of that region (check_prereqs_trace and check_shellcheck_homes).
_readme_prereqs() { _bold_para "$1" '**Prerequisites.**'; }

# _prereq_list <page> — the bullets (with their two-space continuation lines,
# so a reflow cannot drop a tool) inside the page's "## Prerequisites" section
# only. Prose there (the platform paragraph) and every later section are out.
_prereq_list() {
  awk '/^## /{s = /^## Prerequisites$/; b = 0; next}
       s && /^- /{b = 1; print; next}
       s && b && /^  [^ ]/{print; next}
       {b = 0}' "$1"
}

# check_prereqs_trace <page> <readme> — one way (#999): the page's
# Prerequisites list (its backticked single words) names every
# PAGE_PREREQ_TOOLS entry, every tool it names is backticked in README's
# Prerequisites paragraph, and neither side claims the repo is private.
check_prereqs_trace() {
  local page="$1" readme="$2" list rp tools t f rc
  _need "$page" "$readme" || return 2
  list="$(_prereq_list "$page")"
  [ -n "$list" ] || { echo "$page: no Prerequisites list" >&2; return 1; }
  rp="$(_readme_prereqs "$readme")"
  [ -n "$rp" ] || { echo "$readme: no **Prerequisites.** paragraph" >&2; return 2; }
  tools="$(grep -oE '`[a-z][a-z0-9]*`' <<<"$list" | tr -d '`' | sort -u)"
  for t in "${PAGE_PREREQ_TOOLS[@]}"; do
    [[ $'\n'"$tools"$'\n' == *$'\n'"$t"$'\n'* ]] || { echo "$page: page list is missing \`$t\`" >&2; return 1; }
  done
  while IFS= read -r t; do
    [[ "$rp" == *"\`$t\`"* ]] || { echo "$page: not in README Prerequisites: \`$t\`" >&2; return 1; }
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

# The #579 platform posture claims: README carries each (check_platform_tokens),
# and the install page's copied platform paragraph keeps each
# (check_platform_sentence). One list, so the two cannot drift.
PLATFORM_CLAIMS=('developed and tested on **Linux**' 'WSL' 'Git Bash' 'macOS is currently untested' 'readlink -f')

# check_platform_tokens <file> — the file names every PLATFORM_CLAIMS entry.
check_platform_tokens() {
  local f="$1" text c
  _need "$f" || return 2
  text="$(<"$f")"
  for c in "${PLATFORM_CLAIMS[@]}"; do
    [[ "$text" == *"$c"* ]] || { echo "$f: no platform posture token: $c" >&2; return 1; }
  done
}

# _platform_para <file> — the "**Supported platforms.**" paragraph, normalised.
_platform_para() { _bold_para "$1" '**Supported platforms.**' 1; }

# check_platform_sentence <page> <readme> — #999: the page's platform paragraph
# is README's, word for word, or README's cut at a sentence boundary (the page
# keeps the user-facing claims; README goes on to the CI detail), and it keeps
# each user-facing claim. LIMIT: only the page's span is compared, so a README
# edit AFTER the page's cut point stays green.
check_platform_sentence() {
  local page="$1" readme="$2" r p claim
  _need "$page" "$readme" || return 2
  r="$(_platform_para "$readme")"
  [ -n "$r" ] || { echo "$readme: no **Supported platforms.** paragraph" >&2; return 2; }
  p="$(_platform_para "$page")"
  [ -n "$p" ] || { echo "$page: no **Supported platforms.** paragraph" >&2; return 1; }
  if [ "$p" != "$r" ]; then
    [[ "$p" == *. && "$r" == "$p "* ]] || {
      echo "$page: the platform paragraph is not README's, word for word, cut at a sentence end" >&2
      return 1
    }
  fi
  for claim in "${PLATFORM_CLAIMS[@]}"; do
    [[ "$p" == *"$claim"* ]] || { echo "$page: platform paragraph drops the claim: $claim" >&2; return 1; }
  done
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
# history or floor claims and are never passed as roots. Floor: 5 live tokens,
# the measured census after #999 (README x3, install.md x1, the bug-report
# placeholder x1). #999 asked the floor to drop by the token leaving the page,
# assuming floor = count; the count before it was 6, so the floor stays 5.
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
# Prerequisites, the install page's Prerequisites list, config.toml.skel, the
# configuration page), commands/analyze.md (the one home of the detail) and the
# contributor homes. Major zero isolates the shellcheck version from the Claude
# Code and bash versions in the same files. The user floor equals the
# contributor floor by the policy in the scripts/analyze-shellcheck.sh header.
# RECORDED EXEMPTION: a token in the stamp form `analyzer: shellcheck <version>`
# is an example of a measured value, not a claim, and is not counted.
check_shellcheck_homes() {
  local root="$1" install="$2" config="$3" floor vals v h live=0 stale="" region text msg need
  local -a homes
  local -A count=()
  _need "$root/CONTRIBUTING.md" || return 2
  need="$(awk '/^## What you need$/{f=1; next} f && /^## /{exit} f' "$root/CONTRIBUTING.md")"
  floor="$(tr -s '[:space:]' ' ' <<<"$need" \
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

  # The contributor statement (#999 moved it off the install page): the
  # CONTRIBUTING.md "What you need" region names the test runner.
  [[ "$need" == *'`bats`'* ]] || { echo "CONTRIBUTING.md 'What you need' no longer names \`bats\`" >&2; return 1; }

  # The user statements, scoped to their regions: a deleted user statement reddens
  # even with the contributor statements in the same file intact.
  for region in \
      "$(_readme_prereqs "$root/README.md")" \
      "$(_prereq_list "$root/$install")"; do
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

  # Floor: 8 contributor tokens (README 1, CONTRIBUTING 1, pre-push 3,
  # the shellcheck.yml workflow 3) plus one per user statement (README, install page,
  # config.toml.skel, configuration page, commands/analyze.md) = 13. The pins
  # above catch a deleted user statement; this bound is the only guard on the
  # contributor tokens.
  [ "$live" -ge 13 ] || { echo "only $live live shellcheck version tokens, want >= 13" >&2; return 1; }
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

# check_merge_forward_docs <skel> <config-page> <mergemr-command> — #1125: the
# merge_forward opt-in is documented in each home a reader meets it: the
# skeleton (as a commented [project.{{PROJECT}}.merge_forward] block, AFTER the
# first [project.{{PROJECT}}] header — a block above it would read as
# [defaults]), the configuration page and commands/mergemr.md. Each names the
# table, verify = "ci", append_only and the remedy preship-verified-head.sh forward.
check_merge_forward_docs() {
  local skel="$1" config="$2" mergemr="$3" f tok first mf
  _need "$skel" "$config" "$mergemr" || return 2
  for f in "$skel" "$config" "$mergemr"; do
    for tok in 'merge_forward' 'verify = "ci"' 'append_only' 'preship-verified-head.sh forward'; do
      _has "$f" "$tok" "does not name $tok" || return 1
    done
  done
  first="$(grep -nF -m1 '[project.{{PROJECT}}]' "$skel" | cut -d: -f1)"
  mf="$(grep -nF -m1 '[project.{{PROJECT}}.merge_forward]' "$skel" | cut -d: -f1)"
  [ -n "$first" ] && [ -n "$mf" ] || { echo "$skel: no [project.{{PROJECT}}.merge_forward] block" >&2; return 1; }
  [ "$mf" -gt "$first" ] || { echo "$skel: the merge_forward block precedes [project.{{PROJECT}}]" >&2; return 1; }
}
