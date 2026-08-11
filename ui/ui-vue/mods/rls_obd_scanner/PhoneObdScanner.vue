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
          <Metric label="Engine load" :value="percent(live.engineLoad)" />
          <Metric label="Diagnostic status" :value="diagnosticStatusText" :warn="hasActiveFault" />
          <Metric label="Next service (est.)" :value="nextServiceText" />
        </section>

        <section v-if="diagnosticFindings.length" class="card findings-card">
          <h2>Diagnostic findings</h2>
          <article v-for="finding in diagnosticFindings" :key="finding.key" class="finding" :class="finding.severity">
            <b>{{ finding.title }}</b>
            <p v-if="finding.cause"><span>Probable cause</span>{{ finding.cause }}</p>
            <p v-if="finding.effect"><span>Observed effect</span>{{ finding.effect }}</p>
            <p v-if="finding.action"><span>Recommended action</span>{{ finding.action }}</p>
          </article>
        </section>

        <Notice v-if="!liveOnline" title="Waiting for vehicle connection">
          Enter a vehicle and keep the phone open to begin the scan.
        </Notice>
      </main>

      <main v-else-if="tab === 'engine'">
        <section class="card specs-card">
          <h2>Engine specifications</h2>
          <div class="spec-list">
            <div v-if="isNumber(ratedPowerHp)"><span>Peak power</span><strong>{{ whole(ratedPowerHp) }} hk</strong></div>
            <div v-if="isNumber(ratedTorque)"><span>Peak torque</span><strong>{{ torque(ratedTorque) }}</strong></div>
            <div v-if="isNumber(live.idleRpm)"><span>Target idle speed</span><strong>{{ whole(live.idleRpm) }} rpm</strong></div>
            <div v-if="live.forcedInductionName || live.forcedInductionType"><span>Forced induction</span><strong>{{ live.forcedInductionName || live.forcedInductionType }}</strong></div>
          </div>
        </section>

        <section v-if="hasEcuCalibration" class="card calibration-card">
          <h2>ECU calibration</h2>
          <div class="spec-list">
            <div v-if="isNumber(live.ecuLimiterRpm)">
              <span>Rev limiter</span><strong>{{ whole(live.ecuLimiterRpm) }} rpm</strong>
            </div>
            <div v-if="limiterStrategyText">
              <span>Limiter strategy</span><strong>{{ limiterStrategyText }}</strong>
            </div>
            <div v-if="isNumber(limiterCutDurationMs)">
              <span>Cut duration</span><strong>{{ whole(limiterCutDurationMs) }} ms</strong>
            </div>
            <div v-if="isNumber(live.wastegateStartPsi)">
              <span>Wastegate opening pressure</span><strong>{{ boostPressure(live.wastegateStartPsi) }}</strong>
            </div>
          </div>
        </section>

        <section v-if="hasEngineLimits" class="card limits-card">
          <h2>Engine limits</h2>
          <div class="limit-list">
            <div v-if="isNumber(live.overrevThresholdRpm)">
              <span>Over-rev threshold</span><strong>{{ whole(live.overrevThresholdRpm) }} rpm</strong>
            </div>
            <div v-if="isNumber(live.overtorqueThresholdNm)">
              <span>Overtorque damage threshold</span><strong>{{ torque(live.overtorqueThresholdNm) }}</strong>
            </div>
          </div>
        </section>

        <section class="card">
          <h2>Diagnostics</h2>
          <StatusRow v-if="maintenanceOnline" label="Output restriction" :bad="powerLimited && powerLimitReason !== 'Old engine top-end loss'" :warn="powerLimited && powerLimitReason === 'Old engine top-end loss'" :text="powerLimitText" />
          <StatusRow v-if="roughnessState" label="Combustion stability" :bad="roughnessState !== 'Normal'" :text="roughnessState" />
          <StatusRow v-if="misfireState" label="Estimated misfire risk" :bad="misfireState !== 'Normal'" :text="misfireState" />
          <StatusRow v-if="maintenanceOnline && engine.activeSymptom" label="Active condition" bad :text="engine.activeSymptomLabel || 'Fault detected'" />
        </section>
      </main>

      <main v-else-if="tab === 'service'">
        <Notice v-if="!maintenanceOnline" title="Service information unavailable">
          Service information is still initializing or is not available for this vehicle.
        </Notice>
        <template v-else>
          <section v-for="category in maintenanceCategories" :key="category.key" class="card service-card">
            <div class="card-title">
              <span>{{ category.label }}</span>
              <b :class="categoryConditionClass(category.data)">{{ categoryConditionState(category.data) }}</b>
            </div>
            <div v-if="isNumber(category.data.avgMiles)" class="mileage-wear">
              <div><span>Mileage wear</span><b :style="{ color: mileageWearColor(category.data.avgMiles) }">{{ mileageWearPercent(category.data.avgMiles) }}%</b></div>
              <div class="service-bar"><i :style="{ width: mileageWearPercent(category.data.avgMiles) + '%', backgroundColor: mileageWearColor(category.data.avgMiles) }"></i></div>
              <small>{{ whole(category.data.avgMiles) }} mi on installed components</small>
            </div>
            <div class="service-heading">Service condition remaining</div>
            <div v-if="isNumber(category.data.integrityValue) && category.data.integrityValue < 0.999" class="service-item">
              <div><span>Mechanical integrity</span><b :style="{ color: conditionColor(category.data.integrityValue) }">{{ percent(category.data.integrityValue) }}</b></div>
              <div class="service-bar"><i :style="{ width: clampPercent(category.data.integrityValue) + '%', backgroundColor: conditionColor(category.data.integrityValue) }"></i></div>
            </div>
            <div v-for="item in category.data.maintenanceItems || []" :key="item.name" class="service-item">
              <div><span>{{ serviceItemLabel(item) }}</span><b :style="{ color: conditionColor(item.value) }">{{ percent(item.value) }}</b></div>
              <div class="service-bar"><i :style="{ width: clampPercent(item.value) + '%', backgroundColor: conditionColor(item.value) }"></i></div>
              <small v-if="dueText(item)">{{ dueText(item) }}</small>
            </div>
            <div v-for="risk in diagnosticRisks(category.data.riskFlags)" :key="risk.key" class="risk" :class="risk.severity">
              <b>{{ diagnosticRiskLabel(risk) }}</b><span v-if="diagnosticRiskDetail(risk)">{{ diagnosticRiskDetail(risk) }}</span>
            </div>
          </section>
        </template>
      </main>

      <main v-else>
        <section class="card specs-card">
          <h2>Transmission</h2>
          <div class="spec-list">
            <div v-if="gearboxDisplayName"><span>Gearbox</span><strong>{{ gearboxDisplayName }}</strong></div>
            <div v-if="isNumber(live.forwardGearCount)"><span>Forward gears</span><strong>{{ whole(live.forwardGearCount) }}</strong></div>
            <div v-if="live.clutchName"><span>Clutch</span><strong>{{ live.clutchName }}</strong></div>
            <div v-if="isNumber(live.clutchRatedTorqueNm)"><span>Rated clutch capacity</span><strong>{{ torque(live.clutchRatedTorqueNm) }}</strong></div>
            <div v-if="clutchCapacityReduced"><span>Available clutch capacity</span><strong>{{ torque(live.clutchAvailableTorqueNm) }}</strong></div>
          </div>
        </section>

        <section class="card grid">
          <Metric label="Shift response" :value="shiftQualityState" :warn="shiftQualityState !== 'Normal'" />
          <Metric v-if="hasClutchData" label="Estimated clutch condition" :value="clutchWearState" :warn="clutchWearState !== 'Normal'" />
          <Metric v-if="hasClutchData && isNumber(live.clutchTempC)" label="Clutch temperature" :value="`${whole(live.clutchTempC)} °C`" :warn="clutchTemperatureHigh" :caution="clutchTemperatureElevated" />
          <Metric label="Fluid quality" :value="percent(transmission.maintenance?.fluidCondition)" />
          <Metric label="Fluid level" :value="percent(transmission.maintenance?.fluidLevel)" />
        </section>

        <section v-if="hasDifferentialData" class="card differentials-card">
          <h2>Differentials</h2>
          <DifferentialBlock label="Front differential" :data="live.frontDifferential" />
          <DifferentialBlock label="Center coupling" :data="live.centerCoupling" />
          <DifferentialBlock label="Rear differential" :data="live.rearDifferential" />
        </section>

        <section v-if="hasDrivetrainStatus" class="card">
          <h2>Drivetrain status</h2>
          <StatusRow v-if="isBoolean(live.clutchDamaged)" label="Clutch" :bad="live.clutchDamaged" :text="live.clutchDamaged ? 'Fault detected' : 'Normal'" />
          <StatusRow v-if="maintenanceOnline && transmission.activeSymptom" label="Active condition" bad :text="transmission.activeSymptomLabel || 'Fault detected'" />
          <div v-for="risk in diagnosticRisks(transmission.riskFlags)" :key="risk.key" class="risk" :class="risk.severity">
            <b>{{ diagnosticRiskLabel(risk) }}</b><span v-if="diagnosticRiskDetail(risk)">{{ diagnosticRiskDetail(risk) }}</span>
          </div>
        </section>
      </main>

      <footer>Read-only vehicle diagnostics</footer>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { computed, h, onMounted, ref } from "vue"
