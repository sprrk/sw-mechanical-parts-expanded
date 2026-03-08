local EMAFilter = require("sw-lua-lib/dsp/exponential_moving_average")
local clamp = require("sw-lua-lib/extramath/clamp")
local lerp = require("sw-lua-lib/extramath/lerp")
local snap = require("sw-lua-lib/extramath/snap")

local pN = property.getNumber
local iN = input.getNumber
local iB = input.getBool
local sN = output.setNumber
local max = math.max
local line = screen.drawLine
local circleF = screen.drawCircleF

local TARGET_RPS = pN("Target RPS")
local RPS_BAND = pN("RPS band")
local RATIO_MIN = pN("Min. ratio")
local RATIO_MAX = pN("Max. ratio")
local MIN_RPS = TARGET_RPS - RPS_BAND
local MAX_RPS = TARGET_RPS + RPS_BAND
local RESPONSIVENESS = pN("Responsiveness") * 0.001
local CLUTCH_KEY = pN("Clutch key")

local HUD_RADIUS = 5
local CURSOR_SPEED = 2.5
local HUD_X, HUD_Y = 200, 80 -- Offset

-- Note: HUD size is x=256, y=192

local smooth = EMAFilter({ alpha = RESPONSIVENESS })

local cursorPos = { x = 0, y = 0 }
local clutchKeyDown = false

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
	local p1 = Vec2(x, y)

	---@class Gear
	---@field x integer
	---@field y integer
	local instance = { x = x, y = y }

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
			ui.circle(p1, r),
			ui.text(p1:add(Vec2(o, o)), label),
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
	-- TODO: Implement range selector logic

	local base = Gear(x, y, label)

	local r = HUD_RADIUS
	local p1 = Vec2(x, y)

	local pTop = p1:add(Vec2(0, -20))
	local pBot = p1:add(Vec2(0, 20))
	local tOffset = Vec2(r, -r * 0.5 + 1)

	---@class RangeSelector : Gear
	---@field x integer
	---@field y integer
	local instance = { x = x, y = y }

	---@return RenderFunc[]
	function instance:getRenderFuncs()
		local funcs = base:getRenderFuncs()

		---@type RenderFunc[]
		local selectorRenderFuncs = {
			-- Top
			ui.circleF(pTop, r * 0.5),
			ui.text(pTop:add(tOffset), "+"),
			ui.line(p1, pTop, { m1 = r + 1, m2 = r * 0.5 }),
			-- Bottom
			ui.circleF(pBot, r * 0.5),
			ui.text(pBot:add(tOffset), "-"),
			ui.line(p1, pBot, { m1 = r + 1, m2 = r * 0.5 }),
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

---@param gear1 Gear
---@param gear2 Gear
---@return RenderFunc
local function makeGearLineFunc(gear1, gear2)
	-- TODO: Use func provided by ui lib
	local x1, y1, x2, y2 = gear1.x, gear1.y, gear2.x, gear2.y

	local dx = x2 - x1
	local dy = y2 - y1
	local distance = math.sqrt(dx * dx + dy * dy)
	local ux = dx / distance
	local uy = dy / distance

	local r = HUD_RADIUS
	local startCutoff = 1
	local endCutoff = 0
	local l1 = r + startCutoff
	local l2 = r + endCutoff

	local x1Edge = x1 + ux * l1
	local y1Edge = y1 + uy * l1
	local x2Edge = x2 - ux * l2
	local y2Edge = y2 - uy * l2

	---@return nil
	return function()
		line(x1Edge, y1Edge, x2Edge, y2Edge)
	end
end

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

---@param gear Gear
---@return nil
local function snapToGear(gear)
	-- TODO: Snap more smoothly over a few frames instead of instantly
	cursorPos.x = gear.x
	cursorPos.y = gear.y
	currentGear = gear
end

---@param x number
---@param y number
---@return nil
local function moveCursor(x, y)
	local isMoving = (x ~= 0) or (y ~= 0)

	local nearestGear = findNearestGear()

	if isMoving and clutchKeyDown then
		y = -y -- Flip Y, the HUD's Y axis is inverted

		-- TODO: Prevent moving to next gear if X axis is not aligned, so that e.g.
		--       when holding down and left, it snaps to the next gear instead of
		--       skipping multiple gears

		y = y * CURSOR_SPEED
		x = x * CURSOR_SPEED

		-- TODO: Improve cursor constraint calculation
		if nearestGear == gears.P then
			-- Only down
			cursorPos.x = gears.P.x
			if cursorPos.y < gears.P.y then
				cursorPos.y = gears.P.y
			end
		elseif nearestGear == gears.R then
			-- Only up and down
			cursorPos.x = gears.R.x
		elseif nearestGear == gears.N then
			-- Only up and down
			cursorPos.x = gears.N.x
		elseif nearestGear == gears.D then
			-- Up and left
			if cursorPos.x > gears.D.x then
				cursorPos.x = gears.D.x
			end
			if cursorPos.y > gears.D.y then
				cursorPos.y = gears.D.y
			end
		elseif nearestGear == gears.M then
			-- Up, down and right
			if cursorPos.x < gears.M.x then
				cursorPos.x = gears.M.x
			end
			--elseif nearestGear == gears.M_min then
			--	-- TODO: Implement range selector:
			--	--       - Stick cursor x to gears.M.x
			--	--       - Prevent moving cursor y to less than gears.M_max.y and higher than gears.M_min.y
			--	--       - Decrease cursor speed
			--	--       - Only snap to gears.M if nearby enough
			--	cursorPos.x = gears.M_min.x
			--	if cursorPos.y > gears.M_min.y then
			--		cursorPos.y = gears.M_min.y
			--	end
			--elseif nearestGear == gears.M_max then
			--	cursorPos.x = gears.M_max.x
			--	if cursorPos.y < gears.M_max.y then
			--		cursorPos.y = gears.M_max.y
			--	end
		end

		cursorPos.x = cursorPos.x + x
		cursorPos.y = cursorPos.y + y
	elseif not clutchKeyDown then
		if nearestGear then
			snapToGear(nearestGear)
		end
	end
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
	makeGearLineFunc(gears.P, gears.R),
	makeGearLineFunc(gears.R, gears.N),
	makeGearLineFunc(gears.N, gears.D),
	makeGearLineFunc(gears.M, gears.D),
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

function onTick()
	local leftRight = iN(3)
	local upDown = iN(4)
	clutchKeyDown = iB(CLUTCH_KEY)
	if clutchKeyDown then
		currentGear = nil
	end
	moveCursor(leftRight, upDown)

	local throttle = max(0, iN(2)) -- W/S value
	local engineRPS = iN(5)
	local driveshaftRPS = iN(6)
	local clampedEngineRPS = clamp(engineRPS, MIN_RPS, MAX_RPS)
	local clampedDriveshaftRPS = clamp(driveshaftRPS, MIN_RPS * RATIO_MIN, MAX_RPS * RATIO_MAX)

	local engineRatio = RATIO_MIN + (clampedEngineRPS - MIN_RPS) * (RATIO_MAX - RATIO_MIN) / (MAX_RPS - MIN_RPS)
	local driveshaftRatio = clampedDriveshaftRPS / MAX_RPS

	local ratio = lerp(driveshaftRatio, engineRatio, throttle)

	ratio = clamp(ratio, RATIO_MIN, RATIO_MAX)
	ratio = smooth(ratio)
	sN(1, ratio)
end
