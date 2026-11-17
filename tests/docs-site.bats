#!/usr/bin/env bats
# #461, #997: the onboarding site's guard — FACTS, not wording.
#
# A fact is something that must stay true wherever it is written: the install
# commands match README, the workflow table derives from the checklist
# template, every backend verb is documented, the version homes agree. Wording
# (a page's sentence, which pages a walkthrough shows) is the pages' own
# business, and a rewrite of a page must not break a test here. The checks
# live in tests/lib/docs-site-checks.bash as functions that take their subject
# files as arguments (0 holds, 1 broken, 2 cannot run).
#
# Every check has a MUTATION leg below: it copies the subject to a temp dir,
# shows the unbroken copy passes (the control), breaks the fact, proves the edit
# took, and expects the SAME function to return exactly 1 with a reason.
#
# The page set is read, never listed here: the ONE page list is the index's own
# top-level list (index.html's <li><a href> lines; the build's nav source;
# docs-site/README.md). The content
# pages are the directory's *.md/*.html minus README.*, and check_page_set
# holds them equal to index plus that list.
#
# Classification of the 16 tests this file held before #997, as fact (kept) or
# wording (dropped, with its reason): the #997 MR body. The pins a later child
# owns are the lib's PAGE PINS block.

load 'lib/bats-helpers'
load 'lib/docs-site-checks'

WEB="$PLUGIN_ROOT/docs-site"
CONFIG_DOC="$PLUGIN_ROOT/$CONFIG_REL"
TEMPLATE="$PLUGIN_ROOT/templates/checklist-standard.md"
README="$PLUGIN_ROOT/README.md"

# content_pages — every content page of the site, full paths.
content_pages() { site_content "$WEB"; }

# reference_docs — REFERENCE_DOCS as full paths.
reference_docs() {
  local d
  for d in "${REFERENCE_DOCS[@]}"; do printf '%s\n' "$PLUGIN_ROOT/$d"; done
}

# holds <check> <arg>... — the check returns 0.
holds() {
  run "$@"
  [ "$status" -eq 0 ] || { echo "$1: status $status, want 0: $output" >&2; return 1; }
}

# breaks <reason-token> <check> <arg>... — the check returns exactly 1 and its
# reason names the token.
breaks() {
  local token="$1"; shift
  run "$@"
  [ "$status" -eq 1 ] || { echo "$1: status $status, want 1: $output" >&2; return 1; }
  [[ "$output" == *"$token"* ]] || { echo "$1: no '$token' in: $output" >&2; return 1; }
}

# edit <file> <from> <to> — replace every literal <from> with <to>; fail if the
# file did not change (an edit that silently no-ops proves nothing).
edit() {
  local f="$1" from="$2" to="$3" before after
  before="$(cat "$f")"
  after="${before//"$from"/"$to"}"
  [ "$after" != "$before" ] || { echo "edit: '$from' not in $f" >&2; return 1; }
  printf '%s\n' "$after" >"$f"
}

# drop <file> <literal> — delete every line containing the literal; fail if none.
drop() {
  local f="$1" lit="$2"
  grep -qF -- "$lit" "$f" || { echo "drop: '$lit' not in $f" >&2; return 1; }
  grep -vF -- "$lit" "$f" >"$f.tmp" || true
  mv "$f.tmp" "$f"
}

# plant <file> <line> — append a line; fail if it is not there after.
plant() {
  printf '%s\n' "$2" >>"$1"
  grep -qF -- "$2" "$1"
}

# fresh <src> — a pristine temp copy of <src>; prints its path.
fresh() {
  local dst="$BATS_TEST_TMPDIR/${1##*/}"
  cp "$1" "$dst"
  printf '%s\n' "$dst"
}

# temp_root <path>... — a temp repo root holding copies of the given
# root-relative files and directories; prints its path.
temp_root() {
  local t="$BATS_TEST_TMPDIR/root.$RANDOM$RANDOM" p
  mkdir -p "$t"
  for p in "$@"; do (cd "$PLUGIN_ROOT" && cp -r --parents "$p" "$t/"); done
  printf '%s\n' "$t"
}

# filled_index [<source>] — a fresh copy of <source> (default: the landing
# page) with its placeholders filled by the real filler from docs-site/live.txt
# (no pandoc needed); prints its path. The landing page is filled once per file.
filled_index() {
  local src="${1:-$WEB/index.html}" f="$BATS_TEST_TMPDIR/filled.$RANDOM$RANDOM.html"
  local once="$BATS_FILE_TMPDIR/filled-index.html"
  if [ -z "${1:-}" ] && [ -f "$once" ]; then cp "$once" "$f"; printf '%s\n' "$f"; return; fi
  cp "$src" "$f" || return 1
  python3 -I -X utf8 "$FILLER_PY" --settings "$WEB/live.txt" "$f" >/dev/null \
    || { echo "filled_index: the filler refused $f" >&2; return 1; }
  [ -n "${1:-}" ] || cp "$f" "$once"
  printf '%s\n' "$f"
}

# ---------------------------------------------------------------------------
# Facts
# ---------------------------------------------------------------------------

@test "docs-site: the content pages are exactly index plus the index's list, and README is present" {
  holds check_page_set "$WEB"
}

@test "docs-site: the reference documents keep their 1.0 site URLs as stubs to the forge" {
  holds check_reference_stubs "$WEB" "$PLUGIN_ROOT" "${REFERENCE_DOCS[@]}"
}

@test "docs-site: the reference page links the four reference documents" {
  holds check_reference_links "$WEB/reference.md" "${REFERENCE_LINKS[@]}"
}

@test "docs-site: every content page's line-1 derive header names existing sources" {
  local -a pages
  mapfile -t pages < <(content_pages; reference_docs)
  [ "$(content_pages | grep -c .)" -ge 1 ]
  holds check_derived_from "$PLUGIN_ROOT" "${pages[@]}"
}

