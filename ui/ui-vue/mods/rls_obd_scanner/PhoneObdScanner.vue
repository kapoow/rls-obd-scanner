<template>
  <PhoneWrapper app-name="OBD Scanner">
    <div class="scanner">
      <header class="hero">
        <div>
          <div class="eyebrow" :class="{ online: scannerConnected, caution: scannerNeedsIgnition }">{{ connectionPresentation.eyebrow }}</div>
          <h1>{{ vehicleTitle }}</h1>
        </div>
        <span class="status" :class="{ online: scannerConnected, caution: scannerNeedsIgnition }">{{ connectionPresentation.status }}</span>
      </header>

      <nav class="tabs" aria-label="Scanner sections">
        <button v-for="item in tabs" :key="item.id" :class="{ active: tab === item.id }" @click="tab = item.id">
          {{ item.label }}
        </button>
      </nav>

      <Notice v-if="!scannerConnected" :title="connectionPresentation.noticeTitle">
        {{ connectionPresentation.noticeText }}
      </Notice>

      <main v-else-if="tab === 'live'">
        <section class="gauges">
          <article v-if="isNumber(live.rpm)" class="gauge">
            <span>{{ live.hasElectricDrive ? 'Drive motor speed' : 'Engine speed' }}</span><strong>{{ whole(live.rpm) }}</strong><small>rpm</small>
            <div class="bar"><i :style="{ width: rpmPercent + '%' }"></i></div>
          </article>
          <article v-if="live.isHybrid && isNumber(live.engineRpm)" class="gauge">
            <span>Generator engine speed</span><strong>{{ whole(live.engineRpm) }}</strong><small>rpm</small>
            <div class="bar"><i :style="{ width: engineRpmPercent + '%' }"></i></div>
          </article>
          <article v-if="!live.isElectric && isNumber(live.coolantTemp)" class="gauge">
            <span>{{ live.isHybrid ? 'Generator coolant' : 'Coolant temperature' }}</span><strong>{{ temperature(live.coolantTemp) }}</strong>
            <div class="bar"><i :class="{ hot: live.coolantTemp >= 115 }" :style="{ width: temperaturePercent + '%' }"></i></div>
          </article>
        </section>

        <section class="card grid">
          <Metric v-if="!live.isElectric" :label="live.isHybrid ? 'Generator oil' : 'Oil'" :value="temperature(live.oilTemp)" :warn="live.oilTemp >= 135" />
          <Metric v-if="live.hasElectricDrive" label="Battery charge" :value="percent(live.batteryCharge)" />
          <Metric v-if="!live.isElectric" :label="live.isHybrid ? 'Diesel fuel' : 'Fuel level'" :value="percent(live.fuel)" />
          <Metric :label="live.hasElectricDrive ? 'Vehicle state' : 'Ignition'" :value="ignitionText" />
          <Metric :label="live.hasElectricDrive ? 'Propulsion load' : 'Engine load'" :value="percent(live.hasElectricDrive ? live.propulsionLoad : live.engineLoad)" />
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

      </main>

      <main v-else-if="tab === 'engine'">
        <section v-if="!live.isElectric" class="card specs-card">
          <h2>{{ live.isHybrid ? 'Generator engine specifications' : 'Engine specifications' }}</h2>
          <div class="spec-list">
            <div v-if="live.engineName"><span>{{ live.isHybrid ? 'Generator engine' : 'Engine' }}</span><strong>{{ live.engineName }}</strong></div>
            <div v-if="isNumber(ratedPowerHp)"><span>Peak power</span><strong>{{ power(ratedPowerHp) }}</strong></div>
            <div v-if="isNumber(ratedTorque)"><span>Peak torque</span><strong>{{ torque(ratedTorque) }}</strong></div>
            <div v-if="live.forcedInductionName || live.forcedInductionType"><span>Forced induction</span><strong>{{ live.forcedInductionName || live.forcedInductionType }}</strong></div>
          </div>
        </section>

        <section v-if="live.hasElectricDrive && motors.length" class="card specs-card">
          <h2>Drive motor specifications</h2>
          <div class="spec-list">
            <template v-for="motor in motors" :key="motor.id">
              <div><span>{{ motor.position ? `${motor.position} motor` : 'Motor' }}</span><strong>{{ motor.name }}</strong></div>
              <div v-if="isNumber(motor.ratedPowerHp)"><span>Peak power</span><strong>{{ power(motor.ratedPowerHp) }}</strong></div>
              <div v-if="isNumber(motor.ratedTorqueNm)"><span>Peak torque</span><strong>{{ torque(motor.ratedTorqueNm) }}</strong></div>
              <div v-if="isNumber(motor.maxRpm)"><span>Maximum motor speed</span><strong>{{ whole(motor.maxRpm) }} rpm</strong></div>
            </template>
          </div>
        </section>

        <section v-if="!live.isElectric && hasEcuCalibration" class="card calibration-card">
          <h2>Engine management</h2>
          <div class="spec-list">
            <div v-if="isNumber(live.idleRpm)">
              <span>Target idle speed</span><strong>{{ whole(live.idleRpm) }} rpm</strong>
            </div>
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

        <section v-if="!live.isElectric && hasEngineLimits" class="card limits-card">
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

        <section v-if="live.hasElectricDrive" class="card">
          <h2>Drive motor diagnostics</h2>
          <StatusRow label="Current propulsion output" :bad="motorRestrictionNeedsAttention" :warn="motorOutputRestricted && !motorRestrictionNeedsAttention" :text="motorOutputText" />
          <StatusRow v-if="!motorOutputRestricted && isNumber(recentMotorTorqueAvailability)" label="Observed under-load output" warn :text="`${percent(recentMotorTorqueAvailability)} available`" />
          <StatusRow v-for="motor in motors" :key="motor.id" :label="motor.position ? `${motor.position} motor` : motor.name" :bad="motor.broken === true || (motor.disabled === true && motor.hasEnergy === true)" :text="motor.broken === true ? 'Fault detected' : motor.disabled === true && motor.hasEnergy === true ? 'Unavailable' : 'Normal'" />
        </section>

        <section v-if="!live.isElectric" class="card">
          <h2>{{ live.isHybrid ? 'Generator engine diagnostics' : 'Diagnostics' }}</h2>
          <StatusRow v-if="maintenanceOnline" label="Output restriction" :bad="powerLimited && powerLimitReason !== 'Old engine top-end loss'" :warn="powerLimited && powerLimitReason === 'Old engine top-end loss'" :text="powerLimitText" />
          <StatusRow v-if="roughnessState" label="Combustion stability" :bad="roughnessState !== 'Normal'" :text="roughnessState" />
          <StatusRow v-if="misfireState" label="Estimated misfire risk" :bad="misfireState !== 'Normal'" :text="misfireState" />
          <StatusRow v-if="maintenanceOnline && engine.activeSymptom" label="Active condition" bad :text="engine.activeSymptomLabel || 'Fault detected'" />
        </section>
      </main>

      <main v-else-if="tab === 'service'">
        <Notice v-if="live.isElectric && maintenanceOnline" title="RLS maintenance model">
          These service values are applied to this vehicle by RLS and can affect propulsion output, but they are not native EV component readings.
        </Notice>
        <Notice v-if="!maintenanceOnline" title="Service information unavailable">
          {{ maintenanceUnavailableText }}
        </Notice>
        <template v-if="maintenanceOnline">
          <section v-for="category in maintenanceCategories" :key="category.key" class="card service-card">
            <div class="card-title">
              <span>{{ category.label }}</span>
              <b :class="categoryConditionClass(category.data)">{{ categoryConditionState(category.data) }}</b>
            </div>
            <div v-if="isNumber(category.data.avgMiles)" class="mileage-wear">
              <div><span>Mileage wear</span><b :style="{ color: mileageWearColor(category.data.avgMiles) }">{{ mileageWearPercent(category.data.avgMiles) }}%</b></div>
              <div class="service-bar"><i :style="{ width: mileageWearPercent(category.data.avgMiles) + '%', backgroundColor: mileageWearColor(category.data.avgMiles) }"></i></div>
              <small>{{ distanceMiles(category.data.avgMiles) }} on installed components</small>
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
        <section v-if="live.hasElectricDrive" class="card specs-card">
          <h2>Electric drive</h2>
          <div class="spec-list">
            <div v-if="driveLayout"><span>Drive layout</span><strong>{{ driveLayout }}</strong></div>
            <template v-for="motor in motors" :key="motor.id">
              <div><span>{{ motor.position || 'Drive motor' }}</span><strong>{{ motor.name }}</strong></div>
              <div v-if="motor.reductionName"><span>Reduction unit</span><strong>{{ motor.reductionName }}</strong></div>
              <div v-if="motor.reductionRatios?.length"><span>Reduction ratios</span><strong>{{ ratioList(motor.reductionRatios) }}</strong></div>
              <div v-else-if="isNumber(motor.reductionRatio)"><span>Current reduction</span><strong>{{ decimal(motor.reductionRatio, 2) }}:1</strong></div>
              <div v-if="motor.differentialName"><span>Differential</span><strong>{{ motor.differentialName }}</strong></div>
              <div v-if="isNumber(motor.finalDriveRatio)"><span>Final drive</span><strong>{{ decimal(motor.finalDriveRatio, 2) }}:1</strong></div>
            </template>
          </div>
        </section>

        <section v-else class="card specs-card">
          <h2>Transmission</h2>
          <div class="spec-list">
            <div v-if="gearboxDisplayName"><span>Gearbox</span><strong>{{ gearboxDisplayName }}</strong></div>
            <div v-if="isNumber(live.forwardGearCount)"><span>Forward gears</span><strong>{{ whole(live.forwardGearCount) }}</strong></div>
            <div v-if="live.clutchName"><span>Clutch</span><strong>{{ live.clutchName }}</strong></div>
            <div v-if="live.flywheelName"><span>Flywheel</span><strong>{{ live.flywheelName }}</strong></div>
            <div v-if="isNumber(live.clutchRatedTorqueNm)"><span>Rated clutch capacity</span><strong>{{ torque(live.clutchRatedTorqueNm) }}</strong></div>
            <div v-if="clutchCapacityReduced"><span>Available clutch capacity</span><strong>{{ torque(live.clutchAvailableTorqueNm) }}</strong></div>
          </div>
        </section>

        <section v-if="!live.hasElectricDrive" class="card grid">
          <Metric label="Shift response" :value="shiftQualityState" :warn="shiftQualityState !== 'Normal'" />
          <Metric v-if="hasClutchData" label="Estimated clutch condition" :value="clutchWearState" :warn="clutchWearState !== 'Normal'" />
          <Metric v-if="hasClutchData && isNumber(live.clutchTempC)" label="Clutch temperature" :value="temperature(live.clutchTempC)" :warn="clutchTemperatureHigh" :caution="clutchTemperatureElevated" />
          <Metric label="Fluid quality" :value="percent(transmission.maintenance?.fluidCondition)" />
          <Metric label="Fluid level" :value="percent(transmission.maintenance?.fluidLevel)" />
        </section>

        <section v-if="isNumber(live.airPressurePa)" class="card grid">
          <Metric label="Air pressure" :value="airPressure(live.airPressurePa)" :warn="live.lowAirPressure === true" />
          <Metric v-if="isBoolean(live.lowAirPressure)" label="Air system" :value="live.lowAirPressure ? 'Pressure low' : 'Normal'" :warn="live.lowAirPressure" />
          <Metric v-if="isBoolean(live.parkingBrakeApplied)" label="Parking brake" :value="live.parkingBrakeApplied ? 'Applied' : 'Released'" :warn="live.lowAirPressure && live.parkingBrakeApplied" />
        </section>

        <section v-if="!live.hasElectricDrive && hasDifferentialData" class="card differentials-card">
          <h2>Differentials</h2>
          <DifferentialBlock label="Front differential" :data="live.frontDifferential" :hide-final-drive="live.isElectric" />
          <DifferentialBlock label="Center coupling" :data="live.centerCoupling" :hide-final-drive="live.isElectric" />
          <DifferentialBlock label="Rear differential" :data="live.rearDifferential" :hide-final-drive="live.isElectric" />
        </section>

        <section v-if="!live.hasElectricDrive && hasDrivetrainStatus" class="card">
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
import { buildDiagnosticFindings } from "./scannerDiagnostics.js"

