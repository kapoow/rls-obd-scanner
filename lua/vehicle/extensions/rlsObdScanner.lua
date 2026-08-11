-- Read-only vehicle telemetry provider for the RLS phone scanner.
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

local function powerKw(raw)
  raw = number(raw)
  if not raw or raw <= 0 then return nil end
  -- BeamNG maxPower is normally PS-scale, while some devices report watts.
  return raw > 10000 and raw / 1000 or raw * 0.73549875
end

local function reportedBoolean(container, key)
  if type(container) ~= "table" or container[key] == nil then return nil end
  return container[key] == true
end

local function buildState()
  local ev = electrics and electrics.values or {}
  local engine = getEngine()
  local gearbox = getGearbox()
  local clutch = getClutch()
  local thermals = engine and engine.thermals or nil
  local ratedTorque = engine and firstNumber(engine.maxTorque, engine.torqueData and engine.torqueData.maxTorque) or nil
  local mechanicalTorqueRating = engine and firstNumber(
    engine.maxTorqueRating,
    engine.torqueData and engine.torqueData.maxTorqueRating
  ) or nil
  local mechanicalRpmLimit = engine and firstNumber(
    engine.maxAvailableRPM,
    engine.torqueData and engine.torqueData.maxAvailableRPM
  ) or nil
  return {
    vehicleId = obj:getId(),
    vehicleName = v and v.config and (v.config.name or v.config.model) or nil,
    rpm = firstNumber(ev.rpm, engine and engine.outputAV1 and engine.outputAV1 * 9.549296596),
    idleRpm = engine and engine.idleAV and engine.idleAV * 9.549296596 or nil,
    redlineRpm = engine and engine.maxAV and engine.maxAV * 9.549296596 or nil,
    ignition = firstNumber(ev.ignitionLevel, ev.ignition),
    fuel = normalized(ev.fuel),
    coolantTemp = firstNumber(ev.watertemp, ev.coolantTemperature, thermals and thermals.coolantTemperature),
    oilTemp = firstNumber(ev.oiltemp, ev.oilTemperature, thermals and thermals.oilTemperature),
    ratedTorqueNm = ratedTorque,
    mechanicalTorqueRatingNm = mechanicalTorqueRating,
    mechanicalRpmLimit = mechanicalRpmLimit,
    ratedPowerKw = engine and powerKw(firstNumber(engine.maxPower, engine.torqueData and engine.torqueData.maxPower)) or nil,
    pistonRingsDamaged = reportedBoolean(thermals, "pistonRingsDamaged"),
    headGasketDamaged = reportedBoolean(thermals, "headGasketDamaged"),
    rodBearingsDamaged = reportedBoolean(thermals, "connectingRodBearingsDamaged"),
    engineHydrolocked = reportedBoolean(thermals, "engineHydrolocked"),
    gearboxType = gearbox and gearbox.type or nil,
    clutchDamaged = reportedBoolean(clutch, "clutchPermanentlyDamaged"),
  }
end

local function updateGFX(dt)
  timer = timer + (number(dt) or 0)
  if timer < UPDATE_INTERVAL then return end
  timer = 0
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