import { useBridge } from "@/bridge"
import { useEvents, useStreams } from "@/services/events"
import PhoneWrapper from "@/modules/career/views/PhoneWrapper.vue"

const Metric = (props) => props.value === null || props.value === undefined || props.value === '' ? null : h('div', { class: ['metric', props.warn && 'warn', props.caution && 'caution'] }, [
  h('span', props.label), h('strong', props.value), props.unit ? h('small', props.unit) : null,
])
const Notice = (props, { slots }) => h('section', { class: 'notice' }, [h('b', props.title), h('p', slots.default?.())])
const StatusRow = props => h('div', { class: ['status-row', props.bad && 'bad', props.warn && 'warn'] }, [h('span', props.label), h('b', props.text)])
const DifferentialBlock = props => {
  const data = props.data
  if (!data?.name) return null
  const settings = [
    isNumber(data.finalDriveRatio) && ['Final drive', `${decimal(data.finalDriveRatio, 2)}:1`],
    isNumber(data.powerLockPercent) && ['Power lock', `${Math.round(data.powerLockPercent)}%`],
    isNumber(data.coastLockPercent) && ['Coast lock', `${Math.round(data.coastLockPercent)}%`],
    isNumber(data.preloadNm) && ['Preload', torque(data.preloadNm)],
  ].filter(Boolean)
  return h('div', { class: 'differential-block' }, [
    h('div', { class: 'differential-title' }, [h('span', props.label), h('strong', data.name)]),
    settings.length ? h('div', { class: 'differential-settings' }, settings.map(([label, value]) => h('span', [label, h('b', value)]))) : null,
  ])
}

