#!/usr/bin/env bats
# #465, #995: scripts/build-docs-site.sh renders docs-site/ (Markdown *.md and
# hand-written *.html pages, minus README.*) to the static site the Pages
# workflow publishes, with its two asset folders and its moved-page stubs.
#
# Two subject families:
#   REAL  — the tracked docs-site/ built once per file (setup_file); pins the
#           page set by COUNT against the source globs and moved.txt, link
#           closure over href, src and srcset (the builder's tag-scoped reader
#           restated as a superset, so its floor proves the real build was
#           scanned), the one
#           link that leaves docs-site/,
#           per-page code-block and table-row counts against the markdown,
#           titles, nav, and that the output fetches nothing. That last test
#           is the 1.0 fetch ban; #1030 replaces it with an allowlist, and
#           with it the stub leg that reads the ban's regex.
#   FIXTURE — throwaway source dirs that drive each refusal BRANCH (exit 2-6)
#           and each input kind: hand-written pages (derived-from header, H1
#           and nav-label, marker splice, HTML-index nav), the asset folders
#           (<src>/assets/ and --static), and moved-page stubs (moved.txt).
#           Every negative pins the exact code AND a message token, so a
#           different failure cannot satisfy it. The one refusal with no
#           fixture is the post-render count (exit 5 "expected N pages and M
#           stubs"): nothing outside the script can make it fire, so it is
#           pinned by a mutation row in the plan instead, and says so here.
#           fx_build passes an empty --static, so a fixture build never copies
#           the repo's own scripts/docs-site/static/.
#
# awk and pandoc: the builder probes for awk right after its argument checks
# (exit 3 naming awk), then validates its input and derives the nav BEFORE it
# probes for pandoc, so every refusal up to and including the probe is tested
# without it (fx_bin links only the tools that run before the probe; a stub
# stands in where a version is needed). Tests that render call
# need_pandoc, which skips only where pandoc is absent (a local run). In CI the
# file runs un-skipped: test.yml's bats job installs pandoc (#841), and
# publish-docs-site.yml installs pandoc, asserts it, and additionally runs this
# file with skips forbidden. Locally, install pandoc 3.x.
#
# COUPLING: the REAL tests derive their expectations from docs-site/ (fence
# and table-row counts, the install command lines, two H1s, the page set and
# moved.txt, and nav order from index.md's "Where to go next" list).
# docs-site/README.md announces this to page editors; a failure here after a
# page edit usually means the expectation moves with the page, not that the
# page is wrong.

load 'lib/bats-helpers'

BUILD="$PLUGIN_ROOT/scripts/build-docs-site.sh"
SITE="$PLUGIN_ROOT/docs-site"

need_pandoc() {
  command -v pandoc >/dev/null 2>&1 \
    || skip "pandoc not installed — CI runs this file un-skipped (test suite and publish docs site); install pandoc 3.x locally"
}

setup_file() {
  command -v pandoc >/dev/null 2>&1 || return 0
  REAL_OUT="$BATS_FILE_TMPDIR/site"
  export REAL_OUT
  bash "$BUILD" --src "$SITE" --out "$REAL_OUT" > "$BATS_FILE_TMPDIR/real.stdout" 2> "$BATS_FILE_TMPDIR/real.stderr"
}

# fx_reset <dir> — point FX at a fresh fixture dir (src/ and static-empty/).
fx_reset() {
  FX="$1"
  mkdir -p "$FX/src" "$FX/static-empty"
}

setup() {
  FX_BASH="$(command -v bash)"
  fx_reset "$BATS_TEST_TMPDIR"
}

# The fetch scanner and the site policy. CSP is one of the policy's four homes
# (check-fetches.py's POLICY, page.html, the stub writer in build-docs-site.sh),
# written out here and never read from the others, so a drift in any of them
# fails a row.
SCANNER="$PLUGIN_ROOT/scripts/docs-site/check-fetches.py"
CSP="default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' data: blob:; worker-src 'self' blob:; media-src 'self' data: blob:; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'"
CSP_META="<meta http-equiv=\"Content-Security-Policy\" content=\"$CSP\">"
OH='https://other.host'
NS='http://www.w3.org/2000/svg'

# scan — the scanner run directly on $FX/site (no build, no pandoc).
scan() { python3 -I -X utf8 "$SCANNER" "$FX/site"; }

# fx_sf <relpath> <line...> — a file under $FX/site, one argument per line.
fx_sf() {
  local rel="$1"; shift
  mkdir -p "$(dirname "$FX/site/$rel")"
  printf '%s\n' "$@" > "$FX/site/$rel"
}

# fx_doc <relpath> <body line...> — a document under $FX/site carrying the CSP meta.
fx_doc() {
  local rel="$1"; shift
  fx_sf "$rel" '<!DOCTYPE html>' '<html lang="en"><head>' '<meta charset="utf-8">' "$CSP_META" \
    '</head><body>' "$@" '</body></html>'
}

# sc_new — a fresh fixture dir for the next row (one dir per row).
sc_new() { sc_n=$((${sc_n:-0} + 1)); fx_reset "$BATS_TEST_TMPDIR/row$sc_n"; }

