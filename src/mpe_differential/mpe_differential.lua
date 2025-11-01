local AXLE_A = 0
local AXLE_B = 1
local DRIVESHAFT_A = 2
local DRIVESHAFT_B = 3
local SETTINGS_SLOT = 0
local DATA_OUTPUT_SLOT = 0

local LSD_ACCELERATION_LOCK = 0.9
local LSD_BRAKING_LOCK = 0.5
local LSD_PRELOAD_LOCK = 0.1
local LSD_RESPONSIVENESS = 0.1
local TORQUE_BIAS = 0
local DRIVE_RATIO = 1.0
local INERTIA_RESPONSIVENESS = 0.95
local RPS_SLIP_ENGAGEMENT_FACTOR = 1
local BASE_INERTIA = 0

local AXLE_A_INERTIA = 1
local AXLE_B_INERTIA = 1
local DRIVESHAFT_INERTIA = 1

local initialized = false
local axle_bridge = false

local previous_driveshaft_rps = 0

local ACCEL_MAGNITUDE_THRESHOLD = 10
local BRAKE_MAGNITUDE_THRESHOLD = 10
local LOCK_FACTOR = 0

local function clamp(v, mn, mx)
	return v < mn and mn or v > mx and mx or v
end

local function calculateAccelBrakeMagnitudes(current_avg_rps, previous_avg_rps, accel_threshold, brake_threshold)
	local velocity_change = current_avg_rps - previous_avg_rps
	local accel_magnitude = 0
	local brake_magnitude = 0
	if current_avg_rps ~= 0 then
		if velocity_change * current_avg_rps > 0 then
			-- Same sign: accelerating
			accel_magnitude = math.min(math.abs(velocity_change) / accel_threshold, 1)
		else
			-- Opposite sign: braking
			brake_magnitude = math.min(math.abs(velocity_change) / brake_threshold, 1)
		end
	end

	return accel_magnitude, brake_magnitude
end

local function calculateLockFactor(accel_magnitude, brake_magnitude, accel_lock, braking_lock, preload_lock)
	local added_lock = accel_magnitude * accel_lock + brake_magnitude * braking_lock
	return clamp(preload_lock + added_lock, 0, 1)
end

local function init()
	local driveshaft_a_connected = component.slotTorqueIsConnected(DRIVESHAFT_A)
	local driveshaft_b_connected = component.slotTorqueIsConnected(DRIVESHAFT_B)
	local axle_a_connected = component.slotTorqueIsConnected(AXLE_A)
	local axle_b_connected = component.slotTorqueIsConnected(AXLE_B)

	-- Create axle bridge if both connected
	local axle_bridge_ok = true
	if axle_a_connected and axle_b_connected then
		axle_bridge_ok = component.slotTorqueCreateBridge(AXLE_A, AXLE_B)
		if axle_bridge_ok then
			axle_bridge = true
		end
	end

	-- Create driveshaft bridge if both connected
	local driveshaft_bridge_ok = true
	if driveshaft_a_connected and driveshaft_b_connected then
		driveshaft_bridge_ok = component.slotTorqueCreateBridge(DRIVESHAFT_A, DRIVESHAFT_B)
			and component.slotTorqueSetBridgeFactor(DRIVESHAFT_A, 1)
	end

	if axle_bridge_ok and driveshaft_bridge_ok then
		initialized = true
	end
end

