local EMAFilter = require("sw-lua-lib/dsp/exponential_moving_average")
local clamp = require("sw-lua-lib/extramath/clamp")
local lerp = require("sw-lua-lib/extramath/lerp")
local snap = require("sw-lua-lib/extramath/snap")
local setState = require("sw-lua-lib/statemachine/mc_state")

local pN = property.getNumber
local iN = input.getNumber
local iB = input.getBool
local sN = output.setNumber
local sB = output.setBool
local max = math.max
local circleF = screen.drawCircleF

local RATIO_MIN = pN("Min. ratio")
local RATIO_MAX = pN("Max. ratio")
local MIN_RPS = pN("Idle RPS")
local MAX_RPS = pN("Max. RPS")
local RESPONSIVENESS = pN("Responsiveness") * 0.001
local CLUTCH_KEY = pN("Clutch key")
local RATIO_SELECTOR_MIN = pN("Min. selector ratio")
local RATIO_SELECTOR_MAX = pN("Max. selector ratio")
local RATIO_MULT_REVERSE = 0.1 -- TODO: Make configurable

local THROTTLE_GAIN = 0.375 -- TODO: Make configurable
local CLUTCH_GAIN = 2.0 -- TODO: Make configurable

local HUD_RADIUS = 5
local CURSOR_SPEED = pN("HUD cursor speed")
local HUD_X, HUD_Y = 200, 80 -- Offset

-- Note: HUD size is x=256, y=192

local smoothRatio = EMAFilter({ alpha = RESPONSIVENESS })
local smoothClutch = EMAFilter({ alpha = 0.6 })
local smoothThrottle = EMAFilter({ alpha = 0.6 })

local cursorPos = { x = 0, y = 0 }

---@alias RenderFunc fun(): nil

---@param x number
---@param y number
---@return Vec2
local function Vec2(x, y)
	---@class Vec2
	---@field x number
	---@field y number
	local instance = { x = x, y = y }

	---@param v Vec2
	---@return Vec2
	function instance:add(v)
		return Vec2(self.x + v.x, self.y + v.y)
	end

	return instance
end

local ui = {
	---@param p Vec2 Center position
	---@param r number Radius
	---@return RenderFunc
	circle = function(p, r)
		local x, y, f = p.x, p.y, screen.drawCircle

		---@return nil
		return function()
			f(x, y, r)
		end
	end,

	---@param p Vec2 Center position
	---@param r number Radius
	---@return RenderFunc
	circleF = function(p, r)
		local x, y, f = p.x, p.y, screen.drawCircleF

		---@return nil
		return function()
			f(x, y, r)
		end
	end,

	---@param p Vec2 Top-left position
	---@param txt string
	---@return RenderFunc
	text = function(p, txt)
		local x, y, f = p.x, p.y, screen.drawText

		---@return nil
		return function()
			f(x, y, txt)
		end
	end,

	---@class LineFuncKwargs
	---@field m1 number? Start margin
	---@field m2 number? End margin

	---@param p1 Vec2
	---@param p2 Vec2
	---@param kwargs LineFuncKwargs?
	---@return RenderFunc
	line = function(p1, p2, kwargs)
		local m1 = 0
		local m2 = 0
		if kwargs then
			m1 = kwargs.m1 or 0
			m2 = kwargs.m2 or 0
		end

		local f = screen.drawLine
		local x1, y1 = p1.x, p1.y
		local x2, y2 = p2.x, p2.y

		-- TODO: Move distance logic to vec2 lib
		local dx = x2 - x1
		local dy = y2 - y1
		local distance = math.sqrt(dx * dx + dy * dy)
		local ux = dx / distance
		local uy = dy / distance

		local _x1 = x1 + ux * m1
		local _y1 = y1 + uy * m1
		local _x2 = x2 - ux * m2
		local _y2 = y2 - uy * m2

		---@return nil
		return function()
			f(_x1, _y1, _x2, _y2)
		end
	end,

	---@param r integer
	---@param g integer
	---@param b integer
	---@param a integer?
	---@return RenderFunc
	color = function(r, g, b, a)
		local _a, f = a or 255, screen.setColor
		return function()
			f(r, g, b, _a)
		end
	end,
}

local currentGear

local bright = ui.color(255, 255, 255, 128)
local dim = ui.color(255, 255, 255, 64)

---@alias GearLabel string

---@param x integer
---@param y integer
---@param label GearLabel
---@return Gear
local function Gear(x, y, label)
	local r = HUD_RADIUS
	local o = -r * 0.5 + 1
	local pos = Vec2(x, y)

	---@class Gear
	---@field x integer
	---@field y integer
	---@field pos Vec2
	local instance = { x = x, y = y, pos = pos }

	---@return RenderFunc[]
	function instance:getRenderFuncs()
		return {
			function()
				if currentGear == instance then
					bright()
				else
					dim()
				end
			end,
			ui.circle(pos, r),
			ui.text(pos:add(Vec2(o, o)), label),
			dim,
		}
	end

	return instance
