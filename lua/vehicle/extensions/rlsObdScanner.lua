-- Vehicle telemetry provider and conservative malfunction-indicator bridge.
local M = {}

local UPDATE_INTERVAL = 0.20
local RECENT_EVENT_SECONDS = 300
local timer = 0
local recentClutchHeatSeconds = 0
local recentClutchHeatPeakC = nil
local recentMotorRestrictionSeconds = 0
local recentMotorTorqueAvailability = nil
local recentDamageEvents = {}

-- Native BeamNG damage states that are meaningful to a scan-tool user. Device-
-- named powertrain entries are deliberately excluded because their meaning is
-- vehicle-specific and cannot be described reliably without more context.
local trackedDamage = {
  engine = {
    overRevDanger = true,
    mildOverrevDamage = true,
    catastrophicOverrevDamage = true,
    overTorqueDanger = true,
    catastrophicOverTorqueDamage = true,
    coolantOverheating = true,
    oilOverheating = true,
    starvedOfOil = true,
    oilLevelCritical = true,
    oilLevelTooHigh = true,
    engineIsHydrolocking = true,
    engineReducedTorque = true,
    engineDisabled = true,
    engineLockedUp = true,
    impactDamage = true,
    radiatorLeak = true,
    oilRadiatorLeak = true,
    oilpanLeak = true,
    exhaustBroken = true,
    blockMelted = true,
    cylinderWallsMelted = true,
  },
  gearbox = {
    synchroWear = true,
  },
}

local function number(value)
  value = tonumber(value)
  if value and value == value and value ~= math.huge and value ~= -math.huge then return value end
  return nil
end

local function firstNumber(...)
  for i = 1, select("#", ...) do
    local value = number(select(i, ...))
    if value ~= nil then return value end
  end
  return nil
end

local function getEngine()
  if powertrain and powertrain.getDevice then
    local mainEngine = powertrain.getDevice("mainEngine")
    if mainEngine then return mainEngine end
  end
  local devices = powertrain and powertrain.getDevicesByCategory and powertrain.getDevicesByCategory("engine") or nil
  return devices and devices[1] or nil
end

local function getGearbox()
  local devices = powertrain and powertrain.getDevicesByCategory and powertrain.getDevicesByCategory("gearbox") or nil
  return devices and devices[1] or nil
end

local function getClutch()
  local devices = powertrain and powertrain.getDevicesByCategory and powertrain.getDevicesByCategory("clutch") or nil
  return devices and devices[1] or nil
end

local function getElectricBatteryCharge()
  if not (energyStorage and energyStorage.getStorages) then return nil end
  local storedEnergy, capacity = 0, 0
  for _, storage in pairs(energyStorage.getStorages() or {}) do
    if type(storage) == "table" and storage.type == "electricBattery" then
      local storageEnergy = number(storage.storedEnergy)
      local storageCapacity = number(storage.energyCapacity)
      if storageEnergy and storageCapacity and storageCapacity > 0 then
        storedEnergy = storedEnergy + storageEnergy
        capacity = capacity + storageCapacity
      end
    end
  end
  if capacity <= 0 then return nil end
  local ratio = storedEnergy / capacity
  return ratio >= 0 and ratio <= 1 and ratio or nil
end

local function normalized(value)
  value = number(value)
  if value == nil or value < 0 or value > 1 then return nil end
  return value
end

local function normalizedEngineLoad(value)
  value = number(value)
  if value == nil or value > 1 then return nil end
  -- Electric motors report negative load while regenerating. The scanner is
  -- stationary-focused, so keep the load row stable at zero during coast-down.
  return math.max(0, value)
end

local function powerHp(raw)
  raw = number(raw)
  if not raw or raw <= 0 then return nil end
  -- BeamNG maxPower is normally metric horsepower; normalize watt reports to the same unit.
  return raw > 10000 and raw / 735.499 or raw
end

local function reportedBoolean(container, key)
  if type(container) ~= "table" or container[key] == nil then return nil end
  if container[key] == true then return true end
  local numeric = number(container[key])
  return numeric ~= nil and numeric ~= 0
