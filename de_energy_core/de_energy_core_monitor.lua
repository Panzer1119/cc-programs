-- Draconic Evolution Energy Core Monitor
-- CC:Tweaked + Basalt 2.5
--
-- Entry point. Requires (in the same directory):
--   basalt.lua, constants.lua, utils.lua, settings.lua, history.lua

local basalt = require("basalt")
basalt.use("charts")

local const = require("constants")
local utils = require("utils")
local settings = require("settings")
local history = require("history")

-- Unpack constants used heavily in the UI to avoid repeated const.XYZ lookups.
local C = const.C
local W_PCT = const.W_PCT
local W_ENERGY = const.W_ENERGY
local W_RATE = const.W_RATE
local W_DATETIME = const.W_DATETIME

------------------------------------------------------------
-- Settings
------------------------------------------------------------

local savedSettings = settings.load()

------------------------------------------------------------
-- Reactive State
------------------------------------------------------------

-- Live sensor readings (written by the sampler coroutine).
local energy = basalt.signal(0)
local maxEnergy = basalt.signal(0)
local input = basalt.signal(0)
local output = basalt.signal(0)
local connected = basalt.signal(false)

-- User-controlled settings.
local monitorTextScaleIndex = basalt.signal(savedSettings.monitorTextScaleIndex)
local energyUnitIndex = basalt.signal(savedSettings.energyUnitIndex)
local rateUnitIndex = basalt.signal(savedSettings.rateUnitIndex)
local sampleIntervalIndex = basalt.signal(savedSettings.sampleIntervalIndex)
local historyLengthIndex = basalt.signal(savedSettings.historyLengthIndex)
local showInputGraph = basalt.signal(savedSettings.showInputGraph)
local showOutputGraph = basalt.signal(savedSettings.showOutputGraph)

-- Derived from settings signals.
local monitorTextScale = basalt.computed(function() return const.MONITOR_TEXT_SCALES[monitorTextScaleIndex:get()]
end)
local energyUnit = basalt.computed(function() return const.ENERGY_UNITS[energyUnitIndex:get()]
end)
local energyUnitFactor = basalt.computed(function() return const.ENERGY_UNIT_FACTORS[energyUnit:get()]
end)
local rateUnit = basalt.computed(function() return const.RATE_UNITS[rateUnitIndex:get()]
end)
local rateUnitFactor = basalt.computed(function() return const.RATE_UNIT_FACTORS[rateUnit:get()]
end)

local sampleIntervalSeconds = basalt.computed(function() return const.SAMPLE_INTERVAL_OPTIONS[sampleIntervalIndex:get()]
end)
local historyLengthSeconds = basalt.computed(function() return const.HISTORY_LENGTH_OPTIONS[historyLengthIndex:get()]
end)
local historyLength = basalt.computed(function()
    return math.ceil(historyLengthSeconds:get() / sampleIntervalSeconds:get())
end)

-- Derived from sensor readings.
local tier = basalt.computed(function()
    local max = maxEnergy:get()
    if max > 2140000000000 then
        return 8
    end
    return const.TIER_CAPACITY[max] or 0
end)

local isInfinite = basalt.computed(function() return tier:get() == 8
end)
local isFinite = basalt.computed(function() return tier:get() < 8
end)

local chargePercentage = basalt.computed(function()
    local max = maxEnergy:get()
    if max <= 0 then
        return nil
    end
    return math.max(0, math.min(100, energy:get() / max * 100))
end)

local net = basalt.computed(function() return input:get() - output:get()
end)

-- Sampler timing feedback.
local sampleIntervalDelayMs = basalt.signal(0)

------------------------------------------------------------
-- Settings Persistence
------------------------------------------------------------

-- Call whenever a setting signal changes to write all settings to disk.
local function persistSettings()
    settings.save({
        monitorTextScaleIndex = monitorTextScaleIndex:get(),
        energyUnitIndex = energyUnitIndex:get(),
        rateUnitIndex = rateUnitIndex:get(),
        sampleIntervalIndex = sampleIntervalIndex:get(),
        historyLengthIndex = historyLengthIndex:get(),
        showInputGraph = showInputGraph:get(),
        showOutputGraph = showOutputGraph:get(),
    })
end

------------------------------------------------------------
-- History Initialisation
------------------------------------------------------------

