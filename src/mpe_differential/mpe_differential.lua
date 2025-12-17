local AXLE_A = 0
local AXLE_B = 1
local DRIVESHAFT_A = 2
local DRIVESHAFT_B = 3
local SLIP_FACTOR_SLOT = 0

local DRIVE_RATIO = 1.0

local AXLE_A_MASS = 0
local AXLE_B_MASS = 0
local DS_MASS = 0

local function clamp(v, mn, mx)
	return v < mn and mn or v > mx and mx or v
end

local initialized = false
local axle_bridge = false

local function calibrateMass()
	-- Apply identical test impulse to each axle, measure resulting velocity
	local TEST_MOMENTUM = 1.0

	-- TODO: Fix inertia calculation for when this component is used
	--       as a center diff; in that case the axles aren't connected to
	--       wheels but to other diffs, which leads to incorrect mass values.

	-- Measure AXLE_A inertia
	component.slotTorqueApplyMomentum(AXLE_A, 1000, 0) -- Reset to 0
	local rps_a = component.slotTorqueApplyMomentum(AXLE_A, 1, TEST_MOMENTUM)
	local mass_a = (rps_a and rps_a ~= 0) and (TEST_MOMENTUM / rps_a) or 1.0

	-- Measure AXLE_B inertia
	component.slotTorqueApplyMomentum(AXLE_B, 1000, 0) -- Reset to 0
	local rps_b = component.slotTorqueApplyMomentum(AXLE_B, 1, TEST_MOMENTUM)
	local mass_b = (rps_b and rps_b ~= 0) and (TEST_MOMENTUM / rps_b) or 1.0

	-- Driveshaft mass = sum of both axles (equal force distribution)
	local massDrive = mass_a + mass_b

	-- Reset all to 0
	component.slotTorqueApplyMomentum(AXLE_A, mass_a, 0)
	component.slotTorqueApplyMomentum(AXLE_B, mass_b, 0)
	component.slotTorqueApplyMomentum(DRIVESHAFT_A, massDrive, 0)
	component.slotTorqueApplyMomentum(DRIVESHAFT_B, massDrive, 0)

	-- Check connections
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

	-- Only return success if all bridges succeeded
	local success = axle_bridge_ok and driveshaft_bridge_ok
	return mass_a, mass_b, massDrive, success
end

local function init()
	AXLE_A_MASS, AXLE_B_MASS, DS_MASS, initialized = calibrateMass()
end

function onParse()
	initialized, _ = parser.parseBool("initialized", initialized)
	axle_bridge, _ = parser.parseBool("axle_bridge", axle_bridge)
	AXLE_A_MASS, _ = parser.parseNumber("axle_a_mass", AXLE_A_MASS)
	AXLE_B_MASS, _ = parser.parseNumber("axle_b_mass", AXLE_B_MASS)
	DS_MASS, _ = parser.parseNumber("ds_mass", DS_MASS)
end

function onTick()
	if not initialized then
		init()
		return
	end

	-- Slip input (0=locked, 1=open)
	local slip = clamp(component.getInputLogicSlotFloat(SLIP_FACTOR_SLOT), 0, 1)
	if axle_bridge then
		component.slotTorqueSetBridgeFactor(AXLE_A, 1 - slip)
	end

	local driveshaft_a_connected = component.slotTorqueIsConnected(DRIVESHAFT_A)
	local driveshaft_b_connected = component.slotTorqueIsConnected(DRIVESHAFT_B)

	local driveshaft_rps = 0
	if driveshaft_a_connected then
		driveshaft_rps = component.slotTorqueApplyMomentum(DRIVESHAFT_A, 0, 0)
	elseif driveshaft_b_connected then
		driveshaft_rps = component.slotTorqueApplyMomentum(DRIVESHAFT_B, 0, 0)
	end

	local axle_a_rps = component.slotTorqueApplyMomentum(AXLE_A, 0, 0)
	local axle_b_rps = component.slotTorqueApplyMomentum(AXLE_B, 0, 0)

	local target_sum = 2 * driveshaft_rps / DRIVE_RATIO
	local error = target_sum - axle_a_rps - axle_b_rps
	local accel = error * 0.5

	local axle_a_target_rps = axle_a_rps + accel
	local axle_b_target_rps = axle_b_rps + accel

	-- Momentum conservation: driveshaft resists by losing momentum to axles
	-- TODO: Check for accuracy and balancing compared to stock parts
	--local momentumLost = AXLE_A_MASS * accel + AXLE_B_MASS * accel
	--local newDs = DS_MASS ~= 0 and (wDs - (momentumLost / DS_MASS)) or wDs

	local rps_a = component.slotTorqueApplyMomentum(AXLE_A, AXLE_A_MASS, axle_a_target_rps)
	local rps_b = component.slotTorqueApplyMomentum(AXLE_B, AXLE_B_MASS, axle_b_target_rps)

	-- Move driveshaft RPS towards average of the two axles
	local driveshaft_target_rps = ((rps_a + rps_b) / 2) * DRIVE_RATIO

	if driveshaft_a_connected then
		component.slotTorqueApplyMomentum(DRIVESHAFT_A, DS_MASS, driveshaft_target_rps)
	elseif driveshaft_b_connected then
		component.slotTorqueApplyMomentum(DRIVESHAFT_B, DS_MASS, driveshaft_target_rps)
	end
end
