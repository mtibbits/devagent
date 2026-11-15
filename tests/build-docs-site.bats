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
#           titles, nav, and that the allowlist scan (check-fetches.py)
#           accounts for every built file (#1030).
#   FIXTURE — throwaway source dirs that drive each refusal BRANCH (exit 2-6)
#           and each input kind: hand-written pages (derived-from header, H1
#           and nav-label, marker splice, HTML-index nav), the asset folders
#           (<src>/assets/ and --static), and moved-page stubs (moved.txt).
#           Every negative pins the exact code AND a message token, so a
#           different failure cannot satisfy it. The one refusal with no
#           fixture is the post-render count (exit 5 "expected N pages and M
#           stubs"): nothing outside the script can make it fire, so it is
#           pinned by a mutation row in the plan instead, and says so here.
#           fx_build passes the repo's own scripts/docs-site/static/ as
#           --static, read-only (the family files are required); a leg that
#           plants or removes a static file calls fx_static_copy first.
#   SCANNER — scripts/docs-site/check-fetches.py run directly on planted
#           dirs (no pandoc): every rule's refusal and pass rows, each pinned
#           to its status, file, line and a reason token. The "fetch policy"
#           rows prove the wiring through the build: exit 3 for python,
#           exit 7 for a policy break, exit 8 for a scan that did not complete.
#
# awk, python3 and pandoc: the builder probes for awk right after its argument
# checks (exit 3 naming awk), then validates its input and derives the nav
# BEFORE it probes for python3 and then pandoc (python3 just before pandoc), so
# every refusal up to and including the probes is tested
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
  env -u DEVAGENT_PYTHON bash "$BUILD" --src "$SITE" --out "$REAL_OUT" > "$BATS_FILE_TMPDIR/real.stdout" 2> "$BATS_FILE_TMPDIR/real.stderr"
}

# fx_reset <dir> — point FX at a fresh fixture dir: src/, holding the three
# live lines of devagent's docs-site/live.txt (the build requires the file).
fx_reset() {
  FX="$1"
  mkdir -p "$FX/src"
  printf '%s\n' 'live devagent yes index.html' 'live gantry no https://mtibbits.github.io/gantry/' \
    'live learn no https://mtibbits.github.io/journeyman/' > "$FX/src/live.txt"
}

# fx_static_copy — copy the repo's static dir to $FX/static and build from
# the copy (FX_STATIC), for a leg that plants or removes a static file.
fx_static_copy() {
  mkdir -p "$FX/static"
  cp -R "$PLUGIN_ROOT/scripts/docs-site/static/." "$FX/static/"
  FX_STATIC="$FX/static"
}

setup() {
  FX_BASH="$(command -v bash)"
  fx_reset "$BATS_TEST_TMPDIR"
}

# The fetch scanner and the site policy. CSP is one of the policy's three homes
# (check-fetches.py's POLICY, page.html, which the stub writer copies), written
# out here and never read from the others, so a drift in any of them fails a
# row.
SCANNER="$PLUGIN_ROOT/scripts/docs-site/check-fetches.py"
CSP="default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' data: blob:; worker-src 'self' blob:; media-src 'self' data: blob:; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'"
CSP_META="<meta http-equiv=\"Content-Security-Policy\" content=\"$CSP\">"
OH='https://other.host'
NS='http://www.w3.org/2000/svg'

# scan — the scanner run directly on $FX/site (no build, no pandoc);
# scan_args — the scanner with the given arguments.
scan_args() { python3 -I -X utf8 "$SCANNER" "$@"; }
scan() { scan_args "$FX/site"; }

# The scanner with html.parser broken, so a scan crashes inside it:
# python3 -c "$FAULT_PY" <scanner> <args...>.
FAULT_PY='import runpy, sys, html.parser as h; h.HTMLParser.goahead = None; sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name="__main__")'

# The scanner with html.parser made to end raw text only at "</style>" (the
# pre-2025 rule): python3 -c "$OLD_PARSER_PY" <scanner> <args...>.
OLD_PARSER_PY='import re, runpy, sys, html.parser as h; o = h.HTMLParser.set_cdata_mode; h.HTMLParser.set_cdata_mode = lambda self, elem, *a, **k: (o(self, elem, *a, **k), setattr(self, "interesting", re.compile(r"</\s*%s\s*>" % self.cdata_elem, re.I)))[0]; sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name="__main__")'

# The head of a document up to where its CSP meta goes.
DOC_HEAD=('<!DOCTYPE html>' '<html lang="en"><head>' '<meta charset="utf-8">')

# first_line <file> <needle> — set ln to the first line of <file> holding
# <needle>; fail when none does.
first_line() {
  local -a fl
  local k
  mapfile -t fl < "$1"
  for k in "${!fl[@]}"; do
    [[ ${fl[k]} != *"$2"* ]] || { ln=$((k + 1)); return 0; }
  done
  return 1
}

# has_diag <relpath> <ln> <token> — an output line reads
# "check-fetches: <relpath>:<ln>: ..." and holds <token>.
has_diag() {
  local l
  for l in "${lines[@]}"; do
    case "$l" in "check-fetches: $1:$2: "*"$3"*) return 0 ;; esac
  done
  return 1
}

# fx_sf <relpath> <line...> — a file under $FX/site, one argument per line.
fx_sf() {
  local rel="$1"; shift
  mkdir -p "$(dirname "$FX/site/$rel")"
  printf '%s\n' "$@" > "$FX/site/$rel"
}

# fx_doc <relpath> <body line...> — a document under $FX/site carrying the CSP meta.
fx_doc() {
  local rel="$1"; shift
  fx_sf "$rel" "${DOC_HEAD[@]}" "$CSP_META" '</head><body>' "$@" '</body></html>'
}

# sc_new — a fresh fixture dir for the next row (one dir per row).
sc_new() { sc_n=$((${sc_n:-0} + 1)); fx_reset "$BATS_TEST_TMPDIR/row$sc_n"; }

# sc_row <want> <relpath> <needle> <token> — scan $FX/site. want 0: status 0 and
# the ok line. want 3: status 3 and a line "check-fetches: <relpath>:<ln>: ..."
# holding <token>, <ln> the first line of the planted file holding <needle>
# (0 when <needle> is empty), so a violation elsewhere cannot satisfy the row.
sc_row() {
  local want="$1" rel="$2" needle="$3" token="$4" ln=0
  run scan
  [ "$status" -eq "$want" ] || { echo "row ${sc_n:-0} ($rel): status $status, want $want: $output" >&2; return 1; }
  if [ "$want" -eq 0 ]; then
    [[ "$output" == *"check-fetches: ok: "* ]] || { echo "row ${sc_n:-0}: no ok line: $output" >&2; return 1; }
    return 0
  fi
  if [ -n "$needle" ]; then
    first_line "$FX/site/$rel" "$needle" || { echo "row ${sc_n:-0}: '$needle' is not in $rel" >&2; return 1; }
  fi
  has_diag "$rel" "$ln" "$token" || { echo "row ${sc_n:-0}: no 'check-fetches: $rel:$ln: ...$token' in: $output" >&2; return 1; }
}

