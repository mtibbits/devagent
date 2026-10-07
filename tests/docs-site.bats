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
# (substring-proof; `state` must not ride on `mr-state`), every shellcheck
# version home names the CONTRIBUTING.md version (#678), and the audit §E
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
    # #465 r2 walkthrough finding A: the official marketplace is not configured on a
    # fresh install, so the superpowers command needs the marketplace-add line
    # DIRECTLY BEFORE it — adjacency, not just presence — and the shared comment
    # line above them carries the version the negative was measured on.
    grep -A1 -F 'claude plugin marketplace add anthropics/claude-plugins-official' "$f" \
      | grep -qF 'claude plugin install superpowers@claude-plugins-official'
    grep -qF '# Not configured on a fresh install' "$f"
    # Finding B: the install's userConfig notice is explained, both homes. The
    # sentence anchor cannot straddle a wrap; the option names are pinned over
    # whitespace-normalised text so the paragraph may wrap anywhere.
    grep -qF '`userConfig` options not yet set' "$f"
    tr -s '[:space:]' ' ' <"$f" | grep -qF 'options not yet set (`devdoc_root`, `default_project`)'
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
  for tool in bash python3 jq git gh glab curl tomli bats shellcheck; do
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

@test "docs-site: every live Claude Code version home carries the verified-against pin (#579)" {
  # Audit of the pin's homes AS A SET. The literal-pin test above proves the pin
  # is PRESENT in README and install.md; it cannot see a second live home that
  # still names an older version, and it never looked at the bug-report form.
  # The pin is read from README's verified-against sentence, then one sweep over
  # the user-facing roots requires every version token to equal it.
  #
  # RECORDED EXEMPTION: a line carrying a historical measurement marker
  # ("measured at/on", "unmeasured", "re-verified on") states what was observed
  # on a named past version and must NOT be re-stamped on a bump. CHANGELOG,
  # docs/specs, evals/ and tests/ are history or floor claims (">= X") and sit
  # outside the roots for the same reason.
  pin="$(grep -oE 'verified against Claude Code \*\*[0-9]+\.[0-9]+\.[0-9]+\*\*' "$PLUGIN_ROOT/README.md" \
          | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  [ -n "$pin" ] && [ "$(printf '%s\n' "$pin" | wc -l)" -eq 1 ]
  live=0; stale=""
  while IFS= read -r hit; do
    text="${hit#*:*:}"
    [[ "$text" =~ measured|re-verified ]] && continue
    while IFS= read -r v; do
      live=$((live + 1))
      [ "$v" = "$pin" ] || stale+="${hit}"$'\n'
    done < <(grep -oE '[0-9]+\.[0-9]+\.[0-9]{3}' <<<"$text")
  done < <(cd "$PLUGIN_ROOT" && grep -rnIE '[0-9]+\.[0-9]+\.[0-9]{3}' README.md docs-site .github/ISSUE_TEMPLATE)
  if [ -n "$stale" ]; then
    echo "live Claude Code version home disagrees with the README pin ($pin):" >&2
    printf '%s' "$stale" >&2
    return 1
  fi
  # Floor: README x2, install.md x2, the bug-report placeholder. An emptied
  # sweep must not pass vacuously.
  [ "$live" -ge 5 ]
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

@test "docs-site: every shellcheck version home names the CONTRIBUTING.md version (#678)" {
  # Audit of the shellcheck version's homes AS A SET: the user homes (README
  # Prerequisites, the install page's "You need:" list, config.toml.skel,
  # configuration.md), commands/analyze.md (the one home of the detail) and the
  # contributor homes. Every major-zero x.y.z token in a home must equal the version
  # CONTRIBUTING.md "What you need" names; major zero is what isolates
  # the shellcheck version from the Claude Code and bash versions in the same files.
  #
  # The user floor equals the contributor floor by the policy in the
  # scripts/analyze-shellcheck.sh header; a split of the two belongs there first.
  #
  # RECORDED EXEMPTION: a token in the stamp form `analyzer: shellcheck <version>`
  # is an example of a measured value, not a claim, and is not counted.
  local floor vals v h live=0 stale="" region text msg
  local -a homes
  local -A count
  floor="$(awk '/^## What you need$/{f=1; next} f && /^## /{exit} f' "$PLUGIN_ROOT/CONTRIBUTING.md" \
            | tr -s '[:space:]' ' ' \
            | grep -oE '`shellcheck` [0-9]+\.[0-9]+\.[0-9]+ or newer' \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')" || true
  # One assertion per line: a failing non-final member of an && list never trips errexit.
  [ -n "$floor" ] || {
    echo "CONTRIBUTING.md 'What you need' no longer says \`shellcheck\` X.Y.Z or newer:" >&2
    echo "re-point the floor extraction above" >&2
    return 1
  }
  [[ "$floor" != *$'\n'* ]]
  [[ "$floor" =~ ^0\. ]] || {
    echo "CONTRIBUTING.md names shellcheck $floor: a 1.x version needs a new token" >&2
    echo "shape here, because the sweep isolates shellcheck by major zero" >&2
    return 1
  }

  # Planted controls, through the sweep's own predicate. Each stamp control carries a
  # live sibling, so a dropped stamp token proves exemption, not a blind scan.
  [ "$(printf 'a analyzer: shellcheck 0.11.0 b 0.8.0' | _mz_live)" = 0.8.0 ]
  [ "$(printf 'analyzer:\n  shellcheck\n0.11.0 0.8.0\n' | _mz_live)" = 0.8.0 ]
  [ "$(printf 'x 0.8.0 10.9.0 1.0.0 2.1.223 pre-0.9.0' | _mz_live)" = $'0.8.0\n0.9.0' ]
  run _mz_live <"$SITE"
  [ "$status" -eq 2 ]

  homes=(README.md CONTRIBUTING.md docs-site/install.md docs-site/configuration.md
         templates/config.toml.skel commands/analyze.md .githooks/pre-push
         .github/workflows/shellcheck.yml)
  [ "${#homes[@]}" -eq 8 ]
  for h in "${homes[@]}"; do
    [ -f "$PLUGIN_ROOT/$h" ] || { echo "missing version home: $h" >&2; return 1; }
    vals="$(_mz_live <"$PLUGIN_ROOT/$h")"
    while IFS= read -r v; do
      [ -z "$v" ] || [ "$v" = "$floor" ] || stale+="$h: $v"$'\n'
    done <<<"$vals"
    count[$h]="$(grep -c . <<<"$vals" || true)"
    [ -n "${count[$h]}" ]
    live=$((live + count[$h]))
  done
  if [ -n "$stale" ]; then
    echo "shellcheck version home disagrees with CONTRIBUTING.md ($floor):" >&2
    printf '%s' "$stale" >&2
    echo "A token that is not a shellcheck version is a new exemption for this" >&2
    echo "test (see RECORDED EXEMPTION above); do not edit CONTRIBUTING.md for it" >&2
    return 1
  fi

  # Once per prescribed text in the homes that carry one statement each.
  for h in docs-site/configuration.md templates/config.toml.skel commands/analyze.md; do
    [ "${count[$h]}" -eq 1 ] || { echo "$h: ${count[$h]} live version tokens, want 1" >&2; return 1; }
  done

  # The user statements, scoped to their regions: a deleted user statement reddens
  # even with the contributor statements in the same file intact.
  [ "$(grep -c '^- Contributors additionally' "$SITE/install.md")" -eq 1 ]
  for region in \
      "$(awk '/^\*\*Prerequisites\.\*\*/{f=1} f && /^$/{exit} f' "$PLUGIN_ROOT/README.md")" \
      "$(awk '/You need:$/{f=1; next} /^- Contributors additionally/{exit} f' "$SITE/install.md")"; do
    [ -n "$region" ]
    vals="$(_mz_live <<<"$region")"
    [ "$(grep -c . <<<"$vals" || true)" -eq 1 ] || {
      echo "user statement region lacks exactly one shellcheck version: ${region:0:60}..." >&2
      return 1
    }
    [[ "$(tr -s '[:space:]' ' ' <<<"$region")" == *'analyze = "shellcheck"'* ]]
  done

  # commands/analyze.md carries the missing-binary message its producer dies with,
  # and the unattested consequence of an older version.
  msg="shellcheck not found on PATH"
  grep -qF "die \"$msg\"" "$PLUGIN_ROOT/scripts/analyze-shellcheck.sh" || {
    echo "the missing-binary die string moved in scripts/analyze-shellcheck.sh: re-point commands/analyze.md and this test" >&2
    return 1
  }
  text="$(tr -s '[:space:]' ' ' <"$PLUGIN_ROOT/commands/analyze.md")"
  [[ "$text" == *"$msg"* ]]
  [[ "$text" == *unattested* ]]

  # Floor: 9 tokens at 4e3ca74 (README 1, CONTRIBUTING 1, install.md 1,
  # pre-push 3, shellcheck.yml 3) plus one per user statement (README, install.md,
  # config.toml.skel, configuration.md, commands/analyze.md). The pins above already
  # catch a deleted user statement; this bound is the only guard on the contributor
  # tokens (README, install.md, pre-push, shellcheck.yml).
  [ "$live" -ge 14 ]
}
