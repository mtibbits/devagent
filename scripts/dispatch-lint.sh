#!/usr/bin/env bash
# scripts/dispatch-lint.sh — mechanism 4 (#360; design: Issue-333/designs/
# m4-dispatch-lint.md, normative). The dispatched-checker report gate. Four
# misfires to date (#117/#122/#76/#315) returned garbled text with zero tool uses
# and NO artifact recorded the failure. This validates, fail-loud, that "a real
# report came back" — deliberately MINIMAL (templates own full structure, #134).
#
#   dispatch-lint.sh <artifact> <expected-context> [--class review|redmr|preship]
#
# PRIMARY MECHANISM (#458, register PR #524): the producer or relay WRITEs the
# artifact to a FILE, never echoes it through a prose relay — a relayed report
# comes back truncated/elided and is not verbatim. This lint is the NARROW
# BACKSTOP behind that contract: it rejects the elision SHAPES that slip it (a
# marker line, or padding with no distinct substance — #530), not a substitute
# for file-carrying.
#
# rc 0 = looks real; rc≠0 + a one-line reason on stderr = reject (the carrier then
# archives + re-dispatches once, then marks [!]). Unreadable file = FAIL (fail-closed).
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=lib/paths.sh
. "$DEVAGENT_ROOT/scripts/lib/paths.sh"
# shellcheck source=lib/io.sh
. "$DEVAGENT_ROOT/scripts/lib/io.sh"

artifact="${1:-}"
expected_context="${2:-}"
class=""
shift $(( $# >= 2 ? 2 : $# )) || true
while [ $# -gt 0 ]; do
  case "$1" in
    --class) class="${2:-}"; shift 2 ;;
    --class=*) class="${1#--class=}"; shift ;;
    *) shift ;;
  esac
done

_reject() { echo "dispatch-lint: FAIL ($artifact): $1" >&2; exit 1; }

[ -n "$artifact" ] || die "dispatch-lint: <artifact> required"
[ -n "$expected_context" ] || die "dispatch-lint: <expected-context> required (subagent|inline)"
case "$expected_context" in subagent|inline) ;; *) die "dispatch-lint: expected-context must be subagent|inline" ;; esac

# Fail-closed: an unreadable/absent/empty file is a reject, not a pass.
[ -f "$artifact" ] && [ -r "$artifact" ] || _reject "artifact missing or unreadable"
[ -s "$artifact" ] || _reject "artifact is empty"

line1="$(sed -n '1p' "$artifact")"
line2="$(sed -n '2p' "$artifact")"

[ "$line1" = "context: $expected_context" ] \
  || _reject "line 1 must be 'context: $expected_context' (got: '${line1:-<empty>}')"

# TOLERANT model line: tier token unconstrained (fable/inline/inherit/opus/…),
# optional free-text parenthetical. Real artifacts write 'model: opus (per-issue
# checking floor)', 'model: inherit (fallback from <tier>)', etc.
# #458: the token class admits internal hyphens so the agent-default provenance
# form ('model: agent-default (preship-verifier)' — steps 3/14/21 on a project that
# resolves no tier) parses. Hyphens are internal-only: '-leading-hyphen',
# 'opus-', 'agent-' and 'Agent-Default' all stay rejected.
printf '%s\n' "$line2" | grep -Eq '^model: [a-z]+(-[a-z]+)*( \(.*\))?$' \
  || _reject "line 2 must match 'model: <tier>[ (note)]' (got: '${line2:-<empty>}')"