# fx_bin — a PATH holding only what the builder runs BEFORE its pandoc probe, so
# "no pandoc" (or a stub pandoc) is the only thing the probe can see. python3 is
# probed just before pandoc, so it is linked too (a leg removes or replaces it).
fx_bin() {
  local t
  mkdir -p "$FX/bin"
  for t in dirname basename grep sed awk sort python3; do
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
nav_of() { sed -n '/<nav aria-label="Pages">/,/<\/nav>/p' "$1"; }

# fx_build [args...] — build the fixture source dir into $FX/out. FX_PATH, when
# set (pandoc-free legs set it to "$FX/bin" after fx_bin), replaces PATH. It
# passes --static "$FX_STATIC" when a leg set it (fx_static_copy), else the
# repo's own scripts/docs-site/static/, which a build only reads. Later flags
# win: the script's parse loop keeps the last value. DEVAGENT_PYTHON is always
# REPLACED (by FX_PYTHON, else empty, which the builder reads as python3),
# never inherited.
fx_build() { env PATH="${FX_PATH:-$PATH}" DEVAGENT_PYTHON="${FX_PYTHON:-}" "$FX_BASH" "$BUILD" --src "$FX/src" --out "$FX/out" --static "${FX_STATIC:-$PLUGIN_ROOT/scripts/docs-site/static}" "$@"; }

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
  # the content-side asset folder appears exactly when its source exists; the
  # template side (static/) always does, holding the four family files
  if [ -d "$SITE/assets" ]; then extra=$((extra + 1)); [ -d "$REAL_OUT/assets" ]; else [ ! -e "$REAL_OUT/assets" ]; fi
  extra=$((extra + 1))
  local f
  for f in family.css family.js family-topbar.html family-footer.html; do
    [ -f "$REAL_OUT/static/$f" ]
  done
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

@test "build-docs-site: real site — the allowlist scan accounts for every built file; no preview wording" {
  need_pandoc
  local content=() ok total
  mapfile -t content < <(real_content)
  # the build's OWN ok line, exactly once
  [ "$(grep -cE '^check-fetches: ok: ' "$BATS_FILE_TMPDIR/real.stdout")" -eq 1 ]
  ok="$(grep -E '^check-fetches: ok: ' "$BATS_FILE_TMPDIR/real.stdout")"
  [[ "$ok" =~ ^check-fetches:\ ok:\ ([0-9]+)\ files:\ ([0-9]+)\ scanned,\ ([0-9]+)\ binary,\ ([0-9]+)\ vendored$ ]]
  local t="${BASH_REMATCH[1]}" s="${BASH_REMATCH[2]}" b="${BASH_REMATCH[3]}" v="${BASH_REMATCH[4]}"
  # an independent count of what landed on disk
  total="$(find "$REAL_OUT" ! -type d | wc -l)"
  echo "scan: $ok; find: $total" >&2
  [ "$((s + b + v))" -eq "$total" ]
  [ "$t" -eq "$total" ]
  [ "$s" -ge "${#content[@]}" ]
  # a pass leg the real build exercises: a CSS selector colon in the template
  grep -qF 'a:hover' "$PLUGIN_ROOT/scripts/docs-site/page.html"
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
  [[ "$output" == *"  7  the built site breaks the fetch policy"* ]]
  [[ "$output" == *"  8  the fetch scan did not complete"* ]]
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
  fx_static_copy
  mkdir -p "$FX/src/assets/img"
  printf '\x89PNG\r\n\x1a\n\0\0\xff\xfe\x80 end\r\n' > "$FX/src/assets/img/a.png"
  printf 'body { color: #123; }\r\n\0\xc3\xa9\n' > "$FX/static/s.css"
  run fx_build
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

@test "build-docs-site: fetch policy — moved-page stubs build under the scan" {
  need_pandoc
  fx_stub_site
  run fx_build
  [ "$status" -eq 0 ]
  [[ "$output" == *"check-fetches: ok: "* ]]
  # the same stub minus its CSP line is refused, so the scan does read stubs
  mkdir -p "$FX/site"
  grep -vxF "$CSP_META" "$FX/out/old-a.html" > "$FX/site/old-a.html"
  [ "$(wc -l < "$FX/site/old-a.html")" -eq "$(( $(wc -l < "$FX/out/old-a.html") - 1 ))" ]
  run scan
  [ "$status" -eq 3 ]
  [[ "$output" == *"check-fetches: old-a.html:0: no Content-Security-Policy meta"* ]]
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
  run scan_args
  usage_2
  run scan_args "$FX/site" "$FX/site"
  usage_2
  run scan_args --help
  usage_2
  run scan_args "$FX/absent"
  usage_2
  run scan_args "$FX/empty"
  usage_2
  # positive control: the same scanner on the planted site
  run scan
  [ "$status" -eq 0 ]
}

@test "build-docs-site: check-fetches — '--' admits an out-dir that starts with '-'" {
  fx_doc index.html '<p>x</p>'
  mv "$FX/site" "$FX/-site"
  cd "$FX"
  run scan_args -- -site
  [ "$status" -eq 0 ]
  [ "$output" = "check-fetches: ok: 1 files: 1 scanned, 0 binary, 0 vendored" ]
  run scan_args -site
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

# file_row <want> <token> <relpath> <needle> <line...> — one row: <relpath>
# holding the lines. js_row / css_row <want> <token> <line...>: assets/a.js or
# assets/a.css, the needle the first line.
file_row() {
  local want="$1" token="$2" rel="$3" needle="$4"; shift 4
  sc_new; fx_sf "$rel" "$@"
  sc_row "$want" "$rel" "$needle" "$token"
}
js_row() { file_row "$1" "$2" assets/a.js "$3" "${@:3}"; }
css_row() { file_row "$1" "$2" assets/a.css "$3" "${@:3}"; }

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
  # where the token before a "/" does not decide regex or division (")", "}",
  # of, await, yield, …), both readings are scanned, so the string either
  # reading finds is checked, whichever way the guess went
  local amb='remote URL in a JS string'
  js_row 3 "$amb" "var of = 1; y = of / 2; fetch(\"$OH/x\") // \""
  js_row 3 "$amb" "var await = 4; y = await / 2; fetch(\"$OH/x\") // \""
  js_row 3 "$amb" "function* g() { yield /'/; fetch('$OH/x'); // '"
  js_row 3 "$amb" "async function f() { await /'/; fetch('$OH/x'); // '"
  js_row 3 "$amb" "for (const c of /'/.source) {} fetch('$OH/x'); // '"
  js_row 3 "$amb" "if (x) /'/.test(s); var u = '$OH/x';"
  js_row 3 "$amb" "if (x) { y(); } /'/.test(s); var u = '$OH/x';"
  # the guess is trusted where the token decides it: default and extends are
  # keywords (regex), a property name is an operand even across a comment
  # (division), a keyword after a spread is a keyword
  file_row 3 'remote URL in a JS string' assets/a.mjs 'export' "export default /'/.source; F('$OH/x');// '"
  js_row 3 'remote URL in a JS string' "try { class A extends /'/ {} } catch (e) {} F('$OH/x');// '"
  js_row 3 'remote URL in a JS string' "var r = o./**/in / '/' + F('$OH/x');"
  js_row 3 'remote URL in a JS string' "y = o.in / 2; fetch(\"$OH/x\") // \""
  js_row 3 'remote URL in a JS string' "var a = [...typeof /'/]; fetch('$OH/x'); // '"
  # U+FEFF is JS whitespace, and an astral letter is an identifier
  js_row 3 'remote URL in a JS string' "("$'\xef\xbb\xbf'"/'/.test(s)) + F('$OH/x');// '"
  js_row 3 'remote URL in a JS string' $'\xf0\x9d\x91\xa5'" / '/' + F('$OH/x');"
  # controls: a regex after return still holds its quote; both readings agree
  # (no regex reading, or the same strings either way); parentheses settle
  # of/await/yield; a property named of is an operand
  js_row 0 '' 'function f(s) { return /"/.test(s); } var u = "assets/x";'
  js_row 0 '' 'var w = (a + b) / 2 + "px", v = (a) / b / c;'
  js_row 0 '' 'async function f() { await /* c */ /x/; } var u = "assets/x";'
  js_row 0 '' 'function* g() { yield (/"/); } var y = (of) / 2 + o.of / 2; var u = "assets/x";'
  # the documented over-refusal: a regex reading that leaves a string open
  js_row 3 'one reading leaving a string open' "var y = (a)/2 + 'x/y';"
  # no nested guess: a second undecided "/" met by the other reading before
  # the two agree is refused; so is a line on which they never agree
  file_row 3 'with another such "/" before the readings agree' assets/a.js 'if(a)' 'var a = 1, b = 1;' "if(a)/'/;if(b)/'//'//'+F('$OH/x');"
  local pad
  pad="$(printf '1+%.0s' $(seq 2100))"
  js_row 3 'the readings not agreeing within 4000 characters' "if (a) /'/ + ${pad}1 + F('$OH/x');// '"
  js_row 0 '' 'var r = (a) / 2 + (b) / 3 + (c) / 4;'
  # line starts: "++"/"--" first on a line is prefix (a "/" next is a regex);
  # a hashbang is a comment; Annex B "-->" after comments starts a comment
  file_row 3 'remote URL in a JS string' assets/a.js 'lastIndex' 'var b = 1' "++/'/.lastIndex + F('$OH/x');// '"
  file_row 3 'remote URL in a JS string' assets/a.js 'lastIndex' 'var b = 1' "--/'/.lastIndex + F('$OH/x');// '"
  sc_new; fx_sf assets/a.js '#!/*' "F('$OH/x');" '/**/'
  sc_row 3 assets/a.js 'F(' 'remote URL in a JS string'
  sc_new; fx_sf assets/a.js 'var a = 1;' '/**/ --> /*' "F('$OH/x');" '/**/'
  sc_row 3 assets/a.js 'F(' 'remote URL in a JS string'
  js_row 0 '' '#!/usr/bin/env node' 'var u = "assets/x";'
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
svg_whole() { file_row "$1" "$2" assets/d.svg "$3" "${@:4}"; }

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
  # an SVG script loading a local file, with an explicit end tag: the
  # self-closing form is refused (see the parse-divergence shapes)
  html_row 0 '' '' '<svg><script href="static/a.js"></script></svg>'
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
  html_row 3 'a self-closing <script/> or <style/>' '<script/>' "<script/>fetch(\"$OH/x\")</script>"
  html_row 3 'a self-closing <script/> or <style/>' '<style/>' "<style/>@import \"$OH/a.css\";</style>"
  # inside <svg>/<math> too: an HTML element breaks a browser out of <svg>,
  # and Chromium's preload scanner reads <style/> as opening CSS even inside
  # it; and an <svg> that once held HTML must not exempt a later <style/>
  local sc='a self-closing <script/> or <style/>'
  sc_new; fx_sf static/partial.html "<svg><p></p><style/>@import \"$OH/a.css\";</style>"
  sc_row 3 static/partial.html '<svg' "$sc"
  sc_new; fx_sf static/partial.html '<svg><foreignObject><div>hi</div></foreignObject></svg>' "<style/>@import \"$OH/a.css\";</style>"
  sc_row 3 static/partial.html '<style/>' "$sc"
  html_row 3 "$sc" '<svg><style/>' "<svg><style/>@import \"$OH/a.css\";</style></svg>"
  html_row 3 "$sc" '<math><style/>' "<math><style/>@import \"$OH/a.css\";</style></math>"
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
  local doc=("${DOC_HEAD[@]}")
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

@test "build-docs-site: fetch policy — python absent -> exit 3 naming it, nothing written" {
  fx_bin
  rm "$FX/bin/python3"
  fx_page index "hello"
  FX_PATH="$FX/bin"
  run fx_build
  [ "$status" -eq 3 ]
  [[ "$output" == *"python is not installed: 'python3' not found"* ]]
  [ ! -e "$FX/out" ]
  # row 2: DEVAGENT_PYTHON names an interpreter that is not there
  fx_reset "$BATS_TEST_TMPDIR/row2"
  fx_page index "hello"
  FX_PATH=""
  FX_PYTHON="$FX/nope/python3"
  run fx_build
  [ "$status" -eq 3 ]
  [[ "$output" == *"python is not installed: '$FX/nope/python3' not found"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: fetch policy — a python that cannot run -> exit 3 naming it, nothing written" {
  fx_bin
  rm "$FX/bin/python3"
  printf '#!%s\necho "Python was not found; run without arguments to install from the Microsoft Store"\nexit 49\n' \
    "$(command -v bash)" > "$FX/bin/python3"
  chmod +x "$FX/bin/python3"
  fx_page index "hello"
  FX_PATH="$FX/bin"
  run fx_build
  [ "$status" -eq 3 ]
  [[ "$output" == *"python cannot run: 'python3'"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: fetch policy — a python older than 3.8 -> exit 3 naming it, nothing written" {
  local real_py
  real_py="$(command -v python3)"
  fx_bin
  rm "$FX/bin/python3"
  # the real interpreter, reporting 3.7, runs the probe's code
  cat > "$FX/bin/python3" <<EOF
#!$(command -v bash)
exec "$real_py" -I -c 'import sys; sys.version_info = (3, 7, 17, "final", 0); exec(sys.argv[1])' "\${@: -1}"
EOF
  chmod +x "$FX/bin/python3"
  fx_page index "hello"
  FX_PATH="$FX/bin"
  run fx_build
  [ "$status" -eq 3 ]
  [[ "$output" == *"python cannot run: 'python3' is not a working python3 3.8+"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: fetch policy — a python whose html.parser lacks the 2025 fixes -> exit 3 naming it, nothing written" {
  local real_py
  real_py="$(command -v python3)"
  fx_bin
  rm "$FX/bin/python3"
  # the real interpreter for "-c" probes; any script runs under the pre-2025
  # raw-text rule
  cat > "$FX/bin/python3" <<EOF
#!$(command -v bash)
case " \$* " in *" -c "*) exec "$real_py" "\$@" ;; esac
while [ "\${1#-}" != "\$1" ]; do [ "\$1" = -X ] && shift; shift; done
exec "$real_py" -I -X utf8 -c '$OLD_PARSER_PY' "\$@"
EOF
  chmod +x "$FX/bin/python3"
  fx_page index "hello"
  FX_PATH="$FX/bin"
  run fx_build
  [ "$status" -eq 3 ]
  [[ "$output" == *"python's html.parser is too old: 'python3'"* ]]
  [ ! -e "$FX/out" ]
}

# fault_py <file> — an interpreter that runs the probes (any call holding -c or --self-test)
# and the placeholder filler (a call naming fill-placeholders.py)
# with the real python3, and the REAL scanner (its last three arguments:
# scanner, --, out) with html.parser broken, so the scan crashes inside it.
fault_py() {
  local real_py
  real_py="$(command -v python3)"
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
#!$(command -v bash)
case " \$* " in *" -c "*|*" --self-test "*|*fill-placeholders.py*) exec "$real_py" "\$@" ;; esac
exec "$real_py" -I -X utf8 -c '$FAULT_PY' "\${@: -3}"
EOF
  chmod +x "$1"
}

@test "build-docs-site: fetch policy — a scanner crash -> exit 8, says the scan did not complete" {
  need_pandoc
  fx_page index "hello"
  fault_py "$FX/py/python3"
  FX_PYTHON="$FX/py/python3"
  run fx_build
  [ "$status" -eq 8 ]
  [[ "$output" == *"the fetch scan did not complete (check-fetches exited 1)"* ]]
  [[ "$output" != *"built 1 pages"* ]]
}

@test "build-docs-site: check-fetches — an html.parser without the 2025 fixes: the scanner refuses to run (exit 4)" {
  fx_doc index.html '<p>x</p>'
  run python3 -I -X utf8 -c "$OLD_PARSER_PY" "$SCANNER" "$FX/site"
  [ "$status" -eq 4 ]
  [[ "$output" == *"lacks the 2025 fixes"* ]]
  [[ "$output" != *"check-fetches: ok:"* ]]
  # positive control: this python's own parser passes the self-test
  run scan
  [ "$status" -eq 0 ]
}

@test "build-docs-site: check-fetches — a fault inside the scanner exits neither 0 nor 3" {
  fx_doc index.html '<p>x</p>'
  run python3 -I -X utf8 -c "$FAULT_PY" "$SCANNER" "$FX/site"
  [ "$status" -ne 0 ]
  [ "$status" -ne 3 ]
  [[ "$output" != *"check-fetches: ok:"* ]]
  # positive control: the same site, unfaulted
  run scan
  [ "$status" -eq 0 ]
}

# t7_new — a fresh fixture dir for the next mutation row, with a copy of the
# static dir ($FX/static, family files included) the row may plant into.
t7_new() { t7_n=$((${t7_n:-0} + 1)); fx_reset "$BATS_TEST_TMPDIR/row$t7_n"; fx_static_copy; mkdir -p "$FX/src/assets"; }

# t7_row <relpath> <needle> — build (with --static "$FX/static"; later flags
# win); it must exit 7 and name <relpath> at the first built line holding
# <needle>.
t7_row() {
  local rel="$1" needle="$2" ln
  run fx_build --static "$FX/static"
  [ "$status" -eq 7 ] || { echo "row $t7_n ($rel): status $status, want 7: $output" >&2; return 1; }
  [[ "$output" == *"the built site breaks the fetch policy"* ]] || { echo "row $t7_n: no exit-7 message: $output" >&2; return 1; }
  first_line "$FX/out/$rel" "$needle" || { echo "row $t7_n: '$needle' is not in the built $rel" >&2; return 1; }
  has_diag "$rel" "$ln" '' || { echo "row $t7_n: no 'check-fetches: $rel:$ln: ' in: $output" >&2; return 1; }
}

# t7_index <needle> <line> — a mutation row planted in the hand-written index.
t7_index() { t7_new; fx_html index '<h1>Home</h1>' "$2"; t7_row index.html "$1"; }

@test "build-docs-site: fetch policy — mutation rows: the build exits 7 naming file and line" {
  need_pandoc
  t7_n=0
  t7_index importmap "<script type=\"importmap\">{\"imports\":{\"three\":\"$OH/three.js\"}}</script>"
  t7_index 'import x' "<script type=\"module\">import x from \"$OH/m.js\";</script>"
  t7_index '<img' "<img src=\"$OH/a.png\" alt=\"\">"
  t7_index srcset "<img srcset=\"$OH/b.png 2x\" alt=\"\">"
  # (the needle is the URL: the template carries its own <link> to family.css)
  t7_index "$OH/s.css" "<link rel=\"stylesheet\" href=\"$OH/s.css\">"
  t7_index '<table' "<table background=\"$OH/bg.png\"><tr><td>x</td></tr></table>"
  t7_index '<p style' "<p style=\"background:url($OH/x.png)\">x</p>"
  t7_index '<iframe' '<iframe srcdoc="x"></iframe>'
  t7_new; fx_html index '<h1>Home</h1>' '<object data="assets/a.svg"></object>'
  printf '<svg xmlns="%s"/>\n' "$NS" > "$FX/src/assets/a.svg"
  t7_row index.html '<object'
  t7_new; fx_html index '<h1>Home</h1>'; printf 'fetch("%s/api");\n' "$OH" > "$FX/static/app.js"
  t7_row static/app.js fetch
  t7_new; fx_html index '<h1>Home</h1>'; printf 'new Image().src = "%s/i.png";\n' "$OH" > "$FX/static/app.js"
  t7_row static/app.js Image
  t7_new; fx_html index '<h1>Home</h1>'; printf "el.innerHTML = '<img src=\"%s/i.png\">';\n" "$OH" > "$FX/static/app.js"
  t7_row static/app.js innerHTML
  t7_new; fx_html index '<h1>Home</h1>'; printf '@import "%s/a.css";\n' "$OH" > "$FX/static/site.css"
  t7_row static/site.css '@import'
  t7_new; fx_html index '<h1>Home</h1>'; printf 'a { background: image-set("%s/x.png" 1x); }\n' "$OH" > "$FX/static/site.css"
  t7_row static/site.css image-set
  t7_new; fx_html index '<h1>Home</h1>'; printf '<svg xmlns="%s">\n<script href="%s/s.js"/>\n</svg>\n' "$NS" "$OH" > "$FX/src/assets/d.svg"
  t7_row assets/d.svg '<script'
  t7_new; fx_html index '<h1>Home</h1>'
  printf '<svg xmlns="%s">\n<filter id="f"><feImage href="%s/i.png"/></filter>\n</svg>\n' "$NS" "$OH" > "$FX/src/assets/d.svg"
  t7_row assets/d.svg feImage
}

@test "build-docs-site: fetch policy — \"private preview\" in a page fails the build" {
  need_pandoc
  fx_page index "Private" "preview"
  run fx_build
  [ "$status" -eq 7 ]
  [[ "$output" == *"check-fetches: index.html:"*'the words "private preview" may not be published'* ]]
}

# ------------------------------------------- SCANNER: final-review fail-open rows

@test "build-docs-site: check-fetches — a namespace prefix does not hide an .svg element" {
  sc_n=0
  svg_whole 3 '<script> in an .svg file is refused' '<h:script' \
    "<svg xmlns=\"$NS\" xmlns:h=\"http://www.w3.org/1999/xhtml\">" "<h:script>fetch(\"$OH/x\")</h:script>" '</svg>'
  svg_whole 3 'remote URL in a CSS string' '@import' \
    "<s:svg xmlns:s=\"$NS\">" "<s:style>@import \"$OH/a.css\";</s:style>" '</s:svg>'
  svg_whole 3 'is refused' '<h:iframe' \
    "<svg xmlns=\"$NS\" xmlns:h=\"http://www.w3.org/1999/xhtml\">" '<h:iframe src="x.html"/>' '</svg>'
}

@test "build-docs-site: check-fetches — markup inside raw-text elements in <svg> or <math> is refused" {
  local mk='markup inside <'
  sc_n=0
  sc_new; fx_sf static/partial.html "<svg><title><img src=\"$OH/p.png\"></title></svg>"
  sc_row 3 static/partial.html '<svg' "$mk"
  html_row 3 "$mk" '<svg><textarea>' "<svg><textarea><img src=\"$OH/p.png\"></textarea></svg>"
  html_row 3 "$mk" '<math>' "<math><title><img src=\"$OH/p.png\"></title></math>"
  html_row 3 "$mk" '<svg><style>' '<svg><style><img src=//other.host/p.png></style></svg>'
  html_row 3 "$mk" '<svg><script>' '<svg><script><img src=//other.host/p.png></script></svg>'
  # a "/" ending an unquoted value does not self-close the tag, and a stray
  # </math> does not close <svg> (both in a fragment, which has no CSP)
  sc_new; fx_sf static/partial.html "<svg><style x=y/><img src=\"$OH/p.png\"></style></svg>"
  sc_row 3 static/partial.html '<svg' "$mk"
  sc_new; fx_sf static/partial.html '<svg width=8/><style><img src=//other.host/p.png></style></svg>'
  sc_row 3 static/partial.html '<svg' "$mk"
  sc_new; fx_sf static/partial.html '<svg></math><style><img src=//other.host/p.png></style></svg>'
  sc_row 3 static/partial.html '<svg' "$mk"
  # with an element open inside an integration point a browser ignores
  # </svg> and </math>, so the <style> after them is still foreign; below the
  # top level the scanner keeps the root open to the end of the file, so no
  # stray end tag (</desc>, </mtext>, </title>) can end it early
  local ip
  for ip in '<svg><foreignObject>|</svg>' '<svg><desc>|</svg>' '<math><mi>|</math>' \
            '<svg><foreignObject></desc>|</svg>' '<math><mi></mtext>|</math>' '<svg><desc></title>|</svg>'; do
    sc_new; fx_sf static/partial.html "${ip%|*}<div>${ip#*|}</div><style><img src=\"$OH/p.png\"></style>${ip#*|}"
    sc_row 3 static/partial.html "${ip%|*}" "$mk"
  done
  sc_new; fx_sf static/partial.html '<svg><foreignObject><div></svg></div></foreignObject><style><script>document.title = 1</script></style></svg>'
  sc_row 3 static/partial.html '<svg' "$mk"
  # top level: the CSP backs fetches but not navigation, so where a browser may
  # still be inside <svg>, a later <style> may hold no markup, and no <script>
  # body may hold <meta (a refresh)
  html_row 3 'markup inside a <style> after an inline <svg> or <math>' '<svg' \
    '<svg><foreignObject><div></svg></div></foreignObject><style><meta http-equiv=refresh content=0;url=/x></style></svg>'
  html_row 3 '(or holds <meta)' '<script>' "<script>var s = '<meta http-equiv=refresh content=0>';</script>"
  # every element this parser reads as text, not only <style>; and an HTML
  # tag that would break a still-open <svg> out into live HTML in a <script>
  local el
  for el in title textarea xmp noembed; do
    html_row 3 "markup inside a <$el> after an inline <svg> or <math>" '<svg' \
      "<svg><foreignObject><div></svg></div></foreignObject><$el><meta http-equiv=refresh content=0;url=/x></$el></svg>"
  done
  html_row 3 'an HTML tag inside a <script> after an inline <svg> or <math>' '<svg' \
    '<svg><foreignObject><div></svg></div></foreignObject><script><p><link rel=preconnect href=/x></script></svg>'
  html_row 0 '' '' '<svg><rect width="8" height="8"/></svg>' '<script>for (var i = 0; i<n; i++) { x(i<b); }</script>'
  # controls: an icon's <title> holds only text, so <svg> ends at </svg>; a
  # later <style> without markup and a script using && pass
  html_row 0 '' '' '<svg><title>Icon</title><rect width="8" height="8"/></svg>' '<script>var ok = a && b;</script>'
  html_row 0 '' '' '<svg><rect width="8" height="8"/></svg>' '<style>a > b { color: red; }</style>'
  # the accessible-icon idiom, with an entity and a bare "<", still passes
  html_row 0 '' '' '<svg><title>Icon &amp; label, a < b</title><rect width="8" height="8"/></svg>'
}

@test "build-docs-site: check-fetches — an element this parser reads as text inside <noscript> is refused" {
  local r='inside <noscript>, which a browser reads as text'
  sc_n=0
  # a browser (scripting on) ends <noscript> at its own end tag, inside these
  sc_new; fx_sf static/partial.html "<noscript><title></noscript><script>fetch(\"$OH/t\")</script></title></noscript>"
  sc_row 3 static/partial.html '<noscript>' "<title> $r"
  sc_new; fx_sf static/partial.html "<noscript><textarea></noscript><img src=\"$OH/p.png\"></textarea></noscript>"
  sc_row 3 static/partial.html '<noscript>' "<textarea> $r"
  sc_new; fx_sf static/partial.html '<noscript><style></noscript><img src=//other.host/p.png></style></noscript>'
  sc_row 3 static/partial.html '<noscript>' "<style> $r"
  # control: ordinary fallback markup in <noscript> passes
  html_row 0 '' '' '<noscript><p>This page needs JavaScript.</p></noscript>'
}

@test "build-docs-site: check-fetches — a CSP meta a browser ignores does not count" {
  local doc=("${DOC_HEAD[@]}")
  sc_n=0
  sc_new; fx_sf index.html "${doc[@]}" '<p>x</p>' "$CSP_META" '</head><body></body></html>'
  sc_row 3 index.html 'Content-Security-Policy' 'the Content-Security-Policy meta is not inside <head>'
  sc_new; fx_sf index.html "${doc[@]}" 'hello' "$CSP_META" '</head><body></body></html>'
  sc_row 3 index.html 'Content-Security-Policy' 'the Content-Security-Policy meta is not inside <head>'
  # content before <head> opens <body>; the later <head> is ignored
  local before
  for before in '<p>x</p>' 'hello' '<body>'; do
    sc_new; fx_sf index.html '<!DOCTYPE html>' "<html lang=\"en\">$before<head>" "$CSP_META" '</head><body></body></html>'
    sc_row 3 index.html 'Content-Security-Policy' 'the Content-Security-Policy meta is not inside <head>'
  done
  sc_new; fx_sf index.html "${doc[@]}" "<noscript>$CSP_META</noscript>" '</head><body></body></html>'
  sc_row 3 index.html 'Content-Security-Policy' 'inside <noscript>'
  sc_new; fx_sf index.html "${doc[@]}" "<template>$CSP_META</template>" '</head><body></body></html>'
  sc_row 3 index.html 'Content-Security-Policy' 'inside <template>'
  sc_new; fx_sf index.html "${doc[@]}" "<meta http-equiv=\" Content-Security-Policy\" content=\"$CSP\">" '</head><body></body></html>'
  sc_row 3 index.html '' 'no Content-Security-Policy meta'
  # control: whitespace and a comment in <head> before the meta keep it in <head>
  sc_new; fx_sf index.html "${doc[@]}" '  <!-- policy -->' "$CSP_META" '<title>t</title>' '</head><body></body></html>'
  sc_row 0 index.html '' ''
}

@test "build-docs-site: check-fetches — a protocol-relative URL inside a value is refused" {
  sc_n=0
  js_row 3 'remote URL in a JS string' "el.innerHTML = '<img src=\"//other.host/p.png\">';"
  svg_row 3 'remote URL in fill= on <rect>' '<rect' '<rect fill="url(//other.host/p.svg#g)"/>'
  svg_row 3 'remote URL in values= on <animate>' '<animate' '<animate attributeName="href" values="a.png;//other.host/p.png"/>'
  # three or more slashes start a host too (a URL parser with an http(s) base
  # skips them all), in every context
  js_row 3 'remote URL in a JS string' "fetch('///other.host/x');"
  js_row 3 'remote URL in a JS string' "fetch('////other.host/x');"
  sc_new; fx_sf static/partial.html '<img src="///other.host/p.png">'
  sc_row 3 static/partial.html '<img' 'remote URL in src= on <img>'
  svg_row 3 'remote URL in href= on <image>' '<image' '<image href="///other.host/p.png"/>'
  css_row 3 'remote URL in a CSS url()' 'a { background: url(///other.host/p.png); }'
  css_row 3 'remote URL in a CSS string' '@import "///other.host/a.css";'
  html_row 3 'remote URL in content= on <meta>' 'refresh' '<meta http-equiv="refresh" content="0;url=///other.host/">'
  # controls: "//" that starts no host
  js_row 0 '' 'var s = "see // note", t = "a//b", u = "/// ", v = "a///b";'
}

@test "build-docs-site: check-fetches — JS line ends, HTML-like comments and postfix ++ do not hide a string" {
  sc_n=0
  sc_new; fx_sf assets/a.js $'// note\rimport("'"$OH"$'/x.js");'
  sc_row 3 assets/a.js '// note' 'remote URL in a JS string'
  sc_new; fx_sf assets/a.js $'// note import("'"$OH"$'/x.js");'
  sc_row 3 assets/a.js '// note' 'remote URL in a JS string'
  sc_new; fx_sf assets/a.js '<!-- /*' "fetch(\"$OH/x\");" '// */'
  sc_row 3 assets/a.js 'fetch' 'remote URL in a JS string'
  sc_new; fx_sf assets/a.js 'var a = 1;' '--> /*' "fetch(\"$OH/x\");" '// */'
  sc_row 3 assets/a.js 'fetch' 'remote URL in a JS string'
  js_row 3 'remote URL in a JS string' "var y = i++ / 2 + '/' + '$OH/a.js';"
  # in module code "<!--" and "-->" are operators, not comments
  file_row 3 'remote URL in a JS string' assets/a.mjs 'fetch' 'let a = 0, b = 1;' "a <!-- b, fetch(\"$OH/x\");"
  html_row 3 'remote URL in a JS string' 'fetch' '<script type="module">let a = 1;' "--> a; fetch(\"$OH/x\")" '</script>'
  # controls: prefix ++ before a regex, and "-->" that is not at a line start
  js_row 0 '' 'var r = ++i; var s = /ab+c/.test(t); var u = "assets/x";'
  js_row 0 '' 'while (i --> 0) { s = "assets/x"; }'
}

# ------------------------------------------------ FAMILY: the shared family files (#996)
#
# scripts/docs-site/static/ holds the family files other sites copy byte for
# byte. tests/lib/family-check.py reads them (and page.html) and prints one
# "family-check: <file>:<line>: <reason>" line per violation, then
# "family-check: <sub>: <N> subjects, <V> violations"; every leg pins the
# subject count too, so a check that silently reads nothing cannot pass.

FAMILY_STATIC="$PLUGIN_ROOT/scripts/docs-site/static"
FAMILY_CHECK="$PLUGIN_ROOT/tests/lib/family-check.py"
PAGE_TMPL="$PLUGIN_ROOT/scripts/docs-site/page.html"

fc() { python3 -I -X utf8 "$FAMILY_CHECK" "$@"; }

# fc_count <sub> — set fc_n to the <N> of the "family-check: <sub>: <N>
# subjects, 0 violations" line in $output; fails when there is no clean one.
fc_count() {
  [[ $output =~ family-check:\ $1:\ ([0-9]+)\ subjects,\ 0\ violations ]] || { echo "no clean $1 count line in: $output" >&2; return 1; }
  fc_n="${BASH_REMATCH[1]}"
}

# fc_row <want> <token> <sub> <file>... — family-check <sub> on planted files.
# want 1: status 1 and output holding <token>. want 0: status 0 and a clean
# count line.
fc_row() {
  local want="$1" token="$2"; shift 2
  run fc "$@"
  [ "$status" -eq "$want" ] || { echo "family-check $* : status $status, want $want: $output" >&2; return 1; }
  if [ "$want" -eq 1 ]; then
    [[ $output == *"$token"* ]] || { echo "family-check $* : no '$token' in: $output" >&2; return 1; }
  else
    [[ $output == *", 0 violations"* ]] || { echo "family-check $* : not clean: $output" >&2; return 1; }
  fi
}

# family_versioned — the files whose line 1 names the family version; each
# task that adds a family file adds it here.
family_versioned() {
  printf '%s\n' "$FAMILY_STATIC/family.css" "$FAMILY_STATIC/family.js" \
    "$FAMILY_STATIC/family-topbar.html" "$FAMILY_STATIC/family-footer.html" "$PLUGIN_ROOT/docs-site/live.txt"
}

@test "build-docs-site: family files — each header names the same family version" {
  local f=()
  mapfile -t f < <(family_versioned)
  [ "${#f[@]}" -ge 1 ]
  run fc header "${f[@]}"
  [ "$status" -eq 0 ]
  fc_count header
  [ "$fc_n" -eq "${#f[@]}" ]
}

@test "build-docs-site: family files — the palette reads per theme (light and dark sets)" {
  run fc tokens "$FAMILY_STATIC/family.css"
  [ "$status" -eq 0 ]
  fc_count tokens
  [ "$fc_n" -eq 12 ]
}

@test "build-docs-site: family files — page.html holds no token, colour literal or setting" {
  run fc literals "$FAMILY_STATIC/family.css" "$PAGE_TMPL"
  [ "$status" -eq 0 ]
  fc_count literals
  [ "$fc_n" -ge 24 ]
}

@test "build-docs-site: family files — WCAG AA for the listed pairs, both themes" {
  run fc contrast "$FAMILY_STATIC/family.css" "$PAGE_TMPL"
  [ "$status" -eq 0 ]
  fc_count contrast
  # 2 themes x (ink, accent-ink, ink-soft) x (ground, worst grid pixel, nav-bg)
  [ "$fc_n" -eq 18 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -cE '^(light|dark) (ink|accent-ink|ink-soft)/(ground|grid|nav-bg) #[0-9A-F]{6} #[0-9A-F]{6} [0-9]+\.[0-9]{2}$')" -eq 18 ]
}

@test "build-docs-site: family-check — every subcommand reddens on a planted violation" {
  local d="$BATS_TEST_TMPDIR" css="$FAMILY_STATIC/family.css"
  # header: no version; two different versions; one version passes
  printf '/* family v1.0: a */\n' > "$d/a.css"
  printf '/* family v1.1: b */\n' > "$d/b.css"
  printf '/* no version */\n' > "$d/c.css"
  fc_row 1 'c.css:1: line 1 names no family version' header "$d/c.css"
  fc_row 1 'family version v1.1 differs from v1.0' header "$d/a.css" "$d/b.css"
  fc_row 0 '' header "$d/a.css" "$d/a.css"
  # tokens: a dark twin missing; a theme literal inside @media; an active
  # token that is not var()
  grep -v -e '--family-dark-line:' "$css" > "$d/t1.css"
  fc_row 1 'dark twin missing: --family-light-line' tokens "$d/t1.css"
  { cat "$css"; printf '@media print { :root { --family-light-x: #000000; } }\n'; } > "$d/t2.css"
  fc_row 1 '--family-light-x is defined inside @media print' tokens "$d/t2.css"
  sed 's/--family-ink: var(--family-light-ink);/--family-ink: #000000;/' "$css" > "$d/t3.css"
  ! cmp -s "$css" "$d/t3.css" || return 1
  fc_row 1 '--family-ink is not var(--family-light-ink) at the top level' tokens "$d/t3.css"
  # literals: an uppercase hex, a spaced rgba(), a custom property, a
  # non-family var(), an undefined family var(); a family var() passes
  local lc rg gr
  lc="$(grep -m1 -oE -e '--family-light-ink: #[0-9A-Fa-f]{6}' "$css")"
  lc="${lc##* }"
  [ -n "$lc" ]
  printf '<style>\nbody { color: %s; }\n</style>\n' "${lc^^}" > "$d/p1.html"
  fc_row 1 "p1.html:2: holds family colour ${lc,,}" literals "$css" "$d/p1.html"
  rg="$(grep -m1 -oE -e '--family-light-grid-minor: rgba\([^)]*\)' "$css")"
  rg="${rg#*: }"
  [ -n "$rg" ]
  printf '<style>\nmain { color: %s; }\n</style>\n' "$(printf '%s' "$rg" | sed 's/(/( /; s/,/ , /g; s/)/ )/')" > "$d/p2.html"
  fc_row 1 'holds family colour rgba(' literals "$css" "$d/p2.html"
  printf '<style>\n:root { --ink: red; }\n</style>\n' > "$d/p3.html"
  fc_row 1 'p3.html:2: defines custom property --ink' literals "$css" "$d/p3.html"
  printf '<style>\nbody { color: var(--ink); }\n</style>\n' > "$d/p4.html"
  fc_row 1 'p4.html:2: var(--ink) is not a family token' literals "$css" "$d/p4.html"
  printf '<style>\nbody { color: var(--family-nope); }\n</style>\n' > "$d/p5.html"
  fc_row 1 'var(--family-nope) is not defined in' literals "$css" "$d/p5.html"
  printf '<style>\nbody { color: var(--family-ink); }\n</style>\n' > "$d/p6.html"
  fc_row 0 '' literals "$css" "$d/p6.html"
  # contrast: ink-soft equal to ground; text on --family-board; body may
  # paint the board
  gr="$(grep -m1 -oE -e '--family-light-ground: #[0-9A-Fa-f]{6}' "$css")"
  gr="${gr##* }"
  [ -n "$gr" ]
  sed -E "s/(--family-light-ink-soft: )#[0-9A-Fa-f]{6}/\\1$gr/" "$css" > "$d/c1.css"
  ! cmp -s "$css" "$d/c1.css" || return 1
  fc_row 1 'light ink-soft on ground is 1.00:1, below 4.5:1' contrast "$d/c1.css"
  printf '<style>\nnav { background: var(--family-board); }\n</style>\n' > "$d/b1.html"
  fc_row 1 'b1.html:2: nav paints --family-board behind text' contrast "$css" "$d/b1.html"
  printf '<style>\nbody { background: var(--family-board); }\n</style>\n' > "$d/b2.html"
  fc_row 0 '' contrast "$css" "$d/b2.html"
  # scope: a bare nav rule, a p under a family class, a family class;
  # scoped selectors pass
  printf '%s\n' '<header class="family-topbar"><nav><ul class="family-sites"><li>{{live:a|A}}</li></ul></nav></header>' > "$d/top.html"
  printf '%s\n' '<div class="family-footer"><p><button type="button">x</button></p></div>' > "$d/foot.html"
  printf '<style>\nnav { width: 1px; }\n</style>\n' > "$d/s1.html"
  fc_row 1 "s1.html:2: 'nav' reaches family markup (<nav> in" scope "$d/s1.html" "$d/top.html" "$d/foot.html"
  printf '<style>\n.family-footer p { margin: 0; }\n</style>\n' > "$d/s2.html"
  fc_row 1 "'.family-footer p' reaches family markup" scope "$d/s2.html" "$d/top.html" "$d/foot.html"
  printf '<style>\n.family-coming { color: red; }\n</style>\n' > "$d/s3.html"
  fc_row 1 "'.family-coming' styles family markup" scope "$d/s3.html" "$d/top.html" "$d/foot.html"
  # a universal subject under a scoping ancestor still reaches; only a bare * is exempt
  printf '<style>
* { margin: 0; }
div * { color: red; }
</style>
' > "$d/s5.html"
  fc_row 1 "s5.html:3: 'div *' reaches family markup" scope "$d/s5.html" "$d/top.html" "$d/foot.html"
  printf '%s\n' '<style>' 'nav[aria-label="Pages"] a:hover { color: red; }' 'article p, main > footer > a { margin: 0; }' \
    '@media (prefers-reduced-motion: no-preference) { .family-motion nav[aria-label="Pages"] a { color: red; } }' '</style>' > "$d/s4.html"
  fc_row 0 '' scope "$d/s4.html" "$d/top.html" "$d/foot.html"
  # with the template's markers, the page's own ancestors of the partials
  # (main, footer.site-footer) scope nothing: rules under them still reach
  # the footer partial. Child and class scoping that cannot reach it pass.
  local frame='<body>
<!--family-topbar-->
<div class="layout"><main class="family-sheet"><article><p>x</p></article>
<footer>Built from <a href="x">x</a></footer>
<footer class="site-footer">
<!--family-footer-->
<p class="site-links"><a href="r">r</a></p>
</footer></main></div></body>'
  local sel
  for sel in 'main p' '.site-footer li' 'main > footer div' 'main a' '.family-sheet ul'; do
    printf '<style>\n%s { color: red; }\n</style>\n%s\n' "$sel" "$frame" > "$d/s5.html"
    fc_row 1 "'$sel' reaches family markup" scope "$d/s5.html" "$FAMILY_STATIC/family-topbar.html" "$FAMILY_STATIC/family-footer.html"
  done
  printf '<style>\n%s\n</style>\n%s\n' 'article p, main > footer > a, .site-links a, main > footer, * { margin: 0; }' "$frame" > "$d/s6.html"
  fc_row 0 '' scope "$d/s6.html" "$FAMILY_STATIC/family-topbar.html" "$FAMILY_STATIC/family-footer.html"
  # usage
  run fc nosuch "$css"
  [ "$status" -eq 2 ]
  run fc tokens
  [ "$status" -eq 2 ]
}

# need_node — the family.js leg runs the real script under node (no npm).
need_node() {
  command -v node >/dev/null 2>&1 \
    || skip "node not installed — the publish docs site lane runs this leg and forbids skips; install node locally"
}

@test "build-docs-site: family.js — the animation setting (node, stub storage)" {
  need_node
  echo "# node $(node --version)" >&3
  run node "$PLUGIN_ROOT/tests/lib/family-js-test.js" "$FAMILY_STATIC/family.js"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  # the last line counts the cases; every case printed "ok", and an emptied
  # case list cannot pass
  [[ ${lines[${#lines[@]} - 1]} =~ ^cases:\ ([0-9]+)$ ]]
  local n="${BASH_REMATCH[1]}"
  [ "$n" -ge 22 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -c '^ok ')" -eq "$n" ]
  # the header's contract is what the code does (B7): key, class and control
  # as observed on a first view, exports as observed after loading
  local obs exports
  obs="$(printf '%s\n' "${lines[@]}" | sed -n 's/^observed //p')"
  exports="$(printf '%s\n' "${lines[@]}" | sed -n 's/^exports: //p')"
  [ -n "$obs" ] && [ -n "$exports" ]
  run fc contract "$FAMILY_STATIC/family.js"
  [ "$status" -eq 0 ]
  fc_count contract
  [ "$fc_n" -eq 4 ]
  local hdr
  hdr="$(printf '%s\n' "${lines[@]}" | sed -n 's/^header //p')"
  [ "$hdr" = "$obs exports=$exports" ] || { echo "header: $hdr / observed: $obs exports=$exports" >&2; return 1; }
}

@test "build-docs-site: family-check — contract reddens on a header that differs from the code" {
  local d="$BATS_TEST_TMPDIR" js="$FAMILY_STATIC/family.js"
  sed -E '1,/\*\//s/(key: )mtibbits-family-v1/\1mtibbits-family-v9/' "$js" > "$d/k.js"
  ! cmp -s "$js" "$d/k.js" || return 1
  fc_row 1 'header key mtibbits-family-v9 is not a string literal in the code' contract "$d/k.js"
  sed -E '1,/\*\//s/(exports: .*)$/\1, familyNope/' "$js" > "$d/e.js"
  ! cmp -s "$js" "$d/e.js" || return 1
  fc_row 1 'header exports familyNope, which the code never assigns on window' contract "$d/e.js"
  grep -vE '^ \* +control:' "$js" > "$d/c.js"
  ! cmp -s "$js" "$d/c.js" || return 1
  fc_row 1 "the header names no 'control:' line" contract "$d/c.js"
  fc_row 0 '' contract "$js"
}

# ---------------------------------------- FAMILY: live settings and placeholders (#996)
#
# scripts/docs-site/fill-placeholders.py, run directly on planted files (no
# pandoc, no build). One fixture dir per row (sc_new), so a row cannot see an
# earlier row's files.

FILLER="$PLUGIN_ROOT/scripts/docs-site/fill-placeholders.py"
LIVE_TXT="$PLUGIN_ROOT/docs-site/live.txt"

fp() { python3 -I -X utf8 "$FILLER" "$@"; }

# fp_settings <line>... — $FX/live.txt holding the lines.
fp_settings() { printf '%s\n' "$@" > "$FX/live.txt"; }

# fp_std — the fixture settings most rows use: home live, gantry not live, a
# count over $FX/data.md with 3 matching lines.
fp_std() {
  fp_settings '# fixture' 'live home yes index.html' 'live gantry no https://example.invalid/g/' 'count n data.md ^x'
  printf 'x1\nx2\ny\nx3\n' > "$FX/data.md"
}

# fp_fail_row <placeholder text> <reason token> — the page holding the text
# exits 5 naming the page and the reason, and is left unchanged.
fp_fail_row() {
  sc_new; fp_std
  printf '<p>%s</p>\n' "$1" > "$FX/a.html"
  cp "$FX/a.html" "$FX/a.orig"
  run fp --settings "$FX/live.txt" "$FX/a.html"
  [ "$status" -eq 5 ] || { echo "row $sc_n ($1): status $status, want 5: $output" >&2; return 1; }
  [[ $output == *"fill-placeholders: $FX/a.html: "*"$2"* ]] || { echo "row $sc_n ($1): no '$2' naming the page in: $output" >&2; return 1; }
  cmp -s "$FX/a.html" "$FX/a.orig" || { echo "row $sc_n ($1): the page was rewritten" >&2; return 1; }
}

# fp_settings_row <bad line> [<want line no>] — settings holding a good line
# then the bad one exit 4 naming the settings file and the bad line.
fp_settings_row() {
  sc_new
  fp_settings 'live home yes index.html' "$1"
  printf 'x\n' > "$FX/d.md"
  printf '<p>{{live:home|Home}}</p>\n' > "$FX/a.html"
  run fp --settings "$FX/live.txt" "$FX/a.html"
  [ "$status" -eq 4 ] || { echo "row $sc_n ($1): status $status, want 4: $output" >&2; return 1; }
  [[ $output == *"fill-placeholders: $FX/live.txt:${2:-2}: "* ]] || { echo "row $sc_n ($1): no '$FX/live.txt:${2:-2}:' in: $output" >&2; return 1; }
  [[ $output == *"${3:-}"* ]] || { echo "row $sc_n ($1): no '${3:-}' in: $output" >&2; return 1; }
}

@test "build-docs-site: fill-placeholders — live yes, live no and count render byte-exact" {
  sc_n=0; sc_new; fp_std
  printf '<p>\xc3\xa9 {{live:home|Home}}\r\n{{live:gantry|Gantry}}\r\nn={{count:n}}.</p>\r\n' > "$FX/a.html"
  printf '<p>\xc3\xa9 <a href="index.html">Home</a>\r\n<span class="family-coming">Gantry <small>coming</small></span>\r\nn=3.</p>\r\n' > "$FX/want.html"
  run fp --settings "$FX/live.txt" "$FX/a.html"
  [ "$status" -eq 0 ]
  [ "$output" = "fill-placeholders: filled 3 placeholders in 1 files" ]
  cmp "$FX/a.html" "$FX/want.html"
}

@test "build-docs-site: fill-placeholders — a label wrapped across lines is normalised" {
  sc_n=0; sc_new; fp_std
  printf '<p>{{live:gantry|The Gantry\nsite}} and {{live:home|  Home \t page }}</p>\n' > "$FX/a.html"
  run fp --settings "$FX/live.txt" "$FX/a.html"
  [ "$status" -eq 0 ]
  [ "$(cat "$FX/a.html")" = '<p><span class="family-coming">The Gantry site <small>coming</small></span> and <a href="index.html">Home page</a></p>' ]
}

@test "build-docs-site: fill-placeholders — \${{ x }} and lone braces are text" {
  sc_n=0; sc_new; fp_std
  printf '%s\n' 'run: ${{ github.ref }} {{ x }}' 'a { b } {{' '}} {} { {x} }' > "$FX/a.html"
  cp "$FX/a.html" "$FX/a.orig"
  run fp --settings "$FX/live.txt" "$FX/a.html"
  [ "$status" -eq 0 ]
  [ "$output" = "fill-placeholders: filled 0 placeholders in 1 files" ]
  cmp "$FX/a.html" "$FX/a.orig"
}

@test "build-docs-site: fill-placeholders — each placeholder failure exits 5 naming the file" {
  sc_n=0
  fp_fail_row '{{nope:x}}' 'unknown placeholder {{nope:x}}'
  fp_fail_row '{{live:zzz|Z}}' 'unknown placeholder {{live:zzz|Z}}'
  fp_fail_row '{{live:home}}' 'unknown placeholder {{live:home}}'
  fp_fail_row '{{live:home| }}' 'unknown placeholder {{live:home|}}'
  fp_fail_row '{{x}}' 'unknown placeholder {{x}}'
  fp_fail_row '{{}}' 'unknown placeholder {{}}'
  # an unclosed placeholder cannot swallow markup up to a later "}}"
  fp_fail_row 'See {{live:gantry|Gantry</p><h2 id="x">Next</h2><p>Use <code>a}}</code>' 'unclosed placeholder starting {{live:'
  # a label is plain text: markup in it is refused, not inserted
  fp_fail_row '{{live:gantry|<em>Gantry</em>}}' 'unclosed placeholder starting {{live:'
  # a placeholder inside a tag (an attribute value) would write broken HTML
  fp_fail_row '<img alt="{{live:home|Home}}" src="a.png">' 'placeholder inside a tag: {{live:home|Home}}'
  # one inside a comment is refused too, and says where it is
  fp_fail_row '<!-- {{live:home|Home}} -->' 'placeholder inside an HTML comment: {{live:home|Home}}'
  fp_fail_row '{{count:zzz}}' 'unknown placeholder {{count:zzz}}'
  fp_fail_row 'ok {{live:gantry|G' 'unclosed placeholder starting {{live:'
  fp_fail_row 'ok {{count:n' 'unclosed placeholder starting {{count:'
  # a missing count source, and a zero count
  sc_new; fp_std
  printf '%s\n' 'count m missing.md ^x' 'count z data.md ^nomatch' >> "$FX/live.txt"
  printf '<p>{{count:m}}</p>\n' > "$FX/a.html"
  run fp --settings "$FX/live.txt" "$FX/a.html"
  [ "$status" -eq 5 ]
  [[ $output == *"fill-placeholders: $FX/a.html: count source not found: missing.md (count m)"* ]]
  printf '<p>{{count:z}}</p>\n' > "$FX/b.html"
  run fp --settings "$FX/live.txt" "$FX/b.html"
  [ "$status" -eq 5 ]
  [[ $output == *"fill-placeholders: $FX/b.html: count z is zero in data.md; a zero is never published"* ]]
  # one bad file in a set rewrites none of them
  printf '<p>{{live:home|Home}}</p>\n' > "$FX/c.html"
  cp "$FX/c.html" "$FX/c.orig"
  run fp --settings "$FX/live.txt" "$FX/c.html" "$FX/b.html"
  [ "$status" -eq 5 ]
  cmp "$FX/c.html" "$FX/c.orig"
}

@test "build-docs-site: fill-placeholders — each settings refusal exits 4 naming the line" {
  sc_n=0
  fp_settings_row 'frob x' 2 "expected 'live <key> yes|no <url>' or 'count <key> <path> <regex>'"
  fp_settings_row 'live Bad yes index.html'
  fp_settings_row 'live a maybe index.html'
  fp_settings_row 'live a yes http://x.example/'
  fp_settings_row 'live a yes https://x.example/"q'
  fp_settings_row 'live a yes'
  fp_settings_row 'count c /x ^a' 2 'count path must be relative to this file: /x'
  fp_settings_row 'count c C:/x ^a' 2 'count path must be relative to this file: C:/x'
  fp_settings_row 'count c d.md (' 2 'count regex does not compile:'
  fp_settings_row 'live home no index.html' 2 'home is listed twice'
  # a missing file is line 0
  sc_new
  printf '<p>x</p>\n' > "$FX/a.html"
  run fp --settings "$FX/none.txt" "$FX/a.html"
  [ "$status" -eq 4 ]
  [[ $output == *"fill-placeholders: $FX/none.txt:0: not found"* ]]
  # comments, blank lines and trailing spaces are fine; --check counts each kind
  sc_new
  printf '%s\n' '# c' '' '   ' 'live devagent yes index.html   ' 'live gantry no https://x.example/' 'live learn no https://y.example/' 'count n d.md ^x # not a comment' > "$FX/live.txt"
  run fp --settings "$FX/live.txt" --check
  [ "$status" -eq 0 ]
  [ "$output" = "fill-placeholders: settings ok: 3 live, 1 count" ]
}

@test "build-docs-site: fill-placeholders — --check refuses a settings file missing a key the partials use" {
  sc_n=0; sc_new
  grep -v '^live learn ' "$LIVE_TXT" > "$FX/live.txt"
  ! cmp -s "$LIVE_TXT" "$FX/live.txt" || return 1
  run fp --settings "$FX/live.txt" --check
  [ "$status" -eq 4 ]
  [[ $output == *"fill-placeholders: $FX/live.txt:0: missing required key 'learn' (used by family-topbar.html)"* ]]
  # the real file passes
  run fp --settings "$LIVE_TXT" --check
  [ "$status" -eq 0 ]
  [[ $output == "fill-placeholders: settings ok: "*" live, "*" count" ]]
}

@test "build-docs-site: fill-placeholders — usage exits 2" {
  run fp "$BATS_TEST_TMPDIR/a.html"
  [ "$status" -eq 2 ]
  [[ $output == *"--settings is required"* ]]
  run fp --settings "$LIVE_TXT" --frob "$BATS_TEST_TMPDIR/a.html"
  [ "$status" -eq 2 ]
  [[ $output == *"unknown argument: --frob"* ]]
  run fp --settings "$LIVE_TXT"
  [ "$status" -eq 2 ]
  run fp --settings "$LIVE_TXT" --check "$BATS_TEST_TMPDIR/a.html"
  [ "$status" -eq 2 ]
}

@test "build-docs-site: family partials — standalone fragments once filled" {
  local p n=0
  for p in family-topbar.html family-footer.html; do
    cp "$FAMILY_STATIC/$p" "$BATS_TEST_TMPDIR/$p"
    run fp --settings "$LIVE_TXT" "$BATS_TEST_TMPDIR/$p"
    [ "$status" -eq 0 ]
    n=$((n + 1))
  done
  run fc fragment "$FAMILY_STATIC/family.css" "$BATS_TEST_TMPDIR/family-topbar.html" "$BATS_TEST_TMPDIR/family-footer.html"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  fc_count fragment
  [ "$fc_n" -eq "$n" ]
}

@test "build-docs-site: family files — page.html rules do not reach family markup" {
  run fc scope "$PAGE_TMPL" "$FAMILY_STATIC/family-topbar.html" "$FAMILY_STATIC/family-footer.html"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  fc_count scope
  [ "$fc_n" -ge 40 ]
}

@test "build-docs-site: live.txt — each header example renders as written" {
  run fc contract "$LIVE_TXT" "$FILLER"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  fc_count contract
  # one example of each output: live yes, live no, count
  [ "$fc_n" -ge 3 ]
}

@test "build-docs-site: family-check — fragment and live.txt contract redden on a planted violation" {
  local d="$BATS_TEST_TMPDIR" css="$FAMILY_STATIC/family.css"
  printf '<div class="family-footer">{{live:a|A}}</div>\n' > "$d/f1.html"
  fc_row 1 'f1.html:1: a placeholder is left' fragment "$css" "$d/f1.html"
  printf '<div class="family-footer"><script>x()</script></div>\n' > "$d/f2.html"
  fc_row 1 'f2.html:1: <script> is not allowed in a fragment' fragment "$css" "$d/f2.html"
  printf '<div class="family-footer"><p class="nope">x</p></div>\n' > "$d/f3.html"
  fc_row 1 "f3.html:1: class 'nope' is not defined in family.css" fragment "$css" "$d/f3.html"
  printf '<div class="family-footer"><p>x</div>\n' > "$d/f4.html"
  fc_row 1 'f4.html:1: </div> closes <p>' fragment "$css" "$d/f4.html"
  printf '<div class="family-footer"></div>\n<div class="family-footer"></div>\n' > "$d/f5.html"
  fc_row 1 '2 root elements (want 1)' fragment "$css" "$d/f5.html"
  printf '<div class="family-footer" onclick="x()"></div>\n' > "$d/f6.html"
  fc_row 1 'f6.html:1: onclick= is not allowed in a fragment' fragment "$css" "$d/f6.html"
  printf '<!-- c -->\n<div class="family-footer"><p>x<br></p></div>\n' > "$d/f7.html"
  fc_row 0 '' fragment "$css" "$d/f7.html"
  # a wrong example output (the copy keeps its count sources beside it)
  mkdir -p "$d/docs-site" "$d/docs"
  cp "$PLUGIN_ROOT/docs/requirements.md" "$d/docs/"
  cp "$LIVE_TXT" "$d/docs-site/live.txt"
  fc_row 0 '' contract "$d/docs-site/live.txt" "$FILLER"
  sed 's/<small>coming<\/small>/<small>soon<\/small>/' "$LIVE_TXT" > "$d/docs-site/live.txt"
  ! cmp -s "$LIVE_TXT" "$d/docs-site/live.txt" || return 1
  fc_row 1 'renders as' contract "$d/docs-site/live.txt" "$FILLER"
}

# ------------------------------------------ FAMILY: through the build (#996)

@test "build-docs-site: build — no live.txt -> exit 4, nothing written" {
  fx_bin
  FX_PATH="$FX/bin"
  fx_page index "hello"
  rm "$FX/src/live.txt"
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"no live settings file: $FX/src/live.txt (the top bar and placeholders read it)"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: build — malformed live.txt -> exit 4 naming the line, nothing written" {
  fx_bin
  FX_PATH="$FX/bin"
  fx_page index "hello"
  printf 'live devagent maybe index.html\n' >> "$FX/src/live.txt"
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"fill-placeholders: $FX/src/live.txt:4: expected"* ]]
  [[ "$output" == *"the live settings file is malformed"* ]]
  [ ! -e "$FX/out" ]
  # a live.txt missing a key the partials use is malformed too
  grep -v '^live learn ' "$FX/src/live.txt" | grep -v maybe > "$FX/l" && mv "$FX/l" "$FX/src/live.txt"
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"missing required key 'learn'"* ]]
  [ ! -e "$FX/out" ]
}

@test "build-docs-site: build — a static dir missing family.js -> exit 4 naming it, nothing written" {
  fx_bin
  FX_PATH="$FX/bin"
  fx_page index "hello"
  fx_static_copy
  rm "$FX/static/family.js"
  run fx_build
  [ "$status" -eq 4 ]
  [[ "$output" == *"$FX/static: missing family file family.js (the template links or inserts it)"* ]]
  [ ! -e "$FX/out" ]
}

# fx_fill_site — an index.md and a hand-written page, each holding a live
# placeholder, a not-live one and a count over $FX/data.md (2 matching lines).
fx_fill_site() {
  printf 'count fx ../data.md ^x\n' >> "$FX/src/live.txt"
  printf 'x1\ny\nx2\n' > "$FX/data.md"
  fx_page index '- [Hand](./hand.html)' '' '{{live:devagent|Home}}' '' '{{live:gantry|Gantry}}' '' 'n={{count:fx}}.'
  fx_html hand '<h1>Hand</h1>' '<p><a href="index.html">x</a></p>' '<p>{{live:devagent|Home}}</p>' \
    '<p>{{live:gantry|Gantry}}</p>' '<p>n={{count:fx}}.</p>'
}

@test "build-docs-site: build — placeholders fill in Markdown and hand-written pages" {
  need_pandoc
  fx_fill_site
  run fx_build
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  local p
  for p in index hand; do
    article_of "$FX/out/$p.html" | grep -qF '<a href="index.html">Home</a>'
    article_of "$FX/out/$p.html" | grep -qF '<span class="family-coming">Gantry <small>coming</small></span>'
    article_of "$FX/out/$p.html" | grep -qxF '<p>n=2.</p>'
  done
  # no placeholder is left in any page (the partials under static/ are
  # published as written, for other sites to copy)
  [ "$(cat "$FX"/out/*.html | grep -c '{{' || true)" -eq 0 ]
}

@test "build-docs-site: build — an unknown placeholder -> exit 5 naming page and placeholder" {
  need_pandoc
  fx_page index 'see {{live:nope|X}}'
  run fx_build
  [ "$status" -eq 5 ]
  [[ "$output" == *"fill-placeholders: $FX/out/index.html: unknown placeholder {{live:nope|X}}"* ]]
  [[ "$output" == *"a placeholder could not be filled"* ]]
  [[ "$output" != *"built 1 pages"* ]]
}

@test "build-docs-site: build — a zero count -> exit 5" {
  need_pandoc
  printf 'count z ../data.md ^nomatch\n' >> "$FX/src/live.txt"
  printf 'x\n' > "$FX/data.md"
  fx_page index 'n={{count:z}}'
  run fx_build
  [ "$status" -eq 5 ]
  [[ "$output" == *"count z is zero in ../data.md; a zero is never published"* ]]
}

@test "build-docs-site: build — a missing count source -> exit 5" {
  need_pandoc
  printf 'count m ../missing.md ^x\n' >> "$FX/src/live.txt"
  fx_page index 'n={{count:m}}'
  run fx_build
  [ "$status" -eq 5 ]
  [[ "$output" == *"count source not found: ../missing.md (count m)"* ]]
}

@test "build-docs-site: build — a placeholder in a page title (H1) -> exit 5 naming the page" {
  need_pandoc
  printf '# Home {{live:gantry|Gantry}}\n\nx\n' > "$FX/src/index.md"
  run fx_build
  [ "$status" -eq 5 ]
  [[ "$output" == *"index.md: placeholder in the page title (H1) — titles feed <title> and the nav"* ]]
  # the titles are read before any page renders: no page is written
  [ -z "$(find "$FX/out" -name '*.html' 2>/dev/null)" ]
  # a hand-written page's <h1> and its nav-label header are refused too
  rm -rf "$FX/out" "$FX/src/index.md"
  fx_html index '<h1>Home {{count:x}}</h1>'
  run fx_build
  [ "$status" -eq 5 ]
  [[ "$output" == *"index.html: placeholder in the page title (H1)"* ]]
  rm -rf "$FX/out"
  printf '%s\n' '<!-- derived-from: fixture -->' '<!-- nav-label: Go {{live:gantry|G}} -->' '<h1>Home</h1>' > "$FX/src/index.html"
  run fx_build
  [ "$status" -eq 5 ]
  [[ "$output" == *"index.html: placeholder in the nav label"* ]]
}

@test "build-docs-site: build — every page carries both partials once, placeholders filled" {
  need_pandoc
  fx_fill_site
  run fx_build
  [ "$status" -eq 0 ]
  local p part l1
  for p in index hand; do
    for part in family-topbar.html family-footer.html; do
      l1="$(sed -n 1p "$FAMILY_STATIC/$part")"
      [ "$(grep -cxF -- "$l1" "$FX/out/$p.html")" -eq 1 ] || { echo "$p.html: $part line 1 not exactly once" >&2; return 1; }
    done
    [ "$(grep -c '{{' "$FX/out/$p.html" || true)" -eq 0 ]
    ! grep -qxF '<!--family-topbar-->' "$FX/out/$p.html" || return 1
    ! grep -qxF '<!--family-footer-->' "$FX/out/$p.html" || return 1
  done
}

@test "build-docs-site: build — a body line equal to a marker -> exit 5 naming it" {
  need_pandoc
  fx_html index '<h1>Home</h1>' '<!--family-footer-->'
  run fx_build
  [ "$status" -eq 5 ]
  [[ "$output" == *"index.html: expected one <!--family-footer--> line, found 2"* ]]
}

@test "build-docs-site: build — a filler crash -> exit 8, says the fill did not complete" {
  need_pandoc
  fx_page index "hello"
  local real_py
  real_py="$(command -v python3)"
  mkdir -p "$FX/py"
  printf '#!%s\ncase " $* " in *fill-placeholders.py*) case " $* " in *" --check "*) ;; *) exec "%s" -c "import sys; sys.exit(9)" ;; esac ;; esac\nexec "%s" "$@"\n' \
    "$(command -v bash)" "$real_py" "$real_py" > "$FX/py/python3"
  chmod +x "$FX/py/python3"
  FX_PYTHON="$FX/py/python3"
  run fx_build
  [ "$status" -eq 8 ]
  [[ "$output" == *"the placeholder fill did not complete (fill-placeholders exited 9)"* ]]
  [[ "$output" != *"built 1 pages"* ]]
}

# ------------------------------------------ FAMILY: the real site (#996)
#
# The expectations below come from the partials and docs-site/live.txt
# directly (a sed over each live line, in the rendered formats), never from
# the filler, so a filler bug cannot agree with itself.

# region_of <html> <partial> — the lines of <html> that the partial's lines 2
# to its end landed on (line 1, the version comment, is left out).
region_of() {
  local first n
  first="$(sed -n 2p "$2")"
  n=$(( $(wc -l < "$2") - 1 ))
  awk -v f="$first" -v n="$n" 'c == 0 && !done && $0 == f { c = n } c > 0 { print; c--; if (c == 0) done = 1 }' "$1"
}

# expect_region <partial> — the partial's lines 2 to its end, each live
# placeholder rendered from docs-site/live.txt.
expect_region() {
  local sedargs=() k state url
  while read -r _ k state url; do
    if [ "$state" = yes ]; then
      sedargs+=(-e "s#{{live:$k|\\([^}]*\\)}}#<a href=\"$url\">\\1</a>#g")
    else
      sedargs+=(-e "s#{{live:$k|\\([^}]*\\)}}#<span class=\"family-coming\">\\1 <small>coming</small></span>#g")
    fi
  done < <(grep -E '^live[[:space:]]' "$LIVE_TXT")
  [ "${#sedargs[@]}" -gt 0 ] || return 1
  sed -n '2,$p' "$1" | sed "${sedargs[@]}"
}

@test "build-docs-site: real site — every page carries the same top bar and shared footer, filled from live.txt" {
  need_pandoc
  local content=() p part want got n=0
  mapfile -t content < <(real_content)
  [ "${#content[@]}" -ge 2 ]
  for part in family-topbar.html family-footer.html; do
    want="$(expect_region "$FAMILY_STATIC/$part")"
    [ -n "$want" ]
    [[ $want != *'{{'* ]]
    for p in "${content[@]}"; do
      got="$(region_of "$REAL_OUT/$p.html" "$FAMILY_STATIC/$part")"
      [ "$got" = "$want" ] || { echo "$p.html: the $part region is not the expected markup:" >&2; diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2; return 1; }
      n=$((n + 1))
    done
  done
  [ "$n" -eq $(( 2 * ${#content[@]} )) ]
  # plain HTML: each region is markup, outside <noscript>, <script>,
  # <template> and comments
  for p in "${content[@]}"; do
    run fc placement "$REAL_OUT/$p.html" "$FAMILY_STATIC/family-topbar.html" "$FAMILY_STATIC/family-footer.html"
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
    fc_count placement
    [ "$fc_n" -eq 2 ]
  done
}

@test "build-docs-site: real site — live.txt renders both ways: not live without a link, live with one" {
  need_pandoc
  # today's settings (child 11 flips these when the sites go live)
  grep -qE '^live gantry no ' "$LIVE_TXT"
  grep -qE '^live learn no ' "$LIVE_TXT"
  local content=() p k state url label li yes=0 no=0 region
  mapfile -t content < <(real_content)
  for p in "${content[@]}"; do
    region="$(region_of "$REAL_OUT/$p.html" "$FAMILY_STATIC/family-topbar.html")"
    while read -r _ k state url; do
      label="$(sed -n "s/.*{{live:$k|\\([^}]*\\)}}.*/\\1/p" "$FAMILY_STATIC/family-topbar.html")"
      [ -n "$label" ]
      li="$(printf '%s\n' "$region" | grep -F '<li>' | grep -F -e ">$label<" -e ">$label <small>")"
      [ "$(printf '%s\n' "$li" | wc -l)" -eq 1 ] || { echo "$p.html: no single <li> for $label: $li" >&2; return 1; }
      if [ "$state" = no ]; then
        [[ $li != *'href='* ]] || { echo "$p.html: $k is not live but links: $li" >&2; return 1; }
        [[ $li == *'class="family-coming"'* ]]
        no=$((no + 1))
      else
        [ "$(grep -o 'href=' <<< "$li" | wc -l)" -eq 1 ]
        [[ $li == *"href=\"$url\""* ]] || { echo "$p.html: $k is live but its <li> lacks href=\"$url\": $li" >&2; return 1; }
        yes=$((yes + 1))
      fi
    done < <(grep -E '^live[[:space:]]' "$LIVE_TXT")
  done
  [ "$yes" -ge "${#content[@]}" ]
  [ "$no" -ge "${#content[@]}" ]
}

@test "build-docs-site: real site — no animation or transition applies outside .family-motion" {
  need_pandoc
  local content=() css=() html=()
  mapfile -t content < <(real_content)
  mapfile -t css < <(find "$REAL_OUT" -name '*.css' | LC_ALL=C sort)
  html=("$REAL_OUT"/*.html)
  [ "${#css[@]}" -ge 1 ]
  [ -f "$REAL_OUT/static/family.css" ]
  run fc motion "${css[@]}" "${html[@]}"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  fc_count motion
  [ "$fc_n" -ge $(( 1 + ${#content[@]} )) ]
  # 1.0's nav transition is still there, gated
  grep -qF '.family-motion nav[aria-label="Pages"] a { transition: color 120ms ease; }' "$PAGE_TMPL"
}

@test "build-docs-site: real site — nothing is hidden by default; text, top bar and footer are in the HTML" {
  need_pandoc
  local content=() p
  mapfile -t content < <(real_content)
  run fc hidden "$REAL_OUT"/*.html
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  fc_count hidden
  [ "$fc_n" -ge "${#content[@]}" ]
  for p in "${content[@]}"; do
    [ -n "$(article_of "$REAL_OUT/$p.html" | tr -d '[:space:]')" ]
    grep -qF '<header class="family-topbar">' "$REAL_OUT/$p.html"
    grep -qF '<div class="family-footer">' "$REAL_OUT/$p.html"
  done
}

@test "build-docs-site: real site — every count in live.txt resolves to a positive number" {
  local d="$BATS_TEST_TMPDIR" keys=() k
  mapfile -t keys < <(awk '$1 == "count" { print $2 }' "$LIVE_TXT")
  [ "${#keys[@]}" -ge 1 ]
  : > "$d/probe.html"
  for k in "${keys[@]}"; do printf '%s={{count:%s}}\n' "$k" "$k" >> "$d/probe.html"; done
  run fp --settings "$LIVE_TXT" "$d/probe.html"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  for k in "${keys[@]}"; do
    grep -qE "^$k=[1-9][0-9]*\$" "$d/probe.html" || { echo "count $k: $(grep "^$k=" "$d/probe.html")" >&2; return 1; }
  done
}

@test "build-docs-site: real site — the family files publish byte-identical under static/" {
  need_pandoc
  local f
  for f in family.css family.js family-topbar.html family-footer.html; do
    cmp "$FAMILY_STATIC/$f" "$REAL_OUT/static/$f"
  done
}

@test "build-docs-site: family-check — placement, motion and hidden redden on a planted violation" {
  local d="$BATS_TEST_TMPDIR" top="$FAMILY_STATIC/family-topbar.html" foot="$FAMILY_STATIC/family-footer.html"
  # placement: inside <noscript>; inside a comment; twice; a plain page passes
  local tb fb
  tb="$(sed -n '2,$p' "$top")"
  fb="$(sed -n '2,$p' "$foot")"
  printf '<body>\n<noscript>\n%s\n</noscript>\n%s\n</body>\n' "$tb" "$fb" > "$d/pl1.html"
  fc_row 1 '<header class="family-topbar"> sits inside <noscript>' placement "$d/pl1.html" "$top" "$foot"
  printf '<body>\n<!--\n%s\n-->\n%s\n</body>\n' "$tb" "$fb" > "$d/pl2.html"
  fc_row 1 '<header class="family-topbar"> occurs 0 times' placement "$d/pl2.html" "$top" "$foot"
  printf '<body>\n<template>\n%s\n</template>\n%s\n</body>\n' "$fb" "$tb" > "$d/pl3.html"
  fc_row 1 '<div class="family-footer"> sits inside <template>' placement "$d/pl3.html" "$top" "$foot"
  printf '<body>\n%s\n%s\n%s\n</body>\n' "$tb" "$tb" "$fb" > "$d/pl4.html"
  fc_row 1 '<header class="family-topbar"> occurs 2 times' placement "$d/pl4.html" "$top" "$foot"
  printf '<body>\n%s\n<main>x</main>\n%s\n</body>\n' "$tb" "$fb" > "$d/pl5.html"
  fc_row 0 '' placement "$d/pl5.html" "$top" "$foot"
  # motion: an ungated transition; an ungated animation in style=; a mixed
  # selector list; gated rules and @keyframes bodies pass
  printf 'a { transition: color 1s; }\n' > "$d/m1.css"
  fc_row 1 "transition: color 1s in 'a' applies outside .family-motion" motion "$d/m1.css"
  printf '<p style="color: red; animation: spin 1s">x</p>\n' > "$d/m2.html"
  fc_row 1 'animation: spin 1s in style= on <p> applies outside .family-motion' motion "$d/m2.html"
  printf '.family-motion a, b { transition-duration: 1s; }\n' > "$d/m3.css"
  fc_row 1 'transition-duration: 1s in' motion "$d/m3.css"
  printf '<style>\nnav a { transition: color 1s; }\n</style>\n' > "$d/m4.html"
  fc_row 1 'm4.html:2: transition: color 1s' motion "$d/m4.html"
  printf '%s\n' '.family-motion a { transition: color 1s; }' 'html.family-motion .x { animation: spin 1s; }' \
    '@keyframes spin { from { transform: rotate(0); } to { transform: rotate(1turn); } }' \
    '@media (prefers-reduced-motion: no-preference) { .family-motion nav a { transition: color 1s; } }' > "$d/m5.css"
  fc_row 0 '' motion "$d/m5.css"
  # hidden: a hidden attribute; style= display:none; a top-level rule in a
  # linked copy of family.css; a rule under @media passes
  printf '<p hidden>x</p>\n' > "$d/h1.html"
  fc_row 1 'h1.html:1: <p> carries the hidden attribute' hidden "$d/h1.html"
  printf '<div style="display: none">x</div>\n' > "$d/h2.html"
  fc_row 1 'style= on <div> hides it' hidden "$d/h2.html"
  mkdir -p "$d/static"
  { cat "$FAMILY_STATIC/family.css"; printf '.family-footer { display: none; }\n'; } > "$d/static/family.css"
  printf '<link rel="stylesheet" href="static/family.css">\n<p>x</p>\n' > "$d/h3.html"
  fc_row 1 "'.family-footer' hides by default (display: none), outside any @media" hidden "$d/h3.html"
  printf '<style>\n@media (max-width: 1px) { .x { display: none; } }\n.y { visibility: hidden }\n</style>\n' > "$d/h4.html"
  fc_row 1 "'.y' hides by default (visibility: hidden)" hidden "$d/h4.html"
  cp "$FAMILY_STATIC/family.css" "$d/static/family.css"
  printf '<link rel="stylesheet" href="static/family.css">\n<style>\n@media (max-width: 1px) { .x { display: none; } }\n</style>\n<p>x</p>\n' > "$d/h5.html"
  fc_row 0 '' hidden "$d/h5.html"
}
