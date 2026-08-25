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
local HISTORY_LENGTH = math.ceil(HISTORY_LENGTH_SECONDS / SAMPLE_INTERVAL_SECONDS)

local DEFAULT_PERCENTAGE_NUMBER_LENGTH = #"100.00 %"
local DEFAULT_ENERGY_NUMBER_LENGTH = #"+999.99 kRF"
local DEFAULT_ENERGY_RATE_NUMBER_LENGTH = #"+999.99 kRF/t"

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
    [45500000] = 1,
    [273000000] = 2,
    [1640000000] = 3,
    [9880000000] = 4,
    [59300000000] = 5,
    [356000000000] = 6,
    [2140000000000] = 7,
    [-1] = 8,
}

------------------------------------------------------------
-- Colors
------------------------------------------------------------

local C = {
    bg = colors.black,
    panel = colors.gray,
    text = colors.white,
    muted = colors.lightGray,
    accent = colors.cyan,
    input = colors.lime,
    output = colors.red,
    net = colors.yellow,
    good = colors.lime,
    warning = colors.yellow,
    danger = colors.red,
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

local showInputGraph = basalt.signal(true)
local showOutputGraph = basalt.signal(true)

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
    return string.format("%6.2f %%", value)
end

-- Energy rate values

local function inputRateText()
    return withEnergyRateUnit(input:get(), false, true)
end

local function outputRateText()
    return withEnergyRateUnit(output:get(), false, true)
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

    if showInputGraph:get() then
        for _, value in ipairs(inputHistory) do
            maximum = math.max(maximum, value)
            minimum = math.min(minimum, value)
        end
    end

    if showOutputGraph:get() then
        for _, value in ipairs(outputHistory) do
            maximum = math.max(maximum, value)
            minimum = math.min(minimum, value)
        end
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
-- Main Layout (Outer Column)
------------------------------------------------------------

local mainPage = frame:addColumn({
    x = 1,
    y = 1,
    width = basalt.fill(),
    height = basalt.fill(),
    gap = 1,
    --padding = 1,
})

------------------------------------------------------------
-- Header
------------------------------------------------------------

local header = mainPage:addFrame({
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
    x = "{parent.width - 19 - 8}",
    y = 1,
    width = 7,
    text = basalt.computed(function()
        return string.format("%4.0f ms", sampleIntervalDelayMs:get())
    end),
    foreground = basalt.computed(function()
        local value = sampleIntervalDelayMs:get()
        if not value then
            return C.muted
        end

        local valuePercentage = value / (SAMPLE_INTERVAL_SECONDS * 1000)
        if valuePercentage < 0.5 then
            return C.good
        elseif valuePercentage < 1.0 then
            return C.warning
        end

        return C.danger
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
-- Core and Rate Panels Row
------------------------------------------------------------

local contentPanel = mainPage:addColumn({
    width = basalt.fill(),
    height = basalt.fill(),
    gap = 1,
})

local topPanelsRow = contentPanel:addRow({
    width = basalt.fill(),
    height = basalt.auto(),
    gap = 1,
})

local corePanel = topPanelsRow:addColumn({
    width = basalt.fill(1),
    minWidth = 30,
    minHeight = 4,
    shrink = 1,
    background = C.panel,
})

-- Title

corePanel:addLabel({
    text = "CORE",
    foreground = C.accent,
})

local corePanelMaxPropertyWidth = #"Capacity:"

-- Tier

local corePanelTier = corePanel:addRow({
    width = corePanelMaxPropertyWidth + 1 + 1,
    height = 1,
    gap = 1,
})

corePanelTier:addLabel({
    width = corePanelMaxPropertyWidth,
    text = "Tier:",
})

corePanelTier:addLabel({
    width = 1,
    text = basalt.computed(function()
        return tier:get()
    end),
})

-- Capacity

local corePanelCapacity = corePanel:addRow({
    width = corePanelMaxPropertyWidth + 1 + DEFAULT_ENERGY_NUMBER_LENGTH,
    height = 1,
    gap = 1,
})

corePanelCapacity:addLabel({
    width = corePanelMaxPropertyWidth,
    text = "Capacity:",
})

corePanelCapacity:addLabel({
    width = DEFAULT_ENERGY_NUMBER_LENGTH,
    text = basalt.computed(function()
        return capacityText()
    end),
})

-- Stored

local corePanelStored = corePanel:addRow({
    width = corePanelMaxPropertyWidth + 1 + DEFAULT_ENERGY_NUMBER_LENGTH,
    height = 1,
    gap = 1,
})

corePanelStored:addLabel({
    width = corePanelMaxPropertyWidth,
    text = "Stored:",
})

corePanelStored:addLabel({
    width = DEFAULT_ENERGY_NUMBER_LENGTH,
    text = basalt.computed(function()
        return energyText()
    end),
})

-- Charge percentage

corePanelChargePercentage = corePanel:addRow({
    width = corePanelMaxPropertyWidth + 1 + DEFAULT_PERCENTAGE_NUMBER_LENGTH,
    height = 1,
    gap = 1,
    visible = isFinite,
})

corePanelChargePercentage:addLabel({
    width = corePanelMaxPropertyWidth,
    text = "Charge:",
})

corePanelChargePercentage:addLabel({
    width = DEFAULT_PERCENTAGE_NUMBER_LENGTH,
    text = basalt.computed(function()
        return chargePercentageText()
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

-- Charge progress bar

corePanel:addProgressBar({
    width = basalt.fill(),
    --width = "{parent.width - 2}",
    height = 1,
    visible = isFinite,
    progress = chargePercentage:map(function(value)
        return value or 100
    end),
    showPercentage = false,
    background = C.muted,
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

local ratePanel = topPanelsRow:addColumn({
    width = basalt.fill(1),
    minWidth = 30,
    height = basalt.fill(),
    background = C.panel,
})

-- Title

ratePanel:addLabel({
    text = "POWER FLOW",
    foreground = C.accent,
})

local ratePanelMaxPropertyWidth = #"Output:"

-- Input rate

local ratePanelInput = ratePanel:addRow({
    width = ratePanelMaxPropertyWidth + 1 + DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    height = 1,
    gap = 1,
})

ratePanelInput:addLabel({
    width = ratePanelMaxPropertyWidth,
    text = "Input:",
    foreground = C.input,
})

ratePanelInput:addLabel({
    width = DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    text = basalt.computed(function()
        return inputRateText()
    end),
    foreground = C.input,
})

-- Output rate

local ratePanelOutput = ratePanel:addRow({
    width = ratePanelMaxPropertyWidth + 1 + DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    height = 1,
    gap = 1,
})

ratePanelOutput:addLabel({
    width = ratePanelMaxPropertyWidth,
    text = "Output:",
    foreground = C.output,
})

ratePanelOutput:addLabel({
    width = DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    text = basalt.computed(function()
        return outputRateText()
    end),
    foreground = C.output,
})

-- Net rate

local ratePanelNet = ratePanel:addRow({
    width = ratePanelMaxPropertyWidth + 1 + DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    height = 1,
    gap = 1,
})

ratePanelNet:addLabel({
    width = ratePanelMaxPropertyWidth,
    text = "Net:",
    foreground = C.net,
})

ratePanelNet:addLabel({
    width = DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    text = basalt.computed(function()
        return netRateText()
    end),
    foreground = basalt.computed(function()
        return net:get() >= 0 and C.input or C.output
    end),
})

------------------------------------------------------------
-- Monitor text scale selector
------------------------------------------------------------

local monitorTextScaleDropdown = mainPage:addDropdown({
    position = "absolute",
    x = "{parent.width - 1 - 4 - 1 - 4 - 1 - 3}",
    y = "{parent.y + 1}",
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

local energyUnitDropdown = mainPage:addDropdown({
    position = "absolute",
    x = "{parent.width - 1 - 4 - 1 - 4}",
    y = "{parent.y + 1}",
    width = 4,
    text = "RF",
    dropHeight = #ENERGY_UNITS,
    items = ENERGY_UNITS,
})

local rateUnitDropdown = mainPage:addDropdown({
    position = "absolute",
    x = "{parent.width - 1 - 4}",
    y = "{parent.y + 1}",
    width = 4,
    text = "/t",
    dropHeight = #RATE_UNITS,
    items = RATE_UNITS,
})

energyUnitDropdown:bind("selected", energyUnitIndex)
rateUnitDropdown:bind("selected", rateUnitIndex)

------------------------------------------------------------
-- Graph Panel (with integrated footer content)
------------------------------------------------------------

local graphPanelContainer = contentPanel:addColumn({
    width = basalt.fill(),
    height = basalt.fill(),
    gap = 1,
    background = C.panel,
})

local graphHeader = graphPanelContainer:addRow({
    width = basalt.fill(),
    --height = basalt.auto(),
    --minHeight = 1,
    height = 1,
    gap = 1,
    --align = "start",
    --FIXME TODO This does not work
    justify = "spaceBetween",
})

graphHeader:addLabel({
    width = basalt.auto(),
    text = " RATE HISTORY - " .. HISTORY_LENGTH_SECONDS .. " SECONDS",
    foreground = C.accent,
})

local graphButtons = graphHeader:addRow({
    gap = 1,
    --alignSelf = "end",
})

local toggleVisibilityInputGraph = graphButtons:addButton({
    width = basalt.auto(),
    height = 1,
    text = "- INPUT",
    foreground = basalt.computed(function()
        return showInputGraph:get() and C.input or C.panel
    end),
    background = C.muted,
})

local toggleVisibilityOutputGraph = graphButtons:addButton({
    width = basalt.auto(),
    height = 1,
    text = "- OUTPUT",
    foreground = basalt.computed(function()
        return showOutputGraph:get() and C.output or C.panel
    end),
    background = C.muted,
})

graph = graphPanelContainer:addPixelGraph({
    width = basalt.fill(),
    height = basalt.fill(),
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

toggleVisibilityInputGraph:onClick(function()
    showInputGraph:set(not showInputGraph:get())
    graph:setSeriesVisible("input", showInputGraph:get())
end)

toggleVisibilityOutputGraph:onClick(function()
    showOutputGraph:set(not showOutputGraph:get())
    graph:setSeriesVisible("output", showOutputGraph:get())
end)

------------------------------------------------------------
-- Graph Footer (with averages)
------------------------------------------------------------

local graphFooter = graphPanelContainer:addRow({
    width = basalt.fill(),
    height = 1,
    gap = 1,
    --padding = 1,
    justify = "spaceBetween",
})

graphFooter:addLabel({
    width = basalt.auto(),
    text = " " .. HISTORY_LENGTH_SECONDS .. "S AVG",
    foreground = C.accent,
})

graphFooter:addLabel({
    width = 2 + 1 + DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    text = basalt.computed(function()
        return "IN " .. averageInputRateText()
    end),
    foreground = C.input,
})

graphFooter:addLabel({
    width = 3 + 1 + DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    text = basalt.computed(function()
        return "OUT " .. averageOutputRateText()
    end),
    foreground = C.output,
})

local graphFooterNet = graphFooter:addRow({
    width = 3 + 1 + DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    height = 1,
    gap = 1,
})

graphFooterNet:addLabel({
    width = 3,
    text = "NET",
    foreground = C.net,
})

graphFooterNet:addLabel({
    width = DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    text = basalt.computed(function()
        return averageNetRateText()
    end),
    foreground = basalt.computed(function()
        return averageNet:get() >= 0 and C.input or C.output
    end),
})

graphFooter:addLabel({
    width = basalt.auto(),
    text = basalt.computed(function()
        return #inputHistory .. "/" .. HISTORY_LENGTH
    end),
    foreground = C.muted,
})

------------------------------------------------------------
-- Bottom Footer (always at bottom)
------------------------------------------------------------

local footer = mainPage:addRow({
    width = basalt.fill(),
    --height = basalt.auto(),
    height = 1,
    background = C.panel,
})

footer:addLabel({
    x = 2,
    y = 1,
    text = "Ready",
    foreground = C.good,
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
        sampleIntervalDelayMs:set(math.floor(sampleIntervalDelaySeconds * 1000))
        sleep(math.max(0, delay))
    end
end)

------------------------------------------------------------
-- Start Basalt
------------------------------------------------------------

basalt.run()

print("Energy Core Monitor stopped.")