@test "docs-site: the install commands, notice and version are shared with README; README carries the grant" {
  local f
  for f in "$WEB/install.md" "$README"; do
    holds check_install_block "$f"
    holds check_userconfig_notice "$f"
    holds check_verified_version "$f"
  done
  # #999: the grant forms and "Never widen" live on README only; the page links there.
  holds check_permission_grant "$README"
}

@test "docs-site: the headline step count is derived from the template, in README and the index" {
  holds check_step_headline "$TEMPLATE" "$README"
  holds check_step_headline "$TEMPLATE" "$WEB/index.html"
}

@test "docs-site: the workflow table derives from the checklist template steps" {
  holds check_step_table "$TEMPLATE" "$WEB/workflow.md"
}

@test "docs-site: the phase-split file covers each checklist-template step once, in order" {
  holds check_phase_split "$TEMPLATE" "$WEB/phases.txt"
}

@test "docs-site: the landing loop matches the phase-split file" {
  holds check_loop "$WEB/phases.txt" "$TEMPLATE" "$WEB/index.html"
}

@test "docs-site: the landing install commands are README's two, and only those" {
  holds check_install_pair "$README" "$WEB/index.html"
}

@test "docs-site: the nav list is exactly the landing page's 'Where to go next' links" {
  holds check_nav_section "$WEB"
}

@test "docs-site: 'requirements' appears in the landing hero" {
  holds check_hero_word "$WEB/index.html"
}

@test "docs-site: the filled landing page shows no issue number in its visible text" {
  local f
  f="$(filled_index)"
  holds check_no_issue_numbers "$f"
}

@test "docs-site: with scripts off the filled landing page shows every phase, step and install command" {
  local f cmds=()
  f="$(filled_index)"
  mapfile -t cmds < <(landing_cmds "$WEB/index.html")
  [ "${#cmds[@]}" -ge 1 ]
  holds check_scripts_off "$WEB/phases.txt" "$f" "${cmds[@]}"
}

@test "docs-site: every landing live item renders from live.txt, coming without a link, live with one" {
  local f
  f="$(filled_index)"
  holds check_live_items "$WEB/live.txt" "$WEB/index.html" "$f"
}

@test "docs-site: the landing requirement count is the placeholder, filled with the filler's count" {
  local f
  f="$(filled_index)"
  holds check_req_count "$WEB/live.txt" "$WEB/index.html" "$f"
}

@test "docs-site: the landing page carries no install detail beyond the commands, and links the install page" {
  local f
  f="$(filled_index)"
  holds check_install_only "$f"
}

@test "docs-site: the configuration reference names every backend verb" {
  holds check_backend_verbs "$CONFIG_DOC"
}

@test "docs-site: the audit step-count typo never appears in a page or reference document" {
  local -a pages
  mapfile -t pages < <(content_pages; reference_docs)
  [ "$(content_pages | grep -c .)" -ge 1 ]
  holds check_absent -F '21-step' "${pages[@]}"
}

@test "docs-site: the retired permanent-step-ID claim never appears; the live claim is derived (#558)" {
  local -a pages
  local f
  mapfile -t pages < <(content_pages; reference_docs)
  [ "$(content_pages | grep -c .)" -ge 1 ]
  holds check_absent -iE 'permanent(ly)?[ -]+numbered|permanent (step )?ids?' "${pages[@]}" "$README"
  # The landing page shows the numbers through <ol start>, not the sentence.
  for f in "$WEB/workflow.md" "$README"; do
    holds check_numbering_claim "$TEMPLATE" "$f"
  done
}

@test "docs-site: every install-page prerequisite is in README's Prerequisites" {
  holds check_prereqs_trace "$WEB/install.md" "$README"
}

@test "docs-site: the install page's platform paragraph is README's user-facing prefix" {
  holds check_platform_sentence "$WEB/install.md" "$README"
  holds check_platform_tokens "$README"
}

@test "docs-site: the install page shows no issue number in its visible text" {
  holds check_no_issue_numbers "$WEB/install.md"
}

@test "docs-site: command lines on every page are full-arity; the quickstart forms are gate-honest" {
  local -a pages
  mapfile -t pages < <(content_pages)
  holds check_command_arity "${pages[@]}"
  holds check_quickstart_forms "$WEB/quickstart.md"
}

@test "docs-site: the bash floor on the install page matches README and the potholes.sh guard (#611)" {
  holds check_bash_floor "$WEB/install.md" "$README" "$PLUGIN_ROOT/scripts/lib/potholes.sh"
}

@test "docs-site: every live Claude Code version home carries the verified-against pin (#579)" {
  holds check_cc_version_homes "$PLUGIN_ROOT" README.md docs-site .github/ISSUE_TEMPLATE "${REFERENCE_DOCS[@]}"
}

@test "docs-site: every shellcheck version home names the CONTRIBUTING.md version (#678)" {
  # Planted controls on the token reader itself. Each stamp control carries a
  # live sibling, so a dropped stamp token proves exemption, not a blind scan.
  [ "$(printf 'a analyzer: shellcheck 0.11.0 b 0.8.0' | _mz_live)" = 0.8.0 ]
  [ "$(printf 'analyzer:\n  shellcheck\n0.11.0 0.8.0\n' | _mz_live)" = 0.8.0 ]
  [ "$(printf 'x 0.8.0 10.9.0 1.0.0 2.1.223 pre-0.9.0' | _mz_live)" = $'0.8.0\n0.9.0' ]
  run _mz_live <"$WEB"
  [ "$status" -eq 2 ]
  holds check_shellcheck_homes "$PLUGIN_ROOT" docs-site/install.md "$CONFIG_REL"
}

@test "docs-site: merge step keys are documented in the skeleton and the configuration reference (#885)" {
  holds check_merge_keys "$PLUGIN_ROOT/templates/config.toml.skel" "$CONFIG_DOC" \
    "$PLUGIN_ROOT/CHANGELOG.md" "$WEB/workflow.md"
}

@test "#1125 docs: merge_forward is documented in the skeleton, configuration page and mergemr.md" {
  holds check_merge_forward_docs "$PLUGIN_ROOT/templates/config.toml.skel" "$CONFIG_DOC" \
    "$PLUGIN_ROOT/commands/mergemr.md"
}