-- Inject the window-size signals so history.lua can enforce limits
-- without knowing about Basalt.
history.init(historyLength, historyLengthSeconds)
history.load()
history.save() -- flush sanitised state back to disk on startup

------------------------------------------------------------
-- History Statistics (computed over the live arrays)
------------------------------------------------------------

local averageInput = basalt.computed(function() return history.avg(history.input)
end)
local averageOutput = basalt.computed(function() return history.avg(history.output)
end)
local maximumInput = basalt.computed(function() return history.max(history.input)
end)
local maximumOutput = basalt.computed(function() return history.max(history.output)
end)
local minimumInput = basalt.computed(function() return history.min(history.input)
end)
local minimumOutput = basalt.computed(function() return history.min(history.output)
end)

-- Net (input − output) aggregates iterate paired arrays.
local averageNet = basalt.computed(function()
    if #history.input == 0 then
        return 0
    end
    local total = 0
    for i = 1, #history.input do
        total = total + history.input[i].value - history.output[i].value
    end
    return total / #history.input
end)

local maximumNet = basalt.computed(function()
    if #history.input == 0 then
        return 0
    end
    local m = 0
    for i = 1, #history.input do
        m = math.max(m, history.input[i].value - history.output[i].value)
    end
    return m
end)

local minimumNet = basalt.computed(function()
    if #history.input == 0 then
        return 0
    end
    local m = math.huge
    for i = 1, #history.input do
        m = math.min(m, history.input[i].value - history.output[i].value)
    end
    return m
end)

------------------------------------------------------------
-- Formatting
------------------------------------------------------------

local function withEnergyUnit(value, forceSign, forceSpace)
    return utils.si(value / energyUnitFactor:get(), energyUnit:get(), forceSign, forceSpace)
end

local function withRateUnit(value, forceSign, forceSpace)
    return utils.si(
        value * rateUnitFactor:get() / energyUnitFactor:get(),
        energyUnit:get() .. rateUnit:get(),
        forceSign, forceSpace
    )
end

-- Color helpers reused across multiple UI elements.
local function chargeColor(pct)
    if not pct then
        return C.accent
    end
    if pct >= 75 then
        return C.good
    end
    if pct >= 25 then
        return C.warning
    end
    return C.danger
end

local function netColor(value)
    return value >= 0 and C.input or C.output
end

------------------------------------------------------------
-- Peripheral Handling
------------------------------------------------------------

local energyCore, energyCoreName
local monitor, monitorName

local function findEnergyCore()
    for _, typeName in ipairs(const.ENERGY_CORE_TYPES) do
        local w = peripheral.find(typeName)
        if w then
            return w
        end
    end
end

local function refreshPeripherals()
    if not monitorName or not peripheral.isPresent(monitorName) then
        monitor = peripheral.find("monitor")
        if monitor then
            monitor.setTextScale(monitorTextScale:get())
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
-- Graph Management (PixelGraph wrappers — kept separate from history.lua)
------------------------------------------------------------

-- Forward-declared; assigned when the graph widget is created in the UI section.
local graph

local function updateGraphBounds()
    if not graph then
        return
    end

    local maximum, minimum = 1, math.huge

    if showInputGraph:get() then
        for _, e in ipairs(history.input) do
            maximum = math.max(maximum, e.value)
            minimum = math.min(minimum, e.value)
        end
    end
    if showOutputGraph:get() then
        for _, e in ipairs(history.output) do
            maximum = math.max(maximum, e.value)
            minimum = math.min(minimum, e.value)
        end
    end

    if minimum == math.huge then
        minimum = 0
    end
    graph.maxValue = math.max(maximum, minimum + 1)
    graph.minValue = minimum
end

local function setupGraphSeries()
    if not graph then
        return
    end
    graph:addSeries("input", { color = C.input, pointCount = historyLength:get(), visible = showInputGraph:get() })
    graph:addSeries("output", { color = C.output, pointCount = historyLength:get(), visible = showOutputGraph:get() })
end

local function clearGraphSeries()
    if not graph then
        return
    end
    graph:removeSeries("input")
    graph:removeSeries("output")
    setupGraphSeries()
    graph.maxValue = 100
    graph.minValue = 0
end

