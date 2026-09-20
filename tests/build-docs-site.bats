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
# need_pandoc. tests/ runs in test.yml WITHOUT pandoc, so there the rendering
# tests skip with a reason; publish-docs-site.yml installs pandoc, asserts it,
# and runs this file with skips forbidden, so the lane that owns the site
# always executes them. Locally, install pandoc 3.x.
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
  mkdir -p "$FX/src"
}

# fx_bin — a PATH holding only what the builder runs BEFORE its pandoc probe, so
# "no pandoc" (or a stub pandoc) is the only thing the probe can see.
fx_bin() {
  local t
  mkdir -p "$FX/bin"
  for t in dirname basename grep sed; do
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
  run env PATH="$FX/bin" "$(command -v bash)" "$BUILD" --src "$FX/src" --out "$FX/out"
  [ "$status" -eq 3 ]
  [[ "$output" == *"pandoc is not installed"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: pandoc older than 3.x -> exit 3 naming the version found, nothing written" {
  fx_bin
  printf '#!%s\necho "pandoc 2.9.2.1"\n' "$(command -v bash)" > "$FX/bin/pandoc"
  chmod +x "$FX/bin/pandoc"
  fx_page index "hello"
  run env PATH="$FX/bin" "$(command -v bash)" "$BUILD" --src "$FX/src" --out "$FX/out"
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
  run bash "$BUILD" --src "$FX/src" --out "$FX/out"
  [ "$status" -eq 4 ]
  [[ "$output" == *"no content pages"* ]]
}

@test "build-docs-site: pages but no index.md -> exit 4" {
  fx_page install "hello"
  run bash "$BUILD" --src "$FX/src" --out "$FX/out"
  [ "$status" -eq 4 ]
  [[ "$output" == *"no index.md"* ]]
}

@test "build-docs-site: index.md's page list names no page -> exit 4, not a silent alphabetical nav" {
  # "* " bullets: a list the derivation's grep does not see.
  fx_page index "* [Other](./other.md)"
  fx_page other "hello"
  run bash "$BUILD" --src "$FX/src" --out "$FX/out"
  [ "$status" -eq 4 ]
  [[ "$output" == *"page list names no page"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: --out is an existing regular file -> exit 4, file untouched" {
  need_pandoc
  fx_page index "hello"
  printf 'keep me\n' > "$FX/out"
  run bash "$BUILD" --src "$FX/src" --out "$FX/out"
  [ "$status" -eq 4 ]
  [[ "$output" == *"--out exists and is not a directory"* ]]
  [ "$(cat "$FX/out")" = "keep me" ]
}

@test "build-docs-site: non-empty --out is refused untouched -> exit 4" {
  need_pandoc
  fx_page index "hello"
  mkdir -p "$FX/out"
  printf 'keep me\n' > "$FX/out/.hidden-keep"
  run bash "$BUILD" --src "$FX/src" --out "$FX/out"
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
  run bash "$BUILD" --src "$FX/src" --out "$FX/out"
  [ "$status" -eq 5 ]
  [[ "$output" == *"no top-level '# ' heading"*"bare.md"* ]]
}

@test "build-docs-site: a link the filter cannot classify -> exit 5 naming the target" {
  need_pandoc
  fx_page index "see [deep](sub/dir/page.md)"
  run bash "$BUILD" --src "$FX/src" --out "$FX/out"
  [ "$status" -eq 5 ]
  [[ "$output" == *"unclassified link target: sub/dir/page.md"* ]]
}

@test "build-docs-site: a link that leaves docs-site/ with an empty --blob-base -> exit 5 naming it" {
  need_pandoc
  fx_page index "see [up](../LICENSE)"
  run bash "$BUILD" --src "$FX/src" --out "$FX/out" --blob-base ""
  [ "$status" -eq 5 ]
  [[ "$output" == *"no blob_base was given: ../LICENSE"* ]]
}

@test "build-docs-site: a sibling link to a page that does not exist -> exit 6 naming it" {
  need_pandoc
  fx_page index "see [ghost](./ghost.md)"
  run bash "$BUILD" --src "$FX/src" --out "$FX/out"
  [ "$status" -eq 6 ]
  [[ "$output" == *"index.html links to ghost.html"* ]]
}

@test "build-docs-site: a raw-HTML link the Lua filter never sees is still closed over -> exit 6" {
  need_pandoc
  fx_page index 'raw <a href="nowhere.html">link</a>'
  run bash "$BUILD" --src "$FX/src" --out "$FX/out"
  [ "$status" -eq 6 ]
  [[ "$output" == *"links to nowhere.html"* ]]
}

@test "build-docs-site: fixture happy path — sibling link, fragment, and --blob-base all rewrite" {
  need_pandoc
  fx_page index "- [Other](./other.md)" "" "[frag](./other.md#part) and [up](../LICENSE) and [ext](https://example.org/x.md)"
  fx_page other "## part" "" "[home](./index.md)"
  run bash "$BUILD" --src "$FX/src" --out "$FX/out" --blob-base "https://forge.example/blob/main/"
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
  run bash "$BUILD" --src "$FX/src" --out "$FX/out"
  [ "$status" -eq 0 ]
  local navorder
  navorder="$(nav_of "$FX/out/mid.html" | grep -oE 'href="[a-z]+\.html"' | tr '\n' ' ')"
  [ "$navorder" = 'href="index.html" href="zeta.html" href="alpha.html" href="mid.html" ' ]
}