# ---------------------------------------------------------------------------
# Mutation legs: control 0, then each break returns exactly 1.
# ---------------------------------------------------------------------------

@test "mutation: site_pages reads the list as the build does" {
  local d="$BATS_TEST_TMPDIR/w"
  mkdir -p "$d"
  printf '%s\n' '# T' '- [A](./a.md)' '```' '- [B](./b.md)' '```' '~~~' '- [E](./e.md)' '~~~' \
    '- [A again](./a.md)' '- [Home](./index.md)' '- [C](./c-d.html)' '  - [N](./n.md)' >"$d/index.md"
  run site_pages "$d"
  [ "$status" -eq 0 ]
  [ "$output" = $'a\nc-d' ]       # fenced b and e unlisted; a once; index and nested n skipped
  rm "$d/index.md"
  # The index.html list: one-line <li><a href="page.html"> entries outside
  # comments and <pre>/<code>/<script>/<style>/<template>/<textarea>.
  printf '%s\n' '<h1>T</h1>' '<!-- <li><a href="x.html">X</a></li> -->' '<pre>' \
    '<li><a href="y.html">Y</a></li>' '</pre>' '<ul>' '<li><a href="a.html">A</a></li>' \
    '<li class="k"><a class="m" href="./c-d.html">C</a></li>' '<li><a href="a.html">A again</a></li>' \
    '<li><a href="index.html">Home</a></li>' '<li><strong>No</strong> <a href="z.html">Z</a></li>' \
    '</ul>' >"$d/index.html"
  run site_pages "$d"
  [ "$status" -eq 0 ]
  [ "$output" = $'a\nc-d' ]       # commented x, <pre> y, index and the non-entry z skipped; a once
  printf '%s\n' '<ul>' '<li>' '' '  <a href="b.html">B</a></li>' '</ul>' >"$d/index.html"
  run site_pages "$d"
  [ "$status" -eq 2 ]
  [[ "$output" == *"index.html:2: <li> and its <a href> must share a line"* ]]
  rm "$d/index.html"
  run site_pages "$d"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no index.md"* ]]
}

# lc_page <html-fragment> — write a fixture page; prints its path.
lc_page() {
  local f="$BATS_TEST_TMPDIR/lc.$RANDOM$RANDOM.html"
  printf '%s\n' "$1" >"$f"
  printf '%s\n' "$f"
}

# lc_has <line> — $output holds the exact line. lc_lacks <text> — $output
# does not hold the text (grep's status pinned to 1, so an error is not "absent").
lc_has() { grep -qxF -- "$1" <<<"$output" || { echo "no line '$1' in: $output" >&2; return 1; }; }
lc_lacks() {
  local rc=0
  grep -qF -- "$1" <<<"$output" || rc=$?
  [ "$rc" -eq 1 ] || { echo "'$1' read (status $rc) in: $output" >&2; return 1; }
}

@test "mutation: landing-check text reads text nodes, never attributes or styles" {
  local f
  f="$(lc_page '<html><head><style>p{color:#112233}</style></head><body>
<p>see #12</p><svg><text>#7</text><rect fill="#123456"/></svg>
<p style="color:#123">x</p><!-- #12 --><script>var a="#12"</script>
<a href="#1x">y</a><p>caf&eacute; &amp; more</p></body></html>')"
  run landing_py text "$f"
  [ "$status" -eq 0 ]
  lc_has 'see #12'
  lc_has '#7'
  lc_has 'x'
  lc_has 'y'
  lc_has 'café & more'
  [ "$(grep -c '#' <<<"$output")" -eq 2 ]     # only the two text-node marks
  lc_lacks '#123'
  lc_lacks '#112233'
  lc_lacks 'var a'
  lc_lacks '#1x'
}

@test "mutation: landing-check text --scripts-off and --no-svg" {
  local f
  f="$(lc_page '<details><summary>S</summary><p>in</p></details>')"
  run landing_py text --scripts-off "$f"
  [ "$status" -eq 0 ]
  [ "$output" = S ]
  run landing_py text "$f"
  [ "$output" = $'S\nin' ]
  f="$(lc_page '<details open><summary>S</summary><p>in</p></details>')"
  run landing_py text --scripts-off "$f"
  [ "$output" = $'S\nin' ]
  f="$(lc_page '<p hidden>h</p><p style="display: none">d</p><p style="visibility:hidden">v</p><template><p>t</p></template><p>shown</p>')"
  run landing_py text --scripts-off "$f"
  [ "$output" = shown ]
  f="$(lc_page '<p>a</p><svg><title>T</title><text>svgtext</text></svg>')"
  run landing_py text --no-svg "$f"
  [ "$output" = a ]
  run landing_py text "$f"
  lc_has svgtext
  # --within: a void <img> inside the section does not swallow its siblings,
  # and the read stops at </section>.
  f="$(lc_page '<section id="hero"><img src="a.svg" alt="pic"><h1>Title</h1><br><p>under</p></section><p>after</p>')"
  run landing_py text --within hero "$f"
  [ "$status" -eq 0 ]
  [ "$output" = $'Title\nunder' ]
  run landing_py text --within absent "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no element id=absent"* ]]
  # --article: the first <article>, or the whole document without one.
  f="$(lc_page '<nav>top</nav><article><p>body</p></article><footer>foot</footer>')"
  run landing_py text --article "$f"
  [ "$output" = body ]
  f="$(lc_page '<p>whole</p>')"
  run landing_py text --article "$f"
  [ "$output" = whole ]
  run landing_py text "$BATS_TEST_TMPDIR/absent.html"
  [ "$status" -eq 2 ]
}

