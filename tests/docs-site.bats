#!/usr/bin/env bats
# #461: onboarding-site guard — six pages + README exist (array count, not
# ls|wc; Issue-314/32/151), every page's line-1 derive header names real
# existing sources with a non-empty list (the recorded content-drift
# strategy's machine-checkable half), page links are fixed per-page
# assertions (index → five siblings, each sibling → index; no scraped-link
# floor a single page can satisfy), install commands match README on BOTH
# sides, workflow.md has one row per numbered step, configuration.md names
# every backend verb backtick-anchored (substring-proof; `state` must not
# ride on `mr-state`), and the audit §E step-count typo ("21-step") never
# appears in a content page (precise no-match, status -eq 1; Issue-337).

load 'lib/bats-helpers'

REPO="${BATS_TEST_DIRNAME}/.."
SITE="$REPO/docs-site"
PAGES=(index.md install.md quickstart.md workflow.md configuration.md concurrency.md)

@test "docs-site: exactly six content pages plus README" {
  shopt -s nullglob
  files=("$SITE"/*.md)
  [ "${#files[@]}" -eq 7 ]
  for p in "${PAGES[@]}"; do [ -f "$SITE/$p" ]; done
  [ -f "$SITE/README.md" ]
}

@test "docs-site: every page's line-1 derive header names existing repo sources" {
  for p in "${PAGES[@]}"; do
    run head -1 "$SITE/$p"
    [[ "$output" == "<!-- derived-from: "*" -->" ]]
    srcs="${output#<!-- derived-from: }"; srcs="${srcs% -->}"
    [ -n "${srcs// /}" ]
    for s in $srcs; do [ -e "$REPO/$s" ]; done
  done
}

@test "docs-site: index links all five siblings; every other page links back" {
  for t in install quickstart workflow configuration concurrency; do
    grep -qF "](./$t.md" "$SITE/index.md"
  done
  for p in "${PAGES[@]:1}"; do
    grep -qF '](./index.md' "$SITE/$p"
  done
}

@test "docs-site: install commands are verbatim-shared with README" {
  for f in "$SITE/install.md" "$REPO/README.md"; do
    grep -qF 'claude plugin marketplace add mtibbits/devagent' "$f"
    grep -qF 'claude plugin install devagent@devagent' "$f"
    grep -qF 'claude plugin install superpowers@claude-plugins-official' "$f"
  done
}

@test "docs-site: install page says superpowers is recommended (not a hard dependency)" {
  grep -q 'superpowers' "$SITE/install.md"
  grep -qi 'recommended' "$SITE/install.md"
}

@test "docs-site: quickstart carries the auth prerequisite, doctor, and the loop entry" {
  grep -qF '/devagent:auth create' "$SITE/quickstart.md"
  grep -qF '/devagent:doctor' "$SITE/quickstart.md"
  grep -qF '/devagent:next --auto' "$SITE/quickstart.md"
}

@test "docs-site: workflow table has one row per numbered step (24)" {
  run grep -c '^| [0-9]' "$SITE/workflow.md"
  [ "$output" -eq 24 ]
}

@test "docs-site: configuration page names all ten backend verbs" {
  for v in fetch create transition state comment-list \
           push-branch create-mr mr-state mr-comments merge-mr; do
    grep -qF "\`$v\`" "$SITE/configuration.md"
  done
}

@test "docs-site: the audit step-count typo never appears in a content page" {
  for p in "${PAGES[@]}"; do
    run grep '21-step' "$SITE/$p"
    [ "$status" -eq 1 ]
  done
}