end

local function firstReportedBoolean(container, ...)
  for i = 1, select("#", ...) do
    local value = reportedBoolean(container, select(i, ...))
    if value ~= nil then return value end
  end
  return nil
end

local function damageIsActive(value)
  if value == true then return true end
  local numeric = number(value)
  return numeric ~= nil and numeric ~= 0
end

local function damageEventKey(group, name)
  return tostring(group) .. ":" .. tostring(name)
end

local function observeDamageChange(group, name, value)
  if not (trackedDamage[group] and trackedDamage[group][name]) then return end
  local key = damageEventKey(group, name)
  local active = damageIsActive(value)
  local event = recentDamageEvents[key]
  if active then
    recentDamageEvents[key] = {
      group = group,
      name = name,
      active = true,
      secondsRemaining = RECENT_EVENT_SECONDS,
    }
  elseif event and event.active then
    event.active = false
    event.secondsRemaining = RECENT_EVENT_SECONDS
  end
end

local function onDamageDataChanged(_, damageDelta)
  if type(damageDelta) ~= "table" then return end
  for group, values in pairs(damageDelta) do
    if type(values) == "table" and trackedDamage[group] then
      for name, value in pairs(values) do
        observeDamageChange(group, name, value)
      end
    end
  end
end

local function registerDamageListener()
  if not damageTracker or type(damageTracker.registerDamageUpdateCallback) ~= "function" then return end
  if not damageTracker._rlsObdScannerCallbackInstalled then
    damageTracker._rlsObdScannerCallbackInstalled = true
    damageTracker.registerDamageUpdateCallback(function(data, delta)
      local scanner = rawget(_G, "rlsObdScanner")
      if type(scanner) == "table" and type(scanner.onDamageDataChanged) == "function" then
        scanner.onDamageDataChanged(data, delta)
      end
    end)
  end

  if type(damageTracker.getDamage) == "function" then
    for group, names in pairs(trackedDamage) do
      for name in pairs(names) do
        if damageIsActive(damageTracker.getDamage(group, name)) then
          observeDamageChange(group, name, true)
        end
      end
    end
  end
end

local function updateRecentDamageEvents(elapsed)
  for key, event in pairs(recentDamageEvents) do
    if event.active then
      event.secondsRemaining = RECENT_EVENT_SECONDS
    else
      event.secondsRemaining = math.max(0, (number(event.secondsRemaining) or 0) - elapsed)
      if event.secondsRemaining <= 0 then recentDamageEvents[key] = nil end
    end
  end
end

local function recentDamageEventData()
  local result = {}
  for _, event in pairs(recentDamageEvents) do
    result[#result + 1] = {
      group = event.group,
      name = event.name,
      active = event.active == true,
      secondsRemaining = math.ceil(number(event.secondsRemaining) or 0),
    }
  end
  table.sort(result, function(a, b)
    if a.active ~= b.active then return a.active end
    if a.secondsRemaining ~= b.secondsRemaining then return a.secondsRemaining > b.secondsRemaining end
    return damageEventKey(a.group, a.name) < damageEventKey(b.group, b.name)
  end)
  return result
end

local function findActivePart(slotNeedle, nameNeedle, excludedName)
  local activeParts = v and v.data and v.data.activePartsData or nil
  if type(activeParts) ~= "table" then return nil end
  for _, part in pairs(activeParts) do
    local slotType = tostring(type(part) == "table" and part.slotType or ""):lower()
    local partName = tostring(type(part) == "table" and part.information and part.information.name or "")
    local lowerName = partName:lower()
    if slotType:find(slotNeedle, 1, true)
      and (not nameNeedle or lowerName:find(nameNeedle, 1, true))
      and (not excludedName or not lowerName:find(excludedName, 1, true)) then
      return part, partName ~= "" and partName or nil
    end
  end
  return nil
end

