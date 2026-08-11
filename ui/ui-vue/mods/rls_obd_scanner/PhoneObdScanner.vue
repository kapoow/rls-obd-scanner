<template>
  <PhoneWrapper app-name="Vehicle Scanner">
    <div class="scanner">
      <header class="hero">
        <div>
          <div class="eyebrow">CONNECTED VEHICLE</div>
          <h1>{{ vehicleTitle }}</h1>
        </div>
        <span class="status" :class="{ online: liveOnline }">{{ liveOnline ? 'CONNECTED' : 'WAITING' }}</span>
      </header>

      <nav class="tabs" aria-label="Scanner sections">
        <button v-for="item in tabs" :key="item.id" :class="{ active: tab === item.id }" @click="tab = item.id">
          {{ item.label }}
        </button>
      </nav>

      <main v-if="tab === 'live'">
        <section class="gauges">
          <article v-if="isNumber(live.rpm)" class="gauge">
            <span>Engine speed</span><strong>{{ whole(live.rpm) }}</strong><small>rpm</small>
            <div class="bar"><i :style="{ width: rpmPercent + '%' }"></i></div>
          </article>
          <article v-if="isNumber(live.coolantTemp)" class="gauge">
            <span>Coolant temperature</span><strong>{{ temperature(live.coolantTemp) }}</strong><small>°C</small>
            <div class="bar"><i :class="{ hot: live.coolantTemp >= 115 }" :style="{ width: temperaturePercent + '%' }"></i></div>
          </article>
        </section>

        <section class="card grid">
          <Metric label="Oil" :value="temperature(live.oilTemp)" unit="°C" :warn="live.oilTemp >= 135" />
          <Metric label="Fuel level" :value="percent(live.fuel)" />
          <Metric label="Ignition" :value="ignitionText" />
          <Metric label="Rated torque" :value="torque(ratedTorque)" />
          <Metric label="Rated power" :value="decimal(ratedPowerKw, 1)" unit="kW" />
          <Metric label="Redline" :value="whole(live.redlineRpm)" unit="rpm" />
        </section>

        <Notice v-if="!liveOnline" title="Waiting for vehicle telemetry">
          Enter a vehicle and keep the phone open to begin the scan.
        </Notice>
      </main>

      <main v-else-if="tab === 'engine'">
        <section class="card grid">
          <Metric label="Rated torque" :value="torque(ratedTorque)" />
          <Metric label="Rated power" :value="decimal(ratedPowerKw, 1)" unit="kW" />
          <Metric label="Idle target" :value="whole(live.idleRpm)" unit="rpm" />
          <Metric label="Combustion quality" :value="roughnessState" :warn="roughnessState !== 'Normal'" />
          <Metric label="Misfire risk" :value="misfireState" :warn="misfireState !== 'Normal'" />
        </section>

        <section v-if="hasEngineLimits" class="card limits-card">
          <h2>Engine limits</h2>
          <div class="limit-list">
            <div v-if="isNumber(live.mechanicalTorqueRatingNm)">
              <span>Overtorque threshold</span><strong>{{ torque(live.mechanicalTorqueRatingNm) }}</strong>
            </div>
            <div v-if="isNumber(live.mechanicalRpmLimit)">
              <span>Mechanical RPM limit</span><strong>{{ whole(live.mechanicalRpmLimit) }} rpm</strong>
            </div>
          </div>
          <p>BeamNG damage threshold reported by the installed engine configuration; not a continuous output rating.</p>
        </section>

        <section class="card">
          <h2>Engine status</h2>
          <StatusRow v-if="maintenanceOnline" label="Power output" :bad="powerLimited" :text="powerLimitText" />
          <StatusRow v-if="maintenanceOnline || isBoolean(live.pistonRingsDamaged)" label="Piston rings" :bad="pistonRingsDamaged" :text="pistonRingsDamaged ? 'Fault detected' : 'Normal'" />
          <StatusRow v-if="isBoolean(live.headGasketDamaged)" label="Head gasket" :bad="live.headGasketDamaged" :text="live.headGasketDamaged ? 'Fault detected' : 'Normal'" />
          <StatusRow v-if="isBoolean(live.rodBearingsDamaged)" label="Rod bearings" :bad="live.rodBearingsDamaged" :text="live.rodBearingsDamaged ? 'Fault detected' : 'Normal'" />
          <StatusRow v-if="maintenanceOnline" label="Running condition" :bad="Boolean(engine.activeSymptom)" :text="engine.activeSymptomLabel || 'Normal'" />
        </section>
      </main>

      <main v-else-if="tab === 'service'">
        <Notice v-if="!maintenanceOnline" title="RLS maintenance data unavailable">
          Maintenance may be disabled for this save, still initializing, or unsupported by the current vehicle.
        </Notice>
        <template v-else>
          <section v-for="category in maintenanceCategories" :key="category.key" class="card service-card">
            <div class="card-title">
              <span>{{ category.label }}</span>
              <b :class="conditionClass(category.data.maintenanceAverage)">{{ conditionState(category.data.maintenanceAverage) }}</b>
            </div>
            <div class="meta-row">
              <span v-if="isNumber(category.data.avgMiles)">{{ whole(category.data.avgMiles) }} mi</span>
              <span v-if="category.data.wearBand">{{ wearLabel(category.data.wearBand) }}</span>
              <span v-if="isNumber(category.data.integrityValue)">integrity {{ percent(category.data.integrityValue) }}</span>
            </div>
            <div v-for="item in category.data.maintenanceItems || []" :key="item.name" class="service-item">
              <div><span>{{ item.label }}</span><b>{{ percent(item.value) }}</b></div>
              <div class="service-bar"><i :class="conditionClass(item.value)" :style="{ width: clampPercent(item.value) + '%' }"></i></div>
              <small v-if="dueText(item)">{{ dueText(item) }}</small>
            </div>
            <div v-for="risk in category.data.riskFlags || []" :key="risk.key" class="risk" :class="risk.severity">
              <b>{{ diagnosticRiskLabel(risk) }}</b><span v-if="diagnosticRiskDetail(risk)">{{ diagnosticRiskDetail(risk) }}</span>
            </div>
          </section>
        </template>
      </main>

      <main v-else>
        <section class="card grid">
          <Metric label="Transmission" :value="transmissionType" />
          <Metric label="Shift quality" :value="shiftQualityState" :warn="shiftQualityState !== 'Normal'" />
          <Metric label="Torque transfer" :value="torqueTransferState" :warn="torqueTransferState !== 'Normal'" />
          <Metric label="Clutch wear" :value="clutchWearState" :warn="clutchWearState !== 'Normal'" />
          <Metric label="Fluid quality" :value="percent(transmission.maintenance?.fluidCondition)" />
          <Metric label="Fluid level" :value="percent(transmission.maintenance?.fluidLevel)" />
          <Metric label="Integrity" :value="percent(transmission.integrityValue)" />
        </section>
        <section class="card">
          <h2>Drivetrain status</h2>
          <StatusRow v-if="isBoolean(live.clutchDamaged)" label="Clutch" :bad="live.clutchDamaged" :text="live.clutchDamaged ? 'Fault detected' : 'Normal'" />
          <StatusRow v-if="maintenanceOnline" label="Operating condition" :bad="Boolean(transmission.activeSymptom)" :text="transmission.activeSymptomLabel || 'Normal'" />
          <div v-for="risk in transmission.riskFlags || []" :key="risk.key" class="risk" :class="risk.severity">
            <b>{{ diagnosticRiskLabel(risk) }}</b><span v-if="diagnosticRiskDetail(risk)">{{ diagnosticRiskDetail(risk) }}</span>
          </div>
        </section>
      </main>

      <footer>Read-only diagnostics · BeamNG + RLS</footer>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { computed, h, onMounted, ref } from "vue"
