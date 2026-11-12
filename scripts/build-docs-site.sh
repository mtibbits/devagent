#!/usr/bin/env bash
# scripts/build-docs-site.sh — #465, #995.
#
# Renders the onboarding pages in docs-site/ to a static site for GitHub Pages.
# It publishes FROM the tracked sources: there is no second, committed copy of
# the content that could drift from it (docs-site/README.md is the drift policy).
#
# What it builds, all derived from the directory and never listed here:
#   - one <page>.html per content page: docs-site/*.md (Markdown, rendered by
#     pandoc) and docs-site/*.html (hand-written: wrapped in the same template,
#     its body spliced in byte for byte), EXCEPT README.*, the directory's
#     maintenance policy and not a page;
#   - one moved-page stub <old>.html per data line of docs-site/moved.txt;
#   - the asset folders: docs-site/assets/ -> assets/ and
#     scripts/docs-site/static/ (or --static) -> static/, copied unchanged.
#
# Nav order: index first, then the pages the index's own top-level list names,
# in its order (index.md: "- [T](./p.md)" or "(./p.html)" bullets outside code
# fences; index.html: '<li><a href="p.html">' lines outside comments and
# <pre>/<code>/<script>/<style>/<template>/<textarea>), then the pages it omits
# in LC_ALL=C order of their base names, across both kinds.
#
# Usage: build-docs-site.sh [--src <dir>] [--out <dir>] [--blob-base <url>]
#                            [--static <dir>]
#   --src        source dir                 (default: <repo>/docs-site)
#   --out        output dir, must be absent or empty
#                                           (default: <repo>/build-docs-site,
#                                            which .gitignore's build-*/ covers)
#   --blob-base  where links that leave docs-site/ (../README.md) point
#                (default: https://github.com/mtibbits/devagent/blob/master/);
#                no quotes, angle brackets or spaces — page.html interpolates
#                it into an href unescaped, so the value is checked here
#   --static     the template's own static files, copied to <out>/static/
#                (default: <repo>/scripts/docs-site/static, skipped when
#                absent; a dir given here must exist)
#
# Requires pandoc 3.x (CI installs the ubuntu-24.04 package) and awk (the nav
# and title readers; gawk and mawk both work). An older pandoc is refused up
# front: its failures would otherwise be reported against a page.
#
# Exit codes, distinct at the source so no caller parses prose:
#   0  built; last stdout line is  build-docs-site: built <N> pages -> <out>
#      (<N> counts content pages; moved-page stubs are not pages)
#   2  usage
#   3  a required tool is missing or unusable: pandoc (absent, or older than
#      3.x), awk, or sort (the message names which)
#   4  bad input: --src or --static dir missing, no pages, no index page,
#      <x>.md and <x>.html both present, a README.html in --src, a hand-written
#      page without its derived-from header (or with a byte-order mark), a
#      malformed moved.txt line or one
#      naming a live page, the index's page list names no page or splits an
#      <li> from its <a href>, --out not a directory, or --out not empty
#   5  a page failed to render (includes a link or image the filter cannot
#      classify, and a hand-written page with no <h1> or with an entity in it
#      other than &amp; &lt; &gt; &quot; &#39;)
#   6  a rendered page links to a local file the build did not produce (by
#      href, src or srcset; stubs included), to a root-absolute path, or out of
#      the site with ..; or a moved.txt home is not a content page
# (--help prints this header: everything above the first non-comment line.)
set -euo pipefail

die() { local rc="$1"; shift; printf 'build-docs-site: %s\n' "$*" >&2; exit "$rc"; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo="$(cd "$here/.." && pwd -P)"
tmpl="$here/docs-site"
src="$repo/docs-site"
static_dir="$here/docs-site/static"
static_given=0
out="$repo/build-docs-site"
blob_base="https://github.com/mtibbits/devagent/blob/master/"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --src)       [ "$#" -ge 2 ] || die 2 "--src needs a value";       src="$2"; shift 2 ;;
    --out)       [ "$#" -ge 2 ] || die 2 "--out needs a value";       out="$2"; shift 2 ;;
    --blob-base) [ "$#" -ge 2 ] || die 2 "--blob-base needs a value"; blob_base="$2"; shift 2 ;;
    # -ge 2 alone would accept --static "", which names no directory.
    --static)    { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die 2 "--static needs a value"
                 static_dir="$2"; static_given=1; shift 2 ;;
    -h|--help)   awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           die 2 "unknown argument: $1 (see --help)" ;;
  esac
