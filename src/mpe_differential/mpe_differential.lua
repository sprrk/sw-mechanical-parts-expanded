local AXLE_A = 0
local AXLE_B = 1
local DRIVESHAFT_A = 2
local DRIVESHAFT_B = 3
local SETTINGS_SLOT = 0
local DATA_OUTPUT_SLOT = 1

local DRIVE_RATIO = 1.0
local LR_BIAS = 0
local SLIP_FACTOR = 0 -- (0=locked, 1=open)
local BASE_MASS = 0

local AXLE_A_MASS = 1
local AXLE_B_MASS = 1
local DRIVESHAFT_MASS = 1

local MASS_SMOOTHING_FACTOR = 0.5 -- [0..1] low=smooth, high=responsive
local SLIP_MASS_FACTOR = 1

local initialized = false
local axle_bridge = false

local function clamp(v, mn, mx)
	return v < mn and mn or v > mx and mx or v
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
		SLIP_FACTOR = clamp(floats[1], 0, 1)
		DRIVE_RATIO = clamp(floats[2] or 1, 0.1, 10)
		MASS_SMOOTHING_FACTOR = clamp(floats[3], 0, 1)
		SLIP_MASS_FACTOR = math.max(floats[4], 0)
		LR_BIAS = clamp(floats[5], -1, 1) -- TODO: Implement bias for torque vectoring
		BASE_MASS = math.max(floats[6], 0)
	end

	if axle_bridge then
		component.slotTorqueSetBridgeFactor(AXLE_A, 1 - SLIP_FACTOR)
	end

	local driveshaft_a_connected = component.slotTorqueIsConnected(DRIVESHAFT_A)
	local driveshaft_b_connected = component.slotTorqueIsConnected(DRIVESHAFT_B)

	-- Read current RPS values
	local axle_a_rps = component.slotTorqueApplyMomentum(AXLE_A, 0, 0)
	local axle_b_rps = component.slotTorqueApplyMomentum(AXLE_B, 0, 0)

	-- Move driveshaft RPS towards average of the two axles
	local driveshaft_target_rps = ((axle_a_rps + axle_b_rps) * 0.5) * DRIVE_RATIO

	-- Apply driveshaft momentum
	local driveshaft_rps = 0
	if driveshaft_a_connected then
		driveshaft_rps = component.slotTorqueApplyMomentum(
			DRIVESHAFT_A,
			(BASE_MASS + AXLE_A_MASS + AXLE_B_MASS) / DRIVE_RATIO,
			driveshaft_target_rps
		)
	elseif driveshaft_b_connected then
		driveshaft_rps = component.slotTorqueApplyMomentum(
			DRIVESHAFT_B,
			(BASE_MASS + AXLE_A_MASS + AXLE_B_MASS) / DRIVE_RATIO,
			driveshaft_target_rps
		)
	end

	-- Calculate axle RPS targets
	local target_sum = (driveshaft_rps / DRIVE_RATIO)
	local accel = target_sum - axle_a_rps * 0.5 - axle_b_rps * 0.5
	local axle_a_target_rps = axle_a_rps + accel
	local axle_b_target_rps = axle_b_rps + accel

	-- Apply axle momentum
	local rps_a =
		component.slotTorqueApplyMomentum(AXLE_A, (BASE_MASS + DRIVESHAFT_MASS) * DRIVE_RATIO, axle_a_target_rps)
	local rps_b =
		component.slotTorqueApplyMomentum(AXLE_B, (BASE_MASS + DRIVESHAFT_MASS) * DRIVE_RATIO, axle_b_target_rps)

	local slip_magnitude_driveshaft = math.abs(driveshaft_target_rps - driveshaft_rps)
	local calculated_driveshaft_mass = slip_magnitude_driveshaft * SLIP_MASS_FACTOR
	DRIVESHAFT_MASS = DRIVESHAFT_MASS * (1 - MASS_SMOOTHING_FACTOR) + calculated_driveshaft_mass * MASS_SMOOTHING_FACTOR

	local slip_magnitude_axle_a = math.abs(axle_a_target_rps - rps_a)
	local calculated_axle_a_mass = slip_magnitude_axle_a * SLIP_MASS_FACTOR
	AXLE_A_MASS = AXLE_A_MASS * (1 - MASS_SMOOTHING_FACTOR) + calculated_axle_a_mass * MASS_SMOOTHING_FACTOR

	local slip_magnitude_axle_b = math.abs(axle_b_target_rps - rps_b)
	local calculated_axle_b_mass = slip_magnitude_axle_b * SLIP_MASS_FACTOR
	AXLE_B_MASS = AXLE_B_MASS * (1 - MASS_SMOOTHING_FACTOR) + calculated_axle_b_mass * MASS_SMOOTHING_FACTOR

	component.setOutputLogicSlotComposite(DATA_OUTPUT_SLOT, {
		float_values = {
			[1] = driveshaft_rps,
			[2] = rps_a,
			[3] = rps_b,
		},
	})
end
