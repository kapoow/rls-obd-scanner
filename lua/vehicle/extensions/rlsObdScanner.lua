-- Vehicle telemetry provider and conservative malfunction-indicator bridge.
local M = {}

local UPDATE_INTERVAL = 0.20
local RECENT_EVENT_SECONDS = 300
local timer = 0
local milRequestMode = nil
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
    turbochargerHot = true,
    inductionSystemDamaged = true,
  },
  gearbox = {
    synchroWear = true,
  },
  pressureTank = {
    deformationLeak = true,
    breakLeak = true,
  },
  drivingDynamics = {
    systemStateDegraded = true,
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

local function isCombustionEngine(device)
  return tostring(device and device.type or ""):find("combustionEngine", 1, true) == 1
end

local function getEngine()
  if powertrain and powertrain.getDevice then
    local mainEngine = powertrain.getDevice("mainEngine")
    if mainEngine then return mainEngine end
  end
  local devices = powertrain and powertrain.getDevicesByCategory and powertrain.getDevicesByCategory("engine") or nil
  for _, device in pairs(devices or {}) do
    if isCombustionEngine(device) then return device end
  end
  return devices and devices[1] or nil
end

local function findDescendantByType(device, targetType, visited)
  if type(device) ~= "table" then return nil end
  visited = visited or {}
  if visited[device] then return nil end
  visited[device] = true
  if device.type == targetType then return device end
  for _, child in ipairs(device.children or {}) do
    local found = findDescendantByType(child, targetType, visited)
    if found then return found end
  end
  return nil
end

local function drivesWheels(device)
  return findDescendantByType(device, "differential") ~= nil
end

local function getElectricMotors()
  local result = {}
  local devices = powertrain and powertrain.getDevicesByCategory and powertrain.getDevicesByCategory("engine") or nil
  for _, device in pairs(devices or {}) do
    -- Generator machines also use BeamNG's electricMotor device type. Only
    -- report motors whose output path reaches a differential as traction motors.
    if device.type == "electricMotor" and drivesWheels(device) then result[#result + 1] = device end
  end
  table.sort(result, function(a, b)
    return tostring(a.name or "") < tostring(b.name or "")
  end)
  return result
end

local function getGearbox()
  if powertrain and powertrain.getDevice then
    local mainGearbox = powertrain.getDevice("gearbox")
    if mainGearbox then return mainGearbox end
  end
  local devices = powertrain and powertrain.getDevicesByCategory and powertrain.getDevicesByCategory("gearbox") or nil
  for _, device in pairs(devices or {}) do
    if device.type ~= "rangeBox" then return device end
  end
  return nil
end

local function getClutch()
  local devices = powertrain and powertrain.getDevicesByCategory and powertrain.getDevicesByCategory("clutch") or nil
  return devices and devices[1] or nil
end

local function hasDrivingDynamicsControl()
  if not (controller and controller.getControllersFromPath) then return false end
  for _, deviceController in pairs(controller.getControllersFromPath("drivingDynamics/") or {}) do
    if deviceController.typeName == "drivingDynamics/CMU" then return true end
  end
  return false
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

local function findActivePartForPowertrainDevice(deviceName)
  local activeParts = v and v.data and v.data.activePartsData or nil
  if type(activeParts) ~= "table" then return nil end
  for _, part in pairs(activeParts) do
    local partPowertrain = type(part) == "table" and part.powertrain or nil
    for _, row in ipairs(type(partPowertrain) == "table" and partPowertrain or {}) do
      if type(row) == "table" and row[2] == deviceName then
        local partName = tostring(part.information and part.information.name or "")
        return part, partName ~= "" and partName or nil
      end
    end
  end
  return nil
end

local function deviceHasMode(device, wantedMode)
  for _, mode in pairs(type(device) == "table" and device.availableModes or {}) do
    if mode == wantedMode then return true end
  end
  return false
end

local function transferCaseData(partName)
  if not powertrain then return nil end
  local devices = powertrain.getDevices and powertrain.getDevices() or {}
  local rangeBox, selectableDrive = nil, nil
  for deviceName, device in pairs(devices or {}) do
    if device.type == "rangeBox" and deviceHasMode(device, "high") and deviceHasMode(device, "low") then
      rangeBox = rangeBox or device
    end
    if tostring(deviceName):lower():find("transfer", 1, true)
      and deviceHasMode(device, "connected") and deviceHasMode(device, "disconnected") then
      selectableDrive = selectableDrive or device
    end
  end
  if not partName and not rangeBox and not selectableDrive then return nil end
  local currentDriveMode = selectableDrive and ({connected = "4WD", disconnected = "2WD"})[selectableDrive.mode] or nil
  local currentRangeMode = rangeBox and ({high = "High", low = "Low"})[rangeBox.mode] or nil
  return {
    name = partName,
    driveModes = selectableDrive and {"2WD", "4WD"} or nil,
    rangeModes = rangeBox and {"High", "Low"} or nil,
    currentDriveMode = currentDriveMode,
    currentRangeMode = currentRangeMode,
  }
end

local function findEngineName()
  local activeParts = v and v.data and v.data.activePartsData or nil
  if type(activeParts) ~= "table" then return nil end
  local bestName, bestScore = nil, 0
  for partKey, part in pairs(activeParts) do
    local slotType = tostring(type(part) == "table" and part.slotType or ""):lower()
    local partName = tostring(type(part) == "table" and part.information and part.information.name or "")
    local lowerName = partName:lower()
    local lowerKey = tostring(partKey):lower()
    local isManagement = lowerName:find("management", 1, true)
      or lowerKey:find("ecu", 1, true)
    local isGenericName = lowerName == "engine" or lowerName:find("engine options", 1, true)
    if partName ~= "" and not isManagement and not isGenericName then
      local score = 0
      if slotType == "engine" or slotType:sub(-7) == "_engine" then score = score + 4 end
      if lowerKey:find("engine", 1, true) then score = score + 2 end
      if lowerName:find("engine", 1, true) then score = score + 2 end
      if lowerName:find("generator", 1, true) then score = score + 1 end
      if score > bestScore then bestName, bestScore = partName, score end
    end
  end
  return bestName
end

local function electricMotorPosition(device)
  local name = tostring(device and device.name or ""):lower()
  if name:find("front", 1, true) then return "Front" end
  local rearIndex = name:match("rear.-(%d+)$")
  if rearIndex then return "Rear axle " .. rearIndex end
  if name:find("rear", 1, true) then return "Rear" end
  return nil
end

local function findElectricMotorName(device)
  local position = electricMotorPosition(device)
  if position and position:find("Rear", 1, true) then
    local rearIndex = tostring(device and device.name or ""):match("(%d+)$")
    local _, name = findActivePart(rearIndex and ("differential_r_" .. rearIndex) or "differential_r", "electric drive")
    if name then return name end
  elseif position == "Front" then
    local name = findEngineName()
    if name then return name end
  end
  return position and (position .. " electric motor") or "Electric motor"
end

local function electricMotorData(device)
  local ratedPowerHp = powerHp(firstNumber(device.maxPower, device.torqueData and device.torqueData.maxPower))
  local rearIndex = tostring(device and device.name or ""):match("(%d+)$")
  -- EV reductions are not represented by one universal device type. RLS
  -- series hybrids use range boxes, while some native EVs use a fixed-ratio
  -- torsion reactor. Prefer the selectable range box when both exist.
  local reduction = findDescendantByType(device, "rangeBox")
    or findDescendantByType(device, "torsionReactor")
  local differential = findDescendantByType(device, "differential")
  local reductionName, differentialName = nil, nil
  if rearIndex then
    local _
    _, reductionName = findActivePart("ev_reduction_r_" .. rearIndex, nil)
    _, differentialName = findActivePart("ev_differential_r_" .. rearIndex, "differential")
  end
  local reductionRatios = {}
  for _, ratio in pairs(reduction and reduction.gearRatios or {}) do
    if number(ratio) then reductionRatios[#reductionRatios + 1] = number(ratio) end
  end
  table.sort(reductionRatios, function(a, b) return a > b end)
  local differentialRatio = differential and number(differential.gearRatio) or nil
  return {
    id = tostring(device.name or "electricMotor"),
    position = electricMotorPosition(device),
    name = findElectricMotorName(device),
    rpm = math.abs(firstNumber(device.outputRPM, device.outputAV1 and device.outputAV1 * 9.549296596) or 0),
    load = normalizedEngineLoad(device.engineLoad),
    ratedTorqueNm = firstNumber(device.maxTorque, device.torqueData and device.torqueData.maxTorque),
    torqueLimitNm = number(device.maxTorqueLimit),
    ratedPowerHp = ratedPowerHp,
    maxRpm = firstNumber(device.maxRPM, device.maxAV and device.maxAV * 9.549296596),
    reductionName = reductionName,
    reductionRatios = reductionRatios,
    reductionRatio = reduction and number(reduction.gearRatio) or nil,
    reductionType = reduction and reduction.type or nil,
    reductionMode = reduction and reduction.mode or nil,
    differentialName = differentialName,
    -- A unity differential follows the real upstream reduction on several EVs
    -- and is not useful as a separately labelled final drive.
    finalDriveRatio = differentialRatio and math.abs(differentialRatio - 1) > 0.0001
      and differentialRatio or nil,
    broken = reportedBoolean(device, "isBroken"),
    disabled = reportedBoolean(device, "isDisabled"),
    hasEnergy = reportedBoolean(device, "hasEnergy"),
  }
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

local function partDefinesPowertrainValue(part, deviceName, fieldName)
  if type(part) ~= "table" or type(part.powertrain) ~= "table" then return false end
  for _, row in ipairs(part.powertrain) do
    local options = type(row) == "table" and row[5] or nil
    if type(row) == "table" and row[2] == deviceName
      and type(options) == "table" and options[fieldName] ~= nil then
      return true
    end
  end
  return false
end

local function differentialData(axis)
  local key = axis:lower()
  local deviceName = "differential_" .. axis
  local device = powertrain and powertrain.getDevice and powertrain.getDevice(deviceName) or nil
  local part, name = findActivePartForPowertrainDevice(deviceName)
  if not name then part, name = findActivePart("differential_" .. key, "differential") end
  if not device and not name then return nil end
  return {
    name = name,
    finalDriveRatio = firstNumber(finalDriveRatio(axis), device and device.gearRatio),
    powerLockPercent = displayedTuningValue(part, "Power Lock Rate", device and device.lsdLockCoef),
    coastLockPercent = displayedTuningValue(part, "Coast Lock Rate", device and device.lsdRevLockCoef),
    preloadNm = partDefinesPowertrainValue(part, deviceName, "lsdPreload")
      and device and number(device.lsdPreload) or nil,
  }
end

local function getMaintenanceManager()
  if not extensions then return nil end
  if extensions.isExtensionLoaded and extensions.isExtensionLoaded("maintenanceManager") ~= true then
    return nil
  end
  local manager = extensions.maintenanceManager or rawget(_G, "maintenanceManager")
  if type(manager) ~= "table" or type(manager.getSnapshot) ~= "function" then return nil end
  return manager
end

local maintenanceModeEnabled = nil

local function maintenanceNeedsAttention()
  if maintenanceModeEnabled ~= true then return false end
  local manager = getMaintenanceManager()
  if not manager then return false end

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

local function getMilRequestMode(engine, thermals, ev)
  if not engine then return nil end

  local nativeDamage = reportedBoolean(thermals, "pistonRingsDamaged") == true
    or reportedBoolean(thermals, "headGasketDamaged") == true
    or reportedBoolean(thermals, "connectingRodBearingsDamaged") == true
    or reportedBoolean(thermals, "engineHydrolocked") == true
  if nativeDamage then return "steady" end

  local coolantTemp = firstNumber(ev.watertemp, ev.coolantTemperature, thermals and thermals.coolantTemperature)
  if coolantTemp and coolantTemp >= 120 then return "steady" end

  local ratedTorque = number(engine.maxTorque)
  local torqueLimit = number(engine.maxTorqueLimit)
  local meaningfulRestriction = ratedTorque and ratedTorque > 0 and torqueLimit and torqueLimit < ratedTorque * 0.97
  -- RLS restricts output for oil starvation, overheating, ignition faults, and
  -- damage (no longer for mileage age alone). Only turn that restriction into a
  -- dashboard warning when an engine or cooling item is actually service-due.
  if not meaningfulRestriction or not maintenanceNeedsAttention() then return nil end

  -- A high applied ignition-error chance is an active severe fault, so keep the
  -- MIL asserted. Less severe overdue maintenance retains the brief advisory
  -- pulse produced by the slower scanner update.
  local ignitionErrorChance = math.max(
    number(engine.fastIgnitionErrorChance) or 0,
    number(engine.slowIgnitionErrorChance) or 0
  )
  return ignitionErrorChance >= 0.02 and "steady" or "pulse"
end

local function collectLiveDevices()
  return {
    ev = electrics and electrics.values or {},
    engine = getEngine(),
    electricMotors = getElectricMotors(),
    gearbox = getGearbox(),
    clutch = getClutch(),
  }
end

local function buildState(devices)
  devices = devices or collectLiveDevices()
  local ev = devices.ev
  local engine = devices.engine
  local electricMotorDevices = devices.electricMotors
  local hasElectricDrive = #electricMotorDevices > 0
  local isHybrid = hasElectricDrive and isCombustionEngine(engine)
  local isElectric = hasElectricDrive and not isHybrid
  local motors = {}
  local propulsionRpm = nil
  local propulsionLoad = nil
  local worstMotorAvailability = nil
  local worstMotor = nil
  for _, device in ipairs(electricMotorDevices) do
    local motor = electricMotorData(device)
    motors[#motors + 1] = motor
    if motor.rpm then propulsionRpm = math.max(propulsionRpm or 0, motor.rpm) end
    if motor.load then propulsionLoad = math.max(propulsionLoad or 0, motor.load) end
    if motor.ratedTorqueNm and motor.ratedTorqueNm > 0 and motor.torqueLimitNm then
      local availability = math.max(0, math.min(1, motor.torqueLimitNm / motor.ratedTorqueNm))
      if not worstMotorAvailability or availability < worstMotorAvailability then
        worstMotorAvailability = availability
        worstMotor = motor
      end
    end
  end
  local gearbox = devices.gearbox
  local clutch = devices.clutch
  local clutchConfig = v and v.data and v.data.clutch or nil
  -- Only report a hardware rating when the installed JBeam explicitly defines
  -- one. Some clutch devices derive lockTorque from engine output at runtime;
  -- that is not an installed-part torque specification.
  local clutchRatedTorque = clutchConfig and number(clutchConfig.lockTorque) or nil
  local clutchAvailableTorque = clutch and number(clutch.lockTorque) or nil
  if clutchAvailableTorque then
    clutchAvailableTorque = math.max(0, clutchAvailableTorque
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
  local transferCase = transferCaseData(centerCouplingName)
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
  local engineRpm = engine and math.abs(firstNumber(engine.outputRPM, engine.outputAV1 and engine.outputAV1 * 9.549296596) or 0) or nil
  if not hasElectricDrive then propulsionRpm = firstNumber(ev.rpm, engineRpm) end
  local motorBroken, motorDisabled, motorHasEnergy = nil, nil, nil
  for _, motor in ipairs(motors) do
    if motor.broken ~= nil then motorBroken = motorBroken == true or motor.broken end
    if motor.disabled ~= nil then motorDisabled = motorDisabled == true or motor.disabled end
    if motor.hasEnergy ~= nil then motorHasEnergy = motorHasEnergy == true or motor.hasEnergy end
  end
  return {
    vehicleId = obj:getId(),
    maintenanceModeEnabled = maintenanceModeEnabled,
    vehicleName = v and v.config and (v.config.name or v.config.model) or nil,
    isElectric = isElectric,
    isHybrid = isHybrid,
    hasElectricDrive = hasElectricDrive,
    motors = motors,
    rpm = propulsionRpm,
    engineRpm = engineRpm,
    propulsionLoad = propulsionLoad,
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
    generatorRunning = isHybrid and engineRpm and engineRpm >= 100 or nil,
    fuel = normalized(ev.fuel),
    batteryCharge = hasElectricDrive and getElectricBatteryCharge() or nil,
    airPressurePa = firstNumber(ev.mainAirTank_pressureRelative),
    lowAirPressure = reportedBoolean(ev, "lowAirPressure"),
    parkingBrakeApplied = firstReportedBoolean(ev, "parkingbrake", "parkingbrake_input"),
    hasDrivingDynamicsControl = hasDrivingDynamicsControl(),
    checkEngine = reportedBoolean(ev, "checkengine"),
    coolantTemp = isCombustionEngine(engine)
      and firstNumber(thermals and thermals.coolantTemperature, ev.coolantTemperature, ev.watertemp)
      or firstNumber(ev.watertemp, ev.coolantTemperature, thermals and thermals.coolantTemperature),
    oilTemp = isCombustionEngine(engine)
      and firstNumber(thermals and thermals.oilTemperature, ev.oilTemperature, ev.oiltemp)
      or firstNumber(ev.oiltemp, ev.oilTemperature, thermals and thermals.oilTemperature),
    ratedTorqueNm = ratedTorque,
    motorRestrictionRatedTorqueNm = worstMotor and worstMotor.ratedTorqueNm or nil,
    motorTorqueLimitNm = worstMotor and worstMotor.torqueLimitNm or nil,
    motorBroken = motorBroken,
    motorDisabled = motorDisabled,
    motorHasEnergy = motorHasEnergy,
    recentMotorTorqueAvailability = recentMotorRestrictionSeconds > 0 and recentMotorTorqueAvailability or nil,
    overtorqueThresholdNm = overtorqueThreshold,
    overrevThresholdRpm = overrevThresholdRpm,
    ratedPowerHp = ratedPower,
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
    transferCase = transferCase,
    centerCoupling = centerCouplingName and not (transferCase and (transferCase.driveModes or transferCase.rangeModes))
      and {name = centerCouplingName} or nil,
    rearDifferential = differentialData("R"),
  }
end

local function updateGFX(dt)
  local elapsed = number(dt) or 0
  timer = timer + elapsed
  recentClutchHeatSeconds = math.max(0, recentClutchHeatSeconds - elapsed)
  recentMotorRestrictionSeconds = math.max(0, recentMotorRestrictionSeconds - elapsed)
  updateRecentDamageEvents(elapsed)
  if milRequestMode == "steady" and electrics and electrics.values then
    electrics.values.checkengine = true
  end
  if timer < UPDATE_INTERVAL then return end
  timer = 0
  local devices = collectLiveDevices()
  local ev = devices.ev
  local engine = devices.engine
  local clutch = devices.clutch
  for _, motor in ipairs(devices.electricMotors) do
    local ratedTorque = number(motor.maxTorque)
    local torqueLimit = number(motor.maxTorqueLimit)
    local motorLoad = number(motor.engineLoad)
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
  milRequestMode = getMilRequestMode(engine, engine and engine.thermals or nil, ev)
  if milRequestMode then
    -- Never write false: when the RLS condition clears, the native vehicle
    -- controller immediately regains sole ownership of the warning state.
    ev.checkengine = true
  end
  if streams and streams.willSend and streams.willSend("rlsObdScannerData") then
    gui.send("rlsObdScannerData", buildState(devices))
  end
end

local function requestState()
  if gui then gui.send("rlsObdScannerData", buildState()) end
end

local function setMaintenanceModeEnabled(enabled)
  if type(enabled) == "boolean" then
    maintenanceModeEnabled = enabled
  else
    maintenanceModeEnabled = nil
  end
  requestState()
end

local function onExtensionLoaded()
  registerDamageListener()
end

M.onExtensionLoaded = onExtensionLoaded
M.updateGFX = updateGFX
M.requestState = requestState
M.setMaintenanceModeEnabled = setMaintenanceModeEnabled
M.onDamageDataChanged = onDamageDataChanged
return M