@test "mutation: landing-check codes, links and loop" {
  local f
  f="$(lc_page '<pre><code id="a">claude a &amp; b</code></pre><p>x <code>two</code></p>')"
  run landing_py codes "$f"
  [ "$status" -eq 0 ]
  [ "$output" = $'claude a & b\ntwo' ]
  f="$(lc_page '<section id="install"><a href="install.html">I</a><a name="n">no href</a></section><a href="out.html">o</a>')"
  run landing_py links --within install "$f"
  [ "$status" -eq 0 ]
  [ "$output" = install.html ]
  f="$(lc_page '<section id="loop"><svg>
<a href="#phase-plan"><g data-phase="plan"><rect/><text class="loop-name">Plan</text><text class="loop-steps">pull … draft</text></g></a>
<a href="#phase-ship"><g data-phase="ship"><text class="loop-name">Ship</text><text class="loop-steps">ship</text></g></a>
</svg><ol class="landing-phases">
<li id="phase-plan"><details open><summary>Plan</summary><ol><li>pull</li><li>draft</li></ol></details></li>
<li id="phase-ship"><details><summary>Ship</summary><ol start="18"><li>ship</li></ol></details></li>
</ol></section>')"
  run landing_py loop "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'svg\tplan\tPlan\tpull … draft\nsvg\tship\tShip\tship\nlist\tplan\tyes\t1\tPlan\tpull draft\nlist\tship\tno\t18\tShip\tship')" ]
  f="$(lc_page '<section id="other"></section>')"
  run landing_py loop "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no element id=loop"* ]]
  run landing_py nope "$f"
  [ "$status" -eq 2 ]
  f="$(lc_page '<p><a href="x"><span class="family-coming">G <small>coming</small></span></a> <span class="family-coming">B <small>coming</small></span></p>')"
  run landing_py linked-coming "$f"
  [ "$status" -eq 0 ]
  [ "$output" = 'G coming' ]
}

@test "mutation: nav section" {
  local d="$BATS_TEST_TMPDIR/web"
  cp -r "$WEB" "$d"
  holds check_nav_section "$d"
  edit "$d/index.html" $'<ul>\n<li><strong>Requirements first.' $'<ul>\n<li><a href="workflow.html">Steps</a> first.</li>\n<li><strong>Requirements first.'
  breaks "is not the #next section's page links" check_nav_section "$d"
}

@test "mutation: page set" {
  local d="$BATS_TEST_TMPDIR/web"
  cp -r "$WEB" "$d"
  holds check_page_set "$d"
  printf '%s\n' '<!-- derived-from: README.md -->' '# Extra' >"$d/extra.md"
  breaks 'extra' check_page_set "$d"
  rm "$d/extra.md"; holds check_page_set "$d"
  rm "$d/workflow.md"
  breaks 'workflow' check_page_set "$d"
  cp "$WEB/workflow.md" "$d/"; rm "$d/README.md"
  breaks 'README' check_page_set "$d"
}

@test "mutation: derived-from" {
  local p
  p="$(fresh "$WEB/install.md")"
  holds check_derived_from "$PLUGIN_ROOT" "$p"
  sed -i '1s|derived-from: [^ ]*|derived-from: no/such/file.md|' "$p"
  grep -q '^<!-- derived-from: no/such/file.md' "$p"
  breaks 'no/such/file.md' check_derived_from "$PLUGIN_ROOT" "$p"
  p="$(fresh "$WEB/install.md")"
  sed -i '1d' "$p"
  [[ "$(head -1 "$p")" != *derived-from* ]]
  breaks 'line 1' check_derived_from "$PLUGIN_ROOT" "$p"
  # A reference document in docs/ carries the same header.
  p="$(fresh "$PLUGIN_ROOT/$CONCURRENCY_REL")"
  holds check_derived_from "$PLUGIN_ROOT" "$p"
  sed -i '1d' "$p"
  [[ "$(head -1 "$p")" != *derived-from* ]]
  breaks 'line 1' check_derived_from "$PLUGIN_ROOT" "$p"
  run check_derived_from "$PLUGIN_ROOT" "$BATS_TEST_TMPDIR/absent.md"
  [ "$status" -eq 2 ]
}

@test "mutation: reference stubs" {
  local d="$BATS_TEST_TMPDIR/web" t
  mkdir -p "$d"; cp "$WEB/moved.txt" "$d/"
  holds check_reference_stubs "$d" "$PLUGIN_ROOT" "${REFERENCE_DOCS[@]}"
  drop "$d/moved.txt" "concurrency $BLOB_BASE$CONCURRENCY_REL"
  breaks "concurrency $BLOB_BASE" check_reference_stubs "$d" "$PLUGIN_ROOT" "${REFERENCE_DOCS[@]}"
  # A stub whose forge home is gone.
  cp "$WEB/moved.txt" "$d/"
  plant "$d/moved.txt" "gone ${BLOB_BASE}docs/nope.md"
  breaks 'docs/nope.md does not exist' check_reference_stubs "$d" "$PLUGIN_ROOT" "${REFERENCE_DOCS[@]}"
  # The same line, with the file present in a temp root, holds.
  t="$(temp_root "${REFERENCE_DOCS[@]}")"
  mkdir -p "$t/docs"; : >"$t/docs/nope.md"
  holds check_reference_stubs "$d" "$t" "${REFERENCE_DOCS[@]}"
  # A blob_base line the scrape cannot read is "cannot run", named as such.
  BLOB_BASE='${DOCS_BLOB_BASE:-x}'
  run check_reference_stubs "$d" "$t" "${REFERENCE_DOCS[@]}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read blob_base"* ]]
}

@test "mutation: reference links" {
  local f
  f="$(fresh "$WEB/reference.md")"
  holds check_reference_links "$f" "${REFERENCE_LINKS[@]}"
  edit "$f" '](../docs/requirements.md)' '](https://example.com/requirements)'
  breaks 'docs/requirements.md' check_reference_links "$f" "${REFERENCE_LINKS[@]}"
}

