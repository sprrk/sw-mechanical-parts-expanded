local RATIO_MIN = 0.1
local RATIO_MAX = 10
local LOSS = 0.15

local init = false

function onTick(_)
	if not init then
		local a_ok = component.slotTorqueCreateBridge(0, 1)
		local b_ok = component.slotTorqueSetBridgeFactor(0, 1 - LOSS)
		if a_ok and b_ok then
			init = true
		else
			return
		end
	end

	local ratio, ratio_get_ok = component.getInputLogicSlotFloat(0)
	if ratio_get_ok then
		if ratio < RATIO_MIN then
			ratio = RATIO_MIN
		elseif ratio > RATIO_MAX then
			ratio = RATIO_MAX
		end
		component.slotTorqueSetBridgeRatio(0, ratio)
	else
		component.slotTorqueSetBridgeRatio(0, 1)
	end
end
