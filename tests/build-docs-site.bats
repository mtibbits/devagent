#!/usr/bin/env bats
# #465: scripts/build-docs-site.sh renders docs-site/*.md (minus README.md) to
# the static site the Pages workflow publishes.
#
# Two subject families:
#   REAL  — the tracked docs-site/ built once per file (setup_file); pins the
#           page set by COUNT against the source glob, link closure computed
#           here independently of the script's own check, the one link that
#           leaves docs-site/, per-page code-block and table-row counts against
#           the markdown, titles, nav, and that the output fetches nothing.
#   FIXTURE — throwaway source dirs that drive each refusal BRANCH (exit 2-6);
#           every negative pins the exact code AND a message token, so a
#           different failure cannot satisfy it. The one refusal with no
#           fixture is the post-render page count (exit 5 "expected N pages"):
#           nothing outside the script can make it fire, so it is pinned by a
#           mutation row in the plan instead, and says so here.
#
# pandoc: the builder validates its input and derives the nav BEFORE it probes
# for pandoc, so every refusal up to and including the probe is tested without
# it (a stub stands in where a version is needed). Tests that render call
# need_pandoc, which skips only where pandoc is absent (a local run). In CI the
# file runs un-skipped: test.yml's bats job installs pandoc (#841), and
# publish-docs-site.yml installs pandoc, asserts it, and additionally runs this
# file with skips forbidden. Locally, install pandoc 3.x.
#
# COUPLING: the REAL tests derive their expectations from docs-site/*.md (fence
# and table-row counts, the install command lines, two H1s, and nav order from
# index.md's "Where to go next" list). docs-site/README.md announces this to
# page editors; a failure here after a page edit usually means the expectation
# moves with the page, not that the page is wrong.

load 'lib/bats-helpers'

BUILD="$PLUGIN_ROOT/scripts/build-docs-site.sh"
SITE="$PLUGIN_ROOT/docs-site"

need_pandoc() {
  command -v pandoc >/dev/null 2>&1 \
    || skip "pandoc not installed — this file runs in publish-docs-site.yml's lane"
}

setup_file() {
  command -v pandoc >/dev/null 2>&1 || return 0
  REAL_OUT="$BATS_FILE_TMPDIR/site"
  export REAL_OUT
  bash "$BUILD" --src "$SITE" --out "$REAL_OUT" > "$BATS_FILE_TMPDIR/real.stdout" 2> "$BATS_FILE_TMPDIR/real.stderr"
}

setup() {
  FX="$BATS_TEST_TMPDIR"
  FX_BASH="$(command -v bash)"
  mkdir -p "$FX/src" "$FX/static-empty"
}

# fx_bin — a PATH holding only what the builder runs BEFORE its pandoc probe, so
# "no pandoc" (or a stub pandoc) is the only thing the probe can see.
fx_bin() {
  local t
  mkdir -p "$FX/bin"
  for t in dirname basename grep sed awk sort; do
    ln -s "$(command -v "$t")" "$FX/bin/$t"
  done
}

# fx_page <name> <body...> — a minimal valid page in the fixture source dir.
fx_page() {
  local name="$1"; shift
  { printf '# %s\n\n' "$name"; printf '%s\n' "$@"; } > "$FX/src/$name.md"
}

# nav_of <html> — the <nav> block only. The theme CSS names aria-current and
# page bodies link sibling pages, so nav assertions must not see the whole file.
nav_of() { sed -n '/<nav/,/<\/nav>/p' "$1"; }

# fx_build [args...] — build the fixture source dir into $FX/out. FX_PATH, when
# set (pandoc-free legs set it to "$FX/bin" after fx_bin), replaces PATH. It
# passes --static "$FX/static-empty", so a fixture build never copies the
# repo's own scripts/docs-site/static/. Later flags win: the script's parse
# loop keeps the last value.
fx_build() { env PATH="${FX_PATH:-$PATH}" "$FX_BASH" "$BUILD" --src "$FX/src" --out "$FX/out" --static "$FX/static-empty" "$@"; }