@test "mutation: install block" {
  local f
  f="$(fresh "$WEB/install.md")"
  holds check_install_block "$f"
  drop "$f" 'claude plugin marketplace add anthropics/claude-plugins-official'
  breaks 'directly before' check_install_block "$f"
  # Wrong place, not gone: the add line moves to just after the install line.
  f="$(fresh "$WEB/install.md")"
  sed -i -e '/claude plugin marketplace add anthropics\/claude-plugins-official/{h;d}' \
         -e '/claude plugin install superpowers@claude-plugins-official/G' "$f"
  grep -A1 -F 'claude plugin install superpowers@claude-plugins-official' "$f" \
    | grep -qF 'claude plugin marketplace add anthropics/claude-plugins-official'
  breaks 'directly before' check_install_block "$f"
  # A command gone, and the shared comment line gone.
  f="$(fresh "$WEB/install.md")"
  drop "$f" 'claude plugin install devagent@devagent'
  breaks 'no devagent install command' check_install_block "$f"
  f="$(fresh "$WEB/install.md")"
  drop "$f" '# Not configured on a fresh install'
  breaks 'no fresh-install comment line' check_install_block "$f"
}

@test "mutation: userConfig notice" {
  local f
  f="$(fresh "$README")"
  holds check_userconfig_notice "$f"
  edit "$f" '`devdoc_root`' '`devdoc_dir`'
  breaks 'devdoc_root' check_userconfig_notice "$f"
}

@test "mutation: verified version" {
  local f
  f="$(fresh "$WEB/install.md")"
  holds check_verified_version "$f"
  edit "$f" "$VERIFIED_CC" "${VERIFIED_CC%.*}.999"
  breaks "$VERIFIED_CC" check_verified_version "$f"
}

@test "mutation: permission grant" {
  local f
  f="$(fresh "$README")"
  holds check_permission_grant "$f"
  edit "$f" 'Never widen to bare `Bash`' 'Never widen it'
  breaks 'Never widen' check_permission_grant "$f"
  f="$(fresh "$README")"
  edit "$f" ', Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)' ''
  breaks 'two-form' check_permission_grant "$f"
}

@test "mutation: step headline" {
  local f n
  n="$(_step_n "$TEMPLATE")"
  f="$(fresh "$README")"
  holds check_step_headline "$TEMPLATE" "$f"
  edit "$f" "${n}-step workflow" "$((n - 1))-step workflow"
  breaks "${n}-step workflow" check_step_headline "$TEMPLATE" "$f"
}

@test "mutation: numbering claim" {
  local f n
  n="$(_step_n "$TEMPLATE")"
  f="$(fresh "$WEB/workflow.md")"
  holds check_numbering_claim "$TEMPLATE" "$f"
  edit "$f" "numbered 0–$((n - 1)) in" "numbered 0–$((n - 2)) in"
  breaks "numbered 0–$((n - 1)) in" check_numbering_claim "$TEMPLATE" "$f"
}

@test "mutation: step table" {
  local f num cmd
  # A mid-table step, read from the template (not a literal row).
  read -r num cmd < <(template_steps "$TEMPLATE" | sed -n 14p)
  [ -n "$cmd" ]
  f="$(fresh "$WEB/workflow.md")"
  holds check_step_table "$TEMPLATE" "$f"
  drop "$f" "| $num | \`$cmd\`"
  breaks "step $num" check_step_table "$TEMPLATE" "$f"
  f="$(fresh "$WEB/workflow.md")"
  edit "$f" "| $num | \`$cmd\`" "| $num | \`${cmd}x\`"
  breaks "step $num" check_step_table "$TEMPLATE" "$f"
}

@test "mutation: phase split" {
  local f n
  f="$(fresh "$WEB/phases.txt")"
  holds check_phase_split "$TEMPLATE" "$f"
  edit "$f" ' impact ' ' '
  breaks 'impact of' check_phase_split "$TEMPLATE" "$f"
  breaks 'in no phase' check_phase_split "$TEMPLATE" "$f"
  f="$(fresh "$WEB/phases.txt")"
  edit "$f" 'Ship: ship' 'Ship: review ship'
  breaks 'step review appears in more than one place' check_phase_split "$TEMPLATE" "$f"
  f="$(fresh "$WEB/phases.txt")"
  edit "$f" ' redmr ' ' redmrx '
  breaks 'step redmrx is not a step of' check_phase_split "$TEMPLATE" "$f"
  f="$(fresh "$WEB/phases.txt")"
  edit "$f" 'review redmr' 'redmr review'
  breaks 'out of template order' check_phase_split "$TEMPLATE" "$f"
  # The grammar: a line without its colon, and a phase named twice, cannot run.
  f="$(fresh "$WEB/phases.txt")"
  edit "$f" 'Plan: pull' 'Plan pull'
  n="$(grep -n '^Plan pull' "$f" | cut -d: -f1)"
  [ -n "$n" ]
  run phase_split "$f"
  [ "$status" -eq 2 ]
  [[ "$output" == *"$f:$n: expected '<Name>: <step> <step>...'"* ]]
  run check_phase_split "$TEMPLATE" "$f"
  [ "$status" -eq 2 ]
  f="$(fresh "$WEB/phases.txt")"
  plant "$f" 'Plan: pull'
  run phase_split "$f"
  [ "$status" -eq 2 ]
  [[ "$output" == *"phase Plan is listed twice"* ]]
}