end

---@param x integer
---@param y integer
---@param label GearLabel
---@return RangeSelector
local function RangeSelector(x, y, label)
	-- TODO: Implement range selector visualization

	local base = Gear(x, y, label)

	local r = HUD_RADIUS
	local pos = Vec2(x, y)

	local pTop = pos:add(Vec2(0, -20))
	local pBot = pos:add(Vec2(0, 20))
	local tOffset = Vec2(r, -r * 0.5 + 1)

	---@class RangeSelector : Gear
	---@field x integer
	---@field y integer
	---@field pos Vec2
	local instance = { x = x, y = y, pos = pos }

	---@return RenderFunc[]
	function instance:getRenderFuncs()
		local funcs = base:getRenderFuncs()

		---@type RenderFunc[]
		local selectorRenderFuncs = {
			-- Top
			ui.circleF(pTop, r * 0.5),
			ui.text(pTop:add(tOffset), "+"),
			ui.line(pos, pTop, { m1 = r + 1, m2 = r * 0.5 }),
			-- Bottom
			ui.circleF(pBot, r * 0.5),
			ui.text(pBot:add(tOffset), "-"),
			ui.line(pos, pBot, { m1 = r + 1, m2 = r * 0.5 }),
		}

		for i = 1, #selectorRenderFuncs do
			table.insert(funcs, selectorRenderFuncs[i])
		end
		return funcs
	end

	return instance
end

---@type table<GearLabel,Gear>
local gears = {
	P = Gear(HUD_X + 40, HUD_Y + 0, "P"),
	R = Gear(HUD_X + 40, HUD_Y + 20, "R"),
	N = Gear(HUD_X + 40, HUD_Y + 40, "N"),
	D = Gear(HUD_X + 40, HUD_Y + 60, "D"),
	M = RangeSelector(HUD_X + 20, HUD_Y + 60, "M"),
}
currentGear = gears.P -- Default to park

---@return Gear|nil
local function findNearestGear()
	local minDistanceSq = math.huge -- Use squared distance to avoid expensive sqrt
	local nearestGear = nil

	-- Iterate through all defined gears
	for gearKey, gear in pairs(gears) do
		-- Calculate squared Euclidean distance
		local dx = cursorPos.x - gear.x
		local dy = cursorPos.y - gear.y
		local distanceSq = dx * dx + dy * dy

		-- Check if this is the closest gear so far
		if distanceSq < minDistanceSq then
			minDistanceSq = distanceSq
			nearestGear = gearKey
		end
	end

	return gears[nearestGear]
end

---@return nil
local function drawCursor()
	local r = HUD_RADIUS

	if not currentGear then
		bright()
		circleF(snap(cursorPos.x, 1), snap(cursorPos.y, 1), r + 1.5)
	else
		dim()
		circleF(currentGear.x, currentGear.y, r - 0.5)
	end
end

-- Collect all renderables
---@type RenderFunc[]
local renderFuncs = {
	dim,
	ui.line(gears.P.pos, gears.R.pos, { m1 = HUD_RADIUS + 1, m2 = HUD_RADIUS + 0 }),
	ui.line(gears.R.pos, gears.N.pos, { m1 = HUD_RADIUS + 1, m2 = HUD_RADIUS + 0 }),
	ui.line(gears.N.pos, gears.D.pos, { m1 = HUD_RADIUS + 1, m2 = HUD_RADIUS + 0 }),
	ui.line(gears.M.pos, gears.D.pos, { m1 = HUD_RADIUS + 1, m2 = HUD_RADIUS + 0 }),
}
for _, gear in pairs(gears) do
	local funcs = gear:getRenderFuncs()
	for _, func in pairs(funcs) do
		table.insert(renderFuncs, func)
	end
end
table.insert(renderFuncs, drawCursor)

function onDraw()
	for i = 1, #renderFuncs do
		renderFuncs[i]()
	end
end

-- Forward-declare all states so they can be referenced inside other states
local StatePark, StateReverse, StateNeutral, StateDrive, StateManual, StateNavigate

---@return nil
local function handleClutchEngage()
	-- Switch to the navigation state when the clutch key is pushed
	if iB(CLUTCH_KEY) then
		setState(StateNavigate)
	end
end

---@param v number Clutch value [0..1]
---@return nil
local function setClutch(v)
	sN(2, v)
end

---@param v number CVT ratio value
---@return nil
local function setRatio(v)
	sN(1, v)
end

---@return nil
local function updateThrottle()
	local engineRPS = iN(5)
	local userInput = clamp(iN(2), 0, 1) -- W/S value
	local minThrottle = clamp((MIN_RPS - engineRPS) * THROTTLE_GAIN, 0, 1)
	local maxThrottle = clamp((MAX_RPS - engineRPS) * THROTTLE_GAIN, 0, 1)
	local throttle = clamp(userInput, minThrottle, maxThrottle)
	sN(4, smoothThrottle(throttle))
