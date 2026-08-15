function buildPneumaticFindings({ live, isNumber, airPressure }) {
  if (live.lowAirPressure !== true) return []
  return [{
    key: 'low-air-pressure', severity: 'high', title: 'Low air pressure',
    cause: isNumber(live.airPressurePa)
      ? `The pneumatic system currently reports ${airPressure(live.airPressurePa)}.`
      : 'Pneumatic-system pressure is below its operating threshold.',
    effect: live.parkingBrakeApplied === true
      ? 'The spring parking brake is applied and may not release until pressure recovers.'
      : 'Air-brake and pneumatic-system operation may be limited until pressure recovers.',
    action: 'Allow the air compressor to build pressure. Inspect the compressor, tanks, and pneumatic system if pressure does not recover.',
  }]
}

function buildElectricDriveFindings(context) {
  const { live, motorUnavailable, motorOutputRestricted, motorRestrictionNeedsAttention,
    hasMeasuredMotorRestriction, motorTorqueAvailability, recentMotorTorqueAvailability,
    isNumber, percent } = context
  const findings = []
  if (live.motorBroken === true) findings.push({
    key: 'motor-broken', severity: 'high', title: 'Drive motor fault detected',
    cause: 'The installed drive motor has mechanically failed.',
    effect: 'The motor cannot provide normal propulsion.',
    action: 'Inspect and repair or replace the damaged drive motor.',
  })
  if (motorUnavailable) findings.push({
    key: 'motor-unavailable', severity: 'high', title: 'Drive motor unavailable',
    cause: 'The motor is disabled even though connected battery energy remains available.',
    effect: 'Propulsion from the affected motor is unavailable.',
    action: 'Inspect the motor, its controller, and associated powertrain damage.',
  })
  if (motorOutputRestricted) findings.push({
    key: 'propulsion-restriction', severity: motorRestrictionNeedsAttention ? 'high' : 'medium',
    attention: motorRestrictionNeedsAttention,
    title: motorRestrictionNeedsAttention ? 'Propulsion output restricted' : 'Propulsion output reduced under load',
    cause: hasMeasuredMotorRestriction
      ? `The current motor torque limit is ${percent(motorTorqueAvailability)} of its installed rating.`
      : 'The vehicle maintenance system has applied an output restriction.',
    effect: 'Available propulsion torque or power is currently reduced.',
    action: motorRestrictionNeedsAttention
      ? 'Review motor operation and service condition; inspect the powertrain if the restriction persists.'
      : 'No immediate action is required. Continue monitoring under-load availability for further reduction.',
  })
  if (!motorOutputRestricted && isNumber(recentMotorTorqueAvailability)) findings.push({
    key: 'recent-propulsion-restriction', severity: 'medium', attention: false, recent: true,
    title: 'Recently observed — propulsion output reduced under load',
    cause: `The lowest recently observed motor torque limit was ${percent(recentMotorTorqueAvailability)} of its installed rating.`,
    effect: 'The reduction was present under load; current stationary output is no longer restricted.',
    action: 'No immediate action is required. Continue monitoring if available output falls further.',
  })
  return findings
}

function buildNativeDamageEventFindings({ live, nativeDamageFinding }) {
  const recentDamageEvents = Array.isArray(live.recentDamageEvents)
    ? live.recentDamageEvents
    : Object.values(live.recentDamageEvents || {})
  return recentDamageEvents.map(nativeDamageFinding).filter(Boolean)
}

function buildNativeEngineConditionFindings({ live, pistonRingsDamaged }) {
  const findings = []
  if (live.engineHydrolocked) findings.push({ key: 'hydrolock', severity: 'high', title: 'Engine rotation obstructed', cause: 'Liquid intrusion into a combustion chamber is the likely cause.', effect: 'The engine cannot rotate safely.', action: 'Stop attempting to start the engine and inspect it before further operation.' })
  if (live.rodBearingsDamaged) findings.push({ key: 'rod-bearings', severity: 'high', title: 'Severe internal engine damage', cause: 'Bearing or lubrication-system damage is the likely cause.', effect: 'Continued operation may cause complete engine failure.', action: 'Stop the engine and repair the damaged long block.' })
  if (live.headGasketDamaged) findings.push({ key: 'head-gasket', severity: 'high', title: 'Combustion/cooling sealing fault', cause: 'Cylinder-head or head-gasket sealing failure is the likely cause.', effect: 'Cooling and combustion performance may be compromised.', action: 'Inspect and repair the cylinder head and gasket.' })
  if (pistonRingsDamaged) findings.push({ key: 'piston-rings', severity: 'high', title: 'Cylinder sealing fault suspected', cause: 'Piston-ring or cylinder sealing deterioration is the likely cause.', effect: 'Oil consumption and power loss may increase.', action: 'Inspect compression and repair the engine internals.' })
  return findings
}