const Metric = (props) => props.value === null || props.value === undefined || props.value === '' ? null : h('div', { class: ['metric', props.warn && 'warn', props.caution && 'caution'] }, [
  h('span', props.label), h('strong', props.value), props.unit ? h('small', props.unit) : null,
])
const Notice = (props, { slots }) => h('section', { class: 'notice' }, [h('b', props.title), h('p', slots.default?.())])
const StatusRow = props => h('div', { class: ['status-row', props.bad && 'bad', props.warn && 'warn'] }, [h('span', props.label), h('b', props.text)])
const DifferentialBlock = props => {
  const data = props.data
  if (!data?.name) return null
  const settings = [
    !props.hideFinalDrive && isNumber(data.finalDriveRatio) && ['Final drive', `${decimal(data.finalDriveRatio, 2)}:1`],
    isNumber(data.powerLockPercent) && ['Power lock', `${Math.round(data.powerLockPercent)}%`],
    isNumber(data.coastLockPercent) && ['Coast lock', `${Math.round(data.coastLockPercent)}%`],
    isNumber(data.preloadNm) && ['Preload', torque(data.preloadNm)],
  ].filter(Boolean)
  return h('div', { class: 'differential-block' }, [
    h('div', { class: 'differential-title' }, [h('span', props.label), h('strong', data.name)]),
    settings.length ? h('div', { class: 'differential-settings' }, settings.map(([label, value]) => h('span', [label, h('b', value)]))) : null,
  ])
}
DifferentialBlock.props = ['label', 'data', 'hideFinalDrive']