local function findEngineName()
  local activeParts = v and v.data and v.data.activePartsData or nil
  if type(activeParts) ~= "table" then return nil end
  for _, part in pairs(activeParts) do
    local slotType = tostring(type(part) == "table" and part.slotType or ""):lower()
    local partName = tostring(type(part) == "table" and part.information and part.information.name or "")
    local lowerName = partName:lower()
    local isEngineSlot = slotType == "engine" or slotType:sub(-7) == "_engine"
    local isGenericName = lowerName == "engine" or lowerName:find("engine options", 1, true) ~= nil
    if isEngineSlot and partName ~= "" and not isGenericName then
      return partName
    end
  end
  return nil
end

local function findClutchAndFlywheelNames()
  local activeParts = v and v.data and v.data.activePartsData or nil
  if type(activeParts) ~= "table" then return nil, nil end
  local clutchName, clutchScore = nil, 0
  local flywheelName, flywheelScore = nil, 0
  for _, part in pairs(activeParts) do
    local slotType = tostring(type(part) == "table" and part.slotType or ""):lower()
    local partName = tostring(type(part) == "table" and part.information and part.information.name or "")
    local lowerName = partName:lower()
    local isClutchSlot = slotType:find("clutch", 1, true) ~= nil
    local isFlywheelSlot = slotType:find("flywheel", 1, true) ~= nil
    local isDifferential = slotType:find("differential", 1, true) ~= nil
    local isOptionsContainer = lowerName:find("options", 1, true) ~= nil
    if not isDifferential and not isOptionsContainer and partName ~= "" and (isClutchSlot or isFlywheelSlot) then
      if lowerName:find("clutch", 1, true) and lowerName ~= "clutch" then
        local score = (isClutchSlot and 2 or 0) + (isFlywheelSlot and 1 or 0)
        if score > clutchScore then
          clutchName, clutchScore = partName, score
        end
      elseif lowerName:find("flywheel", 1, true) and lowerName ~= "flywheel" then
        local score = isFlywheelSlot and 2 or 1
        if score > flywheelScore then
          flywheelName, flywheelScore = partName, score
        end
      end
    end
  end
  return clutchName, flywheelName
end

local function finalDriveRatio(axis)
  local activeParts = v and v.data and v.data.activePartsData or nil
  if type(activeParts) ~= "table" then return nil end
  local axisSuffix = "_" .. axis:lower()
  for _, part in pairs(activeParts) do
    local slotType = tostring(type(part) == "table" and part.slotType or ""):lower()
    local name = tostring(type(part) == "table" and part.information and part.information.name or "")
    if slotType:find("finaldrive", 1, true) and slotType:sub(-2) == axisSuffix
      and name:lower():find("final drive", 1, true) then
      return number(name:match("([%d%.]+)%s*:%s*1"))
    end
  end
  return nil
end

local function displayedTuningValue(part, title, actualValue)
  actualValue = number(actualValue)
  if type(part) ~= "table" or type(part.variables) ~= "table" or actualValue == nil then return nil end
  for _, variable in ipairs(part.variables) do
    if type(variable) == "table" and variable[8] == title then
      local minimum, maximum = number(variable[6]), number(variable[7])
      local options = variable[10]
      local displayMin = type(options) == "table" and number(options.minDis) or nil
      local displayMax = type(options) == "table" and number(options.maxDis) or nil
      if minimum and maximum and maximum ~= minimum and displayMin and displayMax then
        return displayMin + (actualValue - minimum) / (maximum - minimum) * (displayMax - displayMin)
      end
    end
  end
  return nil
end

local function differentialData(axis)
  local key = axis:lower()
  local device = powertrain and powertrain.getDevice and powertrain.getDevice("differential_" .. axis) or nil
  local part, name = findActivePart("differential_" .. key, "differential")
  if not device and not name then return nil end
  local differentialName = tostring(name or ""):lower()
  local hasLimitedSlip = differentialName:find("limited slip", 1, true)
    or differentialName:find("locking", 1, true)
    or differentialName:find("welded", 1, true)
  return {
    name = name,
    finalDriveRatio = finalDriveRatio(axis),
    powerLockPercent = displayedTuningValue(part, "Power Lock Rate", device and device.lsdLockCoef),
    coastLockPercent = displayedTuningValue(part, "Coast Lock Rate", device and device.lsdRevLockCoef),
    preloadNm = hasLimitedSlip and device and number(device.lsdPreload) or nil,
  }