local function fillGraphFromHistory()
    if not graph then
        return
    end
    clearGraphSeries()
    for _, e in ipairs(history.input) do
        graph:addPoint("input", e.value)
    end
    for _, e in ipairs(history.output) do
        graph:addPoint("output", e.value)
    end
    updateGraphBounds()
end

-- Wrappers that combine the data operation (history.*) with the graph update.
local function clearHistory()
    history.clear()
    clearGraphSeries()
end

local function trimHistoryToCurrentSettings()
    history.trim()
    fillGraphFromHistory()
end

------------------------------------------------------------
-- Sampling
------------------------------------------------------------

local lastSample = 0

local function sample()
    lastSample = os.clock()
    refreshPeripherals()

    if not energyCore then
        connected:set(false)
        return
    end

    local okE, newEnergy = callEnergyCore("getEnergyStored")
    local okM, newMax = callEnergyCore("getMaxEnergyStored")
    local okI, newInput = callEnergyCore("getInputPerTick")
    local okO, newOutput = callEnergyCore("getOutputPerTick")

    if not (okE and okM and okI and okO) then
        connected:set(false)
        return
    end

    local eVal = tonumber(newEnergy) or 0
    local mVal = tonumber(newMax) or 0
    local iVal = tonumber(newInput) or 0
    local oVal = tonumber(newOutput) or 0

    energy:set(eVal)
    maxEnergy:set(mVal)
    input:set(iVal)
    output:set(oVal)

    local now = utils.getUnixTimestamp()
    history.push(now, iVal, oVal)

    graph:addPoint("input", iVal)
    graph:addPoint("output", oVal)

    connected:set(true)
    history.maybeSave()
end

------------------------------------------------------------
-- UI Construction
------------------------------------------------------------

refreshPeripherals()

local frame = basalt.createFrame(monitor, monitorName)
frame.background = C.bg

-- Root: full-height column with a small gap between sections.
local mainPage = frame:addColumn({
    x = 1, y = 1,
    width = basalt.fill(),
    height = basalt.fill(),
    gap = 1,
})

-- ── Header ───────────────────────────────────────────────

local header = mainPage:addRow({
    width = basalt.fill(),
    height = 2,
    gap = 1,
    justify = "spaceBetween",
    background = C.panel,
})

-- Left: title + connection status.
local headerStart = header:addColumn({ width = basalt.auto(), height = basalt.fill() })

headerStart:addLabel({ text = "DRACONIC EVOLUTION ENERGY CORE", foreground = C.accent })

headerStart:addLabel({
    width = basalt.auto(),
    text = basalt.computed(function()
        if connected:get() then
            return 'ONLINE - "' .. tostring(energyCoreName or "") .. '"'
        end
        return "DISCONNECTED - SEARCHING..."
    end),
    foreground = basalt.computed(function()
        return connected:get() and C.good or C.danger
    end),
})

-- Right: sample-delay indicator + datetime.
local headerEndData = header:addColumn({ width = basalt.auto(), height = basalt.fill() })
:addRow({ width = basalt.fill(), height = basalt.fill(), gap = 1 })

headerEndData:addLabel({
    width = 7,
    text = basalt.computed(function()
        return string.format("%4.0f ms", sampleIntervalDelayMs:get())
    end),
    foreground = basalt.computed(function()
        local pct = sampleIntervalDelayMs:get() / (sampleIntervalSeconds:get() * 1000)
        if pct < 0.5 then
            return C.good elseif pct < 1.0 then
            return C.warning
        end
        return C.danger
    end),
})

headerEndData:addLabel({
    width = W_DATETIME,
    text = basalt.computed(function() return os.date("%Y-%m-%d %H:%M:%S")
    end),
    foreground = C.muted,
})

-- ── Settings Dropdowns (absolute-positioned, top-right) ──
--
-- Layout right → left: [rate unit] [energy unit] [scale] [history] [sample]
-- Each `x` expression subtracts the total width of all dropdowns to its right.

local sampleIntervalDropdown = mainPage:addDropdown({
    position = "absolute",
    x = "{parent.width - (5+3 + 1 + 5+2 + 1 + 3+1 + 1 + 4 + 1 + 4) + 1}",
    y = "{parent.y + 1}",
    width = 5 + 3,
    text = const.FORMATTED_SAMPLE_INTERVAL_OPTIONS[sampleIntervalIndex:get()],
    dropHeight = #const.FORMATTED_SAMPLE_INTERVAL_OPTIONS,
    items = const.FORMATTED_SAMPLE_INTERVAL_OPTIONS,
    background = C.muted,
})

