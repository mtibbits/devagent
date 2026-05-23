# Status Report — {{PROJECT}} — {{PIN_FROM_DATE}} → {{PIN_TO_DATE}}
Pin: {{PIN_FROM}} → {{PIN_TO}} ({{PIN_SPAN}})

## Accomplished
{{ACCOMPLISHED_LIST}}

## Needs attention
### Stuck ({{STUCK_COUNT}})
{{STUCK_LIST}}
### Failed red-team ({{FAILED_REDTEAM_COUNT}})
{{FAILED_REDTEAM_LIST}}
### Idle > 7d ({{IDLE_COUNT}})
{{IDLE_LIST}}
### Poorly scoped ({{POORLY_SCOPED_COUNT}})
{{POORLY_SCOPED_LIST}}

## WBS roll-up
{{WBS_ROLLUP}}

## Velocity & estimate
- Last {{VELOCITY_WINDOW_WEEKS}} weeks: {{VELOCITY_PER_WEEK}} issues/week shipped, median {{MEDIAN_DAYS}} days/issue
- Remaining WBS leaves: {{REMAINING_LEAVES}}
- Estimated completion: {{ESTIMATED_COMPLETION}} ± {{ESTIMATE_BAND_WEEKS}} weeks

> Honest noise: v1 makes no attempt at precision. Treat the band as
> a rough indicator, not a forecast.