# fx_fixture_b — #840's Fixture B: a fenced decoy bullet naming alpha above the
# real list, which names only zeta.
fx_fixture_b() {
  fx_page index '```' '- [Alpha](./alpha.md)' '```' '' '## Where to go next' '' '- [Zeta](./zeta.md)'
  fx_page alpha "a"
  fx_page zeta "z"
}

# fx_html <name> <line...> — a hand-written page: the derived-from header, then
# the lines.
fx_html() {
  local name="$1"; shift
  { printf '<!-- derived-from: fixture -->\n'; printf '%s\n' "$@"; } > "$FX/src/$name.html"
}

# article_of <html> — the lines strictly between <article> and </article>.
article_of() { awk '/^<\/article>$/ { f = 0 } f { print } /^<article>$/ { f = 1 }' "$1"; }

# frame_of <html> — every other line, with the per-page parts normalised: the
# current-page mark, the <title>, and the footer's source name.
frame_of() {
  awk '/^<\/article>$/ { f = 0 } !f { print } /^<article>$/ { f = 1 }' "$1" \
    | sed 's/ aria-current="page"//; s#<title>.*</title>#<title/>#; s#docs-site/[A-Za-z0-9_-]*\.\(md\|html\)#docs-site/SRC#g'
}

# ---------------------------------------------------------------- REAL site

