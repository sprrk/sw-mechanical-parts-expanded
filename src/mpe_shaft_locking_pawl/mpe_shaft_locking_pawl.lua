local setState = require("sw-lua-lib/statemachine/component_state")

local MASS = 1000
local RPS_THRESHOLD = 1.0

---@return boolean aConnected, boolean bConnected
local function getConnections()
	local connectedA, okA = component.slotTorqueIsConnected(0)
	local connectedB, okB = component.slotTorqueIsConnected(1)
	return (connectedA and okA), (connectedB and okB)
end

---@return fun(): boolean
local getActivateInputFunc = function()
	local f = component.getInputLogicSlotBool

	---@return boolean
	return function()
		local activate, ok = f(0)
		return (activate and ok)
	end
end

-- Forward-declare all states so they can be referenced inside other states
local StateInit, StateUnlocked, StateWaiting, StateLocked

---@type ComponentState
StateInit = (function()
	-- Initial state: check RPS slot connections, set up torque slot bridge

	return {
		onTick = function()
			local aConnected, bConnected = getConnections()

			if aConnected and bConnected then
				if component.slotTorqueCreateBridge(0, 1) and component.slotTorqueSetBridgeFactor(0, 1) then
					-- Success, proceed
					setState(StateUnlocked)
				end
				-- else: Failed to create bridge or set ratio, try again next tick
				--
			elseif aConnected or bConnected then
				-- Only one slot connected, no bridge has to be setup; proceed
				setState(StateUnlocked)
			end
		end,
	}
end)()

---@type ComponentState
StateUnlocked = (function()
	-- Unlocked state: wait for On signal

	local getActivateInput = getActivateInputFunc()

	return {
		onTick = function()
			if getActivateInput() then
				-- Proceed to waiting state as soon as input is received
				setState(StateWaiting)
			end
		end,
	}
end)()

---@type ComponentState
StateWaiting = (function()
	-- Waiting state: wait until below RPS threshold

	local getActivateInput = getActivateInputFunc()
	local aConnected, bConnected = false, false

	---@param i integer Slot index
	---@return fun(): boolean
	local checkBelowThresholdFunc = function(i)
		local f = component.slotTorqueApplyMomentum
		local abs = math.abs

		---@return boolean
		return function()
			local rps, rpsOK = f(i, 0, 0)
			if rpsOK then
				return abs(rps) < RPS_THRESHOLD
			else
				return false
			end
		end
	end

	local checkBelowThresholdA = checkBelowThresholdFunc(0)
	local checkBelowThresholdB = checkBelowThresholdFunc(1)

	return {
		onEntry = function()
			-- Re-check slot connections on entry
			aConnected, bConnected = getConnections()
		end,

		onTick = function()
			if getActivateInput() then
				-- Check if RPS is below threshold; proceed to locked state if so
				if aConnected and checkBelowThresholdA() then
					setState(StateLocked)
				elseif bConnected and checkBelowThresholdB() then
					setState(StateLocked)
				end
			else
				-- Go back to unlocked state
				setState(StateUnlocked)
			end
		end,
	}
end)()

---@type ComponentState
StateLocked = (function()
	-- Locked state: keep RPS at 0 until deactivation

	local getActivateInput = getActivateInputFunc()
	local aConnected, bConnected = false, false

	---@param i integer Slot index
	---@return fun(): nil
	local lockRPSFunc = function(i)
		local f = component.slotTorqueApplyMomentum
		local mass = MASS

		return function()
			-- Set RPS to 0
			f(i, mass, 0)
		end
	end

	local lockRPSA = lockRPSFunc(0)
	local lockRPSB = lockRPSFunc(1)

	return {
		onEntry = function()
			-- Re-check slot connections on entry
			aConnected, bConnected = getConnections()
		end,

		onTick = function()
			if getActivateInput() then
				-- Set RPS of connected slots to 0
				if aConnected then
					lockRPSA()
				end
				if bConnected then
					lockRPSB()
				end
			else
				-- Go back to unlocked state
				setState(StateUnlocked)
			end
		end,

		onExit = function()
			-- Reset mass to 0 to remove inertia
			component.slotTorqueApplyMomentum(0, 0.01, 0)
			component.slotTorqueApplyMomentum(1, 0.01, 0)
		end,
	}
end)()

function onTick()
	-- Run for 1 tick for proper initialization, then activate state machine
	setState(StateInit)
end
