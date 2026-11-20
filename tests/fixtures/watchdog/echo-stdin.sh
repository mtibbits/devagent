#!/usr/bin/env bash
# tests/fixtures/watchdog/echo-stdin.sh — #932: shows what reached the command:
# the LR_PROBE variable of its environment, then its stdin, byte for byte.
printf 'probe=%s\n' "${LR_PROBE-unset}"
cat