import { useBridge } from "@/bridge"
import { useEvents, useStreams } from "@/services/events"
import PhoneWrapper from "@/modules/career/views/PhoneWrapper.vue"

const Metric = (props) => props.value === null || props.value === undefined || props.value === '' ? null : h('div', { class: ['metric', props.warn && 'warn'] }, [
  h('span', props.label), h('strong', props.value), props.unit ? h('small', props.unit) : null,
])
const Notice = (props, { slots }) => h('section', { class: 'notice' }, [h('b', props.title), h('p', slots.default?.())])
const StatusRow = props => h('div', { class: ['status-row', props.bad && 'bad'] }, [h('span', props.label), h('b', props.text)])

const { api } = useBridge()
const events = useEvents()
const tab = ref('live')
const live = ref({})
const maintenance = ref({})
const liveUpdatedAt = ref(0)

const tabs = [
  { id: 'live', label: 'Overview' }, { id: 'engine', label: 'Engine' },
  { id: 'service', label: 'Service' }, { id: 'drive', label: 'Drive' },
]

useStreams(['rlsObdScannerData', 'vehicleMaintenanceDebugData'], streams => {
  if (streams.rlsObdScannerData) {
    live.value = streams.rlsObdScannerData
    liveUpdatedAt.value = Date.now()
  }
  if (streams.vehicleMaintenanceDebugData) maintenance.value = streams.vehicleMaintenanceDebugData
})