done

case "$blob_base" in
  *[\"\'\<\>\ ]*) die 2 "--blob-base must not contain quotes, angle brackets or spaces: $blob_base" ;;
esac
[ -d "$src" ] || die 4 "source dir not found: $src"
[ "$static_given" -eq 0 ] || [ -d "$static_dir" ] || die 4 "static dir not found: $static_dir"
# The nav derivation and the title readers are awk programs. Without awk they
# would read as "no list" and exit 4 blaming the page; name the tool instead.
command -v awk >/dev/null 2>&1 || die 3 "awk is not installed (the nav derivation needs it)"

shopt -s nullglob
# Discovery: every *.md and *.html in --src is a content page except README.*,
# which is docs-site's policy file (README.md is skipped, a README.html is
# refused). Base names sort with LC_ALL=C across both kinds, so a page the
# index's list omits lands alphabetically whatever its kind.
declare -A kind=()
names=()
for f in "$src"/*.md "$src"/*.html; do
  b="${f##*/}"
  case "$b" in
    README.md)   continue ;;
    README.html) die 4 "README.html: README is reserved for docs-site's policy file" ;;
  esac
  p="${b%.*}"
  [ -z "${kind[$p]:-}" ] || die 4 "both $p.md and $p.html exist in $src; keep one"
  kind[$p]="${b##*.}"
  names+=("$p")
done
pages=()
if [ "${#names[@]}" -gt 0 ]; then
  sorted="$(printf '%s\n' "${names[@]}" | LC_ALL=C sort)" \
    || die 3 "sort failed on the page names (the page order needs a working sort)"
  while IFS= read -r p; do pages+=("$p"); done <<< "$sorted"
fi
[ "${#pages[@]}" -gt 0 ] || die 4 "no content pages (*.md or *.html other than README.*) in $src"
[ -n "${kind[index]:-}" ] || die 4 "no index.md or index.html in $src; the site would have no root page"
index_file="index.${kind[index]}"

# A hand-written page's line 1 is the same provenance header a Markdown page
# carries. (In a variable: an unquoted < inside [[ ]] is an operator.)
derived_re='^<!-- derived-from: [^ ].* -->$'
for p in "${pages[@]}"; do
  [ "${kind[$p]}" = html ] || continue
  l=''
  IFS= read -r l < "$src/$p.html" || true
  case "$l" in
    $'\xEF\xBB\xBF'*) die 4 "$p.html: line 1 starts with a UTF-8 byte-order mark; save the file without one" ;;
  esac
  [[ $l =~ $derived_re ]] || die 4 "$p.html: line 1 must be a '<!-- derived-from: ... -->' header"
done

# A ``` or ~~~ line opens or closes a code fence. One rule, shared by the
# Markdown title reader and the Markdown nav reader (#840).
fence_awk='/^(```|~~~)/ { fence = !fence; next }'

# Non-content regions of a hand-written page, one rule for the HTML nav reader
# and the H1 reader: <!-- ... -->, and <pre>, <code>, <script>, <style>,
# <template>, <textarea> from the opening tag through its closer. Tag names
# compare case-blind; an opening tag is the name then ">", a space or a tab, so
# <pre never matches <preview. A region may span lines and ends at its closer;
# text after the closer is content. nc(line) returns the line minus region text.
# The H1 reader keeps inline <code> text (a heading may name a command), so it
# sets nc_re to the list without code.
nc_awk='
BEGIN { if (nc_re == "") nc_re = "<(pre|code|script|style|template|textarea)[> \t]" }
function nc(line,    out, l, i, t) {
  out = ""
  while (line != "") {
    l = tolower(line)
    if (nc_close != "") {
      i = index(l, nc_close)
      if (!i) return out
      line = substr(line, i + length(nc_close))
      nc_close = ""
      continue
    }
    i = index(l, "<!--")
    if (match(l, nc_re) && (!i || RSTART < i)) {
      t = substr(l, RSTART + 1, RLENGTH - 2)
      out = out substr(line, 1, RSTART - 1)
      line = substr(line, RSTART + RLENGTH - 1)
      nc_close = "</" t ">"
      continue
    }
    if (i) {
      out = out substr(line, 1, i - 1)
      line = substr(line, i + 4)
      nc_close = "-->"
      continue
    }
    return out line
  }
  return out
}
'

