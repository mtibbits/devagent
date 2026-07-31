# Batch restart tuning for the ingest workers

## Motivation
Ingest workers restart with a fixed 30 s backoff; under sustained broker
outages the fleet thunders back in lockstep and re-fails. Operators asked
for jittered exponential backoff.

## Proposed behavior
- Replace the fixed 30 s restart delay with exponential backoff (base 5 s,
  cap 300 s) plus ±20 % jitter.
- Emit a `restart_backoff_seconds` gauge per worker.

## Acceptance criteria
- [ ] Backoff sequence verified by unit test (5, 10, 20, … capped at 300).
- [ ] Jitter bounds verified (±20 %).
- [ ] Gauge visible in the metrics endpoint.

## Source
Operator conversation, 2026-07-30.