function connectVehicle() {
  api.activeObjectLua("extensions.load('rlsObdScanner'); rlsObdScanner.requestState()")
}
events.on('VehicleReset', connectVehicle)
events.on('VehicleChange', connectVehicle)
onMounted(connectVehicle)

const engine = computed(() => maintenance.value.categories?.engine || {})
const radiator = computed(() => maintenance.value.categories?.radiator || {})
const transmission = computed(() => maintenance.value.categories?.transmission || {})
const liveOnline = computed(() => liveUpdatedAt.value > 0)
const maintenanceOnline = computed(() => Boolean(maintenance.value.categories))
const vehicleTitle = computed(() => live.value.vehicleName || (liveOnline.value ? `Vehicle ${live.value.vehicleId}` : 'No connection'))
const ignitionText = computed(() => live.value.ignition == null ? null : live.value.ignition > 1 ? 'Engine on' : live.value.ignition > 0 ? 'Accessory' : 'Off')
const rpmPercent = computed(() => live.value.redlineRpm ? Math.min(100, Math.max(0, live.value.rpm / live.value.redlineRpm * 100)) : 0)
const temperaturePercent = computed(() => typeof live.value.coolantTemp === 'number' ? Math.min(100, Math.max(0, live.value.coolantTemp / 130 * 100)) : 0)
const ratedTorque = computed(() => live.value.ratedTorqueNm ?? engine.value.torqueNm)
const ratedPowerKw = computed(() => live.value.ratedPowerKw ?? (engine.value.powerHp ? engine.value.powerHp * 0.7457 : null))
const hasEngineLimits = computed(() => isNumber(live.value.mechanicalTorqueRatingNm) || isNumber(live.value.mechanicalRpmLimit))
const pistonRingsDamaged = computed(() => live.value.pistonRingsDamaged || engine.value.pistonRingsDamaged)
const powerLimited = computed(() => engine.value.liveMetrics?.powerCapActive === true || radiator.value.liveMetrics?.powerLimitActive === true)
const powerLimitText = computed(() => powerLimited.value
  ? friendlyLimitReason(engine.value.liveMetrics?.powerLimitReason || radiator.value.liveMetrics?.powerLimitReason)
  : 'Normal')
const roughnessState = computed(() => elevatedAbove(engine.value.liveMetrics?.roughnessCoef, 1.25))
const misfireState = computed(() => highIsBadState(engine.value.liveMetrics?.ignitionErrorChance, 0.01, 0.02))
const shiftQualityState = computed(() => lowIsBadState(transmission.value.liveMetrics?.shiftSpeedCoef ?? transmission.value.shiftSpeedCoef, 0.88, 0.78))
const torqueTransferState = computed(() => lowIsBadState(
  transmission.value.liveMetrics?.clutchLockTorqueCoef ?? transmission.value.liveMetrics?.gearboxLockTorqueCoef ?? transmission.value.lockTorqueCoef,
  0.94, 0.86
))
const clutchWearState = computed(() => highIsBadState(
  transmission.value.liveMetrics?.clutchFreePlayCoef ?? transmission.value.clutchFreePlayCoef,
  1.3, 1.7
))
const transmissionType = computed(() => friendlyTransmissionType(live.value.gearboxType))
const maintenanceCategories = computed(() => [
  { key: 'engine', label: 'Engine', data: engine.value },
  { key: 'radiator', label: 'Cooling', data: radiator.value },
  { key: 'transmission', label: 'Transmission', data: transmission.value },
])

