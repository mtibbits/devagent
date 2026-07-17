#!/usr/bin/env bash
# scripts/dispatch-lint.sh — mechanism 4 (#360; design: Issue-333/designs/
# m4-dispatch-lint.md, normative). The dispatched-checker report gate. Four
# misfires to date (#117/#122/#76/#315) returned garbled text with zero tool uses
# and NO artifact recorded the failure. This validates, fail-loud, that "a real
# report came back" — deliberately MINIMAL (templates own full structure, #134).
#
#   dispatch-lint.sh <artifact> <expected-context> [--class review|redmr|preship]
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
# form ('model: agent-default (preship-verifier)' — steps 14/21 on a project that
# resolves no tier) parses. Hyphens are internal-only: '-leading-hyphen',
# 'opus-', 'agent-' and 'Agent-Default' all stay rejected.
printf '%s\n' "$line2" | grep -Eq '^model: [a-z]+(-[a-z]+)*( \(.*\))?$' \
  || _reject "line 2 must match 'model: <tier>[ (note)]' (got: '${line2:-<empty>}')"

# Body: ≥5 non-empty lines beyond the 2-line header.
body_lines="$(sed -n '3,$p' "$artifact" | grep -c '[^[:space:]]' || true)"
[ "$body_lines" -ge 5 ] \
  || _reject "body has $body_lines non-empty lines (need ≥5 — a garbled/no-work report)"

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
