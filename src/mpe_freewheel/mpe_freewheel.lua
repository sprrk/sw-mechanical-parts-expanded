local EMAFilter = require("sw-lua-lib/dsp/exponential_moving_average")
local clamp = require("sw-lua-lib/extramath/clamp")
local lerp = require("sw-lua-lib/extramath/lerp")

local slotTorqueSetBridgeFactor = component.slotTorqueSetBridgeFactor
local slotTorqueApplyMomentum = component.slotTorqueApplyMomentum
local getInputLogicSlotComposite = component.getInputLogicSlotComposite
local setOutputLogicSlotFloat = component.setOutputLogicSlotFloat
local max = math.max

local smooth, updateEMAFilter = EMAFilter({ alpha = 0.3 })

local lockFactor = 0
local deadzone = 1
local minInputRPS = 0
local gain = 0

local initialized = false
local compositeData = {}

---@return nil
local function initialize()
	if
		component.slotTorqueCreateBridge(0, 1)
		and slotTorqueSetBridgeFactor(0, 0) -- Start disengaged
		and component.slotTorqueSetBridgeRatio(0, 1)
	then
		initialized = true
	end
end

---@param factor number
local function setLockFactor(factor)
	factor = smooth(factor)

	if lockFactor ~= factor then
		slotTorqueSetBridgeFactor(0, factor)
		lockFactor = factor
		setOutputLogicSlotFloat(0, factor)
	end
end

---@return nil
local function updateSettings()
	compositeData = getInputLogicSlotComposite(0)
	if compositeData then
		local floatValues = compositeData.float_values
		minInputRPS = max(floatValues[1], 0)
		deadzone = max(floatValues[2], 0)
		gain = max(floatValues[3], 0.01)
		updateEMAFilter({ alpha = clamp(floatValues[4], 0, 1) })
	end
end

function onTick(_)
	if not initialized then
		initialize()
		return
	end

	updateSettings()

	local inputRPS, inputOK = slotTorqueApplyMomentum(0, 0, 0)
	local outputRPS, outputOK = slotTorqueApplyMomentum(1, 0, 0)

	if not inputOK or not outputOK or inputRPS <= minInputRPS then
		setLockFactor(0) -- Failed to read RPS or below threshold; disengage
		return
	end

	local delta = inputRPS - outputRPS
	if delta >= deadzone then
		-- Input significantly faster than output; engage
		local rawFactor = clamp((delta - deadzone) * gain, 0, 1)
		local factor = lerp(0, 1, rawFactor)
		setLockFactor(factor)
	else
		-- Coasting or overspeed; disengage
		setLockFactor(0)
	end
end