@test "mutation: landing loop, install pair, hero word" {
  local f ph="$WEB/phases.txt"
  f="$(fresh "$WEB/index.html")"
  holds check_loop "$ph" "$TEMPLATE" "$f"
  holds check_install_pair "$README" "$f"
  holds check_hero_word "$f"
  edit "$f" 'branch … analyze' 'branch … commit'
  breaks 'phase build: svg steps-label' check_loop "$ph" "$TEMPLATE" "$f"
  f="$(fresh "$WEB/index.html")"
  edit "$f" '<li id="phase-build"><details open>' '<li id="phase-build"><details>'
  breaks 'phase build: list open' check_loop "$ph" "$TEMPLATE" "$f"
  f="$(fresh "$WEB/index.html")"
  edit "$f" '<ol start="8">' '<ol start="9">'
  breaks 'phase build: list start' check_loop "$ph" "$TEMPLATE" "$f"
  f="$(fresh "$WEB/index.html")"
  edit "$f" $'<li>review</li>\n<li>redmr</li>' $'<li>redmr</li>\n<li>review</li>'
  breaks 'phase verify: list steps' check_loop "$ph" "$TEMPLATE" "$f"
  f="$(fresh "$WEB/index.html")"
  edit "$f" '<a href="#phase-ship"><g data-phase="ship"' '<a href="#phase-ship"><g data-phase="shipx"'
  breaks 'phase ship: svg row' check_loop "$ph" "$TEMPLATE" "$f"
  f="$(fresh "$WEB/index.html")"
  edit "$f" 'devagent@devagent' 'devagent@devagnet'
  breaks 'differs from README' check_install_pair "$README" "$f"
  f="$(fresh "$WEB/index.html")"
  plant "$f" '<p><code>claude plugin install superpowers@claude-plugins-official</code></p>'
  breaks 'lacks' check_install_pair "$README" "$f"
  f="$(fresh "$WEB/index.html")"
  edit "$f" 'starting from written requirements.' 'starting from a written plan.'
  breaks 'hero' check_hero_word "$f"
  # A page without the loop section is broken, not "cannot run".
  f="$(fresh "$WEB/index.html")"
  edit "$f" '<section id="loop"' '<section id="loopx"'
  breaks 'id=loop' check_loop "$ph" "$TEMPLATE" "$f"
}

@test "mutation: landing issue numbers, scripts off, live items, count, install detail" {
  local f g n cmds=() src live="$WEB/live.txt" ph="$WEB/phases.txt"
  mapfile -t cmds < <(landing_cmds "$WEB/index.html")
  [ "${#cmds[@]}" -ge 1 ]
  # issue numbers: a text node reddens; an SVG colour value does not.
  f="$(filled_index)"
  holds check_no_issue_numbers "$f"
  edit "$f" '<circle class="landing-loop-ring"' '<rect fill="#123456"/><circle class="landing-loop-ring"'
  holds check_no_issue_numbers "$f"
  plant "$f" '<p>Fixed in #12</p>'
  breaks '#12' check_no_issue_numbers "$f"
  # scripts off: a closed <details>, and a step moved into a <template>.
  f="$(filled_index)"
  holds check_scripts_off "$ph" "$f" "${cmds[@]}"
  edit "$f" '<li id="phase-build"><details open>' '<li id="phase-build"><details>'
  breaks 'branch is not visible with scripts off' check_scripts_off "$ph" "$f" "${cmds[@]}"
  f="$(filled_index)"
  edit "$f" '<li>branch</li>' '<template><li>branch</li></template>'
  breaks 'branch is not visible with scripts off' check_scripts_off "$ph" "$f" "${cmds[@]}"
  f="$(filled_index)"
  breaks 'claude plugin nope' check_scripts_off "$ph" "$f" "${cmds[@]}" 'claude plugin nope'
  # live items: a not-live item that links, and a hand-written "coming".
  f="$(filled_index)"
  holds check_live_items "$live" "$WEB/index.html" "$f"
  edit "$f" '<span class="family-coming">Gantry <small>coming</small></span>' '<a href="x">Gantry</a>'
  breaks 'gantry' check_live_items "$live" "$WEB/index.html" "$f"
  f="$(filled_index)"
  edit "$f" '<span class="family-coming">Gantry <small>coming</small></span>' '<a href="x"><span class="family-coming">Gantry <small>coming</small></span></a>'
  breaks 'inside a link: Gantry coming' check_live_items "$live" "$WEB/index.html" "$f"
  f="$(filled_index)"
  plant "$f" '<p>More <small>coming</small></p>'
  breaks 'coming' check_live_items "$live" "$WEB/index.html" "$f"
  # a live item whose link is gone
  f="$(filled_index)"
  edit "$f" '<a href="https://github.com/mtibbits/devagent/blob/master/README.md#concurrent-sessions">Several projects</a>' 'Several projects'
  breaks 'rung-projects' check_live_items "$live" "$WEB/index.html" "$f"
  # a rung holding two placeholders
  src="$(fresh "$WEB/index.html")"
  edit "$src" '<li>{{live:rung-shared|Shared queues}}</li>' '<li>{{live:rung-shared|Shared queues}} {{live:gantry|Gantry}}</li>'
  f="$(filled_index "$src")"
  breaks 'exactly one' check_live_items "$live" "$src" "$f"
  # the count: a filled number off by one, and a literal in the source.
  f="$(filled_index)"
  holds check_req_count "$live" "$WEB/index.html" "$f"
  n="$(grep -oE 'class="landing-req-count">[0-9]+<' "$f" | grep -oE '[0-9]+')"
  [ -n "$n" ]
  edit "$f" "class=\"landing-req-count\">$n<" "class=\"landing-req-count\">$((n + 1))<"
  breaks 'landing-req-count' check_req_count "$live" "$WEB/index.html" "$f"
  src="$(fresh "$WEB/index.html")"
  edit "$src" '{{count:requirements}}' "$n"
  f="$(filled_index)"
  breaks 'literal' check_req_count "$live" "$src" "$f"
  # install detail on the landing page
  f="$(filled_index)"
  holds check_install_only "$f"
  plant "$f" '<p>Install superpowers too</p>'
  breaks 'superpowers' check_install_only "$f"
  f="$(filled_index)"
  edit "$f" '<p><a href="install.html">Install guide</a></p>' '<p>Install guide</p>'
  breaks 'install.html' check_install_only "$f"
}

@test "mutation: backend verbs" {
  local f
  f="$(fresh "$CONFIG_DOC")"
  holds check_backend_verbs "$f"
  edit "$f" '`whoami`' 'whoami'
  breaks 'whoami' check_backend_verbs "$f"
  # Substring proof: bare `state` gone while `mr-state` stays.
  f="$(fresh "$CONFIG_DOC")"
  edit "$f" '`state`' 'state'
  grep -qF '`mr-state`' "$f"
  breaks '`state`' check_backend_verbs "$f"
}

@test "mutation: 21-step typo" {
  local f
  f="$(fresh "$WEB/workflow.md")"
  holds check_absent -F '21-step' "$f"
  plant "$f" 'the 21-step workflow'
  breaks '21-step' check_absent -F '21-step' "$f"
  run check_absent -F '21-step' "$BATS_TEST_TMPDIR/absent.md"
  [ "$status" -eq 2 ]
}