end

local function maintenanceManagerLoaded()
  if not extensions then return false end
  if extensions.isExtensionLoaded then
    return extensions.isExtensionLoaded("maintenanceManager") == true
  end
  return type(maintenanceManager) == "table"
end

local function maintenanceNeedsAttention()
  if not maintenanceManagerLoaded() then return false end
  local manager = extensions and extensions.maintenanceManager or maintenanceManager
  if type(manager) ~= "table" or type(manager.getSnapshot) ~= "function" then return false end

  local ok, snapshot = pcall(manager.getSnapshot)
  if not ok or type(snapshot) ~= "table" or type(snapshot.categories) ~= "table" then return false end

  local thresholds = {
    engine = {oilCondition = 0.55, oilLevel = 0.50, ignitionService = 0.60},
    radiator = {coolantLevel = 0.55, coolantIntegrity = 0.60},
  }
  for categoryName, targets in pairs(thresholds) do
    local category = snapshot.categories[categoryName]
    if type(category) == "table" then
      if category.persistentCareerDamage == true then return true end
      local maintenance = category.maintenance
      if type(maintenance) == "table" then
        for itemName, target in pairs(targets) do
          local value = number(maintenance[itemName])
          if value and value <= target then return true end
        end
      end
    end
  end
  return false
end

local function shouldRequestMil(engine, thermals, ev)
  if not engine then return false end

  local nativeDamage = reportedBoolean(thermals, "pistonRingsDamaged") == true
    or reportedBoolean(thermals, "headGasketDamaged") == true
    or reportedBoolean(thermals, "connectingRodBearingsDamaged") == true
    or reportedBoolean(thermals, "engineHydrolocked") == true
  if nativeDamage then return true end

  local coolantTemp = firstNumber(ev.watertemp, ev.coolantTemperature, thermals and thermals.coolantTemperature)
  if coolantTemp and coolantTemp >= 120 then return true end

  local ratedTorque = number(engine.maxTorque)
  local torqueLimit = number(engine.maxTorqueLimit)
  local meaningfulRestriction = ratedTorque and ratedTorque > 0 and torqueLimit and torqueLimit < ratedTorque * 0.97
  -- RLS also reduces output as engines age. Only turn that restriction into a
  -- dashboard warning when an engine or cooling item is actually service-due.
  return meaningfulRestriction and maintenanceNeedsAttention()
end

