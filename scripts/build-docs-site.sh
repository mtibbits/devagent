#!/usr/bin/env bash
# scripts/build-docs-site.sh — #465.
#
# Renders the onboarding pages in docs-site/ to a static site for GitHub Pages.
# It publishes FROM the tracked markdown: there is no second, committed copy of
# the content that could drift from it (docs-site/README.md is the drift policy).
#
# What it builds: one <page>.html per docs-site/*.md EXCEPT README.md, which is
# the directory's maintenance policy and not a page. The page set is derived
# from the directory, never listed here.
#
# Usage: build-docs-site.sh [--src <dir>] [--out <dir>] [--blob-base <url>]
#   --src        markdown source dir        (default: <repo>/docs-site)
#   --out        output dir, must be absent or empty
#                                           (default: <repo>/build-docs-site,
#                                            which .gitignore's build-*/ covers)
#   --blob-base  where links that leave docs-site/ (../README.md) point
#                (default: https://github.com/mtibbits/devagent/blob/master/)
#
# Requires pandoc 3.x (CI installs the ubuntu-24.04 package). An older pandoc
# is refused up front: its failures would otherwise be reported against a page.
#
# Exit codes, distinct at the source so no caller parses prose:
#   0  built; last stdout line is  build-docs-site: built <N> pages -> <out>
#   2  usage
#   3  pandoc is not installed, or is older than 3.x (the message says which;
#      the remedy is the same, so the code is shared)
#   4  bad input: --src missing, no pages, no index.md, index.md's page list
#      names no page, --out not a directory, or --out not empty
#   5  a page failed to render (includes a link the filter cannot classify)
#   6  a rendered page links to a local file the build did not produce
# (--help prints this header: everything above the first non-comment line.)
set -euo pipefail

die() { local rc="$1"; shift; printf 'build-docs-site: %s\n' "$*" >&2; exit "$rc"; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo="$(cd "$here/.." && pwd -P)"
assets="$here/docs-site"
src="$repo/docs-site"
out="$repo/build-docs-site"
blob_base="https://github.com/mtibbits/devagent/blob/master/"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --src)       [ "$#" -ge 2 ] || die 2 "--src needs a value";       src="$2"; shift 2 ;;
    --out)       [ "$#" -ge 2 ] || die 2 "--out needs a value";       out="$2"; shift 2 ;;
    --blob-base) [ "$#" -ge 2 ] || die 2 "--blob-base needs a value"; blob_base="$2"; shift 2 ;;
    -h|--help)   awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           die 2 "unknown argument: $1 (see --help)" ;;
  esac
done

case "$blob_base" in
  *[\"\'\<\>\ ]*) die 2 "--blob-base must not contain quotes, angle brackets or spaces: $blob_base" ;;
esac
[ -d "$src" ] || die 4 "source dir not found: $src"

shopt -s nullglob
pages=()
for f in "$src"/*.md; do
  [ "$(basename "$f")" = "README.md" ] && continue
  pages+=("$(basename "$f" .md)")
done
[ "${#pages[@]}" -gt 0 ] || die 4 "no content pages (*.md other than README.md) in $src"
[ -f "$src/index.md" ]   || die 4 "no index.md in $src — the site would have no root page"

# First ATX H1 outside a code fence. Exits 1 when there is none.
page_title() {
  awk '/^(```|~~~)/ { fence = !fence; next }
       !fence && /^# / { sub(/^# +/, ""); print; found = 1; exit }
       END { if (!found) exit 1 }' "$1"
}

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

# Nav order: index first, then pages in the order index.md's own bullet list
# ("- [Install](./install.md) ...") names them, then any page that list omits
# (alphabetical, the glob's order). Prose links are ignored: the bullet list is
# the page's table of contents. The order is read from the content, so there is
# no second list to maintain.
#
# Everything down to the pandoc probe needs no pandoc, so its refusals are
# testable in a lane that has none.
order=(index)
contains() { local n="$1" x; shift; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }
while IFS= read -r linked; do
  if contains "$linked" "${pages[@]}" && ! contains "$linked" "${order[@]}"; then order+=("$linked"); fi
done < <(grep -oE '^- \[[^]]*\]\(\./[A-Za-z0-9_-]+\.md\)' "$src/index.md" | sed -E 's/^.*\]\(\.\///; s/\.md\)$//')
# A site with pages beyond index.md whose list matched NONE of them means the
# list changed shape ("* " bullets, a nested list, a moved section) and the
# grep above saw nothing. Falling through to alphabetical would publish a
# reordered nav with exit 0; refuse instead. (A page the list merely omits is
# fine and is appended below.)
if [ "${#pages[@]}" -gt 1 ] && [ "${#order[@]}" -eq 1 ]; then
  die 4 "index.md's page list names no page: expected top-level bullets like '- [Title](./page.md)' in $src/index.md"
fi
for p in "${pages[@]}"; do contains "$p" "${order[@]}" || order+=("$p"); done

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

declare -A title=() label=()
for p in "${pages[@]}"; do
  t="$(page_title "$src/$p.md")" || die 5 "no top-level '# ' heading in $src/$p.md"
  title[$p]="$t"
  label[$p]="$(printf '%s' "$t" | html_escape)"
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

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

  pandoc --from=gfm --to=html5 --standalone --no-highlight \
    --template="$assets/page.html" \
    --lua-filter="$assets/links.lua" \
    --include-before-body="$nav" \
    --metadata pagetitle="${title[$p]} | devAgent" \
    --metadata blob_base="$blob_base" \
    --metadata srcname="$p.md" \
    --output="$out/$p.html" "$src/$p.md" \
    || die 5 "pandoc failed on $src/$p.md"
done

# Independent count: what landed on disk, not what the loop believes it wrote.
built=("$out"/*.html)
[ "${#built[@]}" -eq "${#pages[@]}" ] \
  || die 5 "expected ${#pages[@]} pages in $out, found ${#built[@]}"

# Link closure over the RENDERED output, so a raw <a href> in the markdown
# (which the Lua filter never sees) is checked too.
bad=0
for html in "${built[@]}"; do
  while IFS= read -r href; do
    case "$href" in
      [A-Za-z]*:*|'#'*) continue ;;
    esac
    target="${href%%#*}"
    if [ ! -f "$out/$target" ]; then
      printf 'build-docs-site: %s links to %s, which the build did not produce\n' \
        "$(basename "$html")" "$target" >&2
      bad=1
    fi
  done < <(grep -oE 'href="[^"]*"' "$html" | sed -E 's/^href="//; s/"$//')
done
[ "$bad" -eq 0 ] || exit 6

printf 'build-docs-site: built %d pages -> %s\n' "${#built[@]}" "$out"