const POWER_LIMIT_DEFINITIONS = {
  'Temporary symptom': {
    status: 'Reduced — active engine fault',
    cause: 'An active engine fault is limiting output.',
  },
  'Oil starvation': {
    status: 'Reduced — lubrication fault',
    cause: 'Insufficient lubrication is limiting engine output.',
    action: 'Check the oil level and lubrication system before continued operation.',
  },
  'Severe ignition issue': {
    status: 'Reduced — ignition fault',
    cause: 'Ignition-system condition is limiting engine output.',
  },
  'Old engine top-end loss': {
    status: 'Reduced — engine wear',
    cause: 'Internal engine wear is reducing available output.',
    action: 'No routine service is due. Test engine output or compression; rebuild or replace the worn engine to restore performance.',
  },
  'Maintenance torque protection': {
    status: 'Reduced — service condition',
    cause: 'Engine service condition has triggered protective output reduction.',
  },
  'Catastrophic cooling loss': {
    cause: 'Severe coolant loss has triggered engine protection.',
  },
  Overheating: {
    cause: 'Excessive engine temperature has triggered engine protection.',
  },
}

const DIAGNOSTIC_RISK_DEFINITIONS = {
  wear_spike: { label: 'Accelerated wear detected', detail: 'Wear rate is currently above normal.' },
  high_output: { label: 'Powertrain load is increasing wear' },
  limit_stress: { label: 'Transmission load is high', detail: 'Operating demand is close to the transmission capacity.' },
  failure_window: { label: 'Transmission failure risk detected', detail: 'Continued operation may cause a mechanical failure.' },
  engine_integrity: { label: 'Engine mechanical integrity is low' },
  oil_starvation: { label: 'Severe oil starvation detected' },
  oil_starvation_catastrophic: { label: 'Critical oil starvation detected' },
  piston_rings: { label: 'Piston-ring damage detected', detail: 'Oil consumption is elevated.' },
  cooling_catastrophic: { label: 'Critical cooling-system loss detected' },
  cooling_severe: { label: 'Severe cooling-system loss detected' },
  overheating: { label: 'Engine is overheating' },
  critical_heat: { label: 'Coolant temperature is critically high' },
  transmission_overheat: { label: 'Transmission is overheating' },
  transmission_heat: { label: 'Transmission temperature is elevated' },
  fluid_quality_critical: { label: 'Transmission-fluid condition is critical' },
  fluid_quality_low: { label: 'Transmission-fluid condition is poor' },
  slip_risk: { label: 'Transmission slip risk detected' },
  fluid_loss: { label: 'Transmission-fluid level is critical' },
  fluid_low: { label: 'Transmission-fluid level is low' },
}