function isNumber(value) { return typeof value === 'number' && Number.isFinite(value) }
function isBoolean(value) { return typeof value === 'boolean' }
function decimal(value, digits = 1) { return isNumber(value) ? value.toFixed(digits) : null }
function whole(value) { return isNumber(value) ? Math.round(value).toLocaleString() : null }
function temperature(value) { return isNumber(value) ? Math.round(value) : null }
function percent(value) { return isNumber(value) ? `${Math.round(value * 100)}%` : null }
function clampPercent(value) { return typeof value === 'number' ? Math.max(0, Math.min(100, value * 100)) : 0 }
function torque(value) { return isNumber(value) ? `${Math.round(value)} Nm` : null }
function conditionClass(value) { return value < 0.35 ? 'bad-text' : value < 0.6 ? 'warn-text' : 'good-text' }
function conditionState(value) {
  if (!isNumber(value)) return 'Unknown'
  if (value < 0.35) return 'Poor'
  if (value < 0.6) return 'Service soon'
  return 'Good'
}
function highIsBadState(value, elevated, high) {
  if (!isNumber(value)) return null
  if (value >= high) return 'High'
  if (value >= elevated) return 'Elevated'
  return 'Normal'
}
function elevatedAbove(value, threshold) {
  if (!isNumber(value)) return null
  return value > threshold ? 'Elevated' : 'Normal'
}
function lowIsBadState(value, reduced, low) {
  if (!isNumber(value)) return null
  if (value <= low) return 'Low'
  if (value <= reduced) return 'Reduced'
  return 'Normal'
}
function wearLabel(value) {
  return ({ fresh: 'Low mileage wear', aged: 'Moderate mileage wear', worn: 'High mileage wear' })[value] || 'Wear unknown'
}
function friendlyTransmissionType(value) {
  if (!value) return null
  const normalized = String(value).replace(/([a-z])([A-Z])/g, '$1 $2').replace(/[_-]+/g, ' ').toLowerCase()
  if (normalized.includes('dct')) return 'Dual-clutch'
  if (normalized.includes('cvt')) return 'CVT'
  if (normalized.includes('automatic')) return 'Automatic'
  if (normalized.includes('manual')) return 'Manual'
  return null
}
function friendlyLimitReason(reason) {
  const labels = {
    'Temporary symptom': 'Reduced — active engine fault',
    'Oil starvation': 'Reduced — lubrication fault',
    'Severe ignition issue': 'Reduced — ignition fault',
    'Old engine top-end loss': 'Reduced — engine wear',
    'Maintenance torque protection': 'Reduced — service condition',
  }
  return labels[reason] || (reason ? `Reduced — ${reason}` : 'Reduced')
}
function diagnosticRiskLabel(risk) {
  const labels = {
    wear_spike: 'Accelerated wear detected',
    high_output: 'Powertrain load is increasing wear',
    limit_stress: 'Transmission load is high',
    failure_window: 'Transmission failure risk detected',
  }
  return labels[risk?.key] || risk?.label || 'Attention required'
}
function diagnosticRiskDetail(risk) {
  if (!risk) return null
  if (risk.key === 'wear_spike') return 'Wear rate is currently above normal.'
  if (risk.key === 'limit_stress') return 'Operating demand is close to the transmission capacity.'
  if (risk.key === 'failure_window') return 'Continued operation may cause a mechanical failure.'
  if (risk.key === 'piston_rings') return 'Oil consumption is elevated.'
  const detail = risk.detail
  if (!detail) return null
  if (/drive multiplier|limit stress|per sec/i.test(detail)) return null
  return detail.replace(/([0-9.]+) C simulated/i, 'Estimated temperature $1 °C')
}
function dueText(item) {
  const due = item.dueMiles ?? item.serviceDueMilesRemaining
  if (typeof due !== 'number') return null
  return due <= 0 ? 'Service due now' : `${Math.round(due).toLocaleString()} mi to service target`
}
</script>

