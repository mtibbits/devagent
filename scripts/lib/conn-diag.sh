#!/usr/bin/env bash
# scripts/lib/conn-diag.sh — #269. Classify a captured connection/probe error string
# into one actionable cause for the rc-2 "can't determine" paths (code/github.sh
# branch-exists, branch.sh baseline fetch). Pure, dependency-free, no side effects.
#
#   conn_diag_message <errtext>
#     echoes ONE remedy line and returns 0 for a recognized class;
#     echoes nothing and returns 1 when the signal is ambiguous, so the caller keeps
#     its existing grouped wording rather than assert a class it cannot prove.
#
# Matched in order rate-limit → auth → network. Rate-limit is checked BEFORE auth on
# purpose: GitHub returns a rate-limit as HTTP 403 (primary) or 429 (secondary), so a
# 403 that also names a "rate limit" is the rate limit, not a bad token. After that, a
# bare 401/403 is auth; a connection-level error is network. Truly ambiguous ⇒ rc 1.
conn_diag_message() {
    local e="$1"
    case "$e" in
        *"HTTP 429"*|*"rate limit"*|*"rate-limit"*|*"abuse detection"*)
            echo "rate-limited (transient) — wait and retry"
            return 0 ;;
        *"HTTP 401"*|*"HTTP 403"*|*"Bad credentials"*|*"Resource not accessible"*|*"must have admin"*|*"requires authentication"*|*"Authentication failed"*|*"Permission denied"*)
            echo "authentication/authorization failure (bad, expired, or under-scoped token) — re-authenticate or check the token's scope"
            return 0 ;;
        *"could not resolve"*|*"Could not resolve"*|*"no such host"*|*"Temporary failure in name resolution"*|*"Connection refused"*|*"Connection reset"*|*"network is unreachable"*|*"Network is unreachable"*|*"Couldn't connect"*|*"Could not connect"*|*"Failed to connect"*|*"error connecting"*|*"dial tcp"*|*"Operation timed out"*|*"i/o timeout"*|*"TLS handshake"*|*"unable to access"*)
            echo "network/availability failure (offline, host down, DNS, or connection reset) — check connectivity and retry"
            return 0 ;;
        *)
            return 1 ;;
    esac
}