end

---@param mult number Ratio multiplier
---@return nil
local function runCVT(mult)
	local userInput = max(0, iN(2)) -- W/S value
	local engineRPS = iN(5)
	local driveshaftRPS = iN(6)
	local clampedEngineRPS = clamp(engineRPS, MIN_RPS, MAX_RPS)
	local clampedDriveshaftRPS = clamp(driveshaftRPS, MIN_RPS * RATIO_MIN, MAX_RPS * RATIO_MAX)

	local engineRatio = RATIO_MIN + (clampedEngineRPS - MIN_RPS) * (RATIO_MAX - RATIO_MIN) / (MAX_RPS - MIN_RPS)
	local driveshaftRatio = clampedDriveshaftRPS / MAX_RPS

	local ratio = lerp(driveshaftRatio, engineRatio, userInput)

	ratio = ratio * mult

	ratio = clamp(ratio, RATIO_MIN, RATIO_MAX)
	ratio = smoothRatio(ratio)

	setRatio(ratio)
end

---@return nil
local function autoClutch()
	local engineRPS = iN(5)

	local userInput = max(0, iN(2)) -- W/S value
	local maxClutch = clamp((engineRPS - MIN_RPS) * CLUTCH_GAIN, 0, 1) -- Anti-stall
	local clutch = clamp(userInput, 0, maxClutch)
	sN(2, smoothClutch(clutch))
end

---@type MicrocontrollerState
StateNavigate = (function()
	return {
		onEntry = function()
			setClutch(0)
			currentGear = nil
		end,

		onTick = function()
			updateThrottle()

			if iB(CLUTCH_KEY) then
				-- As long as the clutch key is pressed, move the cursor

				local x = iN(3) -- Left/right
				local y = iN(4) -- Up/down
				y = -y -- Flip Y, the HUD's Y axis is inverted

				-- TODO: Prevent moving to next gear if X axis is not aligned, so that e.g.
				--       when holding down and left, it snaps to the next gear instead of
				--       skipping multiple gears

				y = y * CURSOR_SPEED
				x = x * CURSOR_SPEED

				cursorPos.x = cursorPos.x + x
				cursorPos.y = cursorPos.y + y
			else
				-- When the clutch key is released, then find the nearest gear,
				-- activate it, and switch to that gear's state
				local gear = findNearestGear()
				if gear then
					-- TODO: Snap more smoothly over a few frames instead of instantly
					cursorPos.x = gear.x
					cursorPos.y = gear.y
					currentGear = gear

					-- TODO: Use lookup table instead of if/else chain
					if gear == gears.P then
						setState(StatePark)
					elseif gear == gears.R then
						setState(StateReverse)
					elseif gear == gears.N then
						setState(StateNeutral)
					elseif gear == gears.D then
						setState(StateDrive)
					elseif gear == gears.M then
						setState(StateManual)
					end
				end
			end
		end,
	}
end)()

---@type MicrocontrollerState
StatePark = (function()
	---@param v boolean
	---@return nil
	local function setPawl(v)
		if v then
			sN(3, 1)
		else
			sN(3, 0)
		end
	end

	return {
		onEntry = function()
			setPawl(true)
		end,

		onTick = function()
			updateThrottle()
			handleClutchEngage()
		end,

		onExit = function()
			setPawl(false)
		end,
	}
end)()

---@type MicrocontrollerState
StateReverse = (function()
	---@param v boolean
	---@return nil
	local function setReverse(v)
		sB(1, v)
	end

	return {
		onEntry = function()
			setReverse(true)
		end,

		onTick = function()
			updateThrottle()
			runCVT(RATIO_MULT_REVERSE)
			autoClutch()
			handleClutchEngage()
		end,

		onExit = function()
			setReverse(false)
		end,
	}
end)()

---@type MicrocontrollerState
StateNeutral = (function()
	return {
		onEntry = function()
			setClutch(0)
		end,

		onTick = function()
			updateThrottle()
			handleClutchEngage()
		end,
	}
end)()

---@type MicrocontrollerState
StateDrive = (function()
	return {
		onTick = function()
			updateThrottle()
			runCVT(1)
			autoClutch()
			handleClutchEngage()
		end,
	}
end)()

---@type MicrocontrollerState
StateManual = (function()
	local ratio = RATIO_SELECTOR_MIN
	local value = 0
	local SPEED = 0.01

	return {
		onTick = function()
			value = value + iN(4) * SPEED -- Up/down
			value = clamp(value, 0, 1)
			ratio = lerp(RATIO_SELECTOR_MIN, RATIO_SELECTOR_MAX, value)

			setRatio(ratio)
			autoClutch()
			updateThrottle()
			handleClutchEngage()
		end,
	}
end)()

function onTick()
	-- Run for 1 tick for proper initialization, then activate state machine
	setState(StatePark)
end
