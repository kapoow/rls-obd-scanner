local M = {}

M.dependencies = {"ui_router_routeManager"}

local TAG = "rlsObd_routes"
local SOURCE = "rls-obd-scanner"
local ROUTE = "phone-obd-scanner"
local APP_ID = "rls-obd-scanner"
local MONITOR_INTERVAL = 5
local monitorTimer = MONITOR_INTERVAL

local function careerActive()
  return career_career and career_career.isActive and career_career.isActive() == true
end

local function scannerInstalled()
  if not extensions.isExtensionLoaded("ui_phone_layout") then
    extensions.load("ui_phone_layout")
  end
  local layout = extensions.ui_phone_layout or ui_phone_layout
  return layout and layout.isAppInstalled and layout.isAppInstalled(APP_ID) == true
end

local function ensureVehicleMonitor()
  if not careerActive() or not be then return end
  local vehicle = be:getPlayerVehicle(0)
  if not vehicle then return end
  if scannerInstalled() then
    vehicle:queueLuaCommand("if not extensions.isExtensionLoaded('rlsObdScanner') then extensions.load('rlsObdScanner') end")
  else
    vehicle:queueLuaCommand("if extensions.isExtensionLoaded('rlsObdScanner') then extensions.unload('rlsObdScanner') end")
  end
end

local function register()
  if not ui_router_routeManager or not ui_router_routeManager.registerModRoutes then
    log("E", TAG, "BeamNG UI route manager is unavailable")
    return false
  end
  if ui_router_routeManager.getRoute and ui_router_routeManager.getRoute(ROUTE) then
    return true
  end
  local result = ui_router_routeManager.registerModRoutes(SOURCE, {{
    name = ROUTE,
    meta = {
      infoBar = {visible = false, showSysInfo = false},
      topBar = {visible = false},
      uiApps = {shown = false},
      luaRoute = {backTarget = "phone-main"},
    },
  }})
  local ok = result and result.success == true
  log(ok and "I" or "E", TAG, ok and "phone route registered" or "phone route registration failed")
  return ok
end

local function unregister()
  if ui_router_routeManager and ui_router_routeManager.unregisterModRoutes then
    ui_router_routeManager.unregisterModRoutes(SOURCE)
  end
end

local function onExtensionLoaded()
  register()
  ensureVehicleMonitor()
end

local function onUpdate(dtReal)
  monitorTimer = monitorTimer + (tonumber(dtReal) or 0)
  if monitorTimer < MONITOR_INTERVAL then return end
  monitorTimer = 0
  ensureVehicleMonitor()
end

local function onVehicleSwitched(_, _, player)
  if player ~= nil and player ~= 0 then return end
  monitorTimer = MONITOR_INTERVAL
  ensureVehicleMonitor()
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = unregister
M.onUpdate = onUpdate
M.onVehicleSwitched = onVehicleSwitched
M.register = register
return M