function buildMaintenanceFindings(context) {
  const { engine, radiator, powerLimited, powerLimitReason, friendlyFindingCause,
    powerLimitAction, maintenanceAction, activeSymptomText } = context
  const findings = []
  if (powerLimited) {
    const cooling = radiator.liveMetrics?.powerLimitActive === true
    findings.push({
      key: 'output-restriction', severity: cooling ? 'high' : 'medium', attention: true,
      title: 'Engine output restricted',
      cause: friendlyFindingCause(powerLimitReason), effect: 'Available engine torque or power is currently reduced.',
      action: powerLimitAction(powerLimitReason, cooling),
    })
  }
  if (!powerLimited && engine.activeSymptom) findings.push({ key: 'engine-symptom', severity: 'medium', title: activeSymptomText(engine), cause: 'An intermittent engine fault is currently active.', effect: 'Engine response or combustion quality may be affected.', action: maintenanceAction(engine, 'Inspect the engine and its service condition.') })
  if (radiator.activeSymptom && !powerLimited) findings.push({ key: 'cooling-symptom', severity: 'medium', title: radiator.activeSymptomLabel || 'Active cooling-system condition', cause: 'The cooling system has detected an abnormal operating condition.', effect: 'Cooling performance may be reduced.', action: maintenanceAction(radiator, 'Inspect the cooling system.') })
  return findings
}

function buildDrivetrainFindings(context) {
  const { live, transmission, recentSymptoms, clutchTemperatureHigh, clutchTemperatureElevated,
    recentSymptom, transmissionSymptomFinding, isNumber, temperature, nowSeconds } = context
  const findings = []
  if (live.clutchDamaged) findings.push({ key: 'clutch-damage', severity: 'high', title: 'Clutch damage detected', cause: 'The clutch can no longer transfer torque normally.', effect: 'Slip or loss of drive may occur.', action: 'Inspect and replace the clutch assembly.' })
  if (clutchTemperatureHigh || clutchTemperatureElevated) findings.push({ key: 'clutch-temperature', severity: clutchTemperatureHigh ? 'high' : 'medium', title: clutchTemperatureHigh ? 'Clutch overheating' : 'Clutch temperature high', cause: 'Excessive clutch slip has generated more heat than the clutch can safely dissipate.', effect: clutchTemperatureHigh ? 'Continued use may permanently damage the clutch.' : 'Clutch capacity may fall if temperature continues to rise.', action: 'Stop slipping the clutch and allow it to cool. Inspect the clutch if overheating returns frequently.' })
  const activeTransmissionSymptom = transmission.activeSymptom
  if (activeTransmissionSymptom) findings.push(transmissionSymptomFinding(activeTransmissionSymptom, true))
  else {
    const stored = recentSymptom(transmission, 'transmission')
    if (['roughShift', 'shiftDelay', 'slip'].includes(stored)) findings.push(transmissionSymptomFinding(stored, false))
  }
  const recentPeak = live.recentClutchHeatPeakC ?? recentSymptoms.clutchHeat?.peakTemp
  const age = nowSeconds - Number(recentSymptoms.clutchHeat?.observedAt || 0)
  const hasRecentHeat = isNumber(live.recentClutchHeatPeakC) || (isNumber(recentPeak) && age >= 0 && age <= 300)
  if (!clutchTemperatureHigh && !clutchTemperatureElevated && hasRecentHeat) findings.push({ key: 'recent-clutch-temperature', severity: 'medium', attention: false, recent: true, title: 'Recent clutch overheating', cause: 'Excessive clutch slip raised temperature above the installed clutch warning threshold.', effect: `Clutch temperature recently reached ${temperature(recentPeak)} and has since fallen.`, action: 'Allow the clutch to cool fully and inspect it if overheating returns frequently.' })
  return findings
}

export function buildDiagnosticFindings(context) {
  const sources = context.live.isElectric
    ? [buildPneumaticFindings(context), buildNativeDamageEventFindings(context), buildElectricDriveFindings(context)]
    : [buildPneumaticFindings(context), buildNativeDamageEventFindings(context), buildNativeEngineConditionFindings(context), buildMaintenanceFindings(context), buildDrivetrainFindings(context)]
  const findings = sources.flat().filter((finding, index, all) => all.findIndex(candidate => candidate.key === finding.key) === index)
  if (!context.live.isElectric && context.live.checkEngine === true && !findings.some(finding => finding.attention !== false)) findings.push({ key: 'controller-warning', severity: 'medium', title: 'Powertrain warning active', cause: 'The vehicle controller has requested a warning, but no more specific supported cause is currently reported.', effect: 'A dashboard powertrain warning is active.', action: 'Review temperatures and live readings, then inspect the vehicle if the warning persists or returns.' })
  return findings.slice(0, 4)
}