# sc_row <want> <relpath> <needle> <token> — scan $FX/site. want 0: status 0 and
# the ok line. want 3: status 3 and a line "check-fetches: <relpath>:<ln>: ..."
# holding <token>, <ln> the first line of the planted file holding <needle>
# (0 when <needle> is empty), so a violation elsewhere cannot satisfy the row.
sc_row() {
  local want="$1" rel="$2" needle="$3" token="$4" ln=0 l hit=0
  run scan
  [ "$status" -eq "$want" ] || { echo "row ${sc_n:-0} ($rel): status $status, want $want: $output" >&2; return 1; }
  if [ "$want" -eq 0 ]; then
    [[ "$output" == *"check-fetches: ok: "* ]] || { echo "row ${sc_n:-0}: no ok line: $output" >&2; return 1; }
    return 0
  fi
  if [ -n "$needle" ]; then
    ln="$(grep -nF -- "$needle" "$FX/site/$rel" | sed -n '1s/:.*//p')"
    [ -n "$ln" ] || { echo "row ${sc_n:-0}: '$needle' is not in $rel" >&2; return 1; }
  fi
  for l in "${lines[@]}"; do
    case "$l" in "check-fetches: $rel:$ln: "*"$token"*) hit=1 ;; esac
  done
  [ "$hit" -eq 1 ] || { echo "row ${sc_n:-0}: no 'check-fetches: $rel:$ln: ...$token' in: $output" >&2; return 1; }
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

# real_content — the tracked site's content pages, one base name per line:
# docs-site/*.md and *.html, minus README.*.
real_content() {
  local f b
  for f in "$SITE"/*.md "$SITE"/*.html; do
    [ -e "$f" ] || continue
    b="${f##*/}"
    b="${b%.*}"
    [ "$b" = README ] || printf '%s\n' "$b"
  done
}

# real_stubs — the old names docs-site/moved.txt lists (its data lines).
real_stubs() {
  [ -f "$SITE/moved.txt" ] || return 0
  awk '!/^[ \t]*(#|$)/ { print $1 }' "$SITE/moved.txt"
}

