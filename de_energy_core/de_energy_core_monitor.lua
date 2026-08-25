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

local SAMPLE_INTERVAL_SECONDS = 1
local HISTORY_LENGTH_SECONDS = 60
local HISTORY_LENGTH = HISTORY_LENGTH_SECONDS / SAMPLE_INTERVAL_SECONDS

--local MONITOR_TEXT_SCALES = { 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0 }
local MONITOR_TEXT_SCALES = { 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0 }
-- multiply all scales by 2 so no decimals in the dropdown
for i, v in ipairs(MONITOR_TEXT_SCALES) do
    MONITOR_TEXT_SCALES[i] = v * 2
end

local ENERGY_CORE_TYPES = { "draconic_rf_storage", "draconicRfStorage", "energy_pylon", "energyPylon" }

local ENERGY_UNITS = { "RF", "FE", "OP", "AE", "EU" }
local ENERGY_UNIT_FACTORS = {
    RF = 1,
    FE = 1,
    OP = 1,
    AE = 2,
    EU = 16,
}
local RATE_UNITS = { "/t", "/s", "/m", "/h", "/d" }
local RATE_UNIT_FACTORS = {
    ["/t"] = 1,
    ["/s"] = 20,
    ["/m"] = 20 * 60,
    ["/h"] = 20 * 60 * 60,
    ["/d"] = 20 * 60 * 60 * 24,
}

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

-- TODO Persist user preferences
local monitorTextScaleIndex = basalt.signal(2)
--local monitorTextScale = basalt.signal(1)
local monitorTextScale = basalt.computed(function()
    return MONITOR_TEXT_SCALES[monitorTextScaleIndex:get()]
end)

local energyUnitIndex = basalt.signal(1)
--local energyUnit = basalt.signal("RF")
local energyUnit = basalt.computed(function()
    return ENERGY_UNITS[energyUnitIndex:get()]
end)
--local energyUnitFactor = basalt.signal(1)
local energyUnitFactor = basalt.computed(function()
    return ENERGY_UNIT_FACTORS[energyUnit:get()]
end)
local rateUnitIndex = basalt.signal(1)
--local rateUnit = basalt.signal("/t")
local rateUnit = basalt.computed(function()
    return RATE_UNITS[rateUnitIndex:get()]
end)
--local rateUnitFactor = basalt.signal(1)
local rateUnitFactor = basalt.computed(function()
    return RATE_UNIT_FACTORS[rateUnit:get()]
end)

-- Rolling samples. These are internal application data;
-- the four signals above remain the primary live state.
local inputHistory = {}
local outputHistory = {}

local lastSample = 0
local sampleIntervalDelayMs = basalt.signal(0)

------------------------------------------------------------
-- Computed values
------------------------------------------------------------

local tier = basalt.computed(function()
    local max = maxEnergy:get()
    if max > 2140000000000 then
        return 8
    end
    return TIER_CAPACITY[max] or 0
end)

local isInfinite = basalt.computed(function()
    return tier:get() == 8
end)

local isFinite = basalt.computed(function()
    return tier:get() < 8
end)

