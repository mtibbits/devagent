# Calibrate moisture sensors

## Motivation
North field station sensors read 2–3 points wet after the firmware update;
dryer runs long and scorches the batch edge.

## Proposed behavior
- Two-point recalibration against the lab meter; store offsets per sensor.

## Acceptance criteria
- [ ] Post-calibration readings within ±0.5 of the lab meter.

## Source
Binned from epic 2026-07-30-harvest-pipeline-reliability (north field).