const { api } = useBridge()
const events = useEvents()
const tab = ref('live')
const live = ref({})
const maintenance = ref({})
const recentSymptoms = ref({})
const liveUpdatedAt = ref(0)
const displayVehicleName = ref(null)

const tabs = [
  { id: 'live', label: 'Overview' }, { id: 'engine', label: 'Engine' },
  { id: 'service', label: 'Service' }, { id: 'drive', label: 'Drivetrain' },
]

useStreams(['rlsObdScannerData', 'vehicleMaintenanceDebugData'], streams => {
  if (streams.rlsObdScannerData) {
    live.value = streams.rlsObdScannerData
    const clutchTemp = streams.rlsObdScannerData.clutchTempC
    const warningTemp = streams.rlsObdScannerData.clutchWarningTempC
    if (isNumber(clutchTemp) && isNumber(warningTemp) && clutchTemp >= warningTemp) {
      recentSymptoms.value = {
        ...recentSymptoms.value,
        clutchHeat: { peakTemp: clutchTemp, observedAt: Date.now() / 1000 },
      }
    }
    liveUpdatedAt.value = Date.now()
  }
  if (streams.vehicleMaintenanceDebugData) {
    const incoming = streams.vehicleMaintenanceDebugData
    const observed = { ...recentSymptoms.value }
    for (const categoryName of ['engine', 'radiator', 'transmission']) {
      const symptom = incoming.categories?.[categoryName]?.activeSymptom
      if (symptom) observed[categoryName] = { symptom, observedAt: Date.now() / 1000 }
    }
    recentSymptoms.value = observed
    maintenance.value = incoming
  }
})

function connectVehicle() {
  api.activeObjectLua("extensions.load('rlsObdScanner'); rlsObdScanner.requestState()")
  api.engineLua(`(function()
    local vehicle = be:getPlayerVehicle(0)
    if not vehicle then return nil end
    local data = core_vehicles.getModel(vehicle.JBeam)
    local model = data and data.model
    if not model then return nil end
    return string.format("%s %s", model.Brand or "", model.Name or "")
  end)()`, value => { displayVehicleName.value = value || null })
}
events.on('VehicleReset', connectVehicle)
events.on('VehicleChange', connectVehicle)
onMounted(connectVehicle)

