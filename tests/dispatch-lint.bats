#!/usr/bin/env bats
# #360 dispatch-lint.sh — the dispatched-checker report gate.
load 'lib/bats-helpers'

setup() { setup_tmp_devagent_home; D="$BATS_TEST_TMPDIR"; }
teardown() { teardown_tmp_devagent_home; }

LINT() { "$PLUGIN_ROOT/scripts/dispatch-lint.sh" "$@"; }

# A well-formed report body (≥5 non-empty lines beyond the 2-line header).
_body() { printf '# Report\n## Section\n- point one\n- point two\n- point three\n- point four\n'; }

@test "dispatch-lint: garbled report (no header, #315 shape) → FAIL (#360)" {
    printf 'the previous response returned some prose\nwith no tool uses at all\n' > "$D/a.md"
    run LINT "$D/a.md" inline
    [ "$status" -ne 0 ]
    [[ "$output" == *"line 1"* ]]
}

@test "dispatch-lint: valid inline report → PASS (#360)" {
    { echo 'context: inline'; echo 'model: inherit (session opus)'; _body; } > "$D/a.md"
    run LINT "$D/a.md" inline
    [ "$status" -eq 0 ]
}

@test "dispatch-lint: expected-context mismatch → FAIL (#360)" {
    { echo 'context: inline'; echo 'model: opus'; _body; } > "$D/a.md"
    run LINT "$D/a.md" subagent
    [ "$status" -ne 0 ]
    [[ "$output" == *"context: subagent"* ]]
}

@test "dispatch-lint: tolerant model grammar admits real forms (#360)" {
    # These are the exact shapes real artifacts write — a strict list would reject them.
    for ml in 'model: opus (per-issue checking floor)' \
              'model: fable (per-issue checking marker — binning)' \
              'model: inherit (fallback from opus)' \
              'model: sonnet'; do
        { echo 'context: subagent'; echo "$ml"; _body; } > "$D/a.md"
        run LINT "$D/a.md" subagent
        [ "$status" -eq 0 ] || { echo "rejected: $ml -- $output" >&2; false; }
    done
}

@test "dispatch-lint: bad model line → FAIL (#360)" {
    { echo 'context: inline'; echo 'MODEL WAS opus'; _body; } > "$D/a.md"
    run LINT "$D/a.md" inline
    [ "$status" -ne 0 ]
    [[ "$output" == *"line 2"* ]]
}

@test "dispatch-lint: too-short body → FAIL (#360)" {
    { echo 'context: inline'; echo 'model: opus'; echo 'only one line'; } > "$D/a.md"
    run LINT "$D/a.md" inline
    [ "$status" -ne 0 ]
    [[ "$output" == *"body"* ]]
}

@test "dispatch-lint: --class review needs a verdict token (#360)" {
    { echo 'context: subagent'; echo 'model: opus'; _body; } > "$D/noverdict.md"
    run LINT "$D/noverdict.md" subagent --class review
    [ "$status" -ne 0 ]
    [[ "$output" == *"verdict"* ]]

    { echo 'context: subagent'; echo 'model: opus'; _body; echo 'Verdict: SHIP-WITH-NITS'; } > "$D/verdict.md"
    run LINT "$D/verdict.md" subagent --class review
    [ "$status" -eq 0 ]
}

@test "dispatch-lint: accepts the house verdict shapes redmr/review actually emit (#405)" {
    # redmr's mandated Summary count line (no SHIP token) — the 41/79 false-FAIL class.
    { echo 'context: subagent'; echo 'model: inherit'; _body
      echo '## Summary'; echo '0 blocking, 0 major, 1 minor, 3 info'; } > "$D/redmr-count.md"
    run LINT "$D/redmr-count.md" subagent --class redmr
    [ "$status" -eq 0 ]

    # review's "## Blocking" section header (the in-window house format).
    { echo 'context: subagent'; echo 'model: opus'; _body
      echo '## Blocking'; echo 'None.'; } > "$D/review-blocking.md"
    run LINT "$D/review-blocking.md" subagent --class review
    [ "$status" -eq 0 ]

    # A body with NONE of the four verdict signals still FAILs (guard the guard).
    { echo 'context: subagent'; echo 'model: opus'; _body; } > "$D/nosignal.md"
    run LINT "$D/nosignal.md" subagent --class redmr
    [ "$status" -ne 0 ]

    # The '## Blocking' accept must NOT be triggered by redmr's bracketed finding
    # header alone — a bracketed-only body with no count line still FAILs.
    { echo 'context: subagent'; echo 'model: inherit'; _body
      echo '### [BLOCKING] something'; } > "$D/bracketed.md"
    run LINT "$D/bracketed.md" subagent --class redmr
    [ "$status" -ne 0 ]
}

@test "dispatch-lint: unreadable/absent artifact → FAIL (fail-closed) (#360)" {
    run LINT "$D/does-not-exist.md" inline
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing or unreadable"* ]]
}