const SERVICE_ITEM_LABELS = {
  coolantIntegrity: 'Coolant condition',
  fluidCondition: 'Fluid quality',
}

const TRANSMISSION_SYMPTOM_DEFINITIONS = {
  roughShift: { label: 'Rough shift', effect: 'Gear changes may feel abrupt or harsh.' },
  shiftDelay: { label: 'Shift delay', effect: 'Gear engagement or shifting may respond more slowly than expected.' },
  slip: { label: 'Transmission slip', effect: 'Engine speed may rise without a matching increase in vehicle speed.' },
}

const NATIVE_DAMAGE_DEFINITIONS = {
  overRevDanger: { title: 'Engine over-rev observed', cause: 'Engine speed exceeded the mechanical safe limit.', effect: 'Internal engine components may have been overstressed.', action: 'Avoid further over-revving and inspect the engine if abnormal operation follows.' },
  mildOverrevDamage: { title: 'Engine over-rev damage', cause: 'BeamNG reported damage caused by excessive engine speed.', effect: 'Engine durability or performance may be reduced.', action: 'Inspect the engine before further high-speed operation.' },
  catastrophicOverrevDamage: { severity: 'high', title: 'Severe engine over-rev damage', cause: 'Engine speed caused catastrophic internal stress.', effect: 'Major internal engine damage may have occurred.', action: 'Stop the engine and inspect it before further operation.' },
  overTorqueDanger: { title: 'Engine overtorque observed', cause: 'Combustion torque exceeded the engine damage threshold.', effect: 'Internal engine components may have been overstressed.', action: 'Reduce load and inspect the engine if abnormal operation follows.' },
  catastrophicOverTorqueDamage: { severity: 'high', title: 'Severe engine overtorque damage', cause: 'BeamNG reported catastrophic damage from excessive torque.', effect: 'Major internal engine damage may have occurred.', action: 'Stop the engine and inspect it before further operation.' },
  coolantOverheating: { title: 'Coolant overheating', cause: 'Coolant temperature exceeded the vehicle warning threshold.', effect: 'Continued operation may damage the cooling system or engine.', action: 'Reduce load, stop safely, and allow the engine to cool.' },
  oilOverheating: { title: 'Engine oil overheating', cause: 'Oil temperature exceeded the vehicle warning threshold.', effect: 'Lubrication performance may be reduced.', action: 'Reduce load and allow the engine oil to cool.' },
  starvedOfOil: { title: 'Oil starvation observed', cause: 'BeamNG reported insufficient oil supply under the current vehicle motion.', effect: 'Engine bearings may have received inadequate lubrication.', action: 'Stop severe manoeuvres and inspect oil level if the warning returns.' },
  oilLevelCritical: { severity: 'high', title: 'Critical engine oil level', cause: 'The engine reported an unsafe oil quantity.', effect: 'Lubrication loss may cause rapid engine damage.', action: 'Stop the engine and correct the oil level before continued operation.' },
  oilLevelTooHigh: { title: 'Engine oil level too high', cause: 'The engine reported excessive oil quantity.', effect: 'Lubrication and crankcase operation may be affected.', action: 'Correct the oil level before continued operation.' },
  engineIsHydrolocking: { title: 'Hydrolock risk observed', cause: 'Liquid intrusion obstructed engine rotation.', effect: 'Further starting attempts may cause severe internal damage.', action: 'Stop attempting to start the engine and inspect it.' },
  engineReducedTorque: { title: 'Engine output reduced', cause: 'The vehicle controller reported reduced engine torque.', effect: 'Available engine performance was limited.', action: 'Review other findings and inspect the engine if the restriction returns.' },
  engineDisabled: { title: 'Engine disabled', cause: 'The vehicle reported that the engine could not operate.', effect: 'Propulsion from the engine was unavailable.', action: 'Inspect active damage and engine systems before restarting.' },
  engineLockedUp: { severity: 'high', title: 'Engine lock-up', cause: 'BeamNG reported that the engine could not rotate.', effect: 'The engine cannot operate normally.', action: 'Stop attempting to run the engine and inspect internal damage.' },
  impactDamage: { title: 'Engine impact damage', cause: 'An impact damaged the engine assembly.', effect: 'Engine operation or durability may be compromised.', action: 'Inspect the engine and its mounts before continued operation.' },
  radiatorLeak: { title: 'Radiator leak', cause: 'BeamNG reported cooling-system leakage from the radiator.', effect: 'Coolant loss may lead to overheating.', action: 'Inspect the radiator and coolant level before continued operation.' },
  oilRadiatorLeak: { title: 'Engine oil cooler leak', cause: 'BeamNG reported oil leakage from the oil cooler.', effect: 'Oil loss may reduce lubrication.', action: 'Inspect the oil cooler and oil level before continued operation.' },
  oilpanLeak: { title: 'Engine oil pan leak', cause: 'BeamNG reported oil leakage from the oil pan.', effect: 'Oil loss may reduce lubrication.', action: 'Inspect the oil pan and oil level before continued operation.' },
  exhaustBroken: { title: 'Exhaust system damage', cause: 'BeamNG reported a broken exhaust connection.', effect: 'Exhaust flow, sound, or emissions behavior may be affected.', action: 'Inspect and repair the exhaust system.' },
  blockMelted: { severity: 'high', title: 'Engine block thermal failure', cause: 'Extreme temperature damaged the engine block.', effect: 'The engine cannot operate safely.', action: 'Stop the engine and replace or rebuild the damaged assembly.' },
  cylinderWallsMelted: { severity: 'high', title: 'Cylinder wall thermal failure', cause: 'Extreme temperature damaged the cylinder walls.', effect: 'The engine cannot operate safely.', action: 'Stop the engine and replace or rebuild the damaged assembly.' },
  synchroWear: { title: 'Gear synchronizer wear observed', cause: 'BeamNG reported synchronizer stress during a gear change.', effect: 'Gear engagement may become difficult or noisy.', action: 'Use the clutch fully and avoid forcing gear engagement.' },
}

