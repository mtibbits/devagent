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
# Every fact has a MUTATION leg below: it copies the subject to a temp dir,
# shows the unbroken copy passes (the control), breaks the fact, proves the edit
# took, and expects the SAME function to return exactly 1 with a reason.
#
# The page set is read, never listed here: the ONE page list is index.md's own
# top-level list (the build's nav source; docs-site/README.md). The content
# pages are the directory's *.md/*.html minus README.*, and check_page_set
# holds them equal to index plus that list.
#
# Classification of the 16 tests this file held before #997, as fact (kept) or
# wording (dropped, with its reason): the #997 MR body. The pins a later child
# owns are the lib's PAGE PINS block.

load 'lib/bats-helpers'
load 'lib/docs-site-checks'

WEB="$PLUGIN_ROOT/docs-site"
# The reference documents' paths, one per line (no tests/ line names the site
# variable and a reference document together).
CONFIG_REL=docs/configuration.md
CONFIG_DOC="$PLUGIN_ROOT/$CONFIG_REL"
TEMPLATE="$PLUGIN_ROOT/templates/checklist-standard.md"
README="$PLUGIN_ROOT/README.md"

# content_pages — every content page of the site, full paths.
content_pages() {
  local f
  for f in "$WEB"/*.md "$WEB"/*.html; do
    [ -e "$f" ] || continue
    case "${f##*/}" in README.*) continue ;; esac
    printf '%s\n' "$f"
  done
}

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
  ! grep -qF -- "$lit" "$f"
}

# plant <file> <line> — append a line; fail if it is not there after.
plant() {
  printf '%s\n' "$2" >>"$1"
  grep -qF -- "$2" "$1"
}

