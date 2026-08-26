#!/usr/bin/env bats
# #136: the plugin's shipped templates and skills must be PROJECT-NEUTRAL — no
# VOLK-specific criteria injected into a non-VOLK project. VOLK's specifics live
# in its devdoc override (registry L2), not the plugin defaults.

REPO="${BATS_TEST_DIRNAME}/.."

# _class_assign <file> <thinking-list> <checking-list> — #583. Print one line per
# enumeration-shaped step number attributed to the WRONG class
# (`BAD <file>:<line> <n>-><class>`) and one per class member never seen under
# its own anchor (`MISS <file> <class>-<n>`); print nothing when the home is
# clean. Attribution = the nearest class anchor (the body key
# `implementation-model`, or the class NAMES thinking/checking in any case)
# within the preceding three lines, up to the occurrence. Enumeration-shaped = a
# run of >= 2 class numbers separated by space or slash, or a canonical
# `<num> <name>` pair — the pairs are DERIVED from templates/checklist-standard.md
# (register: Issue-439), so a renamed step or a mis-paired name is not an
# enumeration and surfaces as MISS instead of silently passing; anything else
# (a per-step TOML key `"9" = …`, `#561`, `rc 2`) is not an enumeration either.
# ONE grep per file; the rest is bash builtins (register: Issue-566 — the
# per-line grep form measured 6.3 s for the 11 homes, this one ~1 s).
_class_assign() {
  local f="$1" thinking="$2" checking="$3"
  local union="(${thinking// /|}|${checking// /|})" pairs="" num name
  while read -r num name; do
    [[ " $thinking $checking " == *" $num "* ]] || continue
    pairs+="${pairs:+|}$num ?\\(?$name"
  done < <(sed -n 's/^- \[.\] *\([0-9]*\)\. *\([A-Za-z][A-Za-z0-9_-]*\).*$/\1 \2/p' \
             "$REPO/templates/checklist-standard.md")
  local -a L; mapfile -t L < "$f"
  local -A seen=()
  local hit i occ pre win w s t best cls list tok from cnt
  while IFS= read -r hit; do                       # "<lineno>:<match>"
    i=$(( ${hit%%:*} - 1 )); occ="${hit#*:}"
    pre="${L[i]%%"$occ"*}"
    from=$(( i >= 3 ? i - 3 : 0 )); cnt=$(( i - from ))
    printf -v win '%s\n' "${L[@]:from:cnt}"; win+="$pre"
    w="${win,,}"; cls=; best=-1
    for t in implementation-model thinking checking; do   # nearest anchor = latest last-occurrence
      s="${w##*"$t"}"; [ "$s" != "$w" ] || continue
      (( ${#w} - ${#s} > best )) && { best=$(( ${#w} - ${#s} )); cls=$t; }
    done
    case "$cls" in
      implementation-model|thinking) cls=thinking; list="$thinking" ;;
      checking)                      list="$checking" ;;
      *) continue ;;                                # no anchor in the window: unattributed prose
    esac
    for tok in ${occ//\// }; do
      [[ " $thinking $checking " == *" $tok "* ]] || continue
      seen["$cls-$tok"]=1
      [[ " $list " == *" $tok "* ]] || echo "BAD $f:$((i + 1)) $tok->$cls"
    done
  done < <(grep -noE "\b${union}\b([ /]${union}\b)+|\b(${pairs})\b" "$f")
  for tok in $thinking; do [ -n "${seen[thinking-$tok]:-}" ] || echo "MISS $f thinking-$tok"; done
  for tok in $checking; do [ -n "${seen[checking-$tok]:-}" ] || echo "MISS $f checking-$tok"; done
}

@test "no VOLK-specific token in the plugin templates (#136)" {
  # Case-insensitive VOLK project markers that must NOT ship in the defaults.
  run grep -rniE 'volk|lgpl|\bdsp\b|\bsdr\b|gnu ?radio|plot_pr_evidence|VOLK_CONFIGPATH|num_points|\bsimd\b|dechirp|\bneon\b|kernel|warmup|vector length' "$REPO/templates"
  # #337: rc-precise. grep rc 1 = clean no-match; rc 2 = error (dir renamed/
  # unreadable) which `-ne 0` would false-pass, blinding the canary.
  [ "$status" -eq 1 ] || { echo "VOLK token in templates/ (or grep error):" >&2; echo "$output" >&2; return 1; }
}

@test "no VOLK-specific token in the shipped skills (#136)" {
  run grep -rniE 'volk|lgpl|\bdsp\b|\bsdr\b|gnu ?radio|plot_pr_evidence|VOLK_CONFIGPATH|src/devDoc/volk|num_points|\bsimd\b|dechirp|\bneon\b|kernel|warmup|vector length' "$REPO/skills"
  # #337: rc-precise (see the templates canary above).
  [ "$status" -eq 1 ] || { echo "VOLK token in skills/ (or grep error):" >&2; echo "$output" >&2; return 1; }
}

@test "no VOLK-specific token in the shipped command docs (#136/#427)" {
  # #427: commands/ is where residual identity text actually survived (ship.md
  # named gnuradio/volk, auth.md examples used volk) because the #340 canary
  # scanned only templates/ + skills/. Widen the scan to the command docs so an
  # identity regression in a shipped command fails CI. (cite-hygiene.bats already
  # scans commands/ but as a citation-PROSE canary (#342) — a different invariant.)
  run grep -rniE 'volk|lgpl|\bdsp\b|\bsdr\b|gnu ?radio|plot_pr_evidence|VOLK_CONFIGPATH|src/devDoc/volk|num_points|\bsimd\b|dechirp|\bneon\b|kernel|warmup|vector length' "$REPO/commands"
  # #337: rc-precise (see the templates canary above).
  [ "$status" -eq 1 ] || { echo "VOLK token in commands/ (or grep error):" >&2; echo "$output" >&2; return 1; }
}

@test "the redteam_issue 16-dimension structure survives genericization (#136/#134/#443)" {
  # Genericizing the prose must not remove the dimensions #134 depends on.
  # #443: the monolith was split — the "Sixteen Dimensions" intro lives in
  # _shared, and the 16 dimension bodies are partitioned across the 3 tier files
  # (light 1,3,5 / standard 2,4,6,7,12,15 / full 8-11,13,14,16). Assert the intro
  # survives in _shared and the COMPOSED dimension count across the tier files is 16.
  grep -q '## The Sixteen Dimensions' "$REPO/templates/redteam_issue_shared.md"
  # Summed with awk, not `paste -sd+ | bc`: bc is NOT a documented prerequisite
  # (docs-site/install.md lists bash, python3, jq, git + bats/shellcheck) and does
  # not ship with Git for Windows, so the bc form made this the one test that
  # could not run on a stock Windows checkout. awk is already required and used
  # throughout the suite.
  local n; n="$(grep -hcE '^### [0-9]+\. ' \
      "$REPO/templates/redteam_issue_light.md" \
      "$REPO/templates/redteam_issue_standard.md" \
      "$REPO/templates/redteam_issue_full.md" | awk '{s+=$1} END{print s+0}')"
  [ "$n" -eq 16 ] || { echo "composed dimension count = $n (expected 16)" >&2; return 1; }
}

@test "no phantom /devagent:run-suite or :born-red in shipped invocation messages (#412)" {
  # Neither has a commands/*.md or a skills-registry entry; the real invocation is
  # the bash script (run-suite.sh / born-red.sh). Grep shipped source only — NOT
  # tests/, which necessarily names the forbidden strings here.
  run grep -rnE '/devagent:(run-suite|born-red)' \
      "$REPO/scripts" "$REPO/commands" "$REPO/skills" "$REPO/templates"
  # rc-precise (#337): rc 1 = clean no-match; rc 2 = grep error must not false-pass.
  [ "$status" -eq 1 ] || { echo "phantom invocation (or grep error):" >&2; echo "$output" >&2; return 1; }
}

@test "the real /devagent:draftmr reference survives in mr_template (#412)" {
  grep -q '/devagent:draftmr' "$REPO/templates/mr_template.md"
}

@test "#561: every issue/epic template boilerplate names BOTH model keys" {
  # Sweep guard (register: Issue-458 — a contract enumerated in N files needs ONE
  # sweep over all N homes, extended in the same change that adds a home). The
  # subject set is DERIVED, not listed: any template carrying the `## Workflow
  # flags` boilerplate must document both keys, so a seventh template added later
  # cannot ship divergent.
  local f n=0 missing=()
  for f in "$REPO"/templates/*.md; do
    grep -q 'Optional per-issue `## Workflow flags`' "$f" || continue
    n=$((n + 1))
    grep -q 'implementation-model' "$f" && grep -q 'checking-model' "$f" \
      || missing+=("$(basename "$f")")
  done
  # assert the DENOMINATOR too: a glob that stops selecting its subjects passes
  # silently (register: Issue-439), so pin the count of boilerplate carriers.
  [ "$n" -eq 6 ] || { echo "boilerplate carriers = $n (expected 6)" >&2; return 1; }
  [ "${#missing[@]}" -eq 0 ] || { echo "missing model keys: ${missing[*]}" >&2; return 1; }
}

@test "#561: the marker prose in config.toml.skel documents the keyed form" {
  # config.toml.skel is the file every new project copies its config from, and it
  # previously said the marker holds "ONE tier token" pinning "the CHECKING-class
  # steps" with "Non-checking steps ignore the marker" — all false after #561.
  # This home was missed by the round-1 plan's enumerated list even though its own
  # derivation command (grep -rn devagent-step-models) finds it.
  grep -q 'checking: fable' "$REPO/templates/config.toml.skel"
  grep -q 'thinking: sonnet' "$REPO/templates/config.toml.skel"
  run grep -c 'Non-checking$' "$REPO/templates/config.toml.skel"
  [ "$status" -eq 1 ]
}

@test "#561/#583: prose step numbers are ASSIGNED to the right class in every home, not merely present as a union" {
  # #561 shipped this as a UNION check and wrote its blind spot into the test: a
  # home that SWAPPED the two lists — claiming `implementation-model` steers the
  # checking numbers — passed, because the union is identical (found by the #561
  # step-16 red team). #583 closes it with per-class attribution (the rule lives
  # in _class_assign's header). LIMITS, stated beside what is asserted (register:
  # Issue-558):
  #  - an enumeration with no anchor in its three-line window is IGNORED, so a
  #    home that enumerates farther from its key surfaces as MISS, never as a pass;
  #  - the class NAMES are anchors (config.toml.skel enumerates by name), so the
  #    ordinary word thinking/checking within three lines above an enumeration
  #    counts too — a collision reddens and names the line;
  #  - a `<num> <name>` pair counts only as the canonical pairing from
  #    templates/checklist-standard.md; a mis-paired name surfaces as MISS.
  # Both halves are mutation-tested below (register: Issue-151).
  local thinking checking
  thinking="$(sed -n 's/.*case " \(2 9[0-9 ]*\)" in.*/\1/p' "$REPO/scripts/lib/config.sh" | head -1)"
  checking="$(sed -n 's/.*case " \(5 15[0-9 ]*\)" in.*/\1/p' "$REPO/scripts/lib/config.sh" | head -1)"
  thinking="$(echo $thinking)"; checking="$(echo $checking)"
  # guard the DERIVATION itself: an empty capture would make every check below
  # vacuously pass (register: Issue-151, mutation-test the guard)
  [ "$thinking" = "2 9 10 11 14" ] || { echo "thinking map drifted or capture failed: '$thinking'" >&2; return 1; }
  [ "$checking" = "5 15 16 17" ]   || { echo "checking map drifted or capture failed: '$checking'" >&2; return 1; }

  # Subject set: files that ENUMERATE the class mapping — they name `draftmr`
  # (step 14, the thinking list's tail) — not files that merely mention the keys
  # (e.g. docs/draft-dispatch-contract.md, which is about step 2 alone).
  local f n=0 out bad=()
  while IFS= read -r f; do
    grep -q 'draftmr' "$f" || continue
    n=$((n + 1))
    out="$(_class_assign "$f" "$thinking" "$checking")"
    [ -z "$out" ] || bad+=("$out")
  done < <(grep -rl 'implementation-model' "$REPO/docs" "$REPO/commands" "$REPO/templates" "$REPO/scripts" "$REPO/CHANGELOG.md" 2>/dev/null)
  # Pin the DENOMINATOR: a grep that stops selecting its subjects passes silently
  # (register: Issue-439). 11 = 6 issue/epic templates + config.toml.skel + spec
  # + commands/pull.md + flags.sh + CHANGELOG.md.
  [ "$n" -eq 11 ] || { echo "class-enumerating homes = $n (expected 11) — did a home lose its enumeration, or gain one?" >&2; return 1; }
  [ "${#bad[@]}" -eq 0 ] || { printf 'class assignment drift:\n%s\n' "${bad[@]}" >&2; return 1; }

  # Mutation half: a swapped list must RED in each prose shape the homes use —
  # the template continuation form, the skel single-line form, the table form.
  local m="$BATS_TEST_TMPDIR/mut"; mkdir -p "$m"
  printf '%s\n' \
    '       - implementation-model: <token>' \
    '                            (#561; steers the THINKING class — steps 5 improve,' \
    '                             15 review, 16 redmr, 17 preship.' \
    '       - checking-model: <token>' \
    '                            (#561; steers the CHECKING class — steps 2 draft,' \
    '                             9 implement, 10 quality, 11 document, 14 draftmr.' > "$m/template.md"
  printf '%s\n' '# Classes: thinking = steps 5 15 16 17, checking = 2 9 10 11 14, else default;' > "$m/skel.toml"
  printf '%s\n' \
    '| `implementation-model: <token>` | *thinking* | 5 improve · 15 review · 16 redmr · 17 preship |' \
    '| `checking-model: <token>` | *checking* | 2 draft · 9 implement · 10 quality · 11 document · 14 draftmr |' > "$m/table.md"
  local union_re="(${thinking// /|}|${checking// /|})" n_union=$(( $(wc -w <<<"$thinking $checking") ))
  for f in "$m/template.md" "$m/skel.toml" "$m/table.md"; do
    out="$(_class_assign "$f" "$thinking" "$checking")"
    [[ "$out" == *BAD* ]] || { echo "guard is blind to a swapped list in $(basename "$f")" >&2; return 1; }
    # ...and the union check this replaces WOULD have passed it: every class
    # number is still present (the exact blind spot #561 recorded).
    [ "$(grep -oE "\b${union_re}\b" "$f" | sort -n -u | grep -c .)" -eq "$n_union" ]
  done
  # MISS half (improve bug 5): a member absent under its own anchor, and an
  # enumeration too far below its anchor to be attributed — the blind spot the
  # LIMITS comment describes must surface as MISS, never as a pass.
  printf '%s\n' \
    '       - implementation-model: <token>' \
    '                            (#561; steers the THINKING class — steps 2 draft,' \
    '                             9 implement, 10 quality, 11 document.' \
    '       - checking-model: <token>' \
    '                            (#561; steers the CHECKING class — steps 5 improve,' \
    '                             15 review, 16 redmr, 17 preship.' > "$m/short.md"
  out="$(_class_assign "$m/short.md" "$thinking" "$checking")"
  [[ "$out" == *"MISS "*"thinking-14"* ]] || { echo "guard is blind to a missing member: [$out]" >&2; return 1; }
  [[ "$out" != *BAD* ]] || { echo "a merely-short list must not read as a swap: [$out]" >&2; return 1; }
  printf '%s\n' '- implementation-model: <token>' '' '' '' \
    '2 draft, 9 implement, 10 quality, 11 document, 14 draftmr' > "$m/far.md"
  out="$(_class_assign "$m/far.md" "$thinking" "$checking")"
  [[ "$out" == *"MISS "*"thinking-2"* && "$out" != *BAD* ]] \
    || { echo "an enumeration 4 lines below its anchor must be MISS, not a pass or a BAD: [$out]" >&2; return 1; }
  # a mis-paired name (right number, wrong step) is not enumeration-shaped
  printf '%s\n' '- implementation-model: <token>' '  steers 2 draft, 9 implement, 10 quality, 11 review, 14 draftmr' > "$m/mispair.md"
  out="$(_class_assign "$m/mispair.md" "$thinking" "$checking")"
  [[ "$out" == *"MISS "*"thinking-11"* ]] || { echo "a mis-paired name must surface as MISS: [$out]" >&2; return 1; }
}