# First ATX H1 outside a code fence. Exits 1 when there is none.
page_title() {
  awk "$fence_awk"'
       !fence && /^# / { sub(/^# +/, ""); print; found = 1; exit }
       END { if (!found) exit 1 }' "$1"
}

# html_h1 <file> — the first <h1>...</h1> outside non-content regions (it may
# span lines; inline <code> text counts), <br> read as a space, other tags
# stripped, whitespace collapsed and trimmed. Entities are left for
# html_unescape. Exits 1 when there is none or it is empty.
html_h1() {
  awk -v nc_re='<(pre|script|style|template|textarea)[> \t]' "$nc_awk"'
       { buf = buf nc($0) "\n" }
       END {
         l = tolower(buf)
         if (!match(l, /<h1[> \t]/)) exit 1
         st = RSTART
         e = index(substr(l, st), "</h1>")
         if (!e) exit 1
         t = substr(buf, st, e + 4)
         gsub(/<[Bb][Rr]([ \t\/][^>]*)?>/, " ", t); gsub(/<[^>]*>/, "", t); gsub(/[ \t\r\n]+/, " ", t)
         sub(/^ /, "", t); sub(/ $/, "", t)
         if (t == "") exit 1
         print t
       }' "$1"
}

# nav_label <file> — the value of a <!-- nav-label: ... --> line in the header
# block (the run of <!-- ... --> lines from line 1), if any.
nav_label() {
  awk '!/^<!--.*-->$/ { exit }
       /^<!-- nav-label: .+ -->$/ { v = $0; sub(/^<!-- nav-label: /, "", v); sub(/ -->$/, "", v); print v; exit }' "$1"
}

# nav_entries <index> — the page names the index's own top-level list links,
# in order, one per line. POSIX awk only (gawk and mawk agree).
#   index.md:   "- [Title](./page.md)" or "(./page.html)" bullets outside code
#               fences.
#   index.html: '<li><a ... href="page.html">' lines outside non-content
#               regions (href double-quoted, <li> and <a> on one line). A lone
#               <li> whose next non-blank line opens an <a> with a page-shaped
#               href prints "!split <line>" and stops.
nav_entries() {
  case "$1" in
    *.html)
      awk "$nc_awk"'
           { s = nc($0); l = tolower(s) }
           lone {
             if (l ~ /^[ \t]*$/) next
             if (l ~ /^[ \t]*<a([ \t][^>]*)?[ \t]href="(\.\/)?[a-z0-9_-]+\.html"/) { print "!split " lone; exit }
             lone = 0
           }
           match(l, /^[ \t]*<li([ \t][^>]*)?>[ \t]*<a([ \t][^>]*)?[ \t]href="(\.\/)?[a-z0-9_-]+\.html"/) {
             m = substr(s, RSTART, RLENGTH)
             sub(/\.[Hh][Tt][Mm][Ll]"$/, "", m); sub(/^.*"/, "", m); sub(/^\.\//, "", m)
             print m
             next
           }
           l ~ /^[ \t]*<li([ \t][^>]*)?>[ \t]*$/ { lone = NR }' "$1" ;;
    *)
      awk "$fence_awk"'
           !fence && match($0, /^- \[[^]]*\]\(\.\/[A-Za-z0-9_-]+\.(md|html)\)/) {
             s = substr($0, RSTART, RLENGTH)
             sub(/^.*\]\(\.\//, "", s); sub(/\.(md|html)\)$/, "", s)
             print s
           }' "$1" ;;
  esac
}

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
# &amp; last, so "&amp;lt;" decodes once, to the literal text "&lt;".
html_unescape() { sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&#39;/'/g" -e 's/&amp;/\&/g'; }

# Nav order (rule in the header): prose links are ignored, since the index's
# list is its table of contents, and the order is read from the content, so
# there is no second list to maintain.
#
# Everything down to the pandoc probe needs no pandoc, so its refusals are
# testable in a lane that has none.
order=(index)
contains() { local n="$1" x; shift; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }
# A command substitution, not < <( ... ): a failing reader must stop the build
# here, not read as an empty list.
listed="$(nav_entries "$src/$index_file")" || die 4 "could not read the page list in $src/$index_file"
while IFS= read -r linked; do
  case "$linked" in
    '!split '*) die 4 "$index_file:${linked#!split }: put <li> and its <a href> on one line" ;;
  esac
  if contains "$linked" "${pages[@]}" && ! contains "$linked" "${order[@]}"; then order+=("$linked"); fi
