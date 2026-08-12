# RLS Vehicle Scanner TODO

## Hybrid vehicle support

Pure-electric support has been implemented and validated live with a standard
BeamNG EV. Full support for true hybrid powertrains still needs to be tested and
implemented with a normal hybrid vehicle. Use live data only to confirm what
BeamNG and RLS genuinely expose.

- Determine how combustion engines and electric motors are represented together
  by `powertrain.getDevicesByCategory("engine")`; do not assume `mainEngine`
  describes the complete propulsion system or select a device merely because it
  appears first.
- Define hybrid-aware Overview, Engine/Motor, Service, and Drivetrain
  presentation without hiding factual combustion data or inventing electric
  equivalents.
- Verify hybrid ready/running states, battery charge, motor and engine output,
  multiple propulsion devices, gearbox behavior, and regenerative braking.
- Discover native BeamNG hybrid damage and warning states, then add only clearly
  understood active or recently observed scanner findings.
- Confirm how RLS `vehicleMaintenanceDebugData` categorizes and affects hybrid
  components. Suppress incompatible presentation rather than modifying or
  reinterpreting RLS maintenance values.
