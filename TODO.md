# RLS Vehicle Scanner TODO

## Hybrid vehicle support

Pure-electric and series-hybrid support have been implemented and validated
live. Series-hybrid validation used a diesel generator, electrical generator,
traction batteries, and two independent electric drive axles. Use live data
only to confirm what BeamNG and RLS genuinely expose.

- Find suitable parallel, series-parallel, and mild-hybrid vehicles or mods for
  live validation. These layouts may mechanically connect both the combustion
  engine and electric motors to the wheels and must not be inferred from the
  completed series-hybrid implementation.
- Extend hybrid classification and presentation only after inspecting each
  layout's combustion engine, traction motors, generator machines, energy
  storage, gearbox behavior, and regenerative braking.
- Discover native BeamNG hybrid damage and warning states, then add only clearly
  understood active or recently observed scanner findings.
- Confirm how RLS `vehicleMaintenanceDebugData` categorizes and affects hybrid
  components. Suppress incompatible presentation rather than modifying or
  reinterpreting RLS maintenance values.
