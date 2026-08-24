-- Draconic Evolution Energy Core Monitor
-- CC:Tweaked + Basalt 2.5
--
-- Requires basalt.lua next to this program.
-- The charts module provides PixelGraph.

local basalt = require("basalt")
basalt.use("charts")

------------------------------------------------------------
-- Configuration
------------------------------------------------------------

local SAMPLE_INTERVAL = 1
local HISTORY_LENGTH = 60

local PYLON_TYPES = { "energy_pylon", "energyPylon" }

local UNITS = { "RF", "FE", "OP" }

local TIER_CAPACITY = {
    [45500000]      = 1,
    [273000000]     = 2,
    [1640000000]    = 3,
    [9880000000]    = 4,
    [59300000000]   = 5,
    [356000000000]  = 6,
    [2140000000000] = 7,
    [-1]            = 8,
}

------------------------------------------------------------
-- Colors
------------------------------------------------------------

local C = {
    bg       = colors.black,
    panel    = colors.gray,
    text     = colors.white,
    muted    = colors.lightGray,
    accent   = colors.cyan,
    input    = colors.lime,
    output   = colors.red,
    net      = colors.yellow,
    good     = colors.lime,
    warning  = colors.yellow,
    danger   = colors.red,
}

------------------------------------------------------------
-- Reactive application state
------------------------------------------------------------

local energy = basalt.signal(0)
local maxEnergy = basalt.signal(0)
local input = basalt.signal(0)
local output = basalt.signal(0)

local connected = basalt.signal(false)
local unit = basalt.signal("RF")

-- Rolling samples. These are internal application data;
-- the four signals above remain the primary live state.
local inputHistory = {}
local outputHistory = {}

------------------------------------------------------------
-- Computed values
------------------------------------------------------------

local tier = basalt.computed(function()
    return TIER_CAPACITY[maxEnergy:get()] or 0
end)

local charge = basalt.computed(function()
    local max = maxEnergy:get()

    if max <= 0 then
        return nil
    end

    return math.max(
        0,
        math.min(100, energy:get() / max * 100)
    )
end)

local net = basalt.computed(function()
    return input:get() - output:get()
end)

local averageInput = basalt.computed(function()
    if #inputHistory == 0 then
        return 0
    end

    local total = 0

    for _, value in ipairs(inputHistory) do
        total = total + value
    end

    return total / #inputHistory
end)

local averageOutput = basalt.computed(function()
    if #outputHistory == 0 then
        return 0
    end

    local total = 0

    for _, value in ipairs(outputHistory) do
        total = total + value
    end

    return total / #outputHistory
end)

local averageNet = basalt.computed(function()
    return averageInput:get() - averageOutput:get()
end)

------------------------------------------------------------
-- Formatting
------------------------------------------------------------

local function compact(value)
    local abs = math.abs(value)

    if abs < 1000 then
        return string.format("%.0f", value)
    end

    local suffix = {
        "k", "M", "G", "T", "P", "E", "Z"
    }

    local i = 1

    while abs >= 1000 and i < #suffix do
        value = value / 1000
        abs = abs / 1000
        i = i + 1
    end

    if abs >= 100 then
        return string.format("%.0f%s", value, suffix[i])
    elseif abs >= 10 then
        return string.format("%.1f%s", value, suffix[i])
    else
        return string.format("%.2f%s", value, suffix[i])
    end
end

local function withUnit(value)
    return compact(value) .. " " .. unit:get()
end

local function signed(value)
    if value > 0 then
        return "+" .. withUnit(value)
    end

    return withUnit(value)
end

local function energyText()
    local max = maxEnergy:get()

    if max == -1 then
        return "∞"
    end

    return withUnit(energy:get())
end

local function capacityText()
    local max = maxEnergy:get()

    if max == -1 then
        return "∞"
    end

    return withUnit(max)
end

local function chargeText()
    local value = charge:get()

    if not value then
        return "∞ capacity"
    end

    return string.format("%.1f%%", value)
end

------------------------------------------------------------
-- Peripheral handling
------------------------------------------------------------

local pylon
local pylonName

local monitor
local monitorName

local function findPylon()
    for _, typeName in ipairs(PYLON_TYPES) do
        local name, wrapped = peripheral.find(typeName)

        if wrapped then
            return name, wrapped
        end
    end

    return nil, nil
end

local function findMonitor()
    return peripheral.find("monitor")
end

local function refreshPeripherals()
    if not monitorName or not peripheral.isPresent(monitorName) then
        monitorName, monitor = findMonitor()
    end

    if not pylonName or not peripheral.isPresent(pylonName) then
        pylonName, pylon = findPylon()
    end

    connected:set(pylon ~= nil)
end