@test "dispatch-lint: empty artifact → FAIL (#360)" {
    : > "$D/empty.md"
    run LINT "$D/empty.md" inline
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty"* ]]
}

@test "dispatch-lint: model grammar admits the agent-default provenance form (#458)" {
    # #458/#527 bind steps 5/16/17 to dedicated agents whose pinned model is the
    # tier of last resort. A fresh-install project (config.toml.skel ships step_models
    # commented out) resolves NO tier, so the wrapper stamps this exact token —
    # the real artifact header, fed through the real linter (register #232:
    # two components that must agree are tested with the produced artifact).
    for ml in 'model: agent-default (preship-verifier)' \
              'model: agent-default (redteam-reviewer)' \
              'model: agent-default (plan-improver)'; do
        { echo 'context: subagent'; echo "$ml"; _body; } > "$D/a.md"
        run LINT "$D/a.md" subagent
        [ "$status" -eq 0 ] || { echo "rejected: $ml -- $output" >&2; false; }
    done
}

@test "dispatch-lint: agent-default header passes the preship/redmr class gates (#458)" {
    # Both classes, because the wrapper writes this header on BOTH bound steps.
    { echo 'context: subagent'; echo 'model: agent-default (preship-verifier)'; _body
      echo 'Verdict: PASS'; } > "$D/preship.md"
    run LINT "$D/preship.md" subagent --class preship
    [ "$status" -eq 0 ] || { echo "preship class rejected -- $output" >&2; false; }

    { echo 'context: subagent'; echo 'model: agent-default (redteam-reviewer)'; _body
      echo '## Summary'; echo '0 blocking, 0 major, 1 minor, 3 info'; } > "$D/redmr.md"
    run LINT "$D/redmr.md" subagent --class redmr
    [ "$status" -eq 0 ] || { echo "redmr class rejected -- $output" >&2; false; }
}

@test "dispatch-lint: a hyphen-only or malformed model token still FAILs (#458)" {
    # The widened class must not degenerate into "anything goes": the grammar
    # still requires a leading letter and rejects junk.
    for ml in 'model: -leading-hyphen' \
              'model: Agent-Default' \
              'model: agent default' \
              'model: opus-' \
              'model: agent-'; do
        { echo 'context: subagent'; echo "$ml"; _body; } > "$D/a.md"
        run LINT "$D/a.md" subagent
        [ "$status" -ne 0 ] || { echo "wrongly accepted: $ml" >&2; false; }
    done
}

@test "dispatch-lint: model grammar admits the rc-2 inherit-escape provenance (#458)" {
    # The #291 escape hatch (marker 'inherit' → step-model.sh rc 2) stamps this
    # form. It shipped missing from the header enumeration once (review MAJOR-1)
    # precisely because nothing fed it through the linter, the way agent-default
    # was. Real header, real linter, both bound classes (register #232).
    { echo 'context: subagent'; echo 'model: inherit (per-issue)'; _body; } > "$D/a.md"
    run LINT "$D/a.md" subagent
    [ "$status" -eq 0 ] || { echo "plain rejected -- $output" >&2; false; }

    { echo 'context: subagent'; echo 'model: inherit (per-issue)'; _body
      echo 'Verdict: PASS'; } > "$D/p.md"
    run LINT "$D/p.md" subagent --class preship
    [ "$status" -eq 0 ] || { echo "preship class rejected -- $output" >&2; false; }

    { echo 'context: subagent'; echo 'model: inherit (per-issue)'; _body
      echo '## Summary'; echo '0 blocking, 0 major, 0 minor, 0 info'; } > "$D/r.md"
    run LINT "$D/r.md" subagent --class redmr
    [ "$status" -eq 0 ] || { echo "redmr class rejected -- $output" >&2; false; }
}

# ---- #598: the review wrapper's Report contract (commands/review.md) is a
# SECOND home of this lint's --class review verdict-signal set: the main session
# pastes it into the dispatched reviewer's prompt, so a drift between the two
# homes makes a reviewer that obeys its prompt fail this lint. These two tests
# are the sweep over both homes. The token set is DERIVED from the lint's own
# grep, never re-spelled here (register: Issue-585). Declared blind spots and
# couplings, each held by a row in the #598 mutation transcript:
#  - a PARTIAL restatement elsewhere in review.md (fewer than every token) is
#    not caught, and the contract must name each token in backticks;
#  - comment lines in dispatch-lint.sh are ignored by both derivations: a
#    commented alternation is not read, a commented alternative is not counted;
#  - the alternative count is bounded by the case label `review|redmr|preship)`
#    and the arm's `;;` line: renaming or reflowing those reddens the count,
#    and its message names that remedy;
#  - disabled code (an `if false` around the arm) keeps both tests green. The
#    behaviour tests above catch that direction (lines 59-94 at 943a80e:
#    "--class review needs a verdict token (#360)" and "accepts the house
#    verdict shapes redmr/review actually emit (#405)").
_review_contract_paras() {  # <count|print> <space-separated tokens>
    awk -v mode="$1" -v toks="$2" 'BEGIN { RS = ""; n = split(toks, T, " ") }
        { ok = 1
          for (i = 1; i <= n; i++) if ($0 !~ ("(^|[^A-Za-z-])" T[i] "([^A-Za-z-]|$)")) ok = 0
          if (ok) { c++; if (mode == "print") print } }
        END { if (mode == "count") print c + 0 }' "$PLUGIN_ROOT/commands/review.md"
}