local historyLengthDropdown = mainPage:addDropdown({
    position = "absolute",
    x = "{parent.width - (5+2 + 1 + 3+1 + 1 + 4 + 1 + 4) + 1}",
    y = "{parent.y + 1}",
    width = 5 + 2,
    text = const.FORMATTED_HISTORY_LENGTH_OPTIONS[historyLengthIndex:get()],
    dropHeight = #const.FORMATTED_HISTORY_LENGTH_OPTIONS,
    items = const.FORMATTED_HISTORY_LENGTH_OPTIONS,
    background = C.muted,
})

local monitorTextScaleDropdown = mainPage:addDropdown({
    position = "absolute",
    x = "{parent.width - (3+1 + 1 + 4 + 1 + 4) + 1}",
    y = "{parent.y + 1}",
    width = 3 + 1,
    text = const.FORMATTED_SCALED_MONITOR_TEXT_SCALES[monitorTextScaleIndex:get()],
    dropHeight = #const.FORMATTED_SCALED_MONITOR_TEXT_SCALES,
    items = const.FORMATTED_SCALED_MONITOR_TEXT_SCALES,
    background = C.muted,
})

local energyUnitDropdown = mainPage:addDropdown({
    position = "absolute",
    x = "{parent.width - (4 + 1 + 4) + 1}",
    y = "{parent.y + 1}",
    width = 4,
    text = const.ENERGY_UNITS[energyUnitIndex:get()],
    dropHeight = #const.ENERGY_UNITS,
    items = const.ENERGY_UNITS,
    background = C.muted,
})

local rateUnitDropdown = mainPage:addDropdown({
    position = "absolute",
    x = "{parent.width - 4 + 1}",
    y = "{parent.y + 1}",
    width = 4,
    text = const.RATE_UNITS[rateUnitIndex:get()],
    dropHeight = #const.RATE_UNITS,
    items = const.RATE_UNITS,
    background = C.muted,
})

-- Wire dropdowns to signals and persist on every change.
sampleIntervalDropdown:bind("selected", sampleIntervalIndex)
sampleIntervalDropdown:onSelect(function()
    trimHistoryToCurrentSettings()
    persistSettings()
end)

historyLengthDropdown:bind("selected", historyLengthIndex)
historyLengthDropdown:onSelect(function()
    trimHistoryToCurrentSettings()
    persistSettings()
end)

monitorTextScaleDropdown:bind("selected", monitorTextScaleIndex)
monitorTextScaleDropdown:onSelect(function(_, index)
    if monitor then
        monitor.setTextScale(const.MONITOR_TEXT_SCALES[index])
    end
    persistSettings()
end)

energyUnitDropdown:bind("selected", energyUnitIndex)
energyUnitDropdown:onSelect(function() persistSettings()
end)

rateUnitDropdown:bind("selected", rateUnitIndex)
rateUnitDropdown:onSelect(function() persistSettings()
end)

-- ── Content Area ─────────────────────────────────────────

local contentPanel = mainPage:addColumn({ width = basalt.fill(), height = basalt.fill(), gap = 1 })
local topPanelsRow = contentPanel:addRow({ width = basalt.fill(), height = basalt.auto(), gap = 1 })

-- ── Core Panel ───────────────────────────────────────────

local corePanel = topPanelsRow:addColumn({
    width = basalt.fill(1),
    minWidth = 30,
    minHeight = 4,
    shrink = 1,
    background = C.panel,
})

corePanel:addLabel({ text = "CORE", foreground = C.accent })

local W_CORE_LABEL = #"Capacity:"

-- Tier
do
    local row = corePanel:addRow({ width = W_CORE_LABEL + 1 + 1, height = 1, gap = 1 })
    row:addLabel({ width = W_CORE_LABEL, text = "Tier:" })
    row:addLabel({ width = 1, text = basalt.computed(function() return tostring(tier:get())
    end) })
end

-- Capacity
do
    local row = corePanel:addRow({ width = W_CORE_LABEL + 1 + W_ENERGY, height = 1, gap = 1 })
    row:addLabel({ width = W_CORE_LABEL, text = "Capacity:" })
    row:addLabel({ width = W_ENERGY, text = basalt.computed(function()
        if isInfinite:get() then
            return "Infinite"
        end
        return withEnergyUnit(maxEnergy:get())
    end) })
