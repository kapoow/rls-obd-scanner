local M = {}

M.dependencies = {"ui_router_routeManager"}

local TAG = "rlsObd_routes"
local SOURCE = "rls-obd-scanner"
local ROUTE = "phone-obd-scanner"

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

M.onExtensionLoaded = register
M.onExtensionUnloaded = unregister
M.register = register
return M