@test "build-docs-site: real site — one html per content page and stub, README not published" {
  need_pandoc
  shopt -s nullglob
  local content=() stubs=() p
  mapfile -t content < <(real_content)
  mapfile -t stubs < <(real_stubs)
  [ "${#content[@]}" -ge 2 ]
  local html=("$REAL_OUT"/*.html) all=("$REAL_OUT"/*) extra=0
  [ "${#html[@]}" -eq "$(( ${#content[@]} + ${#stubs[@]} ))" ]
  # the asset folders appear exactly when their sources exist
  if [ -d "$SITE/assets" ]; then extra=$((extra + 1)); [ -d "$REAL_OUT/assets" ]; else [ ! -e "$REAL_OUT/assets" ]; fi
  if [ -d "$PLUGIN_ROOT/scripts/docs-site/static" ]; then
    extra=$((extra + 1)); [ -d "$REAL_OUT/static" ]
  else
    [ ! -e "$REAL_OUT/static" ]
  fi
  [ "${#all[@]}" -eq "$(( ${#html[@]} + extra ))" ]
  [ ! -e "$REAL_OUT/README.html" ]
  for p in "${content[@]}" "${stubs[@]}"; do
    [ -s "$REAL_OUT/$p.html" ]
  done
  # N counts content pages; stubs are not pages
  grep -qx "build-docs-site: built ${#content[@]} pages -> $REAL_OUT" "$BATS_FILE_TMPDIR/real.stdout"
}

@test "build-docs-site: real site — every local href, src and srcset resolves to a built file" {
  need_pandoc
  local content=() p nmd=0
  mapfile -t content < <(real_content)
  for p in "${content[@]}"; do
    if [ -f "$SITE/$p.md" ]; then nmd=$((nmd + 1)); fi
  done
  # The builder's reader, restated without its comment and raw-text skipping
  # (so it reads a superset): attributes only inside tags (a tag may span
  # lines); names case-blind after whitespace, spaces allowed around "=";
  # values double-quoted, single-quoted or bare; each srcset candidate's URL.
  local tag_re='<[A-Za-z][^<>"'"'"']*("[^"]*"[^<>"'"'"']*|'"'"'[^'"'"']*'"'"'[^<>"'"'"']*)*>'
  local re='[[:space:]](href|src|srcset)[[:space:]]*=[[:space:]]*("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]>"'"'"']+)'
  local html a name v t checked=0 cands
  for html in "$REAL_OUT"/*.html; do
    while IFS= read -r a; do
      a="${a#"${a%%[![:space:]]*}"}"
      name="${a%%[=[:space:]]*}"
      v="${a#*=}"
      v="${v#"${v%%[![:space:]]*}"}"
      v="${v#[\"\']}"
      v="${v%[\"\']}"
      cands=("$v")
      if [ "${name,,}" = srcset ]; then IFS=',' read -ra cands <<< "$v"; fi
      for t in "${cands[@]}"; do
        t="${t#"${t%%[![:space:]]*}"}"
        t="${t%%[[:space:]]*}"
        case "$t" in [A-Za-z]*:*|'#'*) continue ;; esac
        t="${t%%#*}"
        t="${t%%\?*}"
        case "/$t/" in //*|*/../*) echo "$html -> $t leaves the site" >&2; return 1 ;; esac
        [ -f "$REAL_OUT/$t" ] || { echo "$html -> $t" >&2; return 1; }
        checked=$((checked + 1))
      done
    done < <(tr '\n' ' ' < "$html" | grep -oE "$tag_re" | grep -oiE "$re")
  done
  # every content page's nav links every content page: content² is the floor;
  # a zero here means the scan saw nothing.
  [ "$checked" -ge "$(( ${#content[@]} * ${#content[@]} ))" ]
  # the only surviving .md hrefs are forge blob URLs (footers + links leaving docs-site/)
  local stray
  stray="$(grep -rhoE 'href="[^"]*\.md[#"]' "$REAL_OUT" | grep -vcF 'href="https://github.com/mtibbits/devagent/blob/master/' || true)"
  [ "$stray" = "0" ]
  # every Markdown page's footer links its source on the forge
  [ "$(grep -rhoE 'href="[^"]*\.md[#"]' "$REAL_OUT" | wc -l)" -ge "$nmd" ]
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
  local content=() p html
  mapfile -t content < <(real_content)
  # content pages only (a moved-page stub has no nav); each nav links them all
  for p in "${content[@]}"; do
    html="$REAL_OUT/$p.html"
    [ "$(nav_of "$html" | grep -c 'aria-current="page"')" -eq 1 ]
    grep -qF "<a href=\"$p.html\" aria-current=\"page\">" "$html"
    [ "$(nav_of "$html" | grep -c '<a href=')" -eq "${#content[@]}" ]
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

@test "build-docs-site: hand-written page saved with a byte-order mark -> exit 4 naming the BOM" {
  fx_bin
  FX_PATH="$FX/bin"
  fx_page index "- [X](./x.html)"
  printf '\xEF\xBB\xBF<!-- derived-from: fixture -->\n<h1>X</h1>\n' > "$FX/src/x.html"
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"x.html: line 1 starts with a UTF-8 byte-order mark"* ]]
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

@test "build-docs-site: hand-written <h1> with an entity the title reader cannot decode -> exit 5 naming it" {
  need_pandoc
  fx_page index "- [Dash](./dash.html)"
  fx_html dash '<h1>Plan &mdash; ship</h1>'
  run fx_build
  [ "$status" -eq 5 ]
  [[ "$output" == *"dash.html: the <h1> uses &mdash;"* ]]
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
  fx_reset "$BATS_TEST_TMPDIR/row$t3h_n"
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
  t3h_row 3 "$probe" "$e" '<li>' '<a href="https://x.test/">X</a></li>'
  t3h_row 4 "$none" '<pre' ' class="ex">' "$e" '</pre >'
}

# t3i_row <title> <index body line...> — one fixture dir per row, a lone
# hand-written index.html, rendered; its <title> must come from <title>.
t3i_row() {
  local want="$1"; shift
  t3i_n=$((t3i_n + 1))
  fx_reset "$BATS_TEST_TMPDIR/row$t3i_n"
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
  t3i_row 'The next loop' '<h1>The <code>next</code> loop</h1>'
  t3i_row 'Plan it. Ship it.' '<h1>Plan it.<br>Ship it.</h1>'
  t3i_row 'Big &amp; Bold' '<h1' '  class="hero">Big &amp; Bold</h1>' '<h1>Second</h1>'
  t3i_row Real '<pre' '>' '<h1>Fake</h1>' '</pre >' '<h1>Real</h1>'
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
  fx_reset "$BATS_TEST_TMPDIR/row2"
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
  fx_reset "$BATS_TEST_TMPDIR/row$t4i_n"
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
  t4i_row assets/n4.png $'<img\n  src="assets/n4.png" alt="">'
  t4i_row n5.html '<a href = "n5.html">n5</a>'
  t4i_row n6.js '<script src="n6.js"></script>'
}

@test "build-docs-site: href= and src= written in code are text, not links" {
  need_pandoc
  fx_page index "- [Hand](./hand.html)" "" \
    'The list uses `<li><a href="page.html">Title</a></li>`.' "" \
    '```' '  export src=docs-site' '<img src="logo.png" alt="">' '```'
  fx_html hand '<h1>Hand</h1>' \
    '<p><code>&lt;img src=&quot;missing.png&quot;&gt;</code></p>' \
    '<pre>srcset=a.png href=b.html</pre>' \
    '<!-- <img src="old.png"> -->' \
    '<script>var h = "<img src=\"" + u + "\">";</script>'
  run fx_build
  [ "$status" -eq 0 ]
  [[ "$output" == *"built 2 pages -> $FX/out"* ]]
}

# ------------------------------------------------------- FIXTURE: moved-page stubs

# fx_moved <line...> — the fixture's moved.txt, one argument per line.
fx_moved() { printf '%s\n' "$@" > "$FX/src/moved.txt"; }

# fx_two_pages — index.md listing other.md, the base of the moved.txt legs.
fx_two_pages() {
  fx_page index "- [Other](./other.md)"
  fx_page other "o"
}

@test "build-docs-site: moved.txt malformed line -> exit 4 naming the line" {
  fx_bin
  FX_PATH="$FX/bin"
  fx_two_pages
  fx_moved '# old names' '' 'old'
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"moved.txt:3: expected"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: moved.txt naming a live page -> exit 4" {
  fx_bin
  FX_PATH="$FX/bin"
  fx_two_pages
  fx_moved 'other index.html'
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"moved.txt:1: other is still a content page"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: moved.txt listing an old name twice -> exit 4" {
  fx_bin
  FX_PATH="$FX/bin"
  fx_two_pages
  fx_moved 'old-a index.html' 'old-a other.html'
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"moved.txt:2: old-a is listed twice"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: moved.txt naming README as an old page -> exit 4" {
  fx_bin
  FX_PATH="$FX/bin"
  fx_two_pages
  fx_moved 'README other.html'
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"moved.txt:1: README is reserved"* ]]
  [ ! -e "$FX/out" ]
}

# fx_stub_site — T5d's fixture: two pages and two stubs, one home on the site
# and one on the forge.
fx_stub_site() {
  fx_two_pages
  fx_moved '# moved pages' 'old-a other.html' 'old-b https://github.com/mtibbits/devagent/blob/master/docs/x.md'
}

@test "build-docs-site: moved.txt builds stubs that link home, sit in no nav, and are not pages" {
  need_pandoc
  fx_stub_site
  run fx_build
  [ "$status" -eq 0 ]
  grep -qF '<a href="other.html">' "$FX/out/old-a.html"
  grep -qF 'href="https://github.com/mtibbits/devagent/blob/master/docs/x.md"' "$FX/out/old-b.html"
  [ "$(grep -c '<nav' "$FX/out/old-a.html")" -eq 0 ]
  [ "$(grep -c '<nav' "$FX/out/old-b.html")" -eq 0 ]
  local p
  for p in index other; do
    [ "$(nav_of "$FX/out/$p.html" | grep -c 'old-')" -eq 0 ]
  done
  [[ "$output" == *"build-docs-site: wrote 2 moved-page stubs"* ]]
  [ "${lines[${#lines[@]}-1]}" = "build-docs-site: built 2 pages -> $FX/out" ]
}

@test "build-docs-site: moved.txt home that is not a page -> exit 6" {
  fx_bin
  FX_PATH="$FX/bin"
  fx_two_pages
  fx_moved 'old ghost.html'
  run fx_build
  [ "$status" -eq 6 ]
  [[ "$output" == *"moved.txt:1: ghost.html is not a content page this build produces"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: moved.txt self-loop -> exit 6" {
  fx_bin
  FX_PATH="$FX/bin"
  fx_two_pages
  fx_moved 'old-a old-a.html'
  run fx_build
  [ "$status" -eq 6 ]
  [[ "$output" == *"moved.txt:1: old-a.html is not a content page"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: moved.txt stub-to-stub -> exit 6" {
  fx_bin
  FX_PATH="$FX/bin"
  fx_two_pages
  fx_moved 'old-a old-b.html' 'old-b other.html'
  run fx_build
  [ "$status" -eq 6 ]
  [[ "$output" == *"moved.txt:1: old-b.html is not a content page"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: moved-page stubs pass the 1.0 fetch ban" {
  # The ban regex is read from the ban test's own source, so this leg moves
  # with it. #1030 must replace this leg when it rewrites the ban.
  need_pandoc
  local re
  re="$(sed -n "s/^  run grep -rlE '\(.*\)' \"\$REAL_OUT\"$/\1/p" "$BATS_TEST_FILENAME")"
  [ -n "$re" ]
  printf '<script>' | grep -qE "$re"
  fx_stub_site
  run fx_build
  [ "$status" -eq 0 ]
  run grep -lE "$re" "$FX/out/old-a.html" "$FX/out/old-b.html"
  [ "$status" -eq 1 ]
}

# ------------------------------------------------- SCANNER: check-fetches.py, run directly

# usage_2 — the last scanner run exited 2 and ended with the usage line.
usage_2() {
  [ "$status" -eq 2 ] || { echo "status $status, want 2: $output" >&2; return 1; }
  [[ "${lines[${#lines[@]}-1]}" == "usage: check-fetches.py"* ]] || { echo "no usage line last: $output" >&2; return 1; }
}

@test "build-docs-site: check-fetches — usage: no argument, two arguments, a flag, a missing dir and an empty dir exit 2" {
  fx_doc index.html '<p>x</p>'
  mkdir -p "$FX/empty"
  run python3 -I -X utf8 "$SCANNER"
  usage_2
  run python3 -I -X utf8 "$SCANNER" "$FX/site" "$FX/site"
  usage_2
  run python3 -I -X utf8 "$SCANNER" --help
  usage_2
  run python3 -I -X utf8 "$SCANNER" "$FX/absent"
  usage_2
  run python3 -I -X utf8 "$SCANNER" "$FX/empty"
  usage_2
  # positive control: the same scanner on the planted site
  run scan
  [ "$status" -eq 0 ]
}

@test "build-docs-site: check-fetches — '--' admits an out-dir that starts with '-'" {
  fx_doc index.html '<p>x</p>'
  mv "$FX/site" "$FX/-site"
  cd "$FX"
  run python3 -I -X utf8 "$SCANNER" -- -site
  [ "$status" -eq 0 ]
  [ "$output" = "check-fetches: ok: 1 files: 1 scanned, 0 binary, 0 vendored" ]
  run python3 -I -X utf8 "$SCANNER" -site
  usage_2
}

@test "build-docs-site: check-fetches — counts every file once" {
  fx_doc index.html '<p>x</p>'
  fx_sf assets/a.png 'png'
  fx_sf assets/f.woff2 'font'
  fx_sf assets/s.css 'nav a:hover { color: red; }'
  run scan
  [ "$status" -eq 0 ]
  [ "$output" = "check-fetches: ok: 4 files: 2 scanned, 2 binary, 0 vendored" ]
}

@test "build-docs-site: check-fetches — fail-closed file types" {
  sc_n=0
  sc_new; fx_sf assets/x.json '{}';       sc_row 3 assets/x.json '' '(.json)'
  sc_new; fx_sf assets/.gitkeep '';       sc_row 3 assets/.gitkeep '' 'hidden'
  sc_new; fx_sf assets/LICENSE 'MIT';     sc_row 3 assets/LICENSE '' '(no extension)'
  sc_new; fx_sf assets/a.gltf '{}';       sc_row 3 assets/a.gltf '' '(.gltf)'
  sc_new; fx_sf assets/t.js 'var a = 1;'; ln -s "$FX/site/assets/t.js" "$FX/site/assets/l.js"
  sc_row 3 assets/l.js '' 'not a regular file'
  sc_new; mkdir -p "$FX/site/assets"; printf 'a{}\n\xff\n' > "$FX/site/assets/b.css"
  sc_row 3 assets/b.css '' 'not UTF-8 text'
  sc_new; fx_sf real/x.css 'a{}'; mkdir -p "$FX/site/assets"; ln -s ../real "$FX/site/assets/ld"
  sc_row 3 assets/ld '' 'not a regular file'
  # every violation line is followed by the count line
  [[ "$output" == *"check-fetches: 1 violation(s) in 1 file(s)"* ]]
}

@test "build-docs-site: check-fetches — \"private preview\" fails across a line break, any case" {
  sc_n=0
  sc_new; fx_sf assets/p.css '/* Private' '  Preview */'
  sc_row 3 assets/p.css 'Private' 'the words "private preview" may not be published'
  sc_new; fx_doc index.html '<p>A Private' 'preview build</p>'
  sc_row 3 index.html 'Private' 'private preview'
}

# js_row <want> <token> <line...> — one row: assets/a.js holding the lines; the
# needle is the first line.
js_row() {
  local want="$1" token="$2"; shift 2
  sc_new; fx_sf assets/a.js "$@"
  sc_row "$want" assets/a.js "$1" "$token"
}

# css_row <want> <token> <line...> — the same for assets/a.css.
css_row() {
  local want="$1" token="$2"; shift 2
  sc_new; fx_sf assets/a.css "$@"
  sc_row "$want" assets/a.css "$1" "$token"
}

@test "build-docs-site: check-fetches — JS: strings and template chunks with a remote URL are refused" {
  local r='remote URL in a JS string'
  sc_n=0
  js_row 3 "$r" "fetch(\"$OH/x\");"
  js_row 3 "$r" "img.src = '//other.host/i.png';"
  js_row 3 "$r" 'var u = `https://${h}/x`;'
  js_row 3 "$r" 'var u = `${a}ps://other.host`;'
  js_row 3 "$r" 'var u = "\\other.host/x";'
  js_row 3 "$r" 'var u = "http:other.host/x";'
  js_row 3 "$r" $'var u = "ht\ttps://other.host/x";'
  js_row 3 'javascript: URL in a JS string' 'location = "javascript:alert(1)";'
  js_row 3 "$r" "var u = \"data:,$OH/x\";"
  js_row 3 "$r" "var u = \"$NS https://other.host/x\";"
}

@test "build-docs-site: check-fetches — JS: a string extending a namespace URI is refused" {
  sc_n=0
  js_row 3 'remote URL in a JS string' "var u = \"$NS/x\";"
  js_row 3 'remote URL in a JS string' "var u = \"${NS}x\";"
}

@test "build-docs-site: check-fetches — JS: comments, regexes and non-URL colons pass" {
  sc_n=0
  js_row 0 '' "// $OH/x" 'var a = 1;'
  js_row 0 '' "/* $OH */ var a = 1;"
  js_row 0 '' 'var s = ["a:hover", "li:first-child", "Note: x"];'
  js_row 0 '' 'x = a / b / c; s = "assets/x.png";'
  js_row 0 '' "document.createElementNS(\"$NS\",\"rect\");"
  js_row 0 '' 'el.setAttributeNS("http://www.w3.org/1999/xlink","href","#g");'
  js_row 0 '' "var ns = [\"$NS\", \"http://www.w3.org/1999/xhtml\", \"http://www.w3.org/1999/xlink\"," \
    '"http://www.w3.org/1998/Math/MathML", "http://www.w3.org/XML/1998/namespace", "http://www.w3.org/2000/xmlns/"];'
  js_row 0 '' "el.innerHTML = '<svg xmlns=\"$NS\"><path d=\"M0 0\"/></svg>';"
}

@test "build-docs-site: check-fetches — JS: a data: SVG icon string keeps its namespace and passes" {
  sc_n=0
  js_row 0 '' "icon = \"data:image/svg+xml,<svg xmlns='$NS'><path d='M0 0'/></svg>\";"
}

@test "build-docs-site: check-fetches — a regex literal holding a quote does not hide a later string" {
  sc_n=0
  js_row 3 'remote URL in a JS string' "var r = /'/; var u = \"$OH/x\";"
  js_row 0 '' "var r = /'/; var u = \"assets/x\";"
}

@test "build-docs-site: check-fetches — JS: unterminated string or template fails closed" {
  sc_n=0
  js_row 3 'unterminated string' 'var s = "abc' 'var t = 1;'
  js_row 3 'unterminated template' 'var t = `abc' 'more'
}

@test "build-docs-site: check-fetches — a 100k-character run of scheme characters scans inside 2 s" {
  mkdir -p "$FX/site/assets"
  python3 -c 'import sys; open(sys.argv[1], "w").write("var s = \"" + "a" * 100000 + "\";\n")' "$FX/site/assets/big.js"
  local t0 t1
  t0="$(date +%s%N)"
  run scan
  t1="$(date +%s%N)"
  [ "$status" -eq 0 ]
  echo "scan took $(( (t1 - t0) / 1000000 )) ms" >&2
  [ "$(( (t1 - t0) / 1000000 ))" -lt 2000 ]
}

@test "build-docs-site: check-fetches — CSS: url(), @import and image-set() to another host are refused" {
  sc_n=0
  css_row 3 'remote URL in a CSS string' "@import \"$OH/a.css\";"
  css_row 3 'remote URL in a CSS url()' '@import url(//other.host/a.css);'
  css_row 3 'remote URL in a CSS url()' "a { background: url($OH/x.png); }"
  css_row 3 'remote URL in a CSS string' "a { background: image-set(\"$OH/x.png\" 1x); }"
}

@test "build-docs-site: check-fetches — CSS: selectors, comments and data: pass" {
  sc_n=0
  css_row 0 '' 'nav a:hover{color:red}'
  css_row 0 '' "/* @import \"$OH/x\"; */"
  css_row 0 '' 'a { background: url(data:image/png;base64,iVBORw0); }'
  css_row 0 '' 'a { background: url("assets/x.png"); }'
  css_row 0 '' 'body { font-family: "Segoe UI"; }'
  css_row 0 '' "@namespace svg url($NS);"
}

# html_row <want> <token> <needle> <body line...> — one row: index.html, a
# document carrying the CSP meta, with the lines as its body.
html_row() {
  local want="$1" token="$2" needle="$3"; shift 3
  sc_new; fx_doc index.html "$@"
  sc_row "$want" index.html "$needle" "$token"
}

# svg_row <want> <token> <needle> <line...> — one row: assets/d.svg, the lines
# wrapped in <svg xmlns="$NS">…</svg>. svg_whole: the lines are the whole file.
svg_row() {
  local want="$1" token="$2" needle="$3"; shift 3
  sc_new; fx_sf assets/d.svg "<svg xmlns=\"$NS\">" "$@" '</svg>'
  sc_row "$want" assets/d.svg "$needle" "$token"
}
svg_whole() {
  local want="$1" token="$2" needle="$3"; shift 3
  sc_new; fx_sf assets/d.svg "$@"
  sc_row "$want" assets/d.svg "$needle" "$token"
}

@test "build-docs-site: check-fetches — attribute contexts refuse a remote URL anywhere in the value" {
  sc_n=0
  html_row 3 'remote URL in src= on <img>' '<img' '<img src="http:other.host/x" alt="">'
  html_row 3 'remote URL in src= on <img>' '<img' $'<img src="ht\ttps://other.host/x" alt="">'
  html_row 3 'remote URL in src= on <img>' '<img' '<img src="   //other.host/x" alt="">'
  html_row 3 'remote URL in src= on <img>' '<img' '<img src="\\other.host/x" alt="">'
  html_row 3 'remote URL in srcset= on <img>' '<img' '<img src="assets/a.png" srcset="assets/a.png 1x, //other.host/b.png 2x" alt="">'
  html_row 3 'remote URL in ping= on <a>' '<a ' '<a href="x.html" ping="assets/p //other.host/p">x</a>'
  html_row 3 'remote URL in fill= on <rect>' '<rect' "<svg><rect fill=\"url($OH/#g)\"/></svg>"
  html_row 3 'remote URL in background= on <td>' '<td' "<table><tr><td background=\"$OH/bg.png\">x</td></tr></table>"
  html_row 3 'remote URL in a CSS url()' '<p ' "<p style=\"background:url($OH/x.png)\">x</p>"
  html_row 3 'remote URL in a JS string' '<button' "<button onclick=\"fetch('$OH/x')\">x</button>"
  html_row 3 'javascript: URL in href= on <a>' '<a ' '<a href="javascript:alert(1)">x</a>'
  html_row 3 'javascript: URL in href= on <a>' '<a ' '<a href="java&#9;script:alert(1)">x</a>'
  html_row 3 'remote URL in src= on <img>' '<img' '<img src="https&#58;//other.host/x" alt="">'
}

@test "build-docs-site: check-fetches — a multi-line tag reports the attribute's own line" {
  sc_n=0
  html_row 3 'remote URL in src= on <img>' 'src="https' '<img alt="see src"' "  src=\"$OH/x\">"
}

@test "build-docs-site: check-fetches — namespace URIs are exempt only as exact xmlns values" {
  sc_n=0
  html_row 3 'remote URL in xmlns= on <svg>' '<svg' "<svg xmlns=\"${NS}x\"></svg>"
  html_row 3 'remote URL in xmlns= on <svg>' '<svg' "<svg xmlns=\"$NS/\"></svg>"
  html_row 3 'remote URL in src= on <img>' '<img' "<img src=\"$NS\" alt=\"\">"
  html_row 0 '' '' "<svg xmlns=\"$NS\" xmlns:n1=\"http://www.w3.org/1999/xhtml\" xmlns:n2=\"http://www.w3.org/1999/xlink\"" \
    '  xmlns:n3="http://www.w3.org/1998/Math/MathML" xmlns:n4="http://www.w3.org/XML/1998/namespace"' \
    '  xmlns:n5="http://www.w3.org/2000/xmlns/"></svg>'
}

@test "build-docs-site: check-fetches — refused elements" {
  sc_n=0
  html_row 3 '<iframe> is refused' '<iframe' '<iframe srcdoc="x"></iframe>'
  html_row 3 '<object> is refused' '<object' '<object data="assets/a.svg"></object>'
  html_row 3 '<embed> is refused' '<embed' '<embed>'
  html_row 3 '<frame> is refused' '<frame' '<frame>'
  html_row 3 '<script type="speculationrules"> is refused' '<script' \
    '<script type="speculationrules">{"prefetch":[{"where":{"href_matches":"/*"}}]}</script>'
}

@test "build-docs-site: check-fetches — SVG files are parsed as XML" {
  sc_n=0
  svg_row 3 'remote URL in href= on <script>' '<script' "<script href=\"$OH/s.js\"/>"
  svg_row 3 'remote URL in href= on <feImage>' '<feImage' "<filter id=\"f\"><feImage href=\"$OH/i.png\"/></filter>"
  svg_row 3 'remote URL in href= on <image>' '<image' "<image href=\"$OH/i.png\"/>"
  svg_whole 3 'a DOCTYPE with an internal subset' '<!DOCTYPE' \
    "<!DOCTYPE svg [<!ENTITY u \"$OH/x.png\">]><svg xmlns=\"$NS\"><image href=\"&u;\"/></svg>"
  svg_whole 3 'a processing instruction (<?xml-stylesheet)' '<?xml-stylesheet' \
    "<?xml-stylesheet href=\"$OH/x.css\" type=\"text/css\"?><svg xmlns=\"$NS\"/>"
  svg_row 3 'remote URL in a JS string' 'fetch' "<script>fetch(&quot;$OH/x&quot;)</script>"
  # not well-formed: one line, no newline, so expat's error line is line 1
  sc_new; mkdir -p "$FX/site/assets"; printf '<svg xmlns="%s"><rect>' "$NS" > "$FX/site/assets/d.svg"
  sc_row 3 assets/d.svg '<svg' 'not well-formed XML'
  svg_whole 0 '' '' "<svg xmlns=\"$NS\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"><use href=\"#g\"/></svg>"
}

@test "build-docs-site: check-fetches — scripts and handlers on surfaces without a CSP are refused" {
  sc_n=0
  sc_new; fx_sf assets/i.svg "<svg xmlns=\"$NS\">" '<script>var a=1;</script>' '</svg>'
  sc_row 3 assets/i.svg '<script' '<script> in an .svg file is refused (no CSP covers it)'
  sc_new; fx_sf assets/i.svg "<svg xmlns=\"$NS\">" '<rect onclick="x()"/>' '</svg>'
  sc_row 3 assets/i.svg '<rect' 'onclick= in an .svg file is refused (no CSP covers it)'
  sc_new; fx_sf static/partial.html '<button onclick="go()">Go</button>'
  sc_row 3 static/partial.html '<button' 'onclick= in a fragment is refused (no CSP covers it)'
}

@test "build-docs-site: check-fetches — HTML pass contexts" {
  sc_n=0
  html_row 0 '' '' '<a href="https://other.site/">x</a>'
  html_row 0 '' '' '<img alt="Note: x" aria-label="Note: x" title="Note: x" src="data:image/png;base64,iVBORw0">'
  html_row 0 '' '' '<img src="blob:https://site.example/1b2c" alt="">'
  html_row 0 '' '' "<svg xmlns=\"$NS\"><rect width=\"8\" height=\"8\"/></svg>"
  html_row 0 '' '' "<!-- <img src=\"$OH/x\"> -->"
  html_row 0 '' '' "<p>see $OH/</p>"
  html_row 0 '' '' "<script>// $OH" 'var a="a:hover";</script>'
  html_row 0 '' '' "<style>/* $OH */ nav a:hover{}</style>"
  html_row 0 '' '' '<script async src="static/a.js"></script><script type src="static/b.js"></script>' \
    '<details open><summary>s</summary><input disabled></details>'
  html_row 0 '' '' '<svg><script href="static/a.js"/></svg>'
}

@test "build-docs-site: check-fetches — inline scripts: import map and module import" {
  sc_n=0
  html_row 3 'remote URL in a JS string' 'importmap' "<script type=\"importmap\">{\"imports\":{\"three\":\"$OH/three.js\"}}</script>"
  html_row 3 'remote URL in a JS string' 'import x' "<script type=\"module\">import x from \"$OH/m.js\";</script>"
}

@test "build-docs-site: check-fetches — parse-divergence shapes are refused" {
  local cm='a comment the browser and the scanner may end differently'
  sc_n=0
  html_row 3 "$cm" '<!-->' "<!--><img src=\"$OH/x\">-->"
  html_row 3 "$cm" '--!>' "<!-- x --!><img src=\"$OH/x\">"
  html_row 3 'a <script> body that opens an HTML comment or a nested <script>' '<script>a' \
    "<script>a<!--<script></script>fetch(\"$OH\")</script>-->"
  html_row 3 'a self-closing <script/> or <style/> outside <svg> or <math>' '<script/>' "<script/>fetch(\"$OH/x\")</script>"
  html_row 3 'a self-closing <script/> or <style/> outside <svg> or <math>' '<style/>' "<style/>@import \"$OH/a.css\";</style>"
  html_row 3 'an end tag with whitespace after "</"' '</ script' '<script>x=1; // </ script>' "fetch(\"$OH\")</script>"
  html_row 3 '"&" in a <script> or <style> body inside <svg> or <math>' '<svg><script>' \
    "<svg><script>fetch(&quot;$OH/x&quot;)</script></svg>"
  # raw-text elements a browser ends at their end tag: a comment the scanner
  # opens inside one can hide markup the browser runs
  html_row 3 'a comment inside <noscript>' '<noscript>' "<noscript><!--</noscript><script>fetch(\"$OH/x\")</script>-->"
  html_row 3 'a "<![" section the browser and the scanner may end differently' '<![CDATA[' \
    "<p><![CDATA[ x > <img src=\"$OH/x\"> ]]></p>"
}

@test "build-docs-site: check-fetches — CSP meta rule" {
  local doc=('<!DOCTYPE html>' '<html lang="en"><head>' '<meta charset="utf-8">')
  sc_n=0
  # (a) no meta
  sc_new; fx_sf index.html "${doc[@]}" '</head><body><p>x</p></body></html>'
  sc_row 3 index.html '' 'no Content-Security-Policy meta'
  # (b) a different policy: the site policy minus 'wasm-unsafe-eval'
  local w=" 'wasm-unsafe-eval'" less
  less="${CSP/"$w"/}"
  [ "$less" != "$CSP" ]
  sc_new; fx_sf index.html "${doc[@]}" "<meta http-equiv=\"Content-Security-Policy\" content=\"$less\">" \
    '</head><body><p>x</p></body></html>'
  sc_row 3 index.html 'Content-Security-Policy' 'the Content-Security-Policy meta does not carry the site policy'
  # (c) after a stylesheet link
  sc_new; fx_sf index.html "${doc[@]}" '<link rel="stylesheet" href="static/s.css">' "$CSP_META" \
    '</head><body><p>x</p></body></html>'
  sc_row 3 index.html 'Content-Security-Policy' 'the Content-Security-Policy meta comes after a <link>'
  # (d) in <body>
  sc_new; fx_sf index.html "${doc[@]}" '</head><body>' "$CSP_META" '<p>x</p></body></html>'
  sc_row 3 index.html 'Content-Security-Policy' 'the Content-Security-Policy meta is not inside <head>'
  # (e) two
  sc_new; fx_sf index.html "${doc[@]}" "$CSP_META" "<meta content=\"$CSP\" http-equiv=\"Content-Security-Policy\">" \
    '</head><body><p>x</p></body></html>'
  sc_row 3 index.html '<meta content=' 'more than one Content-Security-Policy meta'
  # (f) a document under an asset folder without it
  sc_new; fx_sf assets/doc.html '<html><head></head><body></body></html>'
  sc_row 3 assets/doc.html '' 'a document under an asset folder needs the Content-Security-Policy meta'
  # (g) a fragment needs none
  sc_new; fx_sf static/partial.html '<nav><a href="index.html">Home</a></nav>'
  sc_row 0 static/partial.html '' ''
  # (h) a document under an asset folder with it
  sc_new; fx_doc assets/doc.html '<p>x</p>'
  sc_row 0 assets/doc.html '' ''
  # (i) page.html's shape: the meta before <style>
  sc_new; fx_sf index.html "${doc[@]}" "$CSP_META" '<meta name="viewport" content="width=device-width, initial-scale=1">' \
    '<title>x</title>' '<style>nav a:hover { color: red; }</style>' '</head><body><p>x</p></body></html>'
  sc_row 0 index.html '' ''
}

# ------------------------------------------------- FETCH POLICY: through the build

@test "build-docs-site: fetch policy — page.html carries the exact CSP meta before any <style>" {
  local tmpl="$PLUGIN_ROOT/scripts/docs-site/page.html" at style
  [ "$(grep -cxF "$CSP_META" "$tmpl")" -eq 1 ]
  at="$(grep -nxF "$CSP_META" "$tmpl" | sed -n '1s/:.*//p')"
  style="$(grep -n '<style' "$tmpl" | sed -n '1s/:.*//p')"
  [ -n "$style" ]
  [ "$at" -lt "$style" ]
}

@test "build-docs-site: fetch policy — a rendered page and a stub carry the exact CSP meta in <head>" {
  need_pandoc
  fx_stub_site
  run fx_build
  [ "$status" -eq 0 ]
  local p
  for p in index old-a old-b; do
    [ "$(grep -cxF "$CSP_META" "$FX/out/$p.html")" -eq 1 ] || { echo "$p.html: $(grep -cxF "$CSP_META" "$FX/out/$p.html") exact CSP lines" >&2; return 1; }
    sed -n '/<head>/,/<\/head>/p' "$FX/out/$p.html" | grep -qxF "$CSP_META" || { echo "$p.html: the meta is not in <head>" >&2; return 1; }
  done
}