local chargePercentage = basalt.computed(function()
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

local function si(n, unit, forceSign, forceSpace)
    if not n then
        return "N/A"
    end

    n = math.floor(n)
    local prefixes = {"", "k", "M", "G", "T", "P", "E", "Z", "Y", "R", "Q"}
    local i = 1

    while math.abs(n) >= 1000 and i < #prefixes do
        n = n / 1000
        i = i + 1
    end

    return string.format(forceSign and "%+7.2f %s%s" or (forceSpace and "%7.2f %s%s" or "%6.2f %s%s"), n, prefixes[i], unit or "")
end

local function withEnergyUnit(value, forceSign, forceSpace)
    return si(value / energyUnitFactor:get(), energyUnit:get(), forceSign, forceSpace)
end

local function withEnergyRateUnit(value, forceSign, forceSpace)
    return si(value * rateUnitFactor:get() / energyUnitFactor:get(), energyUnit:get() .. rateUnit:get(), forceSign, forceSpace)
end

-- Energy values

local function energyText()
    return withEnergyUnit(energy:get())
end

local function capacityText()
    local value = maxEnergy:get()
    if value and isInfinite:get() then
        return "Infinite"
    end
    return withEnergyUnit(value)
end

local function chargePercentageText()
    local value = chargePercentage:get()
    if not value then
        return "N/A"
    elseif value and isInfinite:get() then
        return "Infinite capacity"
    end
    return string.format("%.1f%%", value)
end

-- Energy rate values

local function inputRateText()
    return withEnergyRateUnit(input:get())
end

local function outputRateText()
    return withEnergyRateUnit(output:get())
end

local function netRateText()
    return withEnergyRateUnit(net:get(), true)
end

-- Average energy rate values

local function averageInputRateText()
    return withEnergyRateUnit(averageInput:get())
end

local function averageOutputRateText()
    return withEnergyRateUnit(averageOutput:get())
end

local function averageNetRateText()
    return withEnergyRateUnit(averageNet:get(), true)
end

------------------------------------------------------------
-- Peripheral handling
------------------------------------------------------------

local energyCore
local energyCoreName

local monitor
local monitorName

local function findEnergyCore()
    for _, typeName in ipairs(ENERGY_CORE_TYPES) do
        local wrapped = peripheral.find(typeName)

        if wrapped then
            return wrapped
        end
    end

    return nil
end

local function findMonitor()
    return peripheral.find("monitor")
end

--monitorTextScale:subscribe(function(value)
--    if monitor then
--        monitor.setTextScale(value)
--    end
--end, true)

local function refreshPeripherals()
    if not monitorName or not peripheral.isPresent(monitorName) then
        monitor = findMonitor()
        if monitor then
            monitor.setTextScale(monitorTextScale:get() / 2)
            monitorName = peripheral.getName(monitor)
            print("Using monitor: " .. monitorName)
        else
            monitorName = nil
        end
    end

    if not energyCoreName or not peripheral.isPresent(energyCoreName) then
        energyCore = findEnergyCore()
        if energyCore then
            energyCoreName = peripheral.getName(energyCore)
            if not monitor then
                print("Using energy core: " .. energyCoreName)
            end
        else
            energyCoreName = nil
        end
    end

    connected:set(energyCore ~= nil)
end

local function callEnergyCore(method)
    local fn = energyCore and energyCore[method]

    if type(fn) ~= "function" then
        return false, nil
    end

    return pcall(fn, energyCore)
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
    lastSample = os.clock()
    refreshPeripherals()

    if not energyCore then
        connected:set(false)
        return
    end

    local okEnergy, newEnergy = callEnergyCore("getEnergyStored")
    local okMax, newMax = callEnergyCore("getMaxEnergyStored")
    local okInput, newInput = callEnergyCore("getInputPerTick")
    local okOutput, newOutput = callEnergyCore("getOutputPerTick")

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

    -- Scale the graph to the current window's maximum and minimum.
    local maximum = 1
    local minimum = 2140000000000

    for _, value in ipairs(inputHistory) do
        maximum = math.max(maximum, value)
        minimum = math.min(minimum, value)
    end

    for _, value in ipairs(outputHistory) do
        maximum = math.max(maximum, value)
        minimum = math.min(minimum, value)
    end

    --graph.maxValue = maximum * 1.1
    graph.maxValue = maximum
    --graph.minValue = minimum / 1.1
    graph.minValue = minimum
end

------------------------------------------------------------
-- UI
------------------------------------------------------------

refreshPeripherals()

local frame = basalt.createFrame(
    monitor,
    monitorName
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
    --width = basalt.fill(),
    text = "DRACONIC EVOLUTION ENERGY CORE",
    foreground = C.accent,
})

header:addLabel({
    x = 2,
    y = 2,
    width = basalt.fill(),
    text = basalt.computed(function()
        if connected:get() then
            return "ONLINE - \"" .. tostring(energyCoreName or "") .. "\""
        end
        return "DISCONNECTED - SEARCHING..."
    end),
    foreground = basalt.computed(function()
        return connected:get() and C.good or C.danger
    end),
})