done <<< "$listed"
# A site with pages beyond the index whose list matched NONE of them means the
# list changed shape ("* " bullets, a nested list, a moved section) and the
# reader above saw nothing. Falling through to alphabetical would publish a
# reordered nav with exit 0; refuse instead. (A page the list merely omits is
# fine and is appended below.)
if [ "${#pages[@]}" -gt 1 ] && [ "${#order[@]}" -eq 1 ]; then
  if [ "${kind[index]}" = md ]; then
    shape="top-level bullets like '- [Title](./page.md)'"
  else
    shape="lines like '<li><a href=\"page.html\">Title</a></li>' outside <pre>, <code> and comments"
  fi
  die 4 "$index_file's page list names no page: expected $shape in $src/$index_file"
fi
for p in "${pages[@]}"; do contains "$p" "${order[@]}" || order+=("$p"); done

# Moved-page stubs: <src>/moved.txt lists "<old-name> <new-home>" pairs (its
# own header documents the format). Each line becomes <old-name>.html, a stub
# linking to new-home. Read here, before the pandoc probe, so every refusal
# writes nothing. A <page>.html home must be a CONTENT page: not a missing page,
# not its own old name, not another line's old name (a stub to a stub).
moved_re='^([A-Za-z0-9_-]+)[[:blank:]]+([A-Za-z0-9_-]+\.html(#[A-Za-z0-9_-]*)?|https://[^[:space:]"'"'"'<>]+)[[:blank:]]*$'
declare -A moved=()
if [ -f "$src/moved.txt" ]; then
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in '#'*) continue ;; esac
    [ -n "${line//[[:space:]]/}" ] || continue
    [[ $line =~ $moved_re ]] || die 4 "moved.txt:$n: expected '<old-name> <new-home>'"
    old="${BASH_REMATCH[1]}" home="${BASH_REMATCH[2]}"
    [ -z "${kind[$old]:-}" ] || die 4 "moved.txt:$n: $old is still a content page (remove the line or the page)"
    [ -z "${moved[$old]:-}" ] || die 4 "moved.txt:$n: $old is listed twice"
    case "$home" in
      https://*) ;;
      *) hp="${home%%#*}"
         [ "${kind[${hp%.html}]:-}" ] || die 6 "moved.txt:$n: $hp is not a content page this build produces" ;;
    esac
    moved[$old]="$home"
  done < "$src/moved.txt"
fi

command -v pandoc >/dev/null 2>&1 \
  || die 3 "pandoc is not installed (Debian/Ubuntu: sudo apt-get install pandoc)"
# sed, not head: head closing the pipe early can SIGPIPE pandoc under pipefail.
pandoc_v="$(pandoc --version | sed -n '1p')"
[[ "$pandoc_v" =~ ^pandoc(\.exe)?\ ([0-9]+)\. ]] \
  || die 3 "cannot read a version from 'pandoc --version' (first line: $pandoc_v); need pandoc 3.x"
[ "${BASH_REMATCH[2]}" -ge 3 ] \
  || die 3 "pandoc is too old: found '$pandoc_v', need 3.x (the Lua filter and template rely on 3.x behaviour)"