local function buildState()
  local ev = electrics and electrics.values or {}
  local engine = getEngine()
  local isElectric = engine and engine.type == "electricMotor" or false
  local gearbox = getGearbox()
  local clutch = getClutch()
  local clutchConfig = v and v.data and v.data.clutch or nil
  -- Only report a hardware rating when the installed JBeam explicitly defines
  -- one. Some clutch devices derive lockTorque from engine output at runtime;
  -- that is not an installed-part torque specification.
  local clutchRatedTorque = clutchConfig and number(clutchConfig.lockTorque) or nil
  local clutchAvailableTorque = nil
  if clutchRatedTorque and clutch then
    clutchAvailableTorque = math.max(0, (number(clutch.lockTorque) or clutchRatedTorque)
      * (number(clutch.thermalEfficiency) or 1)
      * (number(clutch.damageLockTorqueCoef) or 1)
      * (number(clutch.wearLockTorqueCoef) or 1))
  end
  local thermals = engine and engine.thermals or nil
  local turbocharger = v and v.data and v.data.turbocharger or nil
  local supercharger = v and v.data and v.data.supercharger or nil
  local engineName = findEngineName()
  local _, gearboxName = findActivePart("transmission", "transmission")
  local clutchName, flywheelName = findClutchAndFlywheelNames()
  local _, centerCouplingName = findActivePart("transfer_case", nil)
  local _, turbochargerName = findActivePart("", "turbocharger")
  local _, superchargerName = findActivePart("", "supercharger")
  -- Output figures describe the current installed configuration's peak output.
  local ratedTorque = engine and firstNumber(engine.maxTorque, engine.torqueData and engine.torqueData.maxTorque) or nil
  local ratedPower = engine and powerHp(firstNumber(engine.maxPower, engine.torqueData and engine.torqueData.maxPower)) or nil
  -- maxTorqueRating is BeamNG's overtorque damage threshold, not engine output.
  local overtorqueThreshold = engine and firstNumber(
    engine.maxTorqueRating,
    engine.torqueData and engine.torqueData.maxTorqueRating
  ) or nil
  -- BeamNG starts accumulating over-rev damage above maxPhysicalAV.
  local overrevThresholdRpm = engine and engine.maxPhysicalAV and engine.maxPhysicalAV * 9.549296596 or nil
  local ecuLimiterRpm = engine and firstNumber(
    engine.revLimiterRPM
  ) or nil
  local propulsionRpm = isElectric
    and firstNumber(engine.outputRPM, engine.outputAV1 and engine.outputAV1 * 9.549296596)
    or firstNumber(ev.rpm, engine and engine.outputAV1 and engine.outputAV1 * 9.549296596)
  if isElectric and propulsionRpm then propulsionRpm = math.abs(propulsionRpm) end
  local motorBroken, motorDisabled, motorHasEnergy = nil, nil, nil
  if isElectric then
    motorBroken = reportedBoolean(engine, "isBroken")
    motorDisabled = reportedBoolean(engine, "isDisabled")
    motorHasEnergy = reportedBoolean(engine, "hasEnergy")
  end
  return {
    vehicleId = obj:getId(),
    vehicleName = v and v.config and (v.config.name or v.config.model) or nil,
    isElectric = isElectric,
    rpm = propulsionRpm,
    engineLoad = engine and (isElectric and normalizedEngineLoad(engine.engineLoad) or normalized(engine.engineLoad)) or nil,
    idleRpm = engine and engine.idleAV and engine.idleAV * 9.549296596 or nil,
    ecuLimiterRpm = ecuLimiterRpm,
    revLimiterType = engine and engine.revLimiterType or nil,
    revLimiterCutTime = engine and number(engine.revLimiterCutTime) or nil,
    wastegateStartPsi = turbocharger and number(turbocharger.wastegateStart) or nil,
    forcedInductionType = turbocharger and "Turbocharger" or (supercharger and "Supercharger" or nil),
    forcedInductionName = turbochargerName or superchargerName,
    ignition = firstNumber(ev.ignitionLevel, ev.ignition),
    engineRunning = firstReportedBoolean(ev, "engineRunning", "running"),
    fuel = normalized(ev.fuel),
    batteryCharge = isElectric and getElectricBatteryCharge() or nil,
    checkEngine = reportedBoolean(ev, "checkengine"),
    coolantTemp = firstNumber(ev.watertemp, ev.coolantTemperature, thermals and thermals.coolantTemperature),
    oilTemp = firstNumber(ev.oiltemp, ev.oilTemperature, thermals and thermals.oilTemperature),
    ratedTorqueNm = ratedTorque,
    motorTorqueLimitNm = isElectric and engine and number(engine.maxTorqueLimit) or nil,
    motorBroken = motorBroken,
    motorDisabled = motorDisabled,
    motorHasEnergy = motorHasEnergy,
    recentMotorTorqueAvailability = recentMotorRestrictionSeconds > 0 and recentMotorTorqueAvailability or nil,
    overtorqueThresholdNm = overtorqueThreshold,
    overrevThresholdRpm = overrevThresholdRpm,
    ratedPowerHp = ratedPower,
    ratedPowerKw = isElectric and ratedPower and ratedPower * 0.735499 or nil,
    motorMaxRpm = isElectric and firstNumber(engine.maxRPM, engine.maxAV and engine.maxAV * 9.549296596) or nil,
    engineName = engineName,
    pistonRingsDamaged = reportedBoolean(thermals, "pistonRingsDamaged"),
    headGasketDamaged = reportedBoolean(thermals, "headGasketDamaged"),
    rodBearingsDamaged = reportedBoolean(thermals, "connectingRodBearingsDamaged"),
    engineHydrolocked = reportedBoolean(thermals, "engineHydrolocked"),
    gearboxType = gearbox and gearbox.type or nil,
    gearboxName = gearboxName,
    forwardGearCount = gearbox and number(gearbox.maxGearIndex) or nil,
    clutchName = clutchName,
    flywheelName = flywheelName,
    clutchRatedTorqueNm = clutchRatedTorque,
    clutchAvailableTorqueNm = clutchAvailableTorque,
    clutchTempC = clutch and number(clutch.clutchTemperature) or nil,
    clutchWarningTempC = clutch and number(clutch.clutchWarningTemp) or nil,
    clutchMaxSafeTempC = clutch and number(clutch.clutchMaxSafeTemp) or nil,
    recentClutchHeatPeakC = recentClutchHeatSeconds > 0 and recentClutchHeatPeakC or nil,
    recentDamageEvents = recentDamageEventData(),
    clutchDamaged = reportedBoolean(clutch, "clutchPermanentlyDamaged"),
    frontDifferential = differentialData("F"),
    centerCoupling = centerCouplingName and {name = centerCouplingName} or nil,
    rearDifferential = differentialData("R"),
  }
