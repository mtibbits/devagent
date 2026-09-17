#!/usr/bin/env bats
# #461: onboarding-site guard — six pages + README exist (array count, not
# ls|wc; Issue-314/32/151), every page's line-1 derive header names real
# existing sources with a non-empty list (the recorded content-drift
# strategy's machine-checkable half), page links derive from the PAGES
# array (index → each sibling, each sibling → index; no scraped-link floor
# a single page can satisfy), install commands and the verified Claude Code
# version match README on BOTH sides, workflow.md's step table derives from
# templates/checklist-standard.md (one row per template step, so a step
# insertion or rename reddens the page; the 24 pin keeps the derived count
# honest), configuration.md names every backend verb backtick-anchored
# (substring-proof; `state` must not ride on `mr-state`), and the audit §E
# step-count typo ("21-step") never appears in a content page (one
# multi-file grep; precise no-match, status -eq 1; Issue-337).

load 'lib/bats-helpers'

SITE="$PLUGIN_ROOT/docs-site"
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
    for s in $srcs; do [ -e "$PLUGIN_ROOT/$s" ]; done
  done
}

@test "docs-site: index links every sibling; every sibling links back" {
  for p in "${PAGES[@]:1}"; do
    grep -qF "](./$p" "$SITE/index.md"
    grep -qF '](./index.md' "$SITE/$p"
  done
}

@test "docs-site: install commands and version are verbatim-shared with README" {
  for f in "$SITE/install.md" "$PLUGIN_ROOT/README.md"; do
    grep -qF 'claude plugin marketplace add mtibbits/devagent' "$f"
    grep -qF 'claude plugin install devagent@devagent' "$f"
    grep -qF 'claude plugin install superpowers@claude-plugins-official' "$f"
    # Deliberate literal pin, not derive-from-README: a version bump must be a
    # CONSCIOUS edit here too, because it is the trigger for re-running the
    # plugin-root-grant-automatch smoke rung (#548).
    grep -qF '2.1.223' "$f"
    # #548 permissions-caveat parity: the load-bearing lines are byte-shared.
    grep -qF 'Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)' "$f"
    grep -qF 'Never widen to bare `Bash`' "$f"
  done
  # The headline count token is shared by index.md and README the same way
  # (review minor 18: previously pinned only via workflow.md's derived table).
  grep -qF '24-step workflow' "$SITE/index.md"
  grep -qF '24-step workflow' "$PLUGIN_ROOT/README.md"
}

@test "docs-site: install page carries the #541 posture delta token" {
  grep -qF 'recommended, never hard-required' "$SITE/install.md"
}

@test "docs-site: quickstart carries the auth prerequisite, doctor, and the loop entry" {
  grep -qF '/devagent:auth create' "$SITE/quickstart.md"
  grep -qF '/devagent:doctor' "$SITE/quickstart.md"
  grep -qF '/devagent:next --auto' "$SITE/quickstart.md"
}

@test "docs-site: workflow table derives from the checklist template steps" {
  count=0
  while read -r num cmd; do
    grep -qE "^\| ${num} *\| \`${cmd}\`" "$SITE/workflow.md"
    count=$((count + 1))
  done < <(sed -n 's/^- \[.\] *\([0-9]*\)\. \(.*\)$/\1 \2/p' "$PLUGIN_ROOT/templates/checklist-standard.md")
  [ "$count" -eq 24 ]
  run grep -c '^| [0-9]' "$SITE/workflow.md"
  [ "$output" -eq "$count" ]
}

@test "docs-site: configuration page names all ten backend verbs" {
  for v in fetch create transition state comment-list \
           push-branch create-mr mr-state mr-comments merge-mr; do
    grep -qF "\`$v\`" "$SITE/configuration.md"
  done
}

@test "docs-site: the audit step-count typo never appears in a content page" {
  run grep -l '21-step' "${PAGES[@]/#/$SITE/}"
  [ "$status" -eq 1 ]
}

@test "docs-site: the retired permanent-step-ID claim never appears in a page or README (#558)" {
  # #558 renumbered the steps into execution order, so "permanent IDs" is a
  # claim the code no longer backs. One multi-file grep; precise no-match.
  run grep -liE 'permanent(ly)?[ -]+numbered|permanent (step )?ids?' \
      "${PAGES[@]/#/$SITE/}" "$PLUGIN_ROOT/README.md"
  [ "$status" -eq 1 ]
  # The live claim is byte-shared by its three homes.
  for f in "$SITE/index.md" "$SITE/workflow.md" "$PLUGIN_ROOT/README.md"; do
    grep -qF 'numbered 0–23 in' "$f"
  done
}

@test "docs-site: install-page prerequisite and platform claims trace to README (#579)" {
  # install.md declares README as a derive source. Every toolchain binary the
  # page names must be named by README too, and the platform posture tokens
  # are shared, so neither side can drift alone.
  for tool in bash python3 jq git gh glab curl tomli; do
    grep -qF "\`$tool\`" "$SITE/install.md"
    grep -qF "\`$tool\`" "$PLUGIN_ROOT/README.md"
  done
  for f in "$SITE/install.md" "$PLUGIN_ROOT/README.md"; do
    grep -qF 'developed and tested on **Linux**' "$f"
    grep -qF 'macOS is currently untested' "$f"
    grep -qF 'readlink -f' "$f"
    run grep -liE 'repo(sitory)? is private|private-repo access' "$f"
    [ "$status" -eq 1 ]
  done
}

@test "docs-site: quickstart command lines are full-arity and gate-honest" {
  # Review findings 2-4 + preship class: a fenced /devagent:<verb> line must
  # satisfy the verb's own usage — init takes <project> (init.sh exits 2
  # bare with the shipped empty default_project seed; preship blocker), pull
  # takes <project> origin|fork <num> (commands/pull.md), file takes <slug>
  # (commands/file.md), capture takes text (skills/capture/SKILL.md). Pin
  # the runnable forms, forbid the bare regressions, and keep the
  # push_mr-gate warning present.
  grep -qF '/devagent:init myproj' "$SITE/quickstart.md"
  grep -qF '/devagent:pull myproj origin 42' "$SITE/quickstart.md"
  grep -qF '/devagent:file <slug>' "$SITE/quickstart.md"
  grep -qF 'permissions.push_mr' "$SITE/quickstart.md"
  run grep -E '^/devagent:(init|pull|file|capture) *$' "$SITE/quickstart.md"
  [ "$status" -eq 1 ]
}

@test "docs-site: the bash floor on the install page matches README and the potholes.sh guard (#611)" {
  readme="$(grep -oE 'bash`? \(?≥ [0-9]+\.[0-9]+' "$PLUGIN_ROOT/README.md" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  page="$(grep -oE 'bash`? ≥ [0-9]+\.[0-9]+' "$SITE/install.md" | grep -oE '[0-9]+\.[0-9]+' | sort -u)"
  guard="$(grep -oE 'bash >= [0-9]+\.[0-9]+' "$PLUGIN_ROOT/scripts/lib/potholes.sh" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  [ -n "$readme" ] && [ "$readme" = "$guard" ]
  [ "$(printf '%s\n' "$page" | wc -l)" -eq 1 ] && [ "$page" = "$readme" ]
  run grep -nE 'bash`? ≥ 4\b[^.]' "$SITE/install.md"; [ "$status" -eq 1 ]      # no stale "≥ 4" left
}