end

-- Stored
do
    local row = corePanel:addRow({ width = W_CORE_LABEL + 1 + W_ENERGY, height = 1, gap = 1 })
    row:addLabel({ width = W_CORE_LABEL, text = "Stored:" })
    row:addLabel({ width = W_ENERGY, text = basalt.computed(function()
        return withEnergyUnit(energy:get())
    end) })
end

-- Charge % (hidden for infinite-capacity cores)
do
    local row = corePanel:addRow({ width = W_CORE_LABEL + 1 + W_PCT, height = 1, gap = 1, visible = isFinite })
    row:addLabel({ width = W_CORE_LABEL, text = "Charge:" })
    row:addLabel({
        width = W_PCT,
        text = basalt.computed(function()
            local v = chargePercentage:get()
            return v and string.format("%6.2f %%", v) or "N/A"
        end),
        foreground = basalt.computed(function() return chargeColor(chargePercentage:get())
        end),
    })
end

-- Progress bar (also hidden for infinite cores)
corePanel:addProgressBar({
    width = basalt.fill(),
    height = 1,
    visible = isFinite,
    progress = chargePercentage:map(function(v) return v or 100
    end),
    showPercentage = false,
    background = C.muted,
    barColor = basalt.computed(function() return chargeColor(chargePercentage:get())
    end),
})

-- ── Power Flow Panel ──────────────────────────────────────

local ratePanel = topPanelsRow:addColumn({
    width = basalt.fill(1),
    minWidth = 30,
    height = basalt.fill(),
    background = C.panel,
})

ratePanel:addLabel({ text = "POWER FLOW", foreground = C.accent })

local W_RATE_LABEL = #"Output:"

-- Helper: one labeled rate row. valueColorFn is optional.
local function addRateRow(parent, labelText, labelColor, valueFn, valueColorFn)
    local row = parent:addRow({ width = W_RATE_LABEL + 1 + W_RATE, height = 1, gap = 1 })
    row:addLabel({ width = W_RATE_LABEL, text = labelText, foreground = labelColor })
    row:addLabel({
        width = W_RATE,
        text = basalt.computed(valueFn),
        foreground = valueColorFn and basalt.computed(valueColorFn) or labelColor,
    })
end

addRateRow(ratePanel, "Input:", C.input, function() return withRateUnit(input:get(), false, true)
end)
addRateRow(ratePanel, "Output:", C.output, function() return withRateUnit(output:get(), false, true)
end)
addRateRow(ratePanel, "Net:", C.net, function() return withRateUnit(net:get(), true)
end,
    function() return netColor(net:get())
    end)

-- ── Graph Panel ───────────────────────────────────────────

local graphPanel = contentPanel:addColumn({ width = basalt.fill(), height = basalt.fill(), background = C.panel })

-- Header: title left, toggle/clear buttons right.
local graphHeader = graphPanel:addRow({ width = basalt.fill(), height = 1, gap = 1, justify = "spaceBetween" })

graphHeader:addLabel({
    width = basalt.auto(),
    text = basalt.computed(function()
        return "RATE HISTORY - " .. historyLengthSeconds:get() .. " SECONDS"
    end),
    foreground = C.accent,
})

local graphButtons = graphHeader:addRow({ gap = 1 })

local toggleInputBtn = graphButtons:addButton({
    width = basalt.auto(), height = 1, text = "- INPUT",
    foreground = basalt.computed(function() return showInputGraph:get() and C.input or C.panel
    end),
    background = C.muted,
})
local toggleOutputBtn = graphButtons:addButton({
    width = basalt.auto(), height = 1, text = "- OUTPUT",
    foreground = basalt.computed(function() return showOutputGraph:get() and C.output or C.panel
    end),
    background = C.muted,
})
local clearBtn = graphButtons:addButton({
    width = basalt.auto(), height = 1, text = "CLEAR",
    foreground = C.text, background = C.muted,
})

-- Graph widget (fills the space between header and footer).
graph = graphPanel:addPixelGraph({ width = basalt.fill(), height = basalt.fill(), minValue = 0, maxValue = 100 })