end

local function updateGFX(dt)
  local elapsed = number(dt) or 0
  timer = timer + elapsed
  recentClutchHeatSeconds = math.max(0, recentClutchHeatSeconds - elapsed)
  recentMotorRestrictionSeconds = math.max(0, recentMotorRestrictionSeconds - elapsed)
  updateRecentDamageEvents(elapsed)
  if timer < UPDATE_INTERVAL then return end
  timer = 0
  local ev = electrics and electrics.values or {}
  local engine = getEngine()
  local clutch = getClutch()
  if engine and engine.type == "electricMotor" then
    local ratedTorque = number(engine.maxTorque)
    local torqueLimit = number(engine.maxTorqueLimit)
    local motorLoad = number(engine.engineLoad)
    if ratedTorque and ratedTorque > 0 and torqueLimit and motorLoad and motorLoad >= 0.35 then
      local availability = math.max(0, math.min(1, torqueLimit / ratedTorque))
      if availability < 0.995 then
        recentMotorTorqueAvailability = math.min(recentMotorTorqueAvailability or availability, availability)
        recentMotorRestrictionSeconds = RECENT_EVENT_SECONDS
      end
    end
  end
  if recentMotorRestrictionSeconds <= 0 then recentMotorTorqueAvailability = nil end
  local clutchTemp = clutch and number(clutch.clutchTemperature) or nil
  local clutchWarningTemp = clutch and number(clutch.clutchWarningTemp) or nil
  if clutchTemp and clutchWarningTemp and clutchTemp >= clutchWarningTemp then
    recentClutchHeatPeakC = math.max(recentClutchHeatPeakC or clutchTemp, clutchTemp)
    recentClutchHeatSeconds = 300
  elseif recentClutchHeatSeconds <= 0 then
    recentClutchHeatPeakC = nil
  end
  if shouldRequestMil(engine, engine and engine.thermals or nil, ev) then
    -- Only assert the MIL. The native vehicle controller remains responsible for clearing it.
    ev.checkengine = true
  end
  if streams and streams.willSend and streams.willSend("rlsObdScannerData") then
    gui.send("rlsObdScannerData", buildState())
  end
end

local function requestState()
  if gui then gui.send("rlsObdScannerData", buildState()) end
end

local function onExtensionLoaded()
  registerDamageListener()
end

M.onExtensionLoaded = onExtensionLoaded
M.updateGFX = updateGFX
M.requestState = requestState
M.onDamageDataChanged = onDamageDataChanged
return M
