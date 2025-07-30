local MASS = 4

local init = false

function onTick(tick_time)
    if not init then
        a_ok = component.slotTorqueCreateBridge(0, 1)
        b_ok = component.slotTorqueSetBridgeFactor(0, 1)
        if a_ok and b_ok then init = true else return end
    end

    force, force_get_ok = component.getInputLogicSlotFloat(0)
    if force_get_ok then
        if force < 0 then force = 0 elseif force > 1 then force = 1 end
        component.slotTorqueApplyMomentum(0, MASS*force, 0)
    end
end