@test "mutation: permanent step ID claim" {
  local f re='permanent(ly)?[ -]+numbered|permanent (step )?ids?'
  f="$(fresh "$WEB/index.html")"
  holds check_absent -iE "$re" "$f"
  plant "$f" 'Steps keep permanent step IDs.'
  breaks 'permanent' check_absent -iE "$re" "$f"
}

@test "mutation: prerequisites trace to README" {
  local page readme
  page="$(fresh "$WEB/install.md")"; readme="$(fresh "$README")"
  holds check_prereqs_trace "$page" "$readme"
  # A reflow that moves a tool onto a bullet's two-space continuation line holds.
  edit "$page" '- `jq`.' $'- The JSON tool,\n  `jq`.'
  grep -qx -- '  `jq`\.' "$page"
  holds check_prereqs_trace "$page" "$readme"
  # A backticked bullet under a later "## " heading is outside the list.
  page="$(fresh "$WEB/install.md")"
  plant "$page" '- `zsh` for the prompt.'
  holds check_prereqs_trace "$page" "$readme"
  # README's Prerequisites paragraph loses a tool the page lists.
  page="$(fresh "$WEB/install.md")"
  edit "$readme" '`jq`' 'jq'
  breaks 'not in README Prerequisites: `jq`' check_prereqs_trace "$page" "$readme"
  readme="$(fresh "$README")"
  plant "$page" 'No private-repo access is needed.'
  breaks 'private' check_prereqs_trace "$page" "$readme"
  # A page tool README lacks.
  page="$(fresh "$WEB/install.md")"
  sed -i 's/^- `jq`\.$/- `zsh` for the prompt.\n&/' "$page"
  grep -qx -- '- `zsh` for the prompt.' "$page"
  breaks 'not in README Prerequisites: `zsh`' check_prereqs_trace "$page" "$readme"
  # README names `bats` only outside its Prerequisites paragraph: the scope holds.
  page="$(fresh "$WEB/install.md")"
  grep -qF '`bats`' "$readme"
  sed -i 's/^- `jq`\.$/- `bats` for the tests.\n&/' "$page"
  grep -qx -- '- `bats` for the tests.' "$page"
  breaks 'not in README Prerequisites: `bats`' check_prereqs_trace "$page" "$readme"
  # A floor tool the page no longer names.
  page="$(fresh "$WEB/install.md")"
  edit "$page" '- `jq`.' '- jq.'
  breaks 'page list is missing `jq`' check_prereqs_trace "$page" "$readme"
  # No Prerequisites section at all.
  page="$(fresh "$WEB/install.md")"
  edit "$page" '## Prerequisites' '## Before you start'
  breaks 'no Prerequisites list' check_prereqs_trace "$page" "$readme"
  # README's Prerequisites paragraph gone: the check cannot run.
  page="$(fresh "$WEB/install.md")"
  edit "$readme" '**Prerequisites.**' '**Needs.**'
  run check_prereqs_trace "$page" "$readme"
  [ "$status" -eq 2 ]
}

@test "mutation: platform tokens" {
  local f
  f="$(fresh "$README")"
  holds check_platform_tokens "$f"
  edit "$f" 'macOS is currently untested' 'macOS may work'
  breaks 'macOS' check_platform_tokens "$f"
}

@test "mutation: platform sentence" {
  local page readme
  page="$(fresh "$WEB/install.md")"; readme="$(fresh "$README")"
  holds check_platform_sentence "$page" "$readme"
  # Cut to the first sentence: a README prefix, but it drops claims.
  drop "$page" 'Native Git Bash on Windows can run the plugin.'
  drop "$page" 'macOS is currently untested:'
  breaks 'drops the claim: Git Bash' check_platform_sentence "$page" "$readme"
  # A word changed.
  page="$(fresh "$WEB/install.md")"
  edit "$page" 'can run the plugin' 'runs the plugin'
  breaks 'word for word' check_platform_sentence "$page" "$readme"
  # Cut mid-sentence.
  page="$(fresh "$WEB/install.md")"
  edit "$page" ' (`stat -c`, GNU `sed -i`, `readlink -f`).' ''
  breaks 'word for word' check_platform_sentence "$page" "$readme"
  # The bare label only.
  page="$(fresh "$WEB/install.md")"
  drop "$page" 'Native Git Bash on Windows can run the plugin.'
  drop "$page" 'macOS is currently untested:'
  edit "$page" '**Supported platforms.** devAgent is developed and tested on **Linux**, including WSL on Windows.' \
    '**Supported platforms.**'
  breaks 'word for word' check_platform_sentence "$page" "$readme"
  # README's leading sentences change; the page does not follow.
  page="$(fresh "$WEB/install.md")"
  edit "$readme" 'developed and tested on **Linux**' 'built and tested on **Linux**'
  breaks 'word for word' check_platform_sentence "$page" "$readme"
  # LIMIT (documented on the check): a README edit after the page's cut holds.
  readme="$(fresh "$README")"
  edit "$readme" 'CI runs the full suite on Linux' 'CI runs every test on Linux'
  holds check_platform_sentence "$page" "$readme"
  # The page paragraph gone.
  readme="$(fresh "$README")"
  edit "$page" '**Supported platforms.**' 'Platforms:'
  breaks 'no **Supported platforms.**' check_platform_sentence "$page" "$readme"
  # README's paragraph gone: the check cannot run.
  page="$(fresh "$WEB/install.md")"
  edit "$readme" '**Supported platforms.**' 'Platforms:'
  run check_platform_sentence "$page" "$readme"
  [ "$status" -eq 2 ]
}

@test "mutation: install page issue numbers" {
  local f
  f="$(fresh "$WEB/install.md")"
  holds check_no_issue_numbers "$f"
  plant "$f" 'Fixed long ago (#541).'
  breaks '#541' check_no_issue_numbers "$f"
  f="$(fresh "$WEB/install.md")"
  plant "$f" 'Fixed long ago (Issue-541).'
  breaks 'Issue-541' check_no_issue_numbers "$f"
}