if [ -e "$out" ]; then
  [ -d "$out" ] || die 4 "--out exists and is not a directory: $out"
  leftover=("$out"/* "$out"/.[!.]*)
  [ "${#leftover[@]}" -eq 0 ] \
    || die 4 "--out is not empty: $out (remove it, or pass another --out; this script never deletes)"
fi
mkdir -p "$out"

# Titles and nav labels. A Markdown page's come from its first '# ' heading. A
# hand-written page's title comes from its first <h1> (entities decoded once);
# its label is a nav-label header's value when it has one, else the title.
# Either way the label is escaped here, the <title> by pandoc.
declare -A title=() label=()
entity_re='(&[#A-Za-z0-9]+;)'
for p in "${pages[@]}"; do
  if [ "${kind[$p]}" = md ]; then
    t="$(page_title "$src/$p.md")" || die 5 "no top-level '# ' heading in $src/$p.md"
    lbl="$t"
  else
    t="$(html_h1 "$src/$p.html")" || die 5 "no <h1> in $src/$p.html"
    # html_unescape knows five entities; any other would reach the <title>
    # still encoded, so refuse it rather than publish "&mdash;" as text.
    e="${t//&amp;/}"; e="${e//&lt;/}"; e="${e//&gt;/}"; e="${e//&quot;/}"; e="${e//&#39;/}"
    [[ ! $e =~ $entity_re ]] \
      || die 5 "$src/$p.html: the <h1> uses ${BASH_REMATCH[1]}; write the character itself (only &amp; &lt; &gt; &quot; &#39; are decoded)"
    t="$(printf '%s\n' "$t" | html_unescape)"
    lbl="$(nav_label "$src/$p.html")"
    lbl="${lbl:-$t}"
  fi
  title[$p]="$t"
  label[$p]="$(printf '%s' "$lbl" | html_escape)"
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A hand-written page renders through the same pandoc call as a Markdown page,
# with a one-line marker as its input; the marker's line in the output is then
# replaced by the page's own bytes, so the frame is equal by construction and
# neither pandoc reader touches the body.
marker='<!--docs-site-body-->'
printf '%s\n' "$marker" > "$work/marker.md"
splice() {
  local frame="$work/$1.frame.html" page="$src/$1.html" hits at
  hits="$(grep -nxF -- "$marker" "$frame" || true)"
  case "$hits" in
    ''|*$'\n'*) die 5 "pandoc did not keep the body marker in $1.html" ;;
  esac
  at="${hits%%:*}"
  {
    head -n "$((at - 1))" "$frame"
    cat "$page"
    [ -z "$(tail -c 1 "$page")" ] || printf '\n'
    tail -n "+$((at + 1))" "$frame"
  } > "$out/$1.html"
}

for p in "${pages[@]}"; do
  nav="$work/$p.nav.html"
  {
    printf '<nav aria-label="Pages">\n<div class="navhead">devAgent docs</div>\n'
    for q in "${order[@]}"; do
      cur=''
      [ "$q" = "$p" ] && cur=' aria-current="page"'
      printf '<a href="%s.html"%s>%s</a>\n' "$q" "$cur" "${label[$q]}"
    done
    printf '</nav>\n'
  } > "$nav"

  if [ "${kind[$p]}" = md ]; then
    input="$src/$p.md" dest="$out/$p.html"
  else
    input="$work/marker.md" dest="$work/$p.frame.html"
  fi
  pandoc --from=gfm --to=html5 --standalone --no-highlight \
    --template="$tmpl/page.html" \
    --lua-filter="$tmpl/links.lua" \
    --include-before-body="$nav" \
    --metadata pagetitle="${title[$p]} | devAgent" \
    --metadata blob_base="$blob_base" \
    --metadata srcname="$p.${kind[$p]}" \
    --output="$dest" "$input" \
    || die 5 "pandoc failed on $src/$p.${kind[$p]}"
  [ "${kind[$p]}" = md ] || splice "$p"
done

# Stubs: static HTML that loads nothing and asks not to be indexed. They are in
# no nav and are not counted as pages.
for old in "${!moved[@]}"; do
  new="$(printf '%s' "${moved[$old]}" | html_escape)"
  printf '%s\n' \
    '<!DOCTYPE html>' \
    '<html lang="en">' \
    '<head>' \
    '<meta charset="utf-8">' \
    '<meta name="viewport" content="width=device-width, initial-scale=1">' \
    '<meta name="robots" content="noindex">' \
    '<title>Page moved | devAgent</title>' \
    '</head>' \
    '<body>' \
    "<p>This page has moved to <a href=\"$new\">$new</a>.</p>" \
    '</body>' \
    '</html>' > "$out/$old.html"
done
[ "${#moved[@]}" -eq 0 ] || printf 'build-docs-site: wrote %d moved-page stubs\n' "${#moved[@]}"

# The two asset folders, copied unchanged: the content side (<src>/assets/)
# and the template side (--static). Either may be absent.
if [ -d "$src/assets" ]; then cp -R "$src/assets" "$out/assets"; fi
if [ -d "$static_dir" ]; then cp -R "$static_dir" "$out/static"; fi

# Placeholder seam: child 2 defines the build-time tokens. It runs once per
# content page, after rendering and before the closure check. Identity today.
expand_placeholders() { :; }
for p in "${pages[@]}"; do expand_placeholders "$out/$p.html"; done

# Independent count: what landed on disk, not what the loops believe they
# wrote. Every top-level .html is a content page or a stub.
built=("$out"/*.html)
[ "${#built[@]}" -eq "$(( ${#pages[@]} + ${#moved[@]} ))" ] \
  || die 5 "expected ${#pages[@]} pages and ${#moved[@]} stubs in $out, found ${#built[@]} .html files"

# Link closure over the RENDERED output, so a raw <a href> or <img src> in a
# page (which the Lua filter never sees) is checked too. Attributes are read
# only inside tags (a tag may span lines): text, including code, reaches the
# output escaped, so an "href=" or "src=" written in a snippet has no literal <
# before it and is never read as a link. In a tag, every href, src and srcset
# is read: the attribute name case-blind, after whitespace (so data-src= is not
# read), its value double-quoted, single-quoted or bare; each srcset
# candidate's URL counts. A target with a scheme, or a pure
# #fragment, is skipped; ?query and #fragment are dropped from the rest. A
# root-absolute path (/x) and a path with a .. segment are refused even when
# they resolve on disk: under Pages' /devagent/ subpath both point elsewhere.
tag_re='<[A-Za-z][^<>"'"'"']*("[^"]*"[^<>"'"'"']*|'"'"'[^'"'"']*'"'"'[^<>"'"'"']*)*>'
attr_re='[[:space:]](href|src|srcset)=("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]>"'"'"']+)'
bad=0
for html in "${built[@]}"; do
  page="${html##*/}"
  attrs="$(tr '\n' ' ' < "$html" | grep -oE "$tag_re" | grep -oiE "$attr_re" || true)"
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    a="${a#"${a%%[![:space:]]*}"}"
    name="${a%%=*}"
    v="${a#*=}"
    case "$v" in
      \"*\") v="${v#\"}"; v="${v%\"}" ;;
      \'*\') v="${v#\'}"; v="${v%\'}" ;;
    esac
    cands=()
    if [ "${name,,}" = srcset ]; then
      IFS=',' read -ra parts <<< "$v"
      for c in "${parts[@]}"; do
        c="${c#"${c%%[![:space:]]*}"}"
        c="${c%%[[:space:]]*}"
        if [ -n "$c" ]; then cands+=("$c"); fi
      done
    else
      cands=("$v")
    fi
    for target in "${cands[@]}"; do
      case "$target" in
        [A-Za-z]*:*|'#'*) continue ;;
      esac
      target="${target%%#*}"
      target="${target%%\?*}"
      case "$target" in
        /*)
          printf 'build-docs-site: %s uses a root-absolute path %s; use a relative path (the site is served under a subpath)\n' \
            "$page" "$target" >&2
          bad=1; continue ;;
      esac
      case "/$target/" in
        */../*)
          printf 'build-docs-site: %s climbs out of the site with %s\n' "$page" "$target" >&2
          bad=1; continue ;;
      esac
      if [ ! -f "$out/$target" ]; then
        printf 'build-docs-site: %s links to %s, which the build did not produce\n' \
          "$page" "$target" >&2
        bad=1
      fi
    done
  done <<< "$attrs"
done
[ "$bad" -eq 0 ] || exit 6

printf 'build-docs-site: built %d pages -> %s\n' "${#pages[@]}" "$out"