const { api, units } = useBridge()
const events = useEvents()
const tab = ref('live')
const live = ref({})
// BeamNG serializes an empty Lua table as an object. Keep every consumer on a
// predictable array while preserving populated motor arrays for EVs/hybrids.
const motors = computed(() => Array.isArray(live.value.motors) ? live.value.motors : [])
const maintenance = ref({})
const recentSymptoms = ref({})
const liveUpdatedAt = ref(0)
const displayVehicleName = ref(null)
const isWalking = ref(null)

const tabs = [
  { id: 'live', label: 'Overview' }, { id: 'engine', label: 'Engine' },
  { id: 'service', label: 'Service' }, { id: 'drive', label: 'Drivetrain' },
]

useStreams(['rlsObdScannerData', 'vehicleMaintenanceDebugData'], streams => {
  if (streams.rlsObdScannerData) {
    live.value = streams.rlsObdScannerData
    if (streams.rlsObdScannerData.maintenanceModeEnabled !== true) {
      maintenance.value = {}
      recentSymptoms.value = {}
    }
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
  if (streams.vehicleMaintenanceDebugData && live.value.maintenanceModeEnabled === true) {
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
    local walking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() or false
    local vehicle = be:getPlayerVehicle(0)
    if walking or not vehicle then return {isWalking = walking, vehicleName = nil} end
    local data = core_vehicles.getModel(vehicle.JBeam)
    local model = data and data.model
    local name = model and string.format("%s %s", model.Brand or "", model.Name or "") or nil
    return {isWalking = false, vehicleName = name}
  end)()`, value => {
    isWalking.value = value?.isWalking !== false
    displayVehicleName.value = value?.vehicleName || null
  })
}
events.on('VehicleReset', connectVehicle)
events.on('VehicleChange', connectVehicle)
onMounted(connectVehicle)

const engine = computed(() => maintenance.value.categories?.engine || {})
const radiator = computed(() => maintenance.value.categories?.radiator || {})
const transmission = computed(() => maintenance.value.categories?.transmission || {})
const liveOnline = computed(() => liveUpdatedAt.value > 0)
const ignitionOn = computed(() => isNumber(live.value.ignition) && live.value.ignition >= 2)
const scannerNeedsIgnition = computed(() => isWalking.value === false && liveOnline.value && !ignitionOn.value)
const scannerConnected = computed(() => isWalking.value === false && liveOnline.value && ignitionOn.value)
const connectionPresentation = computed(() => scannerConnected.value
  ? { eyebrow: 'CONNECTED VEHICLE', status: 'CONNECTED', noticeTitle: null, noticeText: null }
  : scannerNeedsIgnition.value
    ? { eyebrow: 'VEHICLE DETECTED', status: 'TURN IGNITION ON', noticeTitle: 'Scanner unavailable', noticeText: 'Turn the ignition on to communicate with the vehicle control modules.' }
    : isWalking.value
      ? { eyebrow: 'VEHICLE SCANNER', status: 'ENTER VEHICLE', noticeTitle: 'No vehicle connected', noticeText: 'Enter a vehicle to connect the scanner.' }
      : { eyebrow: 'VEHICLE SCANNER', status: 'WAITING', noticeTitle: 'Waiting for vehicle connection', noticeText: 'Waiting for vehicle data.' })
const maintenanceOnline = computed(() => live.value.maintenanceModeEnabled === true && Boolean(maintenance.value.categories))
const maintenanceUnavailableText = computed(() => live.value.maintenanceModeEnabled === false
  ? 'RLS Maintenance Mode is disabled for this career save. Native vehicle diagnostics remain available.'
  : 'Service information is still initializing or is not available for this vehicle.')
const vehicleTitle = computed(() => isWalking.value ? 'No vehicle connected' : displayVehicleName.value || live.value.vehicleName || (liveOnline.value ? `Vehicle ${live.value.vehicleId}` : 'No connection'))
const ignitionText = computed(() => live.value.isHybrid
  ? (live.value.ignition == null ? null : live.value.ignition >= 2
      ? (live.value.generatorRunning ? 'Ready — generator running' : 'Ready — generator standby')
      : live.value.ignition > 0 ? 'Accessory' : 'Off')
  : live.value.isElectric
    ? (live.value.ignition == null ? null : live.value.ignition >= 2 ? 'Ready' : live.value.ignition > 0 ? 'Accessory' : 'Off')
    : (live.value.engineRunning === true ? 'Engine running' : live.value.ignition == null ? null : live.value.ignition >= 2 ? 'Ignition on' : live.value.ignition > 0 ? 'Accessory' : 'Off'))
const rpmPercent = computed(() => {
  const motorMaximum = motors.value.reduce((maximum, motor) => Math.max(maximum, isNumber(motor.maxRpm) ? motor.maxRpm : 0), 0)
  const maximum = live.value.hasElectricDrive ? motorMaximum : live.value.ecuLimiterRpm
  return isNumber(maximum) && maximum > 0 ? Math.min(100, Math.max(0, live.value.rpm / maximum * 100)) : 0
})
const engineRpmPercent = computed(() => isNumber(live.value.ecuLimiterRpm) && live.value.ecuLimiterRpm > 0
  ? Math.min(100, Math.max(0, live.value.engineRpm / live.value.ecuLimiterRpm * 100))
  : 0)
const temperaturePercent = computed(() => typeof live.value.coolantTemp === 'number' ? Math.min(100, Math.max(0, live.value.coolantTemp / 130 * 100)) : 0)
const ratedTorque = computed(() => live.value.ratedTorqueNm ?? engine.value.torqueNm)
const ratedPowerHp = computed(() => live.value.ratedPowerHp ?? engine.value.powerHp)
const limiterStrategyText = computed(() => ({ timeBased: 'Timed cut', rpmDrop: 'RPM-drop cut' })[live.value.revLimiterType] || null)
const limiterCutDurationMs = computed(() => limiterStrategyText.value && isNumber(live.value.revLimiterCutTime) ? live.value.revLimiterCutTime * 1000 : null)
const hasEcuCalibration = computed(() => isNumber(live.value.idleRpm) || isNumber(live.value.ecuLimiterRpm) || Boolean(limiterStrategyText.value) || isNumber(live.value.wastegateStartPsi))
const hasEngineLimits = computed(() => isNumber(live.value.overrevThresholdRpm) || isNumber(live.value.overtorqueThresholdNm))
const pistonRingsDamaged = computed(() => live.value.pistonRingsDamaged || engine.value.pistonRingsDamaged)
const nextServiceMiles = computed(() => {
  const due = maintenanceCategories.value.flatMap(category => category.data.maintenanceItems || [])
    .map(item => item.dueMiles ?? item.serviceDueMilesRemaining)
    .filter(value => isNumber(value))
  return due.length ? Math.max(0, Math.min(...due)) : null
})
const nextServiceText = computed(() => distanceMiles(nextServiceMiles.value))
const motorTorqueAvailability = computed(() => isNumber(live.value.motorRestrictionRatedTorqueNm) && live.value.motorRestrictionRatedTorqueNm > 0 && isNumber(live.value.motorTorqueLimitNm)
  ? Math.min(1, Math.max(0, live.value.motorTorqueLimitNm / live.value.motorRestrictionRatedTorqueNm))
  : null)
const hasMeasuredMotorRestriction = computed(() => isNumber(motorTorqueAvailability.value) && motorTorqueAvailability.value < 0.995)
const recentMotorTorqueAvailability = computed(() => isNumber(live.value.recentMotorTorqueAvailability)
  ? Math.min(1, Math.max(0, live.value.recentMotorTorqueAvailability))
  : null)
const motorOutputRestricted = computed(() => live.value.hasElectricDrive && (
  hasMeasuredMotorRestriction.value
  || engine.value.liveMetrics?.powerCapActive === true
  || radiator.value.liveMetrics?.powerLimitActive === true
))
const motorRestrictionNeedsAttention = computed(() => motorOutputRestricted.value
  && hasMeasuredMotorRestriction.value && motorTorqueAvailability.value < 0.9)
const motorOutputText = computed(() => motorOutputRestricted.value
  ? (hasMeasuredMotorRestriction.value ? `Reduced — ${percent(motorTorqueAvailability.value)} available` : 'Reduced')
  : 'Normal')
const motorUnavailable = computed(() => live.value.hasElectricDrive && live.value.motorDisabled === true && live.value.motorBroken !== true && live.value.motorHasEnergy === true)
const powerLimited = computed(() => motorOutputRestricted.value || engine.value.liveMetrics?.powerCapActive === true || radiator.value.liveMetrics?.powerLimitActive === true)
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
const diagnosticFindings = computed(() => buildDiagnosticFindings({
  live: live.value,
  engine: engine.value,
  radiator: radiator.value,
  transmission: transmission.value,
  recentSymptoms: recentSymptoms.value,
  pistonRingsDamaged: pistonRingsDamaged.value,
  motorUnavailable: motorUnavailable.value,
  motorOutputRestricted: motorOutputRestricted.value,
  motorRestrictionNeedsAttention: motorRestrictionNeedsAttention.value,
  hasMeasuredMotorRestriction: hasMeasuredMotorRestriction.value,
  motorTorqueAvailability: motorTorqueAvailability.value,
  recentMotorTorqueAvailability: recentMotorTorqueAvailability.value,
  powerLimited: powerLimited.value,
  powerLimitReason: powerLimitReason.value,
  clutchTemperatureHigh: clutchTemperatureHigh.value,
  clutchTemperatureElevated: clutchTemperatureElevated.value,
  nowSeconds: Date.now() / 1000,
  isNumber,
  percent,
  temperature,
  airPressure,
  nativeDamageFinding,
  friendlyFindingCause,
  powerLimitAction,
  maintenanceAction,
  recentSymptom,
  transmissionSymptomFinding,
}))
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
const driveLayout = computed(() => {
  const motorPositions = motors.value.map(motor => motor.position || '')
  const hasFrontMotor = motorPositions.some(position => position.startsWith('Front'))
  const hasRearMotor = motorPositions.some(position => position.startsWith('Rear'))
  if (hasFrontMotor && hasRearMotor) return 'All-wheel drive'
  if (hasFrontMotor) return 'Front-wheel drive'
  if (hasRearMotor) return 'Rear-wheel drive'
  return live.value.frontDifferential?.name && live.value.rearDifferential?.name
  ? 'All-wheel drive'
  : live.value.frontDifferential?.name
    ? 'Front-wheel drive'
    : live.value.rearDifferential?.name
      ? 'Rear-wheel drive'
      : null
})
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
function temperature(value) { return isNumber(value) ? units.buildString('temperature', value, 0) : null }
function percent(value) { return isNumber(value) ? `${Math.round(value * 100)}%` : null }
function clampPercent(value) { return typeof value === 'number' ? Math.max(0, Math.min(100, value * 100)) : 0 }
function power(metricHorsepower) { return isNumber(metricHorsepower) ? units.buildString('power', metricHorsepower, 0) : null }
function torque(value) { return isNumber(value) ? units.buildString('torque', value, 0) : null }
function distanceMiles(miles) { return isNumber(miles) ? units.buildString('length', miles * 1609.344, 0) : null }
function ratioList(ratios) { return ratios.filter(isNumber).map(ratio => `${decimal(ratio, 2)}:1`).join(' / ') }
function airPressure(pascals) { return isNumber(pascals) ? units.buildString('pressure', pascals / 1000, 1) : null }
function boostPressure(psi) { return isNumber(psi) ? units.buildString('pressure', psi * 6.894757, 1) : null }
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
  return SERVICE_ITEM_LABELS[item?.name] || item?.label || null
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
  const definition = POWER_LIMIT_DEFINITIONS[reason]
  if (definition?.action) return definition.action
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
  const definition = TRANSMISSION_SYMPTOM_DEFINITIONS[symptom]
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
    title: `${active ? 'Active' : 'Intermittent'} ${definition?.label || 'transmission condition'}`,
    cause,
    effect: definition?.effect || 'Shift response or torque transfer may be affected.',
    action: maintenanceAction(transmission.value, symptom === 'slip'
      ? 'Inspect the transmission and clutch if slipping returns.'
      : 'Monitor for recurrence and inspect the transmission if the condition becomes frequent.'),
  }
}
function nativeDamageFinding(event) {
  const definition = NATIVE_DAMAGE_DEFINITIONS[event?.name]
  if (!definition) return null
  const active = event.active === true
  return {
    key: `native-${event.group}-${event.name}`,
    severity: definition.severity || 'medium',
    attention: active,
    recent: !active,
    title: `${active ? 'Active — ' : 'Recently observed — '}${definition.title}`,
    cause: definition.cause, effect: definition.effect, action: definition.action,
  }
}
function friendlyFindingCause(reason) {
  return POWER_LIMIT_DEFINITIONS[reason]?.cause || 'The powertrain has applied a protective output reduction.'
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
  return POWER_LIMIT_DEFINITIONS[reason]?.status || (reason ? `Reduced — ${reason}` : 'Reduced')
}
function diagnosticRiskLabel(risk) {
  if (DIAGNOSTIC_RISK_DEFINITIONS[risk?.key]) return DIAGNOSTIC_RISK_DEFINITIONS[risk.key].label
  if (/_due$/.test(risk?.key || '')) return 'Service overdue'
  return null
}
function diagnosticRisks(risks) {
  const list = Array.isArray(risks) ? risks : Object.values(risks || {})
  return list.filter(risk => diagnosticRiskLabel(risk))
}
function diagnosticRiskDetail(risk) {
  if (!risk) return null
  const definition = DIAGNOSTIC_RISK_DEFINITIONS[risk.key]
  if (definition?.detail) return definition.detail
  const detail = risk.detail
  if (!detail) return null
  if (/drive multiplier|limit stress|per sec/i.test(detail)) return null
  return detail.replace(/([0-9.]+) C simulated/i, (_, value) => `Estimated temperature ${temperature(Number(value))}`)
}
function dueText(item) {
  const due = item.dueMiles ?? item.serviceDueMilesRemaining
  if (typeof due !== 'number') return null
  return due <= 0 ? 'Service due now' : `Estimated service due in ${distanceMiles(due)}`
}
</script>

<style scoped>
.scanner{--bg:#0b1118;--card:#131d27;--line:#263541;--text:#eef5f3;--muted:#91a3aa;--green:#50e3a4;--amber:#ffbe55;--red:#ff6673;height:100%;overflow-y:auto;overscroll-behavior:contain;padding:3.2rem 14px 28px;background:var(--bg);color:var(--text);font-family:Inter,Arial,sans-serif;box-sizing:border-box}.hero{display:flex;align-items:center;justify-content:space-between;padding:6px 2px 14px}.eyebrow{font-size:9px;letter-spacing:.16em;color:var(--muted);font-weight:800}.eyebrow.caution{color:var(--amber)}.hero h1{font-size:20px;line-height:1.15;margin:4px 0 0;max-width:210px}.status{font-size:8px;font-weight:900;letter-spacing:.08em;color:var(--muted);border:1px solid var(--line);border-radius:99px;padding:6px 7px}.status.online,.eyebrow:not(.caution){color:var(--green)}.status.online{border-color:#287a5a;background:#10271f}.status.caution{color:var(--amber);border-color:#7c5d28;background:#271f10}.tabs{display:grid;grid-template-columns:repeat(4,1fr);gap:4px;padding:4px;background:#111a23;border-radius:11px;margin-bottom:10px}.tabs button{border:0;background:transparent;color:var(--muted);font-size:9px;font-weight:700;padding:8px 2px;border-radius:8px}.tabs button.active{background:#263541;color:white}.gauges{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:8px}.gauge,.card,.notice{background:var(--card);border:1px solid var(--line);border-radius:13px}.gauge{padding:12px}.gauge span,:deep(.metric span){display:block;color:var(--muted);font-size:10px}.gauge strong{display:inline-block;font-size:25px;margin-top:5px}.gauge small,:deep(.metric small){color:var(--muted);font-size:9px;margin-left:5px}.bar,.service-bar{height:5px;border-radius:5px;background:#263541;overflow:hidden;margin-top:8px}.bar i,.service-bar i{display:block;height:100%;background:var(--green);border-radius:inherit}.bar i.hot{background:var(--red)}.card{padding:12px;margin-bottom:8px}.grid{display:grid;grid-template-columns:1fr 1fr;padding:0}.metric{min-height:64px;padding:11px;border-right:1px solid var(--line);border-bottom:1px solid var(--line);box-sizing:border-box}.metric:nth-child(even){border-right:0}.metric:nth-last-child(-n+2){border-bottom:0}:deep(.metric strong){font-size:15px;display:inline-block;margin-top:7px}.metric.caution :deep(strong){color:var(--amber)}.metric.warn :deep(strong){color:var(--red)}.card h2,.card-title{font-size:12px;margin:0 0 10px;font-weight:800}.card-title{display:flex;justify-content:space-between;align-items:center}.limits-card h2{margin-bottom:3px}.limit-list>div{display:flex;justify-content:space-between;gap:10px;padding:8px 0;border-bottom:1px solid var(--line);font-size:10px}.limit-list>div:last-child{border-bottom:0}.limit-list span{color:var(--muted)}.limit-list strong{text-align:right}.limits-card p,:deep(.notice p){font-size:9px;line-height:1.45;color:var(--muted);margin:8px 0 0}.status-row{display:flex;justify-content:space-between;gap:10px;padding:8px 0;border-top:1px solid var(--line);font-size:10px}:deep(.status-row b){text-align:right;color:var(--green)}.status-row.warn :deep(b){color:var(--amber)}.status-row.bad :deep(b){color:var(--red)}.notice{padding:13px;margin-bottom:8px;border-color:#5d4b2c;background:#211c14}:deep(.notice b){font-size:11px;color:var(--amber)}.mileage-wear{padding:2px 0 12px;border-bottom:1px solid var(--line)}.mileage-wear>div:first-child{display:flex;justify-content:space-between;font-size:10px}.mileage-wear small{display:block;color:var(--muted);font-size:8px;margin-top:6px}.service-heading{color:var(--muted);font-size:8px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;margin:12px 0 3px}.service-item{margin:11px 0}.service-item>div:first-child{display:flex;justify-content:space-between;font-size:10px}.service-item small{display:block;color:var(--muted);font-size:8px;margin-top:4px}.service-bar i.warn-text{background:var(--amber)}.service-bar i.bad-text{background:var(--red)}.service-bar i.neutral-text{background:var(--muted)}.good-text{color:var(--green)}.warn-text{color:var(--amber)}.bad-text{color:var(--red)}.neutral-text{color:var(--muted)}.risk{display:flex;flex-direction:column;gap:2px;padding:8px;margin-top:6px;border-left:3px solid var(--amber);background:#211c14;font-size:9px}.risk.high{border-color:var(--red);background:#251418}.risk span{color:var(--muted)}footer{text-align:center;color:#60737b;font-size:8px;padding:10px}
.scanner::-webkit-scrollbar{width:4px}
.eyebrow:not(.online):not(.caution){color:var(--muted)}
.scanner::-webkit-scrollbar-track{background:transparent}
.scanner::-webkit-scrollbar-thumb{background:rgba(255,255,255,.18);border-radius:999px}
.scanner::-webkit-scrollbar-thumb:hover{background:rgba(255,255,255,.3)}
.spec-list>div{display:flex;justify-content:space-between;gap:10px;padding:8px 0;border-bottom:1px solid var(--line);font-size:10px}.spec-list>div:last-child{border-bottom:0}.spec-list span{color:var(--muted)}.spec-list strong{text-align:right}
:deep(.differential-block){padding:9px 0;border-top:1px solid var(--line)}:deep(.differential-block:first-of-type){border-top:0;padding-top:0}:deep(.differential-block:last-child){padding-bottom:0}:deep(.differential-title){display:flex;justify-content:space-between;gap:10px;font-size:10px}:deep(.differential-title span){color:var(--muted);flex:0 0 auto}:deep(.differential-title strong){max-width:62%;text-align:right}:deep(.differential-settings){display:flex;flex-wrap:wrap;gap:5px;margin-top:7px}:deep(.differential-settings span){display:flex;gap:4px;font-size:8px;color:var(--muted);background:#0d151d;padding:4px 6px;border-radius:5px}:deep(.differential-settings b){color:var(--text)}
.finding{padding:9px;border-left:3px solid var(--amber);background:#211c14;margin-top:7px}.finding.high{border-color:var(--red);background:#251418}.finding>b{font-size:10px}.finding p{display:grid;grid-template-columns:82px 1fr;gap:6px;font-size:8px;line-height:1.4;margin:6px 0 0;color:var(--text)}.finding p span{color:var(--muted)}
</style>
