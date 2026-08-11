-- Vehicle telemetry provider and conservative malfunction-indicator bridge.
local M = {}

local UPDATE_INTERVAL = 0.20
local timer = 0

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

local function normalized(value)
  value = number(value)
  if value == nil or value < 0 or value > 1 then return nil end
  return value
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

local function finalDriveRatio(axis)
  local _, name = findActivePart("finaldrive_" .. axis:lower(), "final drive")
  if not name then return nil end
  return number(name:match("([%d%.]+)%s*:%s*1"))
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
  return {
    name = name,
    finalDriveRatio = finalDriveRatio(axis),
    powerLockPercent = displayedTuningValue(part, "Power Lock Rate", device and device.lsdLockCoef),
    coastLockPercent = displayedTuningValue(part, "Coast Lock Rate", device and device.lsdRevLockCoef),
    preloadNm = device and number(device.lsdPreload) or nil,
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
  local gearbox = getGearbox()
  local clutch = getClutch()
  local thermals = engine and engine.thermals or nil
  local turbocharger = v and v.data and v.data.turbocharger or nil
  local supercharger = v and v.data and v.data.supercharger or nil
  local _, gearboxName = findActivePart("transmission", "transmission")
  local _, clutchName = findActivePart("", "clutch", "options")
  local _, centerCouplingName = findActivePart("transfer_case", nil)
  local _, turbochargerName = findActivePart("", "turbocharger")
  local _, superchargerName = findActivePart("", "supercharger")
  -- Output figures describe the current installed configuration's peak output.
  local ratedTorque = engine and firstNumber(engine.maxTorque, engine.torqueData and engine.torqueData.maxTorque) or nil
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
  return {
    vehicleId = obj:getId(),
    vehicleName = v and v.config and (v.config.name or v.config.model) or nil,
    rpm = firstNumber(ev.rpm, engine and engine.outputAV1 and engine.outputAV1 * 9.549296596),
    engineLoad = engine and normalized(engine.engineLoad) or nil,
    idleRpm = engine and engine.idleAV and engine.idleAV * 9.549296596 or nil,
    ecuLimiterRpm = ecuLimiterRpm,
    revLimiterType = engine and engine.revLimiterType or nil,
    revLimiterCutTime = engine and number(engine.revLimiterCutTime) or nil,
    wastegateStartPsi = turbocharger and number(turbocharger.wastegateStart) or nil,
    forcedInductionType = turbocharger and "Turbocharger" or (supercharger and "Supercharger" or nil),
    forcedInductionName = turbochargerName or superchargerName,
    ignition = firstNumber(ev.ignitionLevel, ev.ignition),
    fuel = normalized(ev.fuel),
    checkEngine = reportedBoolean(ev, "checkengine"),
    coolantTemp = firstNumber(ev.watertemp, ev.coolantTemperature, thermals and thermals.coolantTemperature),
    oilTemp = firstNumber(ev.oiltemp, ev.oilTemperature, thermals and thermals.oilTemperature),
    ratedTorqueNm = ratedTorque,
    overtorqueThresholdNm = overtorqueThreshold,
    overrevThresholdRpm = overrevThresholdRpm,
    ratedPowerHp = engine and powerHp(firstNumber(engine.maxPower, engine.torqueData and engine.torqueData.maxPower)) or nil,
    pistonRingsDamaged = reportedBoolean(thermals, "pistonRingsDamaged"),
    headGasketDamaged = reportedBoolean(thermals, "headGasketDamaged"),
    rodBearingsDamaged = reportedBoolean(thermals, "connectingRodBearingsDamaged"),
    engineHydrolocked = reportedBoolean(thermals, "engineHydrolocked"),
    gearboxType = gearbox and gearbox.type or nil,
    gearboxName = gearboxName,
    forwardGearCount = gearbox and number(gearbox.maxGearIndex) or nil,
    clutchName = clutchName,
    clutchLockTorqueNm = clutch and number(clutch.lockTorque) or nil,
    clutchDamaged = reportedBoolean(clutch, "clutchPermanentlyDamaged"),
    frontDifferential = differentialData("F"),
    centerCoupling = centerCouplingName and {name = centerCouplingName} or nil,
    rearDifferential = differentialData("R"),
  }
end

local function updateGFX(dt)
  timer = timer + (number(dt) or 0)
  if timer < UPDATE_INTERVAL then return end
  timer = 0
  local ev = electrics and electrics.values or {}
  local engine = getEngine()
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

M.updateGFX = updateGFX
M.requestState = requestState
return M
