---@meta

---@param tick_time number
function onTick(tick_time) end

function onRender() end

function onParse() end

function onRemoveFromSimulation() end

---@table component
component = {}

---@param index number
---@param mass number
---@param rps number
---@return number, boolean
function component.slotTorqueApplyMomentum(index, mass, rps) end

---@table matrix
matrix = {}

---@param radians number
---@return table
function matrix.rotationX(radians) end

---@param radians number
---@return table
function matrix.rotationY(radians) end

---@param radians number
---@return table
function matrix.rotationZ(radians) end

---@param x number
---@param y number
---@param z number
---@return table
function matrix.translation(x, y, z) end

---@table parser
parser = {}

---@param id string
---@param value number
---@return number, boolean
function parser.parseNumber(id, value) end