const engine = computed(() => maintenance.value.categories?.engine || {})
const radiator = computed(() => maintenance.value.categories?.radiator || {})
const transmission = computed(() => maintenance.value.categories?.transmission || {})
const liveOnline = computed(() => liveUpdatedAt.value > 0)
const maintenanceOnline = computed(() => Boolean(maintenance.value.categories))
const vehicleTitle = computed(() => displayVehicleName.value || live.value.vehicleName || (liveOnline.value ? `Vehicle ${live.value.vehicleId}` : 'No connection'))
const ignitionText = computed(() => live.value.ignition == null ? null : live.value.ignition > 1 ? 'Engine on' : live.value.ignition > 0 ? 'Accessory' : 'Off')
const rpmPercent = computed(() => live.value.ecuLimiterRpm ? Math.min(100, Math.max(0, live.value.rpm / live.value.ecuLimiterRpm * 100)) : 0)
const temperaturePercent = computed(() => typeof live.value.coolantTemp === 'number' ? Math.min(100, Math.max(0, live.value.coolantTemp / 130 * 100)) : 0)
const ratedTorque = computed(() => live.value.ratedTorqueNm ?? engine.value.torqueNm)
const ratedPowerHp = computed(() => live.value.ratedPowerHp ?? engine.value.powerHp)
const limiterStrategyText = computed(() => ({ timeBased: 'Timed cut', rpmDrop: 'RPM-drop cut' })[live.value.revLimiterType] || null)
const limiterCutDurationMs = computed(() => limiterStrategyText.value && isNumber(live.value.revLimiterCutTime) ? live.value.revLimiterCutTime * 1000 : null)
const hasEcuCalibration = computed(() => isNumber(live.value.ecuLimiterRpm) || Boolean(limiterStrategyText.value) || isNumber(live.value.wastegateStartPsi))
const hasEngineLimits = computed(() => isNumber(live.value.overrevThresholdRpm) || isNumber(live.value.overtorqueThresholdNm))
const pistonRingsDamaged = computed(() => live.value.pistonRingsDamaged || engine.value.pistonRingsDamaged)
const nextServiceMiles = computed(() => {
  const due = maintenanceCategories.value.flatMap(category => category.data.maintenanceItems || [])
    .map(item => item.dueMiles ?? item.serviceDueMilesRemaining)
    .filter(value => isNumber(value))
  return due.length ? Math.max(0, Math.min(...due)) : null
})
const nextServiceText = computed(() => isNumber(nextServiceMiles.value) ? `${whole(nextServiceMiles.value)} mi` : null)
const powerLimited = computed(() => engine.value.liveMetrics?.powerCapActive === true || radiator.value.liveMetrics?.powerLimitActive === true)
const powerLimitReason = computed(() => {
  const cooling = radiator.value.liveMetrics?.powerLimitActive === true
  const reported = cooling ? radiator.value.liveMetrics?.powerLimitReason : engine.value.liveMetrics?.powerLimitReason
  return effectivePowerLimitReason(reported)
})
const powerLimitText = computed(() => powerLimited.value
  ? friendlyLimitReason(powerLimitReason.value)
  : 'None')
const roughnessState = computed(() => elevatedAbove(engine.value.liveMetrics?.roughnessCoef, 1.25))
const misfireState = computed(() => highIsBadState(engine.value.liveMetrics?.ignitionErrorChance, 0.01, 0.02))
const shiftQualityState = computed(() => lowIsBadState(transmission.value.liveMetrics?.shiftSpeedCoef ?? transmission.value.shiftSpeedCoef, 0.88, 0.78))
const clutchWearState = computed(() => highIsBadState(
  transmission.value.liveMetrics?.clutchFreePlayCoef ?? transmission.value.clutchFreePlayCoef,
  1.3, 1.7
))
const clutchTemperatureHigh = computed(() => isNumber(live.value.clutchTempC) && isNumber(live.value.clutchMaxSafeTempC)
  && live.value.clutchTempC >= live.value.clutchMaxSafeTempC)
const clutchTemperatureElevated = computed(() => !clutchTemperatureHigh.value && isNumber(live.value.clutchTempC)
  && isNumber(live.value.clutchWarningTempC) && live.value.clutchTempC >= live.value.clutchWarningTempC)
const diagnosticFindings = computed(() => buildDiagnosticFindings())
const hasActiveFault = computed(() => diagnosticFindings.value.some(finding => finding.attention !== false))
const hasRecentFinding = computed(() => diagnosticFindings.value.some(finding => finding.recent === true))
const diagnosticStatusText = computed(() => hasActiveFault.value
  ? 'Attention required'
  : (hasRecentFinding.value
      ? 'Recent event observed'
      : (diagnosticFindings.value.length ? 'Advisory' : (liveOnline.value ? 'No issues detected' : null))))
const transmissionType = computed(() => friendlyTransmissionType(live.value.gearboxType))
const gearboxDisplayName = computed(() => live.value.gearboxName || (
  isNumber(live.value.forwardGearCount) && transmissionType.value
    ? `${whole(live.value.forwardGearCount)}-speed ${transmissionType.value}`
    : transmissionType.value
))
const hasDifferentialData = computed(() => Boolean(live.value.frontDifferential?.name || live.value.centerCoupling?.name || live.value.rearDifferential?.name))
const hasClutchData = computed(() => Boolean(live.value.clutchName) || isNumber(live.value.clutchRatedTorqueNm) || isBoolean(live.value.clutchDamaged))
const clutchCapacityReduced = computed(() => isNumber(live.value.clutchRatedTorqueNm)
  && isNumber(live.value.clutchAvailableTorqueNm)
  && live.value.clutchAvailableTorqueNm < live.value.clutchRatedTorqueNm * 0.97)