@test "build-docs-site: real site — one html per content page, README not published" {
  need_pandoc
  shopt -s nullglob
  local md=("$SITE"/*.md) html=("$REAL_OUT"/*.html) all=("$REAL_OUT"/*)
  [ "${#md[@]}" -ge 2 ]
  [ "${#html[@]}" -eq "$(( ${#md[@]} - 1 ))" ]
  [ "${#all[@]}" -eq "${#html[@]}" ]
  [ ! -e "$REAL_OUT/README.html" ]
  local f
  for f in "${md[@]}"; do
    [ "$(basename "$f")" = "README.md" ] && continue
    [ -s "$REAL_OUT/$(basename "$f" .md).html" ]
  done
  grep -qx "build-docs-site: built ${#html[@]} pages -> $REAL_OUT" "$BATS_FILE_TMPDIR/real.stdout"
}

@test "build-docs-site: real site — every local href resolves to a built file" {
  need_pandoc
  local html href checked=0
  for html in "$REAL_OUT"/*.html; do
    while IFS= read -r href; do
      case "$href" in [A-Za-z]*:*|'#'*) continue ;; esac
      [ -f "$REAL_OUT/${href%%#*}" ] || { echo "$html -> $href" >&2; return 1; }
      checked=$((checked + 1))
    done < <(grep -oE 'href="[^"]*"' "$html" | sed -E 's/^href="//; s/"$//')
  done
  # 6 pages x 6 nav links is the floor; a zero here means the scan saw nothing.
  [ "$checked" -ge 36 ]
  # the only surviving .md hrefs are forge blob URLs (footers + links leaving docs-site/)
  local stray
  stray="$(grep -rhoE 'href="[^"]*\.md[#"]' "$REAL_OUT" | grep -vcF 'href="https://github.com/mtibbits/devagent/blob/master/' || true)"
  [ "$stray" = "0" ]
  [ "$(grep -rhoE 'href="[^"]*\.md[#"]' "$REAL_OUT" | wc -l)" -ge 6 ]
}

@test "build-docs-site: real site — the link that leaves docs-site/ goes to the forge blob" {
  need_pandoc
  grep -qF '](../README.md#running-the-test-suite)' "$SITE/install.md"
  grep -qF 'href="https://github.com/mtibbits/devagent/blob/master/README.md#running-the-test-suite"' "$REAL_OUT/install.html"
}

@test "build-docs-site: real site — code blocks and table rows match the markdown, page by page" {
  need_pandoc
  local f page fences pres total=0
  for f in "$SITE"/*.md; do
    page="$(basename "$f" .md)"
    [ "$page" = "README" ] && continue
    fences="$(grep -cE '^```' "$f" || true)"
    pres="$(grep -oE '<pre' "$REAL_OUT/$page.html" | wc -l)"
    [ "$pres" -eq "$(( fences / 2 ))" ] || { echo "$page: $fences fence lines, $pres <pre>" >&2; return 1; }
    total=$((total + pres))
  done
  [ "$total" -gt 0 ]
  # workflow.md's step table: every markdown table line but the |---| separator is a <tr>.
  local rows trs
  rows="$(grep -cE '^\|' "$SITE/workflow.md")"
  trs="$(grep -oE '<tr' "$REAL_OUT/workflow.html" | wc -l)"
  [ "$rows" -gt 2 ]
  [ "$trs" -eq "$(( rows - 1 ))" ]
}

@test "build-docs-site: real site — install commands survive rendering verbatim" {
  need_pandoc
  # The three commands tests/docs-site.bats pins README<->install.md on; here the
  # pin continues one hop, markdown -> html.
  local cmd
  while IFS= read -r cmd; do
    [ -n "$cmd" ]
    grep -qF "$cmd" "$REAL_OUT/install.html"
  done < <(grep -E '^claude plugin (marketplace add|install devagent)' "$SITE/install.md")
  [ "$(grep -cE '^claude plugin (marketplace add|install devagent)' "$SITE/install.md")" -ge 3 ]
}

@test "build-docs-site: real site — title from the H1, nav marks exactly the current page" {
  need_pandoc
  grep -qF '<title>Install | devAgent</title>' "$REAL_OUT/install.html"
  grep -qF '<title>Multi-project &amp; concurrency | devAgent</title>' "$REAL_OUT/concurrency.html"
  # the nav label is escaped by THIS script (sed), the <title> by pandoc — pin both
  # (index.md's body links the same page, and pandoc escapes that one)
  nav_of "$REAL_OUT/index.html" | grep -qF '>Multi-project &amp; concurrency</a>'
  local html page
  for html in "$REAL_OUT"/*.html; do
    page="$(basename "$html")"
    [ "$(nav_of "$html" | grep -c 'aria-current="page"')" -eq 1 ]
    grep -qF "<a href=\"$page\" aria-current=\"page\">" "$html"
    [ "$(nav_of "$html" | grep -c '<a href=')" -eq 6 ]
  done
  # nav order is index.md's bullet list, not the alphabetical glob
  local navorder
  navorder="$(nav_of "$REAL_OUT/index.html" | grep -oE 'href="[a-z]+\.html"' | tr '\n' ' ')"
  echo "nav order rendered: $navorder" >&2
  echo "(derived from docs-site/index.md's 'Where to go next' bullets — see docs-site/README.md; if that list changed on purpose, this expectation moves with it)" >&2
  [ "$navorder" = 'href="index.html" href="install.html" href="quickstart.html" href="workflow.html" href="configuration.html" href="concurrency.html" ' ]
}

@test "build-docs-site: real site — pages fetch nothing and carry no preview banner" {
  need_pandoc
  run grep -rlE '<script|<link |<img |<iframe| src=|@import|url\(' "$REAL_OUT"
  [ "$status" -eq 1 ]
  run grep -rli 'private preview' "$REAL_OUT"
  [ "$status" -eq 1 ]
}

# ------------------------------------------------------------- FIXTURE: refusals

@test "build-docs-site: unknown argument -> exit 2" {
  run bash "$BUILD" --nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument: --nope"* ]]
}

@test "build-docs-site: --blob-base with an attribute-breaking character -> exit 2" {
  # page.html interpolates \$blob_base\$ into an href unescaped (pandoc templates
  # have no escape filter), so the value is validated at the argument instead.
  run bash "$BUILD" --blob-base 'https://x/" onmouseover="alert(1)'
  [ "$status" -eq 2 ]
  [[ "$output" == *"--blob-base must not contain"* ]]
}

@test "build-docs-site: pandoc absent -> exit 3, nothing written" {
  fx_bin
  fx_page index "hello"
  FX_PATH="$FX/bin"
  run fx_build
  [ "$status" -eq 3 ]
  [[ "$output" == *"pandoc is not installed"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: pandoc older than 3.x -> exit 3 naming the version found, nothing written" {
  fx_bin
  printf '#!%s\necho "pandoc 2.9.2.1"\n' "$(command -v bash)" > "$FX/bin/pandoc"
  chmod +x "$FX/bin/pandoc"
  fx_page index "hello"
  FX_PATH="$FX/bin"
  run fx_build
  [ "$status" -eq 3 ]
  [[ "$output" == *"pandoc is too old"*"2.9.2.1"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: --help prints the whole header, through its last line" {
  run bash "$BUILD" --help
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "scripts/build-docs-site.sh"* ]]
  # the header's final line, derived from the script so a longer header cannot truncate
  local last
  last="$(awk 'NR == 1 { next } !/^#/ { exit } { l = $0 } END { sub(/^# ?/, "", l); print l }' "$BUILD")"
  [ -n "$last" ]
  [ "${lines[${#lines[@]}-1]}" = "$last" ]
  [[ "$output" == *"  6  a rendered page links"* ]]
}

@test "build-docs-site: missing source dir -> exit 4" {
  run bash "$BUILD" --src "$FX/absent" --out "$FX/out"
  [ "$status" -eq 4 ]
  [[ "$output" == *"source dir not found"* ]]
}

@test "build-docs-site: a source dir holding only README.md has no pages -> exit 4" {
  printf '# policy\n' > "$FX/src/README.md"
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"no content pages"* ]]
}

@test "build-docs-site: pages but no index.md -> exit 4" {
  fx_page install "hello"
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"no index.md"* ]]
}

@test "build-docs-site: index.md's page list names no page -> exit 4, not a silent alphabetical nav" {
  # "* " bullets: a list the derivation's grep does not see.
  fx_page index "* [Other](./other.md)"
  fx_page other "hello"
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"page list names no page"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: index.md whose only list bullets are fenced -> exit 4, not a nav" {
  fx_bin
  FX_PATH="$FX/bin"
  fx_page index '```' '- [Other](./other.md)' '```' '' '~~~' '- [Other](./other.md)' '~~~'
  fx_page other "hello"
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"page list names no page"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: fenced decoy above one real bullet gets past the guard" {
  # positive control for the leg above: #840's Fixture B reaches the pandoc probe
  fx_bin
  FX_PATH="$FX/bin"
  fx_fixture_b
  run fx_build
  [ "$status" -eq 3 ]
  [[ "$output" == *"pandoc is not installed"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: awk absent -> exit 3 naming awk, not \"names no page\"" {
  fx_bin
  FX_PATH="$FX/bin"
  rm "$FX/bin/awk"
  fx_fixture_b
  run fx_build
  [ "$status" -eq 3 ]
  [[ "$output" == *"awk is not installed"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: --out is an existing regular file -> exit 4, file untouched" {
  need_pandoc
  fx_page index "hello"
  printf 'keep me\n' > "$FX/out"
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"--out exists and is not a directory"* ]]
  [ "$(cat "$FX/out")" = "keep me" ]
}

@test "build-docs-site: non-empty --out is refused untouched -> exit 4" {
  need_pandoc
  fx_page index "hello"
  mkdir -p "$FX/out"
  printf 'keep me\n' > "$FX/out/.hidden-keep"
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"--out is not empty"* ]]
  [ "$(cat "$FX/out/.hidden-keep")" = "keep me" ]
  local after=("$FX/out"/*)
  [ ! -e "${after[0]}" ]
}

@test "build-docs-site: a page with no H1 -> exit 5 naming the file" {
  need_pandoc
  fx_page index "- [Bare](./bare.md)"
  printf '```\n# not a heading, inside a fence\n```\nno heading here\n' > "$FX/src/bare.md"
  run fx_build
  [ "$status" -eq 5 ]
  [[ "$output" == *"no top-level '# ' heading"*"bare.md"* ]]
}

@test "build-docs-site: a link the filter cannot classify -> exit 5 naming the target" {
  need_pandoc
  fx_page index "see [deep](sub/dir/page.md)"
  run fx_build
  [ "$status" -eq 5 ]
  [[ "$output" == *"unclassified link target: sub/dir/page.md"* ]]
}

@test "build-docs-site: a link that leaves docs-site/ with an empty --blob-base -> exit 5 naming it" {
  need_pandoc
  fx_page index "see [up](../LICENSE)"
  run fx_build --blob-base ""
  [ "$status" -eq 5 ]
  [[ "$output" == *"no blob_base was given: ../LICENSE"* ]]
}

@test "build-docs-site: a sibling link to a page that does not exist -> exit 6 naming it" {
  need_pandoc
  fx_page index "see [ghost](./ghost.md)"
  run fx_build
  [ "$status" -eq 6 ]
  [[ "$output" == *"index.html links to ghost.html"* ]]
}

@test "build-docs-site: a raw-HTML link the Lua filter never sees is still closed over -> exit 6" {
  need_pandoc
  fx_page index 'raw <a href="nowhere.html">link</a>'
  run fx_build
  [ "$status" -eq 6 ]
  [[ "$output" == *"links to nowhere.html"* ]]
}

@test "build-docs-site: fixture happy path — sibling link, fragment, and --blob-base all rewrite" {
  need_pandoc
  fx_page index "- [Other](./other.md)" "" "[frag](./other.md#part) and [up](../LICENSE) and [ext](https://example.org/x.md)"
  fx_page other "## part" "" "[home](./index.md)"
  run fx_build --blob-base "https://forge.example/blob/main/"
  [ "$status" -eq 0 ]
  grep -qF 'href="other.html#part"' "$FX/out/index.html"
  grep -qF 'href="https://forge.example/blob/main/LICENSE"' "$FX/out/index.html"
  grep -qF 'href="https://example.org/x.md"' "$FX/out/index.html"
  grep -qF 'href="index.html"' "$FX/out/other.html"
}

@test "build-docs-site: fixture nav order — index, then the list's order, then pages the list omits" {
  need_pandoc
  fx_page index "- [Zeta](./zeta.md)" "- [Alpha](./alpha.md)"
  fx_page zeta "z"
  fx_page alpha "a"
  fx_page mid "the list does not name this page"
  run fx_build
  [ "$status" -eq 0 ]
  local navorder
  navorder="$(nav_of "$FX/out/mid.html" | grep -oE 'href="[a-z]+\.html"' | tr '\n' ' ')"
  [ "$navorder" = 'href="index.html" href="zeta.html" href="alpha.html" href="mid.html" ' ]
}

@test "build-docs-site: fixture nav order — a fenced example of the list does not order the nav" {
  need_pandoc
  fx_fixture_b
  run fx_build
  [ "$status" -eq 0 ]
  local navorder
  navorder="$(nav_of "$FX/out/index.html" | grep -oE 'href="[a-z]+\.html"' | tr '\n' ' ')"
  [ "$navorder" = 'href="index.html" href="zeta.html" href="alpha.html" ' ]
}

# ------------------------------------------------------- FIXTURE: hand-written pages

@test "build-docs-site: x.md and x.html both present -> exit 4, nothing written" {
  fx_bin
  FX_PATH="$FX/bin"
  fx_page index "- [X](./x.md)"
  fx_page x "markdown"
  fx_html x '<h1>X</h1>'
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"both x.md and x.html exist"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: hand-written page without a derived-from header -> exit 4, nothing written" {
  fx_bin
  FX_PATH="$FX/bin"
  fx_page index "- [X](./x.html)"
  printf '<h1>X</h1>\n<!-- derived-from: too late -->\n' > "$FX/src/x.html"
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"x.html: line 1 must be a"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: HTML index: list links inside <pre>, <code> and comments are not a nav -> exit 4" {
  fx_bin
  FX_PATH="$FX/bin"
  fx_html index '<h1>Home</h1>' \
    '<pre>' '<li><a href="other.html">O</a></li>' '</pre>' \
    '<p>Example: <code>' '<li><a href="other.html">O</a></li></code></p>' \
    '<!--' '<li><a href="other.html">O</a></li>' '-->'
  fx_page other "o"
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"page list names no page"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: hand-written index.html — body byte-identical; head, nav and footer equal a Markdown page's" {
  need_pandoc
  fx_html index '<h1>Home &amp; away</h1>' \
    '<ul>' '<li><a href="other.html">Other</a></li>' '<li><a href="ent.html">Ent</a></li>' '</ul>' \
    '<svg xmlns="http://www.w3.org/2000/svg"><rect width="8" height="8"/></svg>' \
    '<script>document.createElementNS("http://www.w3.org/2000/svg","rect")</script>'
  fx_page other "hello"
  fx_html ent '<h1>a &amp;lt; b</h1>'
  run fx_build
  [ "$status" -eq 0 ]
  # the body, byte for byte: neither pandoc reader touched it
  cmp <(article_of "$FX/out/index.html") "$FX/src/index.html"
  # the frame (head, nav, footer) equals the Markdown page's
  diff <(frame_of "$FX/out/index.html") <(frame_of "$FX/out/other.html")
  grep -qF '<title>Home &amp; away | devAgent</title>' "$FX/out/index.html"
  nav_of "$FX/out/index.html" | grep -qF '>Home &amp; away</a>'
  # entities decode once: &amp;lt; shows as the literal text "&lt;"
  grep -qF '<title>a &amp;lt; b | devAgent</title>' "$FX/out/ent.html"
  nav_of "$FX/out/ent.html" | grep -qF '>a &amp;lt; b</a>'
}

@test "build-docs-site: nav-label header sets the nav label; the H1 still sets the title" {
  need_pandoc
  fx_page index "- [Q](./q.html)"
  printf '%s\n' '<!-- derived-from: fixture -->' '<!-- nav-label: Q & A -->' '<h1>A long hero heading</h1>' > "$FX/src/q.html"
  run fx_build
  [ "$status" -eq 0 ]
  nav_of "$FX/out/index.html" | grep -qF '>Q &amp; A</a>'
  grep -qF '<title>A long hero heading | devAgent</title>' "$FX/out/q.html"
}

@test "build-docs-site: hand-written page with no <h1> -> exit 5 naming it" {
  need_pandoc
  fx_page index "- [Bare](./bare.html)"
  fx_html bare '<p>no heading here</p>'
  run fx_build
  [ "$status" -eq 5 ]
  [[ "$output" == *"no <h1> in"*"bare.html"* ]]
}

@test "build-docs-site: HTML index nav order — a <pre> decoy, then the real list after </pre>" {
  need_pandoc
  fx_html index '<h1>Home</h1>' \
    '<pre>' '<li><a href="alpha.html">Alpha</a></li>' '</pre>' \
    '<ul>' '<li><a href="zeta.html">Zeta</a></li>' '</ul>'
  fx_page alpha "a"
  fx_page zeta "z"
  run fx_build
  [ "$status" -eq 0 ]
  local navorder
  navorder="$(nav_of "$FX/out/index.html" | grep -oE 'href="[a-z]+\.html"' | tr '\n' ' ')"
  [ "$navorder" = 'href="index.html" href="zeta.html" href="alpha.html" ' ]
}

# t3h_row <status> <token> <index body line...> — one fixture dir per row:
# index.html (the lines) + other.md, built pandoc-free.
t3h_row() {
  local want="$1" token="$2"; shift 2
  t3h_n=$((t3h_n + 1))
  FX="$BATS_TEST_TMPDIR/row$t3h_n"
  mkdir -p "$FX/src" "$FX/static-empty"
  fx_bin
  FX_PATH="$FX/bin"
  fx_html index '<h1>Home</h1>' "$@"
  fx_page other "o"
  run fx_build
  [ "$status" -eq "$want" ] || { echo "row $t3h_n: status $status, want $want: $output" >&2; return 1; }
  [[ "$output" == *"$token"* ]] || { echo "row $t3h_n: no '$token' in: $output" >&2; return 1; }
  [ ! -e "$FX/out" ] || { echo "row $t3h_n: wrote $FX/out" >&2; return 1; }
}

@test "build-docs-site: HTML index parse-model edges (nav)" {
  local e='<li><a href="other.html">O</a></li>' none='page list names no page' probe='pandoc is not installed'
  t3h_n=0
  t3h_row 4 "$none" '<script>' "$e" '</script>'
  t3h_row 4 "$none" '<style>' "$e" '</style>'
  t3h_row 4 "$none" '<template>' "$e" '</template>'
  t3h_row 4 "$none" '<textarea>' "$e" '</textarea>'
  t3h_row 4 "$none" '<PRE>' "$e" '</PRE>'
  t3h_row 3 "$probe" '<preview>' "$e" '</preview>'
  t3h_row 3 "$probe" '<li><a class="card" href="other.html">O</a></li>'
  t3h_row 3 "$probe" '<LI><A HREF="other.html">O</A></LI>'
  t3h_row 4 'put <li> and its <a href> on one line' '<li>' '<a href="other.html">O</a></li>'
}

# t3i_row <title> <index body line...> — one fixture dir per row, a lone
# hand-written index.html, rendered; its <title> must come from <title>.
t3i_row() {
  local want="$1"; shift
  t3i_n=$((t3i_n + 1))
  FX="$BATS_TEST_TMPDIR/row$t3i_n"
  mkdir -p "$FX/src" "$FX/static-empty"
  fx_html index '<p>intro</p>' "$@"
  run fx_build
  [ "$status" -eq 0 ] || { echo "row $t3i_n: status $status: $output" >&2; return 1; }
  grep -qF "<title>$want | devAgent</title>" "$FX/out/index.html" \
    || { echo "row $t3i_n: $(grep -F '<title>' "$FX/out/index.html")" >&2; return 1; }
}

@test "build-docs-site: hand-written H1 parse-model edges" {
  need_pandoc
  t3i_n=0
  t3i_row Real '<!-- <h1>Fake</h1> -->' '<h1>Real</h1>'
  t3i_row Real '<pre>' '<h1>Fake</h1>' '</pre>' '<h1>Real</h1>'
  t3i_row Real '<script>var s = "<h1>Fake</h1>";</script>' '<h1>Real</h1>'
  t3i_row Upper '<H1 class="x">Upper</H1>'
}

@test "build-docs-site: README.html in --src -> exit 4, nothing written" {
  fx_bin
  FX_PATH="$FX/bin"
  fx_page index "hello"
  printf '%s\n' '<!-- derived-from: fixture -->' '<h1>Readme</h1>' > "$FX/src/README.html"
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"README is reserved"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: Markdown index may name a hand-written page; omitted pages sort across kinds" {
  need_pandoc
  fx_page index "- [Hand](./hand.html)" "- [Alpha](./alpha.md)"
  fx_html hand '<h1>Hand</h1>'
  fx_page alpha "a"
  fx_html beta '<h1>Beta</h1>'
  fx_page mid "m"
  run fx_build
  [ "$status" -eq 0 ]
  local navorder
  navorder="$(nav_of "$FX/out/mid.html" | grep -oE 'href="[a-z]+\.html"' | tr '\n' ' ')"
  [ "$navorder" = 'href="index.html" href="hand.html" href="alpha.html" href="beta.html" href="mid.html" ' ]
  article_of "$FX/out/index.html" | grep -qF 'href="hand.html"'
}

# ------------------------------------------------------- FIXTURE: asset folders

@test "build-docs-site: --static with an empty or missing value is refused" {
  fx_bin
  FX_PATH="$FX/bin"
  fx_page index "hello"
  run fx_build --static ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"--static needs a value"* ]]
  run fx_build --static "$FX/nope"
  [ "$status" -eq 4 ]
  [[ "$output" == *"static dir not found"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: both asset folders copy byte-identical" {
  need_pandoc
  fx_page index "hello"
  mkdir -p "$FX/src/assets/img" "$FX/static"
  printf '\x89PNG\r\n\x1a\n\0\0\xff\xfe\x80 end\r\n' > "$FX/src/assets/img/a.png"
  printf 'body { color: #123; }\r\n\0\xc3\xa9\n' > "$FX/static/s.css"
  run fx_build --static "$FX/static"
  [ "$status" -eq 0 ]
  cmp "$FX/src/assets/img/a.png" "$FX/out/assets/img/a.png"
  cmp "$FX/static/s.css" "$FX/out/static/s.css"
}

@test "build-docs-site: src= to a missing local asset -> exit 6 naming it" {
  need_pandoc
  fx_page index '<img src="assets/missing.png" alt="">'
  run fx_build
  [ "$status" -eq 6 ]
  [[ "$output" == *"links to assets/missing.png"* ]]
}

@test "build-docs-site: srcset candidate to a missing asset -> exit 6 naming it" {
  need_pandoc
  fx_page index '<img src="assets/a.png" srcset="assets/a.png 1x, assets/b.png 2x" alt="">'
  mkdir -p "$FX/src/assets"
  printf 'a\n' > "$FX/src/assets/a.png"
  run fx_build
  [ "$status" -eq 6 ]
  [[ "$output" == *"links to assets/b.png"* ]]
  [[ "$output" != *"links to assets/a.png"* ]]
}

@test "build-docs-site: a root-absolute local path -> exit 6" {
  need_pandoc
  fx_page index '<a href="/x.css">style</a>'
  run fx_build
  [ "$status" -eq 6 ]
  [[ "$output" == *"uses a root-absolute path /x.css"* ]]
}

@test "build-docs-site: Markdown image from the asset folder rewrites and builds" {
  need_pandoc
  fx_page index '![d](./assets/d.svg)'
  mkdir -p "$FX/src/assets"
  printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' > "$FX/src/assets/d.svg"
  run fx_build
  [ "$status" -eq 0 ]
  grep -qF 'src="assets/d.svg"' "$FX/out/index.html"
}

@test "build-docs-site: Markdown image from another host -> exit 5" {
  need_pandoc
  fx_page index '![x](https://x.test/a.png)'
  run fx_build
  [ "$status" -eq 5 ]
  [[ "$output" == *"unclassified image target: https://x.test/a.png"* ]]
}

@test "build-docs-site: a .. path that leaves the site -> exit 6" {
  need_pandoc
  # row 1: a raw link out of --out that happens to resolve on disk
  fx_page index "- [Other](./other.md)" "" 'see <a href="../src/other.md">up</a>'
  fx_page other "o"
  run fx_build
  [ "$status" -eq 6 ]
  [[ "$output" == *"climbs out of the site with ../src/other.md"* ]]
  # row 2: the asset class does not accept a .. segment
  FX="$BATS_TEST_TMPDIR/row2"
  mkdir -p "$FX/src" "$FX/static-empty"
  fx_page index "- [Other](./other.md)" "" "[x](./assets/../other.md)"
  fx_page other "o"
  run fx_build
  [ "$status" -eq 5 ]
  [[ "$output" == *"unclassified link target"* ]]
}

# t4i_row <target> <raw html> — one fixture dir per row; the page must exit 6
# naming the target.
t4i_row() {
  local want="$1" html="$2"
  t4i_n=$((t4i_n + 1))
  FX="$BATS_TEST_TMPDIR/row$t4i_n"
  mkdir -p "$FX/src" "$FX/static-empty"
  fx_page index "$html"
  run fx_build
  [ "$status" -eq 6 ] || { echo "row $t4i_n: status $status: $output" >&2; return 1; }
  [[ "$output" == *"links to $want"* ]] || { echo "row $t4i_n: no 'links to $want' in: $output" >&2; return 1; }
}

@test "build-docs-site: closure parse-model edges" {
  need_pandoc
  t4i_n=0
  t4i_row assets/n1.png '<img src=assets/n1.png alt="">'
  t4i_row assets/n2.png '<IMG SRC="assets/n2.png">'
  t4i_row n3.html "<a href='n3.html'>n3</a>"
}
