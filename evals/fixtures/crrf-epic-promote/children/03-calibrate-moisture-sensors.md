# Calibrate moisture sensors

## Motivation
River field station sensors drift dry in high humidity; the dryer stops
early and the batch molds in the silo.

## Proposed behavior
- Two-point recalibration against the lab meter; store offsets per sensor;
  add the humidity-compensation term the north station does not need.

## Acceptance criteria
- [ ] Post-calibration readings within ±0.5 of the lab meter at 60–90 % RH.

## Source
Binned from epic 2026-07-30-harvest-pipeline-reliability (river field).
