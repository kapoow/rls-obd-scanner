const TAG = "[rls_obd_scanner]"
const APP_ID = "rls-obd-scanner"
const ROUTE = "phone-obd-scanner"
const VIEW = "/ui/ui-vue/mods/rls_obd_scanner/PhoneObdScanner.vue"

let stopWatch = null
let stopLayoutEvents = null

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

async function waitForUi(timeoutMs = 60000) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    if (window.Vue && window.bngVue?.app?._context && window.vueRouter) return true
    await sleep(50)
  }
  return false
}

function definition() {
  return {
    id: APP_ID,
    name: "OBD Scanner",
    iconImage: "/ui/entrypoints/main/tiles/rls-obd-scanner.svg",
    iconImageFit: "contain",
    route: "/career/" + ROUTE,
    color: "#101923",
    iconColor: "#50e3a4",
    category: "Tools",
    defaultPage: 0,
    defaultPosition: 16,
    systemApp: false,
    hideFromStore: false,
    isUsageUnlocked: true,
    storeTagline: "Live vehicle diagnostics and maintenance data",
    storeDescription:
      "View engine, thermal, drivetrain and service information from the current vehicle.",
    lockedMessage: "",
  }
}

async function loadView() {
  const { getComponent } = await import("@/services/modManager")
  let data = await getComponent(VIEW, false, true)
  if (!data?.compiled && typeof data?.compile === "function") data = await data.compile()
  if (data?.error || !data?.component) {
    console.error(TAG, "view failed to compile", data?.error, data?.errorObj)
    return null
  }
  return data.component
}

async function addRoute() {
  if (window.vueRouter.hasRoute?.(ROUTE)) return true
  const component = await loadView()
  if (!component) return false
  window.vueRouter.addRoute({ path: "/career/" + ROUTE, name: ROUTE, component })
  return true
}

async function injectApp() {
  const mod = await import("@/modules/career/utils/phoneAppRegistry")
  const { lua, useBridge } = await import("@/bridge")
  if (typeof mod.usePhoneApps !== "function") return false
  const { catalogApps, availableApps } = mod.usePhoneApps()
  const { events } = useBridge()
  const app = definition()
  let installed = null
  const syncVehicleMonitor = () => {
    try {
      Promise.resolve(lua.rlsObd_routes.ensureVehicleMonitor()).catch(error => {
        console.warn(TAG, "vehicle monitor sync failed", error)
      })
    } catch (error) {
      console.warn(TAG, "vehicle monitor sync failed", error)
    }
  }
  const ensureCatalog = () => {
    const list = catalogApps
    if (Array.isArray(list?.value) && !list.value.some(item => item?.id === APP_ID)) list.value.push(app)
  }
  const syncAvailable = () => {
    if (!Array.isArray(availableApps?.value)) return
    const present = availableApps.value.some(item => item?.id === APP_ID)
    if (installed && !present) availableApps.value.push(app)
    if (!installed && present) availableApps.value = availableApps.value.filter(item => item?.id !== APP_ID)
  }
  const onLayoutData = data => {
    const nextInstalled = Array.isArray(data?.installedAppIds) && data.installedAppIds.includes(APP_ID)
    installed = nextInstalled
    ensureCatalog()
    syncAvailable()
    syncVehicleMonitor()
  }
  ensureCatalog()
  syncAvailable()
  stopWatch = window.Vue.watch(
    () => [catalogApps?.value, availableApps?.value],
    () => { ensureCatalog(); syncAvailable() },
    { flush: "post" }
  )
  events.on('phoneLayoutData', onLayoutData)
  stopLayoutEvents = () => events.off('phoneLayoutData', onLayoutData)
  await lua.extensions.load('ui_phone_layout')
  lua.ui_phone_layout?.requestLayout?.()
  return true
}

export async function onLoad() {
  try {
    if (!await waitForUi()) return console.error(TAG, "timed out waiting for Vue")
    const route = await addRoute()
    const app = await injectApp()
    console.log(TAG, "loaded", { route, app })
  } catch (error) {
    console.error(TAG, "load failed", error)
  }
}

export async function onUnload() {
  if (stopWatch) { stopWatch(); stopWatch = null }
  if (stopLayoutEvents) { stopLayoutEvents(); stopLayoutEvents = null }
  if (window.vueRouter?.hasRoute?.(ROUTE)) window.vueRouter.removeRoute(ROUTE)
}