# fresh <src> [name] — a pristine temp copy of <src>; prints its path.
fresh() {
  local dst="$BATS_TEST_TMPDIR/${2:-${1##*/}}"
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

# ---------------------------------------------------------------------------
# Facts
# ---------------------------------------------------------------------------

@test "docs-site: the content pages are exactly index plus index.md's list, and README is present" {
  holds check_page_set "$WEB"
}

@test "docs-site: the reference documents keep their 1.0 site URLs as stubs to the forge" {
  holds check_reference_stubs "$WEB" "$PLUGIN_ROOT" "${REFERENCE_DOCS[@]}"
}

@test "docs-site: the reference page links the four reference documents" {
  holds check_reference_links "$WEB/reference.md" "${REFERENCE_DOCS[@]}" \
    docs/specs/2026-05-19-devagent-plugin-design.md docs/requirements.md
}

@test "docs-site: every content page's line-1 derive header names existing sources" {
  local -a pages
  mapfile -t pages < <(content_pages; reference_docs)
  [ "${#pages[@]}" -ge 2 ]
  holds check_derived_from "$PLUGIN_ROOT" "${pages[@]}"
}

@test "docs-site: the install commands, notice, version and grant are shared with README" {
  local f
  for f in "$WEB/install.md" "$README"; do
    holds check_install_block "$f"
    holds check_userconfig_notice "$f"
    holds check_verified_version "$f"
    holds check_permission_grant "$f"
  done
}

@test "docs-site: the headline step count is derived from the template, in README and the index" {
  holds check_step_headline "$TEMPLATE" "$README"
  holds check_step_headline "$TEMPLATE" "$WEB/index.md"
}

@test "docs-site: the workflow table derives from the checklist template steps" {
  holds check_step_table "$TEMPLATE" "$WEB/workflow.md"
}

@test "docs-site: the configuration reference names every backend verb" {
  holds check_backend_verbs "$CONFIG_DOC"
}

@test "docs-site: the audit step-count typo never appears in a page or reference document" {
  local -a pages
  mapfile -t pages < <(content_pages; reference_docs)
  holds check_absent -F '21-step' "${pages[@]}"
}

@test "docs-site: the retired permanent-step-ID claim never appears; the live claim is derived (#558)" {
  local -a pages
  local f
  mapfile -t pages < <(content_pages; reference_docs)
  holds check_absent -iE 'permanent(ly)?[ -]+numbered|permanent (step )?ids?' "${pages[@]}" "$README"
  for f in "$WEB/index.md" "$WEB/workflow.md" "$README"; do
    holds check_numbering_claim "$TEMPLATE" "$f"
  done
}

@test "docs-site: install-page prerequisite and platform claims trace to README (#579)" {
  holds check_prereqs_trace "$WEB/install.md" "$README"
  holds check_platform_tokens "$WEB/install.md"
  holds check_platform_tokens "$README"
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
  rm "$d/index.md"; printf '<ul><li><a href="a.html">A</a></li></ul>\n' >"$d/index.html"
  run site_pages "$d"
  [ "$status" -eq 2 ]
  [[ "$output" == *"#998"* ]]
  rm "$d/index.html"
  run site_pages "$d"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no index.md"* ]]
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
  cp -r "$WEB/." "$d/"; rm "$d/README.md"
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
  p="$(fresh "$PLUGIN_ROOT/${REFERENCE_DOCS[1]}")"
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
  drop "$d/moved.txt" "concurrency $BLOB_BASE${REFERENCE_DOCS[1]}"
  breaks "concurrency $BLOB_BASE" check_reference_stubs "$d" "$PLUGIN_ROOT" "${REFERENCE_DOCS[@]}"
  # A stub whose forge home is gone.
  cp "$WEB/moved.txt" "$d/"
  plant "$d/moved.txt" "gone ${BLOB_BASE}docs/nope.md"
  breaks 'docs/nope.md does not exist' check_reference_stubs "$d" "$PLUGIN_ROOT" "${REFERENCE_DOCS[@]}"
  # The same line, with the file present in a temp root, holds.
  t="$(temp_root "${REFERENCE_DOCS[@]}")"
  mkdir -p "$t/docs"; : >"$t/docs/nope.md"
  holds check_reference_stubs "$d" "$t" "${REFERENCE_DOCS[@]}"
}

@test "mutation: reference links" {
  local f docs=("${REFERENCE_DOCS[@]}" docs/specs/2026-05-19-devagent-plugin-design.md docs/requirements.md)
  f="$(fresh "$WEB/reference.md")"
  holds check_reference_links "$f" "${docs[@]}"
  edit "$f" '](../docs/requirements.md)' '](https://example.com/requirements)'
  breaks 'docs/requirements.md' check_reference_links "$f" "${docs[@]}"
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
  edit "$f" '2.1.223' '2.1.224'
  breaks '2.1.223' check_verified_version "$f"
}

@test "mutation: permission grant" {
  local f
  f="$(fresh "$WEB/install.md")"
  holds check_permission_grant "$f"
  edit "$f" 'Never widen to bare `Bash`' 'Never widen it'
  breaks 'Never widen' check_permission_grant "$f"
  f="$(fresh "$WEB/install.md")"
  edit "$f" ', Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)' ''
  breaks 'two-form' check_permission_grant "$f"
}

@test "mutation: step headline" {
  local f
  f="$(fresh "$README")"
  holds check_step_headline "$TEMPLATE" "$f"
  edit "$f" '25-step workflow' '24-step workflow'
  breaks '25-step workflow' check_step_headline "$TEMPLATE" "$f"
}

@test "mutation: numbering claim" {
  local f
  f="$(fresh "$WEB/workflow.md")"
  holds check_numbering_claim "$TEMPLATE" "$f"
  edit "$f" 'numbered 0–24 in' 'numbered 0–23 in'
  breaks 'numbered 0–24 in' check_numbering_claim "$TEMPLATE" "$f"
}

@test "mutation: step table" {
  local f
  f="$(fresh "$WEB/workflow.md")"
  holds check_step_table "$TEMPLATE" "$f"
  drop "$f" '| 13 | `analyze`'
  breaks 'step 13' check_step_table "$TEMPLATE" "$f"
  f="$(fresh "$WEB/workflow.md")"
  edit "$f" '| 13 | `analyze`' '| 13 | `analyse`'
  breaks 'step 13' check_step_table "$TEMPLATE" "$f"
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
  f="$(fresh "$WEB/index.md")"
  holds check_absent -iE "$re" "$f"
  plant "$f" 'Steps keep permanent step IDs.'
  breaks 'permanent' check_absent -iE "$re" "$f"
}

@test "mutation: prerequisites trace to README" {
  local page readme
  page="$(fresh "$WEB/install.md")"; readme="$(fresh "$README")"
  holds check_prereqs_trace "$page" "$readme"
  edit "$readme" '`jq`' 'jq'
  breaks '`jq`' check_prereqs_trace "$page" "$readme"
  readme="$(fresh "$README")"
  plant "$page" 'No private-repo access is needed.'
  breaks 'private' check_prereqs_trace "$page" "$readme"
  # A page tool README lacks.
  page="$(fresh "$WEB/install.md")"
  sed -i 's/^- Contributors additionally/- **`zsh`** for the prompt.\n&/' "$page"
  grep -qF -- '- **`zsh`**' "$page"
  breaks '`zsh`' check_prereqs_trace "$page" "$readme"
  # A tool the page no longer names.
  page="$(fresh "$WEB/install.md")"
  edit "$page" '**`jq`**' '**jq**'
  breaks '`jq`' check_prereqs_trace "$page" "$readme"
}

@test "mutation: platform tokens" {
  local f
  f="$(fresh "$WEB/install.md")"
  holds check_platform_tokens "$f"
  edit "$f" 'macOS is currently untested' 'macOS may work'
  breaks 'macOS' check_platform_tokens "$f"
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
  local f guard="$PLUGIN_ROOT/scripts/lib/potholes.sh"
  f="$(fresh "$WEB/install.md")"
  holds check_bash_floor "$f" "$README" "$guard"
  edit "$f" '≥ 4.4' '≥ 4.3'
  breaks 'page 4.3' check_bash_floor "$f" "$README" "$guard"
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
}
