#!/usr/bin/env bats

setup() { . "$BATS_TEST_DIRNAME/../scripts/lib/conn-diag.sh"; }

@test "auth: HTTP 403 → auth message, rc0 (#269)" {
    run conn_diag_message "gh: HTTP 403: Resource not accessible by integration"
    [ "$status" -eq 0 ]
    [[ "$output" == *authentication* ]]
    [[ "$output" == *token* ]]
}

@test "auth: HTTP 401 Bad credentials → auth message (#269)" {
    run conn_diag_message "HTTP 401: Bad credentials (https://docs.github.com/...)"
    [ "$status" -eq 0 ]
    [[ "$output" == *authentication* ]]
}

@test "rate-limit: HTTP 429 → rate message (#269)" {
    run conn_diag_message "HTTP 429: API rate limit exceeded for user"
    [ "$status" -eq 0 ]
    [[ "$output" == *rate-limited* ]]
}

@test "network: could not resolve host → network message (#269)" {
    run conn_diag_message "fatal: unable to access 'https://github.com/...': Could not resolve host: github.com"
    [ "$status" -eq 0 ]
    [[ "$output" == *network* ]]
    [[ "$output" == *connectivity* ]]
}

@test "network: connection refused → network message (#269)" {
    run conn_diag_message "ssh: connect to host github.com port 22: Connection refused"
    [ "$status" -eq 0 ]
    [[ "$output" == *network* ]]
}

@test "ambiguous signal → rc1, empty (caller keeps grouped wording) (#269)" {
    run conn_diag_message "some unrecognized weirdness"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "auth wins over network when both substrings present (#269)" {
    run conn_diag_message "HTTP 403 ... Connection reset by peer"
    [ "$status" -eq 0 ]
    [[ "$output" == *authentication* ]]
}

@test "a 403 that names a rate limit is rate-limit, not auth (#269)" {
    run conn_diag_message "gh: API rate limit exceeded (HTTP 403)"
    [ "$status" -eq 0 ]
    [[ "$output" == *rate-limited* ]]
}

@test "network: gh dial-tcp/no-such-host → network message (#269)" {
    run conn_diag_message "error connecting to api.github.com: dial tcp: lookup api.github.com: no such host"
    [ "$status" -eq 0 ]
    [[ "$output" == *network* ]]
}