@test "review.md's Report contract names exactly the lint's --class review signal set, once (#598)" {
    local lint="$PLUGIN_ROOT/scripts/dispatch-lint.sh" alts toks n_alt n para want got
    alts="$(grep -v '^[[:space:]]*#' "$lint" | grep -oE '[\]b[(][A-Z|-]+[)][\]b' || true)"
    [ -n "$alts" ] && [ "$(printf '%s\n' "$alts" | wc -l)" -eq 1 ] \
        || { echo "expected ONE token alternation in dispatch-lint.sh's code lines, got: [$alts]" >&2; false; }
    toks="$(printf '%s\n' "$alts" | sed -E 's/^[\]b[(]//; s/[)][\]b$//' | tr '|' ' ')"
    # The three non-token signals cannot be derived as a set; count the arm's
    # `grep -Eq` calls instead (occurrences, not lines, comment lines excluded),
    # so a new or dropped signal reddens here.
    n_alt="$(sed -n '/^  review|redmr|preship)/,/^    ;;/p' "$lint" \
        | grep -v '^[[:space:]]*#' | grep -oE 'grep -Eq' | wc -l)"
    [ "$n_alt" -eq 4 ] \
        || { echo "dispatch-lint --class review has $n_alt signal alternatives, not 4: if the lint gained or lost a signal, update review.md's Report contract and this test together; if the lint's case arm was only reflowed or renamed, re-derive this count" >&2; false; }
    # Stated ONCE (AC2): exactly one paragraph of review.md names every token.
    n="$(_review_contract_paras count "$toks")"
    [ "$n" -eq 1 ] \
        || { echo "review.md paragraphs naming every lint token [$toks]: $n (want exactly 1)" >&2; false; }
    para="$(_review_contract_paras print "$toks")"
    # ...and names exactly the lint's tokens: a lint narrowing, or a token the
    # lint does not accept, reddens in either direction.
    want="$(tr ' ' '\n' <<<"$toks" | sort -u | tr '\n' ' ')"
    # The backticks below are literal markdown code markup, not an expansion.
    # shellcheck disable=SC2016
    got="$(grep -oE '`[A-Z][A-Z-]*[A-Z]`' <<<"$para" | tr -d '`' | sort -u | tr '\n' ' ')"
    [ "$got" = "$want" ] \
        || { echo "contract's backticked token set [$got] != the lint's [$want]" >&2; false; }
    # The three shape signals, matched over whitespace-normalised text so a
    # re-wrap of the block cannot split a fragment (register: Issue-612).
    para="$(tr -s '[:space:]' ' ' <<<"$para")"
    grep -qE '[0-9]+ blocking' <<<"$para" || { echo "contract lacks the digit-led count-line signal" >&2; false; }
    grep -qF '## Blocking' <<<"$para"     || { echo "contract lacks the '## Blocking' signal" >&2; false; }
    grep -qF 'Verdict:' <<<"$para"        || { echo "contract lacks the 'Verdict:' signal" >&2; false; }
}

# _routes <label> <region>: the region names the Report contract and routes it
# into the prompt. Each failure names its region; the #598 mutation matrix keys
# on these messages.
_routes() {
    grep -qi 'report contract' <<<"$2" || { echo "$1 carries no Report contract" >&2; return 1; }
    grep -qi 'prompt' <<<"$2" || { echo "$1 does not route the contract into the prompt" >&2; return 1; }
}

@test "every review dispatch (both paths and the 5a retry) routes the Report contract into the prompt (#598)" {
    local review="$PLUGIN_ROOT/commands/review.md" sp fb rt
    # Each region is bounded by markers: the invoke line, the Fallback label and
    # the nudge line (all pinned by tests/cmd_wrappers.bats), then item 5a's
    # label and item 6's number.
    sp="$(sed -n '/Invoke `superpowers:requesting-code-review` with the diff scope/,/Fallback (superpowers absent)/p' "$review")"
    fb="$(sed -n '/Fallback (superpowers absent)/,/recommended: claude plugin install/p' "$review")"
    rt="$(sed -n '/^5a\. \*\*Report validation/,/^6\. /p' "$review")"
    [ -n "$sp" ] && [ -n "$fb" ] && [ -n "$rt" ] \
        || { echo "could not bound the three dispatch regions in $review" >&2; false; }
    _routes "superpowers path" "$sp"
    _routes "fallback path" "$fb"
    _routes "5a retry" "$rt"
}