local function callPylon(method)
    local fn = pylon and pylon[method]

    if type(fn) ~= "function" then
        return false, nil
    end

    return pcall(fn, pylon)
end

------------------------------------------------------------
-- Sampling
------------------------------------------------------------

local function push(history, value)
    history[#history + 1] = value

    if #history > HISTORY_LENGTH then
        table.remove(history, 1)
    end
end

local function sample()
    refreshPeripherals()

    if not pylon then
        connected:set(false)
        return
    end

    local okEnergy, newEnergy = callPylon("getEnergyStored")
    local okMax, newMax = callPylon("getMaxEnergyStored")
    local okInput, newInput = callPylon("getInputPerTick")
    local okOutput, newOutput = callPylon("getOutputPerTick")

    if not (okEnergy and okMax and okInput and okOutput) then
        connected:set(false)
        return
    end

    newEnergy = tonumber(newEnergy) or 0
    newMax = tonumber(newMax) or 0
    newInput = tonumber(newInput) or 0
    newOutput = tonumber(newOutput) or 0

    -- These four signals are the only live values that
    -- need to be written by the sampler.
    energy:set(newEnergy)
    maxEnergy:set(newMax)
    input:set(newInput)
    output:set(newOutput)

    push(inputHistory, newInput)
    push(outputHistory, newOutput)

    connected:set(true)

    -- PixelGraph is streaming state, so it is updated here.
    graph:addPoint("input", newInput)
    graph:addPoint("output", newOutput)

    -- Scale the graph to the current 60-second maximum.
    local maximum = 1

    for _, value in ipairs(inputHistory) do
        maximum = math.max(maximum, value)
    end

    for _, value in ipairs(outputHistory) do
        maximum = math.max(maximum, value)
    end

    graph.maxValue = maximum * 1.1
end

------------------------------------------------------------
-- UI
------------------------------------------------------------

local frame = basalt.createFrame(
    monitor,
    "EnergyCore"
)

frame.background = C.bg

------------------------------------------------------------
-- Header
------------------------------------------------------------

local header = frame:addFrame({
    x = 1,
    y = 1,
    width = basalt.fill(),
    height = 3,
    background = C.panel,
})

header:addLabel({
    x = 2,
    y = 1,
    text = "DRACONIC EVOLUTION ENERGY CORE",
    foreground = C.accent,
})

header:addLabel({
    x = 2,
    y = 2,
    text = basalt.computed(function()
        if connected:get() then
            return "● ONLINE  ·  " .. tostring(pylonName or "")
        end

        return "● DISCONNECTED  ·  SEARCHING..."
    end),
    foreground = basalt.computed(function()
        return connected:get() and C.good or C.danger
    end),
})

------------------------------------------------------------
-- Core panel
------------------------------------------------------------

local corePanel = frame:addFrame({
    x = 2,
    y = 5,
    width = function(self)
        return self.parent.width >= 60
            and math.floor((self.parent.width - 5) / 2)
            or self.parent.width - 4
    end,
    height = 8,
    background = C.panel,
})

corePanel:addLabel({
    x = 2,
    y = 1,
    text = "CORE",
    foreground = C.accent,
})

corePanel:addLabel({
    x = 2,
    y = 2,
    text = basalt.computed(function()
        return "Tier: " .. tier:get()
    end),
})

corePanel:addLabel({
    x = 2,
    y = 3,
    text = basalt.computed(function()
        return "Stored: " .. energyText()
    end),
})

corePanel:addLabel({
    x = 2,
    y = 4,
    text = basalt.computed(function()
        return "Capacity: " .. capacityText()
    end),
})

corePanel:addLabel({
    x = 2,
    y = 5,
    text = basalt.computed(function()
        return "Charge: " .. chargeText()
    end),
    foreground = basalt.computed(function()
        local value = charge:get()

        if not value then
            return C.accent
        elseif value >= 75 then
            return C.good
        elseif value >= 25 then
            return C.warning
        end

        return C.danger
    end),
})

corePanel:addProgressBar({
    x = 2,
    y = 6,
    width = "{parent.width - 3}",
    progress = charge:map(function(value)
        return value or 100
    end),
    showPercentage = false,
    background = C.bg,
    barColor = basalt.computed(function()
        local value = charge:get()

        if not value then
            return C.accent
        elseif value >= 75 then
            return C.good
        elseif value >= 25 then
            return C.warning
        end

        return C.danger
    end),
})

------------------------------------------------------------
-- Power panel
------------------------------------------------------------

local ratePanel = frame:addFrame({
    x = function(self)
        return self.parent.width >= 60
            and math.floor(self.parent.width / 2) + 1
            or 2
    end,

    y = function(self)
        return self.parent.width >= 60 and 5 or 14
    end,

    width = function(self)
        return self.parent.width >= 60
            and self.parent.width - math.floor(self.parent.width / 2) - 2
            or self.parent.width - 4
    end,

    height = 8,
    background = C.panel,
})

ratePanel:addLabel({
    x = 2,
    y = 1,
    text = "POWER FLOW",
    foreground = C.accent,
})

ratePanel:addLabel({
    x = 2,
    y = 2,
    text = basalt.computed(function()
        return "Input: " .. withUnit(input:get()) .. "/t"
    end),
    foreground = C.input,
})

ratePanel:addLabel({
    x = 2,
    y = 3,
    text = basalt.computed(function()
        return "Output: " .. withUnit(output:get()) .. "/t"
    end),
    foreground = C.output,
})

ratePanel:addLabel({
    x = 2,
    y = 4,
    text = basalt.computed(function()
        return "Net: " .. signed(net:get()) .. "/t"
    end),
    foreground = C.net,
})

ratePanel:addLabel({
    x = 2,
    y = 5,
    text = basalt.computed(function()
        return "60s Avg In: " .. withUnit(averageInput:get()) .. "/t"
    end),
    foreground = C.input,
})

ratePanel:addLabel({
    x = 2,
    y = 6,
    text = basalt.computed(function()
        return "60s Avg Out: " .. withUnit(averageOutput:get()) .. "/t"
    end),
    foreground = C.output,
})

------------------------------------------------------------
-- Unit selector
------------------------------------------------------------

local unitButton = frame:addButton({
    x = function(self)
        return self.parent.width - 15
    end,

    y = 1,
    width = 13,
    height = 2,

    text = unit:map(function(value)
        return value .. "  ↻"
    end),

    background = C.panel,
    foreground = C.accent,
})

unitButton:onClick(function()
    unit:update(function(current)
        local index = 1

        for i, value in ipairs(UNITS) do
            if value == current then
                index = i
                break
            end
        end

        return UNITS[index % #UNITS + 1]
    end)
end)

------------------------------------------------------------
-- Graph
------------------------------------------------------------

local graphPanel = frame:addFrame({
    x = 2,

    y = function(self)
        return self.parent.width >= 60 and 14 or 23
    end,

    width = "{parent.width - 4}",

    height = function(self)
        local top = self.parent.width >= 60 and 14 or 23

        return math.max(
            8,
            self.parent.height - top - 5
        )
    end,

    background = C.panel,
})

graphPanel:addLabel({
    x = 2,
    y = 1,
    text = "RATE HISTORY · 60 SECONDS",
    foreground = C.accent,
})

graphPanel:addLabel({
    x = "{parent.width - 28}",
    y = 1,
    text = "● INPUT   ● OUTPUT",
    foreground = C.muted,
})

graph = graphPanel:addPixelGraph({
    x = 2,
    y = 3,
    width = "{parent.width - 3}",
    height = function(self)
        return math.max(5, self.parent.height - 4)
    end,
    minValue = 0,
    maxValue = 100,
})

graph:addSeries("input", {
    color = C.input,
    pointCount = HISTORY_LENGTH,
    visible = true,
})

graph:addSeries("output", {
    color = C.output,
    pointCount = HISTORY_LENGTH,
    visible = true,
})

------------------------------------------------------------
-- Footer
------------------------------------------------------------

local footer = frame:addFrame({
    x = 2,
    y = "{parent.height - 3}",
    width = "{parent.width - 4}",
    height = 3,
    background = C.panel,
})

footer:addLabel({
    x = 2,
    y = 1,
    text = "60S AVG",
    foreground = C.accent,
})

footer:addLabel({
    x = 10,
    y = 1,
    text = basalt.computed(function()
        return "IN " .. withUnit(averageInput:get()) .. "/t"
    end),
    foreground = C.input,
})

footer:addLabel({
    x = 27,
    y = 1,
    text = basalt.computed(function()
        return "OUT " .. withUnit(averageOutput:get()) .. "/t"
    end),
    foreground = C.output,
})

footer:addLabel({
    x = 45,
    y = 1,
    text = basalt.computed(function()
        return "NET " .. signed(averageNet:get()) .. "/t"
    end),
    foreground = C.net,
})

footer:addLabel({
    x = "{parent.width - 9}",
    y = 1,
    text = basalt.computed(function()
        return #inputHistory .. "/60"
    end),
    foreground = C.muted,
})

------------------------------------------------------------
-- Sampler
------------------------------------------------------------

basalt.schedule(function()
    while true do
        local ok = pcall(sample)

        if not ok then
            connected:set(false)
        end

        sleep(SAMPLE_INTERVAL)
    end
end)

------------------------------------------------------------
-- Start Basalt
------------------------------------------------------------

basalt.run()