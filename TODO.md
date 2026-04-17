# Hardware Capture TODO

This checklist tracks real Ember hardware states we still need to capture for robust fixture coverage.

## Captured
- [x] `idle-empty`
- [x] `overshoot-cooling`
- [x] `heating`

## Still Needed
- [ ] `idle-with-liquid`
- [ ] `heating-ramp-low`
- [ ] `heating-ramp-mid`
- [ ] `at-target-hold`
- [ ] `charging-idle`
- [ ] `charging-heating` (if observed)
- [ ] `low-battery-idle` (<20%)
- [ ] `very-low-battery` (<10%)
- [ ] `post-reconnect`
- [ ] `just-off-charger`

## Sampling Guidance
- Capture each state 3 times (`s01`, `s02`, `s03`) with ~10-15s between captures.
- Keep labels consistent so grouped export stays useful.
- Include notes on any transitions (for example, "just lifted from charger").

## Liquid State Mapping Notes
Current interpretation from observed hardware captures:
- `0x01` -> `empty`
- `0x03` -> `cooling`
- `0x04` -> `cooling`
- `0x06` -> `heating`