setupGraphSeries()
fillGraphFromHistory()

toggleInputBtn:onClick(function()
    showInputGraph:set(not showInputGraph:get())
    graph:setSeriesVisible("input", showInputGraph:get())
    updateGraphBounds()
    persistSettings()
end)

toggleOutputBtn:onClick(function()
    showOutputGraph:set(not showOutputGraph:get())
    graph:setSeriesVisible("output", showOutputGraph:get())
    updateGraphBounds()
    persistSettings()
end)

clearBtn:onClick(clearHistory)

-- ── Graph Footer ──────────────────────────────────────────

local graphFooter = graphPanel:addColumn({ width = basalt.fill(), height = 3 })

-- Helper: one statistics row with IN / OUT / NET values and a sample count.
-- getLabelFn () → string e.g. function() return "60S AVG" end
-- inFn / outFn () → string formatted rate (no sign, with space)
-- netFn () → string formatted net rate (with sign)
-- netColorFn () → color
local function addFooterStatRow(parent, getLabelFn, inFn, outFn, netFn, netColorFn)
    local row = parent:addRow({ width = basalt.fill(), height = 1, gap = 1, justify = "spaceBetween" })

    row:addLabel({ width = basalt.auto(), text = basalt.computed(getLabelFn), foreground = C.accent })

    row:addLabel({
        width = 2 + 1 + W_RATE,
        text = basalt.computed(function() return "IN " .. inFn()
        end),
        foreground = C.input,
    })
    row:addLabel({
        width = 3 + 1 + W_RATE,
        text = basalt.computed(function() return "OUT " .. outFn()
        end),
        foreground = C.output,
    })

    -- Nested row so NET label and value can carry independent colors.
    local netRow = row:addRow({ width = 3 + 1 + W_RATE, height = 1, gap = 1 })
    netRow:addLabel({ width = 3, text = "NET", foreground = C.net })
    netRow:addLabel({
        width = W_RATE,
        text = basalt.computed(netFn),
        foreground = basalt.computed(netColorFn),
    })

    -- Sample count "NNN/MMM".
    row:addLabel({
        width = basalt.computed(function() return 2 * #tostring(historyLength:get()) + 1
        end),
        text = basalt.computed(function()
            local max = historyLength:get()
            return string.format("%" .. #tostring(max) .. "d/%d", #history.input, max)
        end),
        foreground = C.muted,
    })
end

addFooterStatRow(graphFooter,
    function() return historyLengthSeconds:get() .. "S AVG"
    end,
    function() return withRateUnit(averageInput:get(), false, true)
    end,
    function() return withRateUnit(averageOutput:get(), false, true)
    end,
    function() return withRateUnit(averageNet:get(), true)
    end,
    function() return netColor(averageNet:get())
    end
)

addFooterStatRow(graphFooter,
    function() return historyLengthSeconds:get() .. "S MAX"
    end,
    function() return withRateUnit(maximumInput:get(), false, true)
    end,
    function() return withRateUnit(maximumOutput:get(), false, true)
    end,
    function() return withRateUnit(maximumNet:get(), true)
    end,
    function() return netColor(maximumNet:get())
    end
)

addFooterStatRow(graphFooter,
    function() return historyLengthSeconds:get() .. "S MIN"
    end,
    function() return withRateUnit(minimumInput:get(), false, true)
    end,
    function() return withRateUnit(minimumOutput:get(), false, true)
    end,
    function() return withRateUnit(minimumNet:get(), true)
    end,
    function() return netColor(minimumNet:get())
    end
)

-- ── Status Footer ─────────────────────────────────────────

mainPage:addRow({ width = basalt.fill(), height = 1, background = C.panel })
:addLabel({ x = 2, y = 1, text = "Ready", foreground = C.good })

------------------------------------------------------------
-- Sampler Coroutine
------------------------------------------------------------

basalt.schedule(function()
    while true do
        local ok = pcall(sample)
        if not ok then
            connected:set(false)
        end

        local elapsed = os.clock() - lastSample
        sampleIntervalDelayMs:set(math.floor(elapsed * 1000))
        sleep(math.max(0, sampleIntervalSeconds:get() - elapsed))
    end
end)

------------------------------------------------------------
-- Start
------------------------------------------------------------

basalt.run()

print("Energy Core Monitor stopped.")