const hasDrivetrainStatus = computed(() => isBoolean(live.value.clutchDamaged) || Boolean(
  maintenanceOnline.value && transmission.value.activeSymptom
) || diagnosticRisks(transmission.value.riskFlags).length > 0)
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
function boostPressure(psi) { return isNumber(psi) ? `${decimal(psi * 0.0689476, 2)} bar / ${decimal(psi, 1)} psi` : null }
function serviceConditionSeverity(item) {
  if (!isNumber(item?.value) || !isNumber(item?.targetValue) || item.targetValue <= 0) return null
  if (item.value < item.targetValue - 0.12) return 'bad'
  if (item.value <= item.targetValue) return 'warn'
  return 'good'
}
function conditionColor(value) {
  if (!isNumber(value)) return 'var(--muted)'
  const amount = Math.max(0, Math.min(1, value))
  const red = [255, 102, 115]
  const amber = [255, 190, 85]
  const green = [80, 227, 164]
  const start = amount < 0.5 ? red : amber
  const end = amount < 0.5 ? amber : green
  const mix = amount < 0.5 ? amount * 2 : (amount - 0.5) * 2
  const channel = index => Math.round(start[index] + (end[index] - start[index]) * mix)
  return `rgb(${channel(0)}, ${channel(1)}, ${channel(2)})`
}
function mileageWearPercent(avgMiles) {
  return Math.round(Math.max(0, Math.min(1, avgMiles / 250000)) * 100)
}
function mileageWearColor(avgMiles) {
  return conditionColor(1 - mileageWearPercent(avgMiles) / 100)
}
function categoryConditionSeverity(category) {
  const severities = (category?.maintenanceItems || []).map(serviceConditionSeverity)
  if (severities.includes('bad')) return 'bad'
  if (severities.includes('warn')) return 'warn'
  if (severities.includes('good')) return 'good'
  return null
}
function categoryConditionClass(category) {
  const severity = categoryConditionSeverity(category)
  if (severity === 'good') return 'neutral-text'
  return severity ? `${severity}-text` : 'neutral-text'
}
function categoryConditionState(category) {
  const severity = categoryConditionSeverity(category)
  if (severity === 'bad') return 'Overdue'
  if (severity === 'warn') return 'Service due'
  if (severity === 'good') return 'No service due'
  return 'Unknown'
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
function serviceItemLabel(item) {
  const labels = { coolantIntegrity: 'Coolant condition', fluidCondition: 'Fluid quality' }
  return labels[item?.name] || item?.label || null
}
function dueMaintenanceItem(category) {
  return (category?.maintenanceItems || [])
    .filter(item => ['warn', 'bad'].includes(serviceConditionSeverity(item)))
    .sort((a, b) => a.value - b.value)[0] || null
}
function maintenanceAction(category, fallback) {
  const item = dueMaintenanceItem(category)
  return item?.label ? `Service or inspect ${serviceItemLabel(item).toLowerCase()}.` : fallback
}
function effectivePowerLimitReason(reason) {
  if (reason === 'Maintenance torque protection' && !dueMaintenanceItem(engine.value) && (engine.value.avgMiles || 0) >= 180000) {
    return 'Old engine top-end loss'
  }
  return reason
}
function powerLimitAction(reason, cooling) {
  if (cooling) return maintenanceAction(radiator.value, 'Inspect coolant temperature, level, and the cooling system for faults.')
  if (reason === 'Old engine top-end loss') return 'No routine service is due. Test engine output or compression; rebuild or replace the worn engine to restore performance.'
  if (reason === 'Oil starvation') return 'Check the oil level and lubrication system before continued operation.'
  if (reason === 'Severe ignition issue') return maintenanceAction(engine.value, 'Inspect and service the ignition system.')
  if (reason === 'Temporary symptom') return maintenanceAction(engine.value, 'Monitor for recurrence and inspect the engine if the condition becomes frequent.')
  return maintenanceAction(engine.value, 'Inspect the engine if the output restriction persists.')
}
function recentSymptom(category, categoryName) {
  const known = ['roughRunning', 'ticking', 'roughIdle', 'torqueDip', 'powerFade', 'stall', 'coolantSeep', 'fanOverwork', 'roughShift', 'shiftDelay', 'slip']
  const observed = recentSymptoms.value[categoryName]
  const type = observed?.symptom || category?.lastFailureType
  const observedAt = observed?.observedAt || Number(category?.lastFailureTime || 0)
  const ageSeconds = Date.now() / 1000 - observedAt
  return known.includes(type) && ageSeconds >= 0 && ageSeconds <= 300 ? type : null
}
function transmissionSymptomFinding(symptom, active) {
  const labels = { roughShift: 'Rough shift', shiftDelay: 'Shift delay', slip: 'Transmission slip' }
  const effects = {
    roughShift: 'Gear changes may feel abrupt or harsh.',
    shiftDelay: 'Gear engagement or shifting may respond more slowly than expected.',
    slip: 'Engine speed may rise without a matching increase in vehicle speed.',
  }
  const dueItem = dueMaintenanceItem(transmission.value)
  const highMileage = (transmission.value.avgMiles || 0) >= 200000
  const cause = dueItem
    ? `${serviceItemLabel(dueItem)} is at or below its service threshold.`
    : (highMileage
        ? 'Accumulated transmission mileage can cause intermittent shift-quality changes.'
        : 'The event may be related to temporary load or temperature conditions.')
  return {
    key: active ? 'transmission-symptom' : `stored-transmission-${symptom}`,
    severity: 'medium',
    attention: active,
    recent: !active,
    title: `${active ? 'Active' : 'Intermittent'} ${labels[symptom] || 'transmission condition'}`,
    cause,
    effect: effects[symptom] || 'Shift response or torque transfer may be affected.',
    action: maintenanceAction(transmission.value, symptom === 'slip'
      ? 'Inspect the transmission and clutch if slipping returns.'
      : 'Monitor for recurrence and inspect the transmission if the condition becomes frequent.'),
  }
}
function buildDiagnosticFindings() {
  const findings = []
  const add = finding => {
    if (!findings.some(existing => existing.key === finding.key)) findings.push(finding)
  }

  if (live.value.engineHydrolocked) add({
    key: 'hydrolock', severity: 'high', title: 'Engine rotation obstructed',
    cause: 'Liquid intrusion into a combustion chamber is the likely cause.', effect: 'The engine cannot rotate safely.',
    action: 'Stop attempting to start the engine and inspect it before further operation.',
  })
  if (live.value.rodBearingsDamaged) add({
    key: 'rod-bearings', severity: 'high', title: 'Severe internal engine damage',
    cause: 'Bearing or lubrication-system damage is the likely cause.', effect: 'Continued operation may cause complete engine failure.',
    action: 'Stop the engine and repair the damaged long block.',
  })
  if (live.value.headGasketDamaged) add({
    key: 'head-gasket', severity: 'high', title: 'Combustion/cooling sealing fault',
    cause: 'Cylinder-head or head-gasket sealing failure is the likely cause.', effect: 'Cooling and combustion performance may be compromised.',
    action: 'Inspect and repair the cylinder head and gasket.',
  })
  if (pistonRingsDamaged.value) add({
    key: 'piston-rings', severity: 'high', title: 'Cylinder sealing fault suspected',
    cause: 'Piston-ring or cylinder sealing deterioration is the likely cause.', effect: 'Oil consumption and power loss may increase.',
    action: 'Inspect compression and repair the engine internals.',
  })
  if (powerLimited.value) {
    const cooling = radiator.value.liveMetrics?.powerLimitActive === true
    const reason = powerLimitReason.value
    const ageRelated = reason === 'Old engine top-end loss'
    add({
      key: 'output-restriction', severity: cooling ? 'high' : 'medium', attention: !ageRelated,
      title: ageRelated ? 'Age-related performance loss' : 'Engine output restricted',
      cause: friendlyFindingCause(reason), effect: 'Available engine torque or power is currently reduced.',
      action: powerLimitAction(reason, cooling),
    })
  }
  if (!powerLimited.value && engine.value.activeSymptom) add({
    key: 'engine-symptom', severity: 'medium', title: engine.value.activeSymptomLabel || 'Active engine condition',
    cause: 'An intermittent engine fault is currently active.', effect: 'Engine response or combustion quality may be affected.',
    action: maintenanceAction(engine.value, 'Inspect the engine and its service condition.'),
  })
  if (radiator.value.activeSymptom && !powerLimited.value) add({
    key: 'cooling-symptom', severity: 'medium', title: radiator.value.activeSymptomLabel || 'Active cooling-system condition',
    cause: 'The cooling system has detected an abnormal operating condition.', effect: 'Cooling performance may be reduced.',
    action: maintenanceAction(radiator.value, 'Inspect the cooling system.'),
  })
  if (live.value.clutchDamaged) add({
    key: 'clutch-damage', severity: 'high', title: 'Clutch damage detected',
    cause: 'The clutch can no longer transfer torque normally.', effect: 'Slip or loss of drive may occur.',
    action: 'Inspect and replace the clutch assembly.',
  })
  if (clutchTemperatureHigh.value || clutchTemperatureElevated.value) add({
    key: 'clutch-temperature', severity: clutchTemperatureHigh.value ? 'high' : 'medium', title: clutchTemperatureHigh.value ? 'Clutch overheating' : 'Clutch temperature high',
    cause: 'Excessive clutch slip has generated more heat than the clutch can safely dissipate.',
    effect: clutchTemperatureHigh.value ? 'Continued use may permanently damage the clutch.' : 'Clutch capacity may fall if temperature continues to rise.',
    action: 'Stop slipping the clutch and allow it to cool. Inspect the clutch if overheating returns frequently.',
  })
  const activeTransmissionSymptom = transmission.value.activeSymptom
  if (activeTransmissionSymptom) add(transmissionSymptomFinding(activeTransmissionSymptom, true))
  else {
    const storedTransmissionSymptom = recentSymptom(transmission.value, 'transmission')
    if (['roughShift', 'shiftDelay', 'slip'].includes(storedTransmissionSymptom)) {
      add(transmissionSymptomFinding(storedTransmissionSymptom, false))
    }
  }
  const recentClutchHeatPeak = live.value.recentClutchHeatPeakC ?? recentSymptoms.value.clutchHeat?.peakTemp
  const clutchHeatAge = Date.now() / 1000 - Number(recentSymptoms.value.clutchHeat?.observedAt || 0)
  const hasRecentClutchHeat = isNumber(live.value.recentClutchHeatPeakC)
    || (isNumber(recentClutchHeatPeak) && clutchHeatAge >= 0 && clutchHeatAge <= 300)
  if (!clutchTemperatureHigh.value && !clutchTemperatureElevated.value && hasRecentClutchHeat) add({
    key: 'recent-clutch-temperature', severity: 'medium', attention: false, recent: true, title: 'Recent clutch overheating',
    cause: 'Excessive clutch slip raised temperature above the installed clutch warning threshold.',
    effect: `Clutch temperature recently reached ${whole(recentClutchHeatPeak)} °C and has since fallen.`,
    action: 'Allow the clutch to cool fully and inspect it if overheating returns frequently.',
  })
  if (live.value.checkEngine === true && !findings.some(finding => finding.attention !== false)) add({
    key: 'controller-warning', severity: 'medium', title: 'Powertrain warning active',
    cause: 'The vehicle controller has requested a warning, but no more specific supported cause is currently reported.',
    effect: 'A dashboard powertrain warning is active.',
    action: 'Review temperatures and live readings, then inspect the vehicle if the warning persists or returns.',
  })
  return findings.slice(0, 4)
}
function friendlyFindingCause(reason) {
  const labels = {
    'Temporary symptom': 'An active engine fault is limiting output.',
    'Oil starvation': 'Insufficient lubrication is limiting engine output.',
    'Severe ignition issue': 'Ignition-system condition is limiting engine output.',
    'Old engine top-end loss': 'Internal engine wear is reducing available output.',
    'Maintenance torque protection': 'Engine service condition has triggered protective output reduction.',
    'Catastrophic cooling loss': 'Severe coolant loss has triggered engine protection.',
    Overheating: 'Excessive engine temperature has triggered engine protection.',
  }
  return labels[reason] || 'The powertrain has applied a protective output reduction.'
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
    engine_integrity: 'Engine mechanical integrity is low',
    oil_starvation: 'Severe oil starvation detected',
    oil_starvation_catastrophic: 'Critical oil starvation detected',
    piston_rings: 'Piston-ring damage detected',
    cooling_catastrophic: 'Critical cooling-system loss detected',
    cooling_severe: 'Severe cooling-system loss detected',
    overheating: 'Engine is overheating',
    critical_heat: 'Coolant temperature is critically high',
    transmission_overheat: 'Transmission is overheating',
    transmission_heat: 'Transmission temperature is elevated',
    fluid_quality_critical: 'Transmission-fluid condition is critical',
    fluid_quality_low: 'Transmission-fluid condition is poor',
    slip_risk: 'Transmission slip risk detected',
    fluid_loss: 'Transmission-fluid level is critical',
    fluid_low: 'Transmission-fluid level is low',
  }
  if (labels[risk?.key]) return labels[risk.key]
  if (/_due$/.test(risk?.key || '')) return 'Service overdue'
  return null
}
function diagnosticRisks(risks) {
  const list = Array.isArray(risks) ? risks : Object.values(risks || {})
  return list.filter(risk => diagnosticRiskLabel(risk))
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
  return due <= 0 ? 'Service due now' : `Estimated service due in ${Math.round(due).toLocaleString()} mi`
}
</script>