function onTick()
	if not initialized then
		init()
		return
	end

	-- Read settings from composite input
	local composite, composite_ok = component.getInputLogicSlotComposite(SETTINGS_SLOT)
	if composite_ok then
		local floats = composite.float_values
		LSD_ACCELERATION_LOCK = clamp(floats[1], 0, 1)
		LSD_BRAKING_LOCK = clamp(floats[2], 0, 1)
		LSD_PRELOAD_LOCK = clamp(floats[3], 0, 1)
		LSD_RESPONSIVENESS = clamp(floats[4] or 0.1, 0, 1)
		TORQUE_BIAS = clamp(floats[5], -1, 1)
		DRIVE_RATIO = clamp(floats[6] or 1, 0.1, 10)
		INERTIA_RESPONSIVENESS = clamp(floats[7] or 0.95, 0, 1)
		RPS_SLIP_ENGAGEMENT_FACTOR = math.max(floats[8] or 1, 0)
		BASE_INERTIA = math.max(floats[9], 0)
		ACCEL_MAGNITUDE_THRESHOLD = math.max(floats[10] or 0.02, 0.0001)
		BRAKE_MAGNITUDE_THRESHOLD = math.max(floats[11] or 0.2, 0.0001)
	end

	local driveshaft_a_connected = component.slotTorqueIsConnected(DRIVESHAFT_A)
	local driveshaft_b_connected = component.slotTorqueIsConnected(DRIVESHAFT_B)

	local bias_a = 1 - TORQUE_BIAS -- -1 bias = all to A
	local bias_b = 1 + TORQUE_BIAS -- +1 bias = all to B

	-- Read current RPS values
	local axle_a_rps = component.slotTorqueApplyMomentum(AXLE_A, 0, 0)
	local axle_b_rps = component.slotTorqueApplyMomentum(AXLE_B, 0, 0)

	-- Calculate target driveshaft RPS
	local driveshaft_target_rps = ((axle_a_rps + axle_b_rps) * 0.5) * DRIVE_RATIO

	-- Apply driveshaft momentum
	local driveshaft_rps = 0
	if driveshaft_a_connected then
		driveshaft_rps = component.slotTorqueApplyMomentum(
			DRIVESHAFT_A,
			(BASE_INERTIA + AXLE_A_INERTIA * bias_a + AXLE_B_INERTIA * bias_b) / DRIVE_RATIO,
			driveshaft_target_rps
		)
	elseif driveshaft_b_connected then
		driveshaft_rps = component.slotTorqueApplyMomentum(
			DRIVESHAFT_B,
			(BASE_INERTIA + AXLE_A_INERTIA * bias_a + AXLE_B_INERTIA * bias_b) / DRIVE_RATIO,
			driveshaft_target_rps
		)
	end

	-- Calculate axle RPS targets
	local target_sum = (driveshaft_rps / DRIVE_RATIO)
	local accel = target_sum - axle_a_rps * 0.5 - axle_b_rps * 0.5
	local axle_a_target_rps = axle_a_rps + accel
	local axle_b_target_rps = axle_b_rps + accel

	-- Calculate acceleration/braking magnitude
	local accel_magnitude, brake_magnitude = calculateAccelBrakeMagnitudes(
		driveshaft_rps,
		previous_driveshaft_rps,
		ACCEL_MAGNITUDE_THRESHOLD,
		BRAKE_MAGNITUDE_THRESHOLD
	)

	local lock_factor =
		calculateLockFactor(accel_magnitude, brake_magnitude, LSD_ACCELERATION_LOCK, LSD_BRAKING_LOCK, LSD_PRELOAD_LOCK)
	LOCK_FACTOR = LOCK_FACTOR * (1 - LSD_RESPONSIVENESS) + lock_factor * LSD_RESPONSIVENESS

	-- Apply lock factor to axle bridge
	if axle_bridge then
		component.slotTorqueSetBridgeFactor(AXLE_A, LOCK_FACTOR)
	end

	-- Apply axle momentum
	local base_axle_torque = (BASE_INERTIA + DRIVESHAFT_INERTIA) * DRIVE_RATIO
	local rps_a = component.slotTorqueApplyMomentum(AXLE_A, base_axle_torque * bias_a, axle_a_target_rps)
	local rps_b = component.slotTorqueApplyMomentum(AXLE_B, base_axle_torque * bias_b, axle_b_target_rps)

	-- Calculate the inertia values for the next tick.
	-- Inertia is scaled proportionally to RPS slip to simulate viscous differential behavior.
	-- Greater speed difference creates stronger coupling, naturally aligning speeds.
	local slip_magnitude_driveshaft = math.abs(driveshaft_target_rps - driveshaft_rps)
	local calculated_driveshaft_inertia = slip_magnitude_driveshaft * RPS_SLIP_ENGAGEMENT_FACTOR
	DRIVESHAFT_INERTIA = DRIVESHAFT_INERTIA * (1 - INERTIA_RESPONSIVENESS)
		+ calculated_driveshaft_inertia * INERTIA_RESPONSIVENESS

	local slip_magnitude_axle_a = math.abs(axle_a_target_rps - rps_a)
	local calculated_axle_a_inertia = slip_magnitude_axle_a * RPS_SLIP_ENGAGEMENT_FACTOR
	AXLE_A_INERTIA = AXLE_A_INERTIA * (1 - INERTIA_RESPONSIVENESS) + calculated_axle_a_inertia * INERTIA_RESPONSIVENESS

	local slip_magnitude_axle_b = math.abs(axle_b_target_rps - rps_b)
	local calculated_axle_b_inertia = slip_magnitude_axle_b * RPS_SLIP_ENGAGEMENT_FACTOR
	AXLE_B_INERTIA = AXLE_B_INERTIA * (1 - INERTIA_RESPONSIVENESS) + calculated_axle_b_inertia * INERTIA_RESPONSIVENESS

	component.setOutputLogicSlotComposite(DATA_OUTPUT_SLOT, {
		float_values = {
			[1] = driveshaft_rps,
			[2] = rps_a,
			[3] = rps_b,
			[4] = accel_magnitude,
			[5] = brake_magnitude,
			[6] = LOCK_FACTOR,
		},
	})

	-- Update state for next tick
	previous_driveshaft_rps = driveshaft_rps
end