# Body (lines 3..EOF): reject the ELISION shape class (#530). A relayed report —
# one echoed through another model session instead of file-carried (#458) — comes
# back truncated: an ellipsis/omission MARKER line, or a body padded to clear a
# raw line count with almost no DISTINCT substance. The file-carried artifact
# contract (see header) is the primary mechanism; this is the narrow backstop.
#
# ONE awk pass (awk exits 0 regardless of match count — no `grep -c` rc=1
# pipefail trap, #314/#316). It emits `elision=<0|1> distinct=<n>`:
#  - Shape 1 (elision marker): OUTSIDE a ``` fence (fenced lines are the
#    checker's own quoted content, exempt), a line whose trimmed+lowercased form
#    exactly equals a member of the fixed literal marker set → elision=1.
#  - Shape 2 (low distinct substance): count DISTINCT non-blank lines that are
#    not a horizontal rule and not a marker (trimmed+lowercased, deduped).
# KNOWN GAP (#530 redmr INFO): Shape 1 is fence-evadable — a marker inside a
# fence, or an unclosed fence, is exempt. This is deliberate (the file-carried
# contract is primary; Shape 2 still applies), so the lint does NOT close the
# elision class — it is the narrow backstop, not a substitute for file-carrying.
# mawk-safe (#526): literal `…` (no \x escape), no regex backreferences.
_body_stats="$(sed -n '3,$p' "$artifact" | awk '
  function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
  BEGIN{ elision=0
    n=split("...|…|[...]|[truncated]|[elided]|[omitted]|<elided>|<truncated>|(truncated)|(rest omitted)", M, "|")
    for(i=1;i<=n;i++) marker[tolower(M[i])]=1
  }
  { line=trim($0); low=tolower(line)
    if (line ~ /^`{3}/ || line ~ /^~{3}/) { in_fence = !in_fence; next }  # ``` or ~~~ fence
    if (line=="") next
    if (!in_fence && (low in marker)) { elision=1; next }
    if (line ~ /^-{3,}$/ || line ~ /^\*{3,}$/ || line ~ /^={3,}$/ || line ~ /^_{3,}$/) next  # horizontal rule
    if (in_fence && (low in marker)) next        # fenced quoted marker: not substance, not elision
    if (!(low in seen)) { seen[low]=1; distinct++ }
  }
  END{ printf "%d %d\n", elision, distinct }
')"
elision="${_body_stats%% *}"      # awk-emitted integers; no pipe rc exposure, no eval
distinct="${_body_stats##* }"
[ "${elision:-0}" -eq 0 ] \
  || _reject "body contains an elision/relay marker line (a relayed/truncated report — file-carry the artifact, do not echo it; #458)"
[ "${distinct:-0}" -ge 5 ] \
  || _reject "body has ${distinct:-0} distinct substantive lines (need ≥5 — a garbled/relayed report)"

# A verdict SIGNAL is required for the judgement classes (#405). The house skills
# emit different-but-legitimate shapes: preship writes per-criterion PASS/FAIL;
# redmr's mandated Summary is the count line "B blocking, M major, m minor, I info"
# (core-redmr §; no SHIP token); review uses a "## Blocking" section header (or an
# older "Verdict:" line) with no count and no token. Accept any of these four —
# each is a human-recognizable "the checker reached a verdict" marker that a
# garbled/no-work report (the #117/#122/#76/#315 misfire class this gate exists to
# catch) does not carry. The `## Blocking` pattern deliberately does NOT match
# redmr's bracketed `### [BLOCKING]` finding header; the `Verdict:` pattern is
# line-anchored so it does not match mid-prose.
case "$class" in
  review|redmr|preship)
    if grep -Eq '\b(SHIP|SHIP-WITH-NITS|FIX-BEFORE-SHIP|NO-SHIP|PASS|FAIL)\b' "$artifact" \
       || grep -Eq '[0-9]+[[:space:]]+blocking\b' "$artifact" \
       || grep -Eq '^#{1,6}[[:space:]]+Blocking\b' "$artifact" \
       || grep -Eqi '^#{0,6}[[:space:]]*verdict:' "$artifact"; then
      :
    else
      _reject "no verdict signal for --class $class (need a SHIP/PASS/FAIL token, a house count line 'N blocking, …', a '## Blocking' review section, or a 'Verdict:' line)"
    fi
    ;;
esac

echo "dispatch-lint: PASS ($artifact)" >&2