<style scoped>
.scanner{--bg:#0b1118;--card:#131d27;--line:#263541;--text:#eef5f3;--muted:#91a3aa;--green:#50e3a4;--amber:#ffbe55;--red:#ff6673;height:100%;overflow-y:auto;overscroll-behavior:contain;padding:3.2rem 14px 28px;background:var(--bg);color:var(--text);font-family:Inter,Arial,sans-serif;box-sizing:border-box}.hero{display:flex;align-items:center;justify-content:space-between;padding:6px 2px 14px}.eyebrow{font-size:9px;letter-spacing:.16em;color:var(--green);font-weight:800}.hero h1{font-size:20px;line-height:1.15;margin:4px 0 0;max-width:210px}.status{font-size:8px;font-weight:900;letter-spacing:.08em;color:var(--muted);border:1px solid var(--line);border-radius:99px;padding:6px 7px}.status.online{color:var(--green);border-color:#287a5a;background:#10271f}.tabs{display:grid;grid-template-columns:repeat(4,1fr);gap:4px;padding:4px;background:#111a23;border-radius:11px;margin-bottom:10px}.tabs button{border:0;background:transparent;color:var(--muted);font-size:9px;font-weight:700;padding:8px 2px;border-radius:8px}.tabs button.active{background:#263541;color:white}.gauges{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:8px}.gauge,.card,.notice{background:var(--card);border:1px solid var(--line);border-radius:13px}.gauge{padding:12px}.gauge span,:deep(.metric span){display:block;color:var(--muted);font-size:10px}.gauge strong{display:inline-block;font-size:25px;margin-top:5px}.gauge small,:deep(.metric small){color:var(--muted);font-size:9px;margin-left:5px}.bar,.service-bar{height:5px;border-radius:5px;background:#263541;overflow:hidden;margin-top:8px}.bar i,.service-bar i{display:block;height:100%;background:var(--green);border-radius:inherit}.bar i.hot{background:var(--red)}.card{padding:12px;margin-bottom:8px}.grid{display:grid;grid-template-columns:1fr 1fr;padding:0}.metric{min-height:64px;padding:11px;border-right:1px solid var(--line);border-bottom:1px solid var(--line);box-sizing:border-box}.metric:nth-child(even){border-right:0}.metric:nth-last-child(-n+2){border-bottom:0}:deep(.metric strong){font-size:15px;display:inline-block;margin-top:7px}.metric.caution :deep(strong){color:var(--amber)}.metric.warn :deep(strong){color:var(--red)}.card h2,.card-title{font-size:12px;margin:0 0 10px;font-weight:800}.card-title{display:flex;justify-content:space-between;align-items:center}.limits-card h2{margin-bottom:3px}.limit-list>div{display:flex;justify-content:space-between;gap:10px;padding:8px 0;border-bottom:1px solid var(--line);font-size:10px}.limit-list>div:last-child{border-bottom:0}.limit-list span{color:var(--muted)}.limit-list strong{text-align:right}.limits-card p,:deep(.notice p){font-size:9px;line-height:1.45;color:var(--muted);margin:8px 0 0}.status-row{display:flex;justify-content:space-between;gap:10px;padding:8px 0;border-top:1px solid var(--line);font-size:10px}:deep(.status-row b){text-align:right;color:var(--green)}.status-row.warn :deep(b){color:var(--amber)}.status-row.bad :deep(b){color:var(--red)}.notice{padding:13px;margin-bottom:8px;border-color:#5d4b2c;background:#211c14}:deep(.notice b){font-size:11px;color:var(--amber)}.mileage-wear{padding:2px 0 12px;border-bottom:1px solid var(--line)}.mileage-wear>div:first-child{display:flex;justify-content:space-between;font-size:10px}.mileage-wear small{display:block;color:var(--muted);font-size:8px;margin-top:6px}.service-heading{color:var(--muted);font-size:8px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;margin:12px 0 3px}.service-item{margin:11px 0}.service-item>div:first-child{display:flex;justify-content:space-between;font-size:10px}.service-item small{display:block;color:var(--muted);font-size:8px;margin-top:4px}.service-bar i.warn-text{background:var(--amber)}.service-bar i.bad-text{background:var(--red)}.service-bar i.neutral-text{background:var(--muted)}.good-text{color:var(--green)}.warn-text{color:var(--amber)}.bad-text{color:var(--red)}.neutral-text{color:var(--muted)}.risk{display:flex;flex-direction:column;gap:2px;padding:8px;margin-top:6px;border-left:3px solid var(--amber);background:#211c14;font-size:9px}.risk.high{border-color:var(--red);background:#251418}.risk span{color:var(--muted)}footer{text-align:center;color:#60737b;font-size:8px;padding:10px}
.scanner::-webkit-scrollbar{width:4px}
.scanner::-webkit-scrollbar-track{background:transparent}
.scanner::-webkit-scrollbar-thumb{background:rgba(255,255,255,.18);border-radius:999px}
.scanner::-webkit-scrollbar-thumb:hover{background:rgba(255,255,255,.3)}
.spec-list>div{display:flex;justify-content:space-between;gap:10px;padding:8px 0;border-bottom:1px solid var(--line);font-size:10px}.spec-list>div:last-child{border-bottom:0}.spec-list span{color:var(--muted)}.spec-list strong{text-align:right}
:deep(.differential-block){padding:9px 0;border-top:1px solid var(--line)}:deep(.differential-block:first-of-type){border-top:0;padding-top:0}:deep(.differential-block:last-child){padding-bottom:0}:deep(.differential-title){display:flex;justify-content:space-between;gap:10px;font-size:10px}:deep(.differential-title span){color:var(--muted);flex:0 0 auto}:deep(.differential-title strong){max-width:62%;text-align:right}:deep(.differential-settings){display:flex;flex-wrap:wrap;gap:5px;margin-top:7px}:deep(.differential-settings span){display:flex;gap:4px;font-size:8px;color:var(--muted);background:#0d151d;padding:4px 6px;border-radius:5px}:deep(.differential-settings b){color:var(--text)}
.finding{padding:9px;border-left:3px solid var(--amber);background:#211c14;margin-top:7px}.finding.high{border-color:var(--red);background:#251418}.finding>b{font-size:10px}.finding p{display:grid;grid-template-columns:82px 1fr;gap:6px;font-size:8px;line-height:1.4;margin:6px 0 0;color:var(--text)}.finding p span{color:var(--muted)}
</style>
