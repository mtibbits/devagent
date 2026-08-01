# Add dryer exhaust telemetry

## Motivation
The dryer's exhaust temperature is invisible; gaps in telemetry hid a
30-minute overheat that cost a batch.

## Proposed behavior
- Sample exhaust temperature every 10 s; alert over 85 °C for 3 samples.

## Acceptance criteria
- [ ] Gauge visible in the dashboard; alert fires in the staged overheat
      drill.

## Source
Binned from epic 2026-07-30-harvest-pipeline-reliability.