header:addLabel({
    x = "{parent.width - 19}",
    y = 1,
    width = 19,
    text = basalt.computed(function()
        return os.date("%Y-%m-%d %H:%M:%S")
    end),
    foreground = C.muted,
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
    --width = basalt.fill(),
    --height = 5,
    height = basalt.computed(function()
        return isInfinite:get() and 5 or 5 + 2
    end),
    background = C.panel,
})

corePanel:addLabel({
    x = 2,
    y = 1,
    --width = basalt.fill(),
    text = "CORE",
    foreground = C.accent,
})

corePanel:addLabel({
    x = 2,
    y = 2,
    width = basalt.fill(),
    text = basalt.computed(function()
        return "Tier: " .. tier:get()
    end),
})

corePanel:addLabel({
    x = 2,
    y = 3,
    width = basalt.fill(),
    text = basalt.computed(function()
        return "Stored:   " .. energyText()
    end),
})

corePanel:addLabel({
    x = 2,
    y = 4,
    width = basalt.fill(),
    text = basalt.computed(function()
        return "Capacity: " .. capacityText()
    end),
})

corePanel:addLabel({
    x = 2,
    y = 5,
    width = basalt.fill(),
    visible = isFinite,
    text = basalt.computed(function()
        return "Charge: " .. chargePercentageText()
    end),
    foreground = basalt.computed(function()
        local value = chargePercentage:get()

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
    visible = isFinite,
    progress = chargePercentage:map(function(value)
        return value or 100
    end),
    showPercentage = false,
    background = C.bg,
    barColor = basalt.computed(function()
        local value = chargePercentage:get()

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
        --and self.parent.width - math.floor(self.parent.width / 2) - 2
        --or self.parent.width - 2
        and self.parent.width - math.floor(self.parent.width / 2) - 1
        or self.parent.width - 4
    end,

    --TODO Use flex layout for this?
    height = isInfinite:get() and 5 or 7,
    background = C.panel,
})

local ratePanelRow = 1

ratePanel:addLabel({
    x = 2,
    y = ratePanelRow,
    --width = basalt.fill(),
    text = "POWER FLOW",
    foreground = C.accent,
})

ratePanelRow = ratePanelRow + 1

ratePanel:addLabel({
    x = 2,
    y = ratePanelRow,
    text = "Input:",
    foreground = C.input,
})

ratePanel:addLabel({
    x = 15,
    y = ratePanelRow,
    width = basalt.fill(),
    text = basalt.computed(function()
        return inputRateText()
    end),
    foreground = C.input,
})

ratePanelRow = ratePanelRow + 1

ratePanel:addLabel({
    x = 2,
    y = ratePanelRow,
    text = "Output:",
    foreground = C.output,
})

ratePanel:addLabel({
    x = 15,
    y = ratePanelRow,
    width = basalt.fill(),
    text = basalt.computed(function()
        return outputRateText()
    end),
    foreground = C.output,
})

ratePanelRow = ratePanelRow + 1

--ratePanel:addLabel({
--    x = 2,
--    y = ratePanelRow,
--    text = "" .. HISTORY_LENGTH_SECONDS .. "s Avg In:",
--    foreground = C.input,
--})
--
--ratePanel:addLabel({
--    x = 15,
--    y = ratePanelRow,
--    width = basalt.fill(),
--    text = basalt.computed(function()
--        return averageInputRateText()
--    end),
--    foreground = C.input,
--})
--
--ratePanelVerticalIndex = ratePanelVerticalIndex + 1
--
--ratePanel:addLabel({
--    x = 2,
--    y = ratePanelRow,
--    text = "" .. HISTORY_LENGTH_SECONDS .. "s Avg Out:",
--    foreground = C.output,
--})
--
--ratePanel:addLabel({
--    x = 15,
--    y = ratePanelRow,
--    width = basalt.fill(),
--    text = basalt.computed(function()
--        return averageOutputRateText()
--    end),
--    foreground = C.output,
--})
--
--ratePanelVerticalIndex = ratePanelVerticalIndex + 1

ratePanel:addLabel({
    x = 2,
    y = ratePanelRow,
    text = "Net:",
    foreground = C.net,
})

ratePanel:addLabel({
    x = 15,
    y = ratePanelRow,
    width = basalt.fill(),
    text = basalt.computed(function()
        return netRateText()
    end),
    --foreground = C.net,
    foreground = basalt.computed(function()
        return net:get() >= 0 and C.input or C.output
    end),
})

ratePanelRow = ratePanelRow + 1

--ratePanel:addLabel({
--    x = 2,
--    y = ratePanelRow,
--    text = "" .. HISTORY_LENGTH_SECONDS .. "s Avg Net:",
--    foreground = C.net,
--})
--
--ratePanel:addLabel({
--    x = 15,
--    y = ratePanelRow,
--    width = basalt.fill(),
--    text = basalt.computed(function()
--        return averageNetRateText()
--    end),
--    --foreground = C.net,
--    foreground = basalt.computed(function()
--        return averageNet:get() >= 0 and C.input or C.output
--    end),
--})
--
--ratePanelVerticalIndex = ratePanelVerticalIndex + 1

------------------------------------------------------------
-- Unit selectors
------------------------------------------------------------

local monitorTextScaleDropdown = frame:addDropdown({
    --local monitorTextScaleDropdown = header:addDropdown({
    --x = function(self)
    --    return self.parent.width - 15
    --end,
    x = function(self)
        return self.parent.width - 4 - 5 - 5 + 1
    end,
    --y = 1,
    y = 2,
    --z = 2,
    --width = 13,
    width = 3,
    text = "1.0",
    dropHeight = #MONITOR_TEXT_SCALES,
    items = MONITOR_TEXT_SCALES,
})

monitorTextScaleDropdown:bind("selected", monitorTextScaleIndex)
monitorTextScaleDropdown:onSelect(function(self, index, item)
    if monitor then
        monitor.setTextScale(item.value / 2)
    end
end)

------------------------------------------------------------
-- Unit selectors
------------------------------------------------------------

local energyUnitDropdown = frame:addDropdown({
--local energyUnitDropdown = header:addDropdown({
    --x = function(self)
    --    return self.parent.width - 15
    --end,
    x = function(self)
        return self.parent.width - 5 - 5 + 1
    end,
    --y = 1,
    y = 2,
    --z = 2,
    --width = 13,
    width = 4,
    text = "RF",
    dropHeight = #ENERGY_UNITS,
    items = ENERGY_UNITS,
})

local rateUnitDropdown = frame:addDropdown({
--local rateUnitDropdown = header:addDropdown({
    --x = function(self)
    --    return self.parent.width - 15
    --end,
    x = function(self)
        return self.parent.width - 5 + 1
    end,
    --y = 1,
    y = 2,
    --z = 2,
    --width = 13,
    width = 4,
    text = "/t",
    dropHeight = #RATE_UNITS,
    items = RATE_UNITS,
})

energyUnitDropdown:bind("selected", energyUnitIndex)
rateUnitDropdown:bind("selected", rateUnitIndex)

--local energyUnitButton = frame:addButton({
--    x = function(self)
--        return self.parent.width - 15
--    end,
--
--    y = 1,
--    width = 13,
--    height = 1,
--
--    text = energyUnit:map(function(value)
--        return value .. "  >"
--    end),
--
--    background = C.panel,
--    foreground = C.accent,
--})
--
--energyUnitButton:onClick(function()
--    energyUnit:update(function(current)
--        local index = 1
--
--        for i, value in ipairs(ENERGY_UNITS) do
--            if value == current then
--                index = i
--                break
--            end
--        end
--
--        return ENERGY_UNITS[index % #ENERGY_UNITS + 1]
--    end)
--    energyUnitFactor:set(ENERGY_UNIT_FACTORS[energyUnit:get()])
--end)
--
--local rateUnitButton = frame:addButton({
--    x = function(self)
--        return self.parent.width - 15
--    end,
--
--    y = 2,
--    width = 13,
--    height = 1,
--
--    text = rateUnit:map(function(value)
--        return value .. "  >"
--    end),
--
--    background = C.panel,
--    foreground = C.accent,
--})
--
--rateUnitButton:onClick(function()
--    rateUnit:update(function(current)
--        local index = 1
--
--        for i, value in ipairs(RATE_UNITS) do
--            if value == current then
--                index = i
--                break
--            end
--        end
--
--        return RATE_UNITS[index % #RATE_UNITS + 1]
--    end)
--    rateUnitFactor:set(RATE_UNIT_FACTORS[rateUnit:get()])
--end)

------------------------------------------------------------
-- Graph
------------------------------------------------------------

local graphPanel = frame:addFrame({
    x = 2,

    y = function(self)
        --TODO Use flex layout for this?
        if isFinite:get() then
            return self.parent.width >= 60 and 13 or 22
        end
        return self.parent.width >= 60 and 11 or 20
    end,

    --width = "{parent.width - 4}",
    width = "{parent.width - 2}",

    height = function(self)
        --TODO Use flex layout for this?
        local top = self.parent.width >= 60 and 11 or 20
        if isFinite:get() then
            top = self.parent.width >= 60 and 13 or 22
        end

        --TODO Use flex layout for this?
        return math.max(
            isInfinite:get() and 12 or 10,
            self.parent.height - top - 5
        )
    end,

    background = C.panel,
})

graphPanel:addLabel({
    x = 2,
    y = 1,
    --width = basalt.fill(),
    text = "RATE HISTORY - " .. HISTORY_LENGTH_SECONDS .. " SECONDS",
    foreground = C.accent,
})

graphPanel:addLabel({
    x = "{parent.width - 28}",
    y = 1,
    --width = basalt.fill(),
    text = "- INPUT",
    foreground = C.input,
})

graphPanel:addLabel({
    x = "{parent.width - 28 + 11}",
    y = 1,
    --width = basalt.fill(),
    text = "- OUTPUT",
    foreground = C.output,
})

graph = graphPanel:addPixelGraph({
    x = 2,
    y = 3,
    width = "{parent.width - 3}",
    height = function(self)
        --return math.max(12 - 3, self.parent.height - 4)
        --TODO Use flex layout for this?
        return math.max((isInfinite:get() and 12 or 10) - 3, self.parent.height - 3)
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
    y = "{parent.height - 2}",
    --width = "{parent.width - 4}",
    width = "{parent.width - 2}",
    height = 2,
    background = C.panel,
})

footer:addLabel({
    x = 2,
    y = 1,
    --width = basalt.fill(),
    text = "" .. HISTORY_LENGTH_SECONDS .. "S AVG",
    foreground = C.accent,
})

footer:addLabel({
    x = 10,
    y = 1,
    width = basalt.fill(),
    text = basalt.computed(function()
        return "IN " .. averageInputRateText()
    end),
    foreground = C.input,
})

footer:addLabel({
    x = 27,
    y = 1,
    width = basalt.fill(),
    text = basalt.computed(function()
        return "OUT " .. averageOutputRateText()
    end),
    foreground = C.output,
})

footer:addLabel({
    x = 45,
    y = 1,
    width = basalt.fill(),
    text = basalt.computed(function()
        return "NET " .. averageNetRateText()
    end),
    foreground = C.net,
})

footer:addLabel({
    x = "{parent.width - 9}",
    y = 1,
    width = basalt.fill(),
    text = basalt.computed(function()
        return #inputHistory .. "/" .. HISTORY_LENGTH
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

        local now = os.clock()
        local sampleIntervalDelaySeconds = now - lastSample
        local delay = SAMPLE_INTERVAL_SECONDS - sampleIntervalDelaySeconds
        sampleIntervalDelayMs.set(math.floor(sampleIntervalDelaySeconds * 1000))
        sleep(math.max(0, delay))
    end
end)

------------------------------------------------------------
-- Start Basalt
------------------------------------------------------------

basalt.run()

print("Energy Core Monitor stopped.")
