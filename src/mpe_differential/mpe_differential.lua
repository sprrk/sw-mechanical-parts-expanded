local MASS = 1.0
local DRIVESHAFT_A = 2
local DRIVESHAFT_B = 3
local AXLE_A = 0
local AXLE_B = 1

local init = false

function onTick(tick_time)
    if not init then
        ok_1 = component.slotTorqueCreateBridge(DRIVESHAFT_A, DRIVESHAFT_B)
        ok_2 = component.slotTorqueCreateBridge(AXLE_A, AXLE_B)
        ok_3 = component.slotTorqueSetBridgeFactor(DRIVESHAFT_A, 1)
        if ok_1 and ok_2 and ok_3 then init=true end
    end

    slip, slip_ok = component.getInputLogicSlotFloat(0)
    if slip < 0 then slip=0 elseif slip > 1 then slip=1 end
    component.slotTorqueSetBridgeFactor(0, 1-slip)

    driveshaft_a_connected = false
    driveshaft_b_connected = false

    rps_driveshaft, success = component.slotTorqueApplyMomentum(DRIVESHAFT_A, 0, 0)
    if not success or rps_driveshaft == 0 then
        rps_driveshaft, success = component.slotTorqueApplyMomentum(DRIVESHAFT_B, 0, 0)
        if not success or rps_driveshaft == 0 then
            -- No torque to apply to axles
            return
        else
            driveshaft_b_connected = true
        end
    else
        driveshaft_a_connected = true
    end

    axle_a_connected = component.slotTorqueIsConnected(AXLE_A)
    axle_b_connected = component.slotTorqueIsConnected(AXLE_B)

    -- Target the same RPS as the driveshaft
    if axle_a_connected then
        if axle_b_connected then mass=MASS*0.5 else mass=MASS end
        rps_axle_a, success = component.slotTorqueApplyMomentum(AXLE_A, mass, rps_driveshaft)
    end
    if axle_b_connected then
        if axle_a_connected then mass=MASS*0.5 else mass=MASS end
        rps_axle_b, success = component.slotTorqueApplyMomentum(AXLE_B, mass, rps_driveshaft)
    end

    -- Determine the slowdown factor for the driveshaft
    if axle_a_connected and axle_b_connected then
        rps_slowdown = (rps_axle_a+rps_axle_b)/2
    elseif axle_a_connected then
        rps_slowdown = rps_axle_a
    elseif axle_b_connected then
        rps_slowdown = rps_axle_b
    else
        rps_slowdown = 0
    end

     -- Try to slow the driveshaft down to the axle speeds
    -- TODO Consider the slip factor for the slowdown value
    if driveshaft_a_connected then
        component.slotTorqueApplyMomentum(DRIVESHAFT_A, MASS, rps_slowdown)
    elseif driveshaft_b_connected then
        component.slotTorqueApplyMomentum(DRIVESHAFT_B, MASS, rps_slowdown)
    end
end