<style scoped>
.scanner{--bg:#0b1118;--card:#131d27;--line:#263541;--text:#eef5f3;--muted:#91a3aa;--green:#50e3a4;--amber:#ffbe55;--red:#ff6673;height:100%;overflow-y:auto;overscroll-behavior:contain;padding:3.2rem 14px 28px;background:var(--bg);color:var(--text);font-family:Inter,Arial,sans-serif;box-sizing:border-box}.hero{display:flex;align-items:center;justify-content:space-between;padding:6px 2px 14px}.eyebrow{font-size:9px;letter-spacing:.16em;color:var(--green);font-weight:800}.hero h1{font-size:20px;line-height:1.15;margin:4px 0 0;max-width:210px}.status{font-size:8px;font-weight:900;letter-spacing:.08em;color:var(--muted);border:1px solid var(--line);border-radius:99px;padding:6px 7px}.status.online{color:var(--green);border-color:#287a5a;background:#10271f}.tabs{display:grid;grid-template-columns:repeat(4,1fr);gap:4px;padding:4px;background:#111a23;border-radius:11px;margin-bottom:10px}.tabs button{border:0;background:transparent;color:var(--muted);font-size:9px;font-weight:700;padding:8px 2px;border-radius:8px}.tabs button.active{background:#263541;color:white}.gauges{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:8px}.gauge,.card,.notice{background:var(--card);border:1px solid var(--line);border-radius:13px}.gauge{padding:12px}.gauge span,:deep(.metric span){display:block;color:var(--muted);font-size:10px}.gauge strong{display:inline-block;font-size:25px;margin-top:5px}.gauge small,:deep(.metric small){color:var(--muted);font-size:9px;margin-left:5px}.bar,.service-bar{height:5px;border-radius:5px;background:#263541;overflow:hidden;margin-top:8px}.bar i,.service-bar i{display:block;height:100%;background:var(--green);border-radius:inherit}.bar i.hot{background:var(--red)}.card{padding:12px;margin-bottom:8px}.grid{display:grid;grid-template-columns:1fr 1fr;padding:0}.metric{min-height:64px;padding:11px;border-right:1px solid var(--line);border-bottom:1px solid var(--line);box-sizing:border-box}.metric:nth-child(even){border-right:0}.metric:nth-last-child(-n+2){border-bottom:0}:deep(.metric strong){font-size:15px;display:inline-block;margin-top:7px}.metric.warn :deep(strong){color:var(--red)}.card h2,.card-title{font-size:12px;margin:0 0 10px;font-weight:800}.card-title{display:flex;justify-content:space-between;align-items:center}.limits-card h2{margin-bottom:3px}.limit-list>div{display:flex;justify-content:space-between;gap:10px;padding:8px 0;border-bottom:1px solid var(--line);font-size:10px}.limit-list>div:last-child{border-bottom:0}.limit-list span{color:var(--muted)}.limit-list strong{text-align:right}.limits-card p,:deep(.notice p){font-size:9px;line-height:1.45;color:var(--muted);margin:8px 0 0}.status-row{display:flex;justify-content:space-between;gap:10px;padding:8px 0;border-top:1px solid var(--line);font-size:10px}:deep(.status-row b){text-align:right;color:var(--green)}.status-row.bad :deep(b){color:var(--red)}.notice{padding:13px;margin-bottom:8px;border-color:#5d4b2c;background:#211c14}:deep(.notice b){font-size:11px;color:var(--amber)}.meta-row{display:flex;gap:5px;flex-wrap:wrap;margin:-3px 0 11px}.meta-row span{font-size:8px;text-transform:uppercase;color:var(--muted);background:#0d151d;padding:4px 6px;border-radius:5px}.service-item{margin:11px 0}.service-item>div:first-child{display:flex;justify-content:space-between;font-size:10px}.service-item small{display:block;color:var(--muted);font-size:8px;margin-top:4px}.service-bar i.warn-text{background:var(--amber)}.service-bar i.bad-text{background:var(--red)}.good-text{color:var(--green)}.warn-text{color:var(--amber)}.bad-text{color:var(--red)}.risk{display:flex;flex-direction:column;gap:2px;padding:8px;margin-top:6px;border-left:3px solid var(--amber);background:#211c14;font-size:9px}.risk.high{border-color:var(--red);background:#251418}.risk span{color:var(--muted)}footer{text-align:center;color:#60737b;font-size:8px;padding:10px}
</style>