@test "mutation: command arity" {
  local f
  f="$(fresh "$WEB/quickstart.md")"
  holds check_command_arity "$f"
  plant "$f" '/devagent:init'
  breaks 'bare command' check_command_arity "$f"
  f="$(fresh "$WEB/quickstart.md")"
  drop "$f" '/devagent:'
  breaks 'subject floor' check_command_arity "$f"
}

@test "mutation: quickstart forms" {
  local f
  f="$(fresh "$WEB/quickstart.md")"
  holds check_quickstart_forms "$f"
  edit "$f" '/devagent:pull myproj 42' '/devagent:pull 42'
  breaks 'pull form' check_quickstart_forms "$f"
  f="$(fresh "$WEB/quickstart.md")"
  edit "$f" 'permissions.push_mr' 'the push setting'
  breaks 'push_mr' check_quickstart_forms "$f"
}

@test "mutation: bash floor" {
  local f guard="$PLUGIN_ROOT/scripts/lib/potholes.sh" floor
  floor="$(grep -oE 'bash >= [0-9]+\.[0-9]+' "$guard" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  [ -n "$floor" ]
  f="$(fresh "$WEB/install.md")"
  holds check_bash_floor "$f" "$README" "$guard"
  edit "$f" "≥ $floor" "≥ ${floor%.*}.0"
  breaks "page ${floor%.*}.0" check_bash_floor "$f" "$README" "$guard"
  f="$(fresh "$WEB/install.md")"
  plant "$f" 'Some features need bash ≥ 5.0.'
  breaks 'several bash floors' check_bash_floor "$f" "$README" "$guard"
}

@test "mutation: Claude Code version homes" {
  local t
  t="$(temp_root README.md docs-site .github/ISSUE_TEMPLATE)"
  holds check_cc_version_homes "$t" README.md docs-site .github/ISSUE_TEMPLATE
  # Control: the historical-measurement form is exempt.
  plant "$t/docs-site/quickstart.md" 'This was measured on 2.1.100.'
  holds check_cc_version_homes "$t" README.md docs-site .github/ISSUE_TEMPLATE
  plant "$t/docs-site/quickstart.md" 'Use Claude Code 2.1.100 or newer.'
  breaks '2.1.100' check_cc_version_homes "$t" README.md docs-site .github/ISSUE_TEMPLATE
  run check_cc_version_homes "$t" no-such-dir
  [ "$status" -eq 2 ]
}

@test "mutation: shellcheck version homes" {
  local t
  t="$(temp_root README.md CONTRIBUTING.md docs-site/install.md "$CONFIG_REL" templates/config.toml.skel \
        commands/analyze.md .githooks/pre-push .github/workflows/shellcheck.yml scripts/analyze-shellcheck.sh)"
  holds check_shellcheck_homes "$t" docs-site/install.md "$CONFIG_REL"
  plant "$t/$CONFIG_REL" 'Older docs said shellcheck 0.8.0.'
  breaks "$CONFIG_REL: 0.8.0" check_shellcheck_homes "$t" docs-site/install.md "$CONFIG_REL"
  # #999: the contributor statement lives in CONTRIBUTING.md "What you need".
  # An edit, not a drop, so the shellcheck floor on the same bullet still parses.
  cp "$PLUGIN_ROOT/$CONFIG_REL" "$t/$CONFIG_REL"
  edit "$t/CONTRIBUTING.md" '`bats` 1.10 or newer, ' ''
  breaks 'no longer names `bats`' check_shellcheck_homes "$t" docs-site/install.md "$CONFIG_REL"
}

@test "mutation: merge keys" {
  local skel="$PLUGIN_ROOT/templates/config.toml.skel" cl="$PLUGIN_ROOT/CHANGELOG.md" c w
  c="$(fresh "$CONFIG_DOC")"; w="$(fresh "$WEB/workflow.md")"
  holds check_merge_keys "$skel" "$c" "$cl" "$w"
  plant "$c" 'Note: no step merges the MR.'
  breaks 'no step merges the MR' check_merge_keys "$skel" "$c" "$cl" "$w"
  c="$(fresh "$CONFIG_DOC")"
  edit "$c" 'merge_checks = "if-present"' 'merge_checks = "never"'
  breaks 'if-present' check_merge_keys "$skel" "$c" "$cl" "$w"
  c="$(fresh "$CONFIG_DOC")"
  edit "$w" 'WAITING' 'PENDING'
  breaks 'WAITING' check_merge_keys "$skel" "$c" "$cl" "$w"
  # The skeleton half: its documented default gone.
  w="$(fresh "$WEB/workflow.md")"; skel="$(fresh "$skel")"
  drop "$skel" '# merge_checks = "required"'
  breaks 'merge_checks default' check_merge_keys "$skel" "$c" "$cl" "$w"
}

@test "mutation: merge_forward docs" {
  local skel c m
  skel="$(fresh "$PLUGIN_ROOT/templates/config.toml.skel")"; c="$(fresh "$CONFIG_DOC")"
  m="$(fresh "$PLUGIN_ROOT/commands/mergemr.md")"
  holds check_merge_forward_docs "$skel" "$c" "$m"
  edit "$m" 'preship-verified-head.sh forward' 'preship-verified-head.sh record'
  breaks 'preship-verified-head.sh forward' check_merge_forward_docs "$skel" "$c" "$m"
  m="$(fresh "$PLUGIN_ROOT/commands/mergemr.md")"
  edit "$c" 'append_only' 'append_list'
  breaks 'append_only' check_merge_forward_docs "$skel" "$c" "$m"
  # The skeleton half: the block moved above the first project header.
  c="$(fresh "$CONFIG_DOC")"
  drop "$skel" '# [project.{{PROJECT}}.merge_forward]'
  printf '# [project.{{PROJECT}}.merge_forward]\n%s\n' "$(cat "$skel")" > "$skel"
  breaks 'precedes' check_merge_forward_docs "$skel" "$c" "$m"
}
