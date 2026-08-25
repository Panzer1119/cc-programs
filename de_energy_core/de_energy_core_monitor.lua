-- Draconic Evolution Energy Core Monitor
-- CC:Tweaked + Basalt 2.5
--
-- Requires basalt.lua and config.lua in the same directory.

local basalt = require("basalt")
basalt.use("charts")

local cfg = require("config")

-- Unpack frequently-used config into locals for brevity.
local C = cfg.C
local SAMPLE_INTERVAL_OPTIONS = cfg.SAMPLE_INTERVAL_OPTIONS
local HISTORY_LENGTH_OPTIONS = cfg.HISTORY_LENGTH_OPTIONS
local FORMATTED_SAMPLE_INTERVAL_OPTIONS = cfg.FORMATTED_SAMPLE_INTERVAL_OPTIONS
local FORMATTED_HISTORY_LENGTH_OPTIONS = cfg.FORMATTED_HISTORY_LENGTH_OPTIONS
local MONITOR_TEXT_SCALES = cfg.MONITOR_TEXT_SCALES
local FORMATTED_SCALED_MONITOR_TEXT_SCALES = cfg.FORMATTED_SCALED_MONITOR_TEXT_SCALES
local ENERGY_UNITS = cfg.ENERGY_UNITS
local ENERGY_UNIT_FACTORS = cfg.ENERGY_UNIT_FACTORS
local RATE_UNITS = cfg.RATE_UNITS
local RATE_UNIT_FACTORS = cfg.RATE_UNIT_FACTORS
local TIER_CAPACITY = cfg.TIER_CAPACITY
local ENERGY_CORE_TYPES = cfg.ENERGY_CORE_TYPES
local SETTINGS_PATH = cfg.SETTINGS_PATH
local HISTORY_PATH = cfg.HISTORY_PATH
local DEFAULT_USER_SETTINGS = cfg.DEFAULT_USER_SETTINGS
-- Column width constants (shorthand)
local W_PCT = cfg.PERCENTAGE_NUMBER_LENGTH
local W_ENERGY = cfg.ENERGY_NUMBER_LENGTH
local W_RATE = cfg.ENERGY_RATE_NUMBER_LENGTH
local W_DATETIME = cfg.DATETIME_STRING_LENGTH
-- Functions
local findIndex = cfg.findIndex

------------------------------------------------------------
-- Utilities
------------------------------------------------------------

local function getUnixTimestamp()
    return os.time(os.date("*t"))
end

local function clamp(value, minimum, maximum)
    if value < minimum then
        return minimum
    end
    if value > maximum then
        return maximum
    end
    return value
end

------------------------------------------------------------
-- User Settings – load / sanitize
------------------------------------------------------------

local function sanitizeUserSettings(s)
    s = type(s) == "table" and s or {}
    return {
        monitorTextScaleIndex = clamp(tonumber(s.monitorTextScaleIndex) or DEFAULT_USER_SETTINGS.monitorTextScaleIndex, 1, #MONITOR_TEXT_SCALES),
        energyUnitIndex = clamp(tonumber(s.energyUnitIndex) or DEFAULT_USER_SETTINGS.energyUnitIndex, 1, #ENERGY_UNITS),
        rateUnitIndex = clamp(tonumber(s.rateUnitIndex) or DEFAULT_USER_SETTINGS.rateUnitIndex, 1, #RATE_UNITS),
        sampleIntervalIndex = clamp(tonumber(s.sampleIntervalIndex) or DEFAULT_USER_SETTINGS.sampleIntervalIndex, 1, #SAMPLE_INTERVAL_OPTIONS),
        historyLengthIndex = clamp(tonumber(s.historyLengthIndex) or DEFAULT_USER_SETTINGS.historyLengthIndex, 1, #HISTORY_LENGTH_OPTIONS),
        showInputGraph = s.showInputGraph == nil and DEFAULT_USER_SETTINGS.showInputGraph or not not s.showInputGraph,
        showOutputGraph = s.showOutputGraph == nil and DEFAULT_USER_SETTINGS.showOutputGraph or not not s.showOutputGraph,
    }
end

local function loadUserSettings()
    local handle = fs.open(SETTINGS_PATH, "r")
    if not handle then
        return sanitizeUserSettings(nil)
    end

    local content = handle.readAll()
    handle.close()

    if not content or content == "" then
        return sanitizeUserSettings(nil)
    end

    local ok, settings = pcall(textutils.unserialize, content)
    if not ok or type(settings) ~= "table" then
        print('Failed to load settings from "' .. SETTINGS_PATH .. '".')
        return sanitizeUserSettings(nil)
    end

    return sanitizeUserSettings(settings)
end

local userSettings = loadUserSettings()

------------------------------------------------------------
-- Reactive State
------------------------------------------------------------

-- Live sensor readings (written by the sampler coroutine)
local energy = basalt.signal(0)
local maxEnergy = basalt.signal(0)
local input = basalt.signal(0)
local output = basalt.signal(0)
local connected = basalt.signal(false)

-- User-controlled settings (persisted)
local monitorTextScaleIndex = basalt.signal(userSettings.monitorTextScaleIndex)
local energyUnitIndex = basalt.signal(userSettings.energyUnitIndex)
local rateUnitIndex = basalt.signal(userSettings.rateUnitIndex)
local sampleIntervalIndex = basalt.signal(userSettings.sampleIntervalIndex)
local historyLengthIndex = basalt.signal(userSettings.historyLengthIndex)
local showInputGraph = basalt.signal(userSettings.showInputGraph)
local showOutputGraph = basalt.signal(userSettings.showOutputGraph)

-- Computed settings values
local monitorTextScale = basalt.computed(function() return MONITOR_TEXT_SCALES[monitorTextScaleIndex:get()]
end)
local energyUnit = basalt.computed(function() return ENERGY_UNITS[energyUnitIndex:get()]
end)
local energyUnitFactor = basalt.computed(function() return ENERGY_UNIT_FACTORS[energyUnit:get()]
end)
local rateUnit = basalt.computed(function() return RATE_UNITS[rateUnitIndex:get()]
end)
local rateUnitFactor = basalt.computed(function() return RATE_UNIT_FACTORS[rateUnit:get()]
end)

local sampleIntervalSeconds = basalt.computed(function() return SAMPLE_INTERVAL_OPTIONS[sampleIntervalIndex:get()]
end)
local historyLengthSeconds = basalt.computed(function() return HISTORY_LENGTH_OPTIONS[historyLengthIndex:get()]
end)
local historyLength = basalt.computed(function()
    return math.ceil(historyLengthSeconds:get() / sampleIntervalSeconds:get())
end)

-- Computed sensor values
local tier = basalt.computed(function()
    local max = maxEnergy:get()
    if max > 2140000000000 then
        return 8
    end
    return TIER_CAPACITY[max] or 0
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

-- Sampler timing feedback
local sampleIntervalDelayMs = basalt.signal(0)

------------------------------------------------------------
-- Settings Persistence
------------------------------------------------------------

local function persistUserSettings()
    local handle = fs.open(SETTINGS_PATH, "w")
    if not handle then
        print("Failed to open settings file for writing.")
        return
    end
    handle.write(textutils.serialize({
        monitorTextScaleIndex = monitorTextScaleIndex:get(),
        energyUnitIndex = energyUnitIndex:get(),
        rateUnitIndex = rateUnitIndex:get(),
        sampleIntervalIndex = sampleIntervalIndex:get(),
        historyLengthIndex = historyLengthIndex:get(),
        showInputGraph = showInputGraph:get(),
        showOutputGraph = showOutputGraph:get(),
    }))
    handle.close()
end

------------------------------------------------------------
-- History Management
------------------------------------------------------------

-- Rolling sample arrays; each entry is { timestamp = int, value = number }.
local inputHistory = {}
local outputHistory = {}

-- Assigned during UI construction; used by history helpers below.
local graph

local function sanitizeHistoryEntries(entries, nowTimestamp)
    local result = {}
    local cutoff = nowTimestamp - historyLengthSeconds:get()
    local maxLen = historyLength:get()

    if type(entries) ~= "table" then
        return result
    end

    for _, e in ipairs(entries) do
        local t = type(e) == "table" and tonumber(e.timestamp) or nil
        local v = type(e) == "table" and tonumber(e.value) or nil
        if t and v and t >= cutoff and t <= nowTimestamp then
            result[#result + 1] = { timestamp = math.floor(t), value = v }
        end
    end

    table.sort(result, function(a, b)
        if a.timestamp == b.timestamp then
            return a.value < b.value
        end
        return a.timestamp < b.timestamp
    end)

    while #result > maxLen do
        table.remove(result, 1)
    end
    return result
end

-- Keep both arrays the same length by trimming the longer one from the front.
local function normalizeHistoryPair(inp, out)
    local len = math.min(#inp, #out)
    while #inp > len do
        table.remove(inp, 1)
    end
    while #out > len do
        table.remove(out, 1)
    end
    return inp, out
end

local function loadHistory()
    local handle = fs.open(HISTORY_PATH, "r")
    if not handle then
        return {}, {}
    end

    local content = handle.readAll()
    handle.close()

    if not content or content == "" then
        return {}, {}
    end

    local ok, data = pcall(textutils.unserialize, content)
    if not ok or type(data) ~= "table" then
        print('Failed to load history from "' .. HISTORY_PATH .. '".')
        return {}, {}
    end

    local now = getUnixTimestamp()
    return normalizeHistoryPair(
        sanitizeHistoryEntries(data.inputHistory, now),
        sanitizeHistoryEntries(data.outputHistory, now)
    )
end

local function persistHistory()
    local handle = fs.open(HISTORY_PATH, "w")
    if not handle then
        print("Failed to open history file for writing.")
        return
    end
    handle.write(textutils.serialize({ inputHistory = inputHistory, outputHistory = outputHistory }))
    handle.close()
end

local function pushSample(history, timestamp, value)
    history[#history + 1] = { timestamp = timestamp, value = value }

    local cutoff = timestamp - historyLengthSeconds:get()
    local maxLen = historyLength:get()

    while #history > maxLen do
        table.remove(history, 1)
    end
    while #history > 0 and history[1].timestamp < cutoff do
        table.remove(history, 1)
    end
end

-- Graph series helpers (require `graph` to be assigned first).

local function updateGraphBounds()
    if not graph then
        return
    end

    local maximum, minimum = 1, math.huge

    if showInputGraph:get() then
        for _, e in ipairs(inputHistory) do
            maximum = math.max(maximum, e.value)
            minimum = math.min(minimum, e.value)
        end
    end
    if showOutputGraph:get() then
        for _, e in ipairs(outputHistory) do
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
    for _, e in ipairs(inputHistory) do
        graph:addPoint("input", e.value)
    end
    for _, e in ipairs(outputHistory) do
        graph:addPoint("output", e.value)
    end
    updateGraphBounds()
end

local function clearHistory()
    inputHistory = {}
    outputHistory = {}
    clearGraphSeries()
    persistHistory()
end

local function trimHistoryToCurrentSettings()
    local maxLen = historyLength:get()
    local cutoff = getUnixTimestamp() - historyLengthSeconds:get()

    while #inputHistory > maxLen do
        table.remove(inputHistory, 1)
    end
    while #outputHistory > maxLen do
        table.remove(outputHistory, 1)
    end
    while #inputHistory > 0 and inputHistory[1].timestamp < cutoff do
        table.remove(inputHistory, 1)
    end
    while #outputHistory > 0 and outputHistory[1].timestamp < cutoff do
        table.remove(outputHistory, 1)
    end

    inputHistory, outputHistory = normalizeHistoryPair(inputHistory, outputHistory)
    fillGraphFromHistory()
    persistHistory()
end

-- Bootstrap history from disk on startup.
inputHistory, outputHistory = loadHistory()
persistHistory()

------------------------------------------------------------
-- History Statistics (computed signals)
------------------------------------------------------------

-- Generic helpers that operate on a single history array.
local function historyAvg(h)
    if #h == 0 then
        return 0
    end
    local total = 0
    for _, e in ipairs(h) do
        total = total + e.value
    end
    return total / #h
end

local function historyMax(h)
    if #h == 0 then
        return 0
    end
    local max = 0
    for _, e in ipairs(h) do
        max = math.max(max, e.value)
    end
    return max
end

local function historyMin(h)
    if #h == 0 then
        return 0
    end
    local min = math.huge
    for _, e in ipairs(h) do
        min = math.min(min, e.value)
    end
    return min
end

local averageInput = basalt.computed(function() return historyAvg(inputHistory)
end)
local averageOutput = basalt.computed(function() return historyAvg(outputHistory)
end)
local maximumInput = basalt.computed(function() return historyMax(inputHistory)
end)
local maximumOutput = basalt.computed(function() return historyMax(outputHistory)
end)
local minimumInput = basalt.computed(function() return historyMin(inputHistory)
end)
local minimumOutput = basalt.computed(function() return historyMin(outputHistory)
end)

-- Net (input − output) statistics iterate paired arrays.
local averageNet = basalt.computed(function()
    if #inputHistory == 0 then
        return 0
    end
    local total = 0
    for i = 1, #inputHistory do
        total = total + inputHistory[i].value - outputHistory[i].value
    end
    return total / #inputHistory
end)

local maximumNet = basalt.computed(function()
    if #inputHistory == 0 then
        return 0
    end
    local max = 0
    for i = 1, #inputHistory do
        max = math.max(max, inputHistory[i].value - outputHistory[i].value)
    end
    return max
end)

local minimumNet = basalt.computed(function()
    if #inputHistory == 0 then
        return 0
    end
    local min = math.huge
    for i = 1, #inputHistory do
        min = math.min(min, inputHistory[i].value - outputHistory[i].value)
    end
    return min
end)

------------------------------------------------------------
-- Formatting
------------------------------------------------------------

-- Format a number with an SI prefix (e.g. 1500 → "  1.50 k").
-- forceSign prepends "+" for positive values; forceSpace reserves sign space.
local function si(n, unit, forceSign, forceSpace)
    if not n then
        return "N/A"
    end
    n = math.floor(n)
    local prefixes = { "", "k", "M", "G", "T", "P", "E", "Z", "Y", "R", "Q" }
    local i = 1
    while math.abs(n) >= 1000 and i < #prefixes do
        n = n / 1000
        i = i + 1
    end
    local fmt = forceSign and "%+7.2f %s%s" or (forceSpace and "%7.2f %s%s" or "%6.2f %s%s")
    return string.format(fmt, n, prefixes[i], unit or "")
end

local function withEnergyUnit(value, forceSign, forceSpace)
    return si(value / energyUnitFactor:get(), energyUnit:get(), forceSign, forceSpace)
end

local function withRateUnit(value, forceSign, forceSpace)
    return si(
        value * rateUnitFactor:get() / energyUnitFactor:get(),
        energyUnit:get() .. rateUnit:get(),
        forceSign, forceSpace
    )
end

-- Color helpers shared by several UI elements.
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
    for _, typeName in ipairs(ENERGY_CORE_TYPES) do
        local w = peripheral.find(typeName)
        if w then
            return w
        end
    end
    return nil
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

    local now = getUnixTimestamp()
    pushSample(inputHistory, now, iVal)
    pushSample(outputHistory, now, oVal)

    graph:addPoint("input", iVal)
    graph:addPoint("output", oVal)

    connected:set(true)
    persistHistory()
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

-- Left side: title + connection status
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

-- Right side: sample-delay indicator + datetime
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

-- ── Settings Dropdowns (absolute, top-right) ─────────────
--
-- Layout (right → left): [rate unit][energy unit][scale][history][sample]
-- Each x expression subtracts the cumulative width of all dropdowns to its right.

local sampleIntervalDropdown = mainPage:addDropdown({
    position = "absolute",
    x = "{parent.width - (5+3 + 1 + 5+2 + 1 + 3+1 + 1 + 4 + 1 + 4) + 1}",
    y = "{parent.y + 1}",
    width = 5 + 3,
    text = FORMATTED_SAMPLE_INTERVAL_OPTIONS[sampleIntervalIndex:get()],
    dropHeight = #FORMATTED_SAMPLE_INTERVAL_OPTIONS,
    items = FORMATTED_SAMPLE_INTERVAL_OPTIONS,
    background = C.muted,
})

local historyLengthDropdown = mainPage:addDropdown({
    position = "absolute",
    x = "{parent.width - (5+2 + 1 + 3+1 + 1 + 4 + 1 + 4) + 1}",
    y = "{parent.y + 1}",
    width = 5 + 2,
    text = FORMATTED_HISTORY_LENGTH_OPTIONS[historyLengthIndex:get()],
    dropHeight = #FORMATTED_HISTORY_LENGTH_OPTIONS,
    items = FORMATTED_HISTORY_LENGTH_OPTIONS,
    background = C.muted,
})

local monitorTextScaleDropdown = mainPage:addDropdown({
    position = "absolute",
    x = "{parent.width - (3+1 + 1 + 4 + 1 + 4) + 1}",
    y = "{parent.y + 1}",
    width = 3 + 1,
    text = FORMATTED_SCALED_MONITOR_TEXT_SCALES[monitorTextScaleIndex:get()],
    dropHeight = #FORMATTED_SCALED_MONITOR_TEXT_SCALES,
    items = FORMATTED_SCALED_MONITOR_TEXT_SCALES,
    background = C.muted,
})

local energyUnitDropdown = mainPage:addDropdown({
    position = "absolute",
    x = "{parent.width - (4 + 1 + 4) + 1}",
    y = "{parent.y + 1}",
    width = 4,
    text = ENERGY_UNITS[energyUnitIndex:get()],
    dropHeight = #ENERGY_UNITS,
    items = ENERGY_UNITS,
    background = C.muted,
})

local rateUnitDropdown = mainPage:addDropdown({
    position = "absolute",
    x = "{parent.width - 4 + 1}",
    y = "{parent.y + 1}",
    width = 4,
    text = RATE_UNITS[rateUnitIndex:get()],
    dropHeight = #RATE_UNITS,
    items = RATE_UNITS,
    background = C.muted,
})

-- Wire each dropdown to its signal and persist changes.
sampleIntervalDropdown:bind("selected", sampleIntervalIndex)
sampleIntervalDropdown:onSelect(function()
    trimHistoryToCurrentSettings()
    persistUserSettings()
end)

historyLengthDropdown:bind("selected", historyLengthIndex)
historyLengthDropdown:onSelect(function()
    trimHistoryToCurrentSettings()
    persistUserSettings()
end)

monitorTextScaleDropdown:bind("selected", monitorTextScaleIndex)
monitorTextScaleDropdown:onSelect(function(_, index)
    if monitor then
        monitor.setTextScale(MONITOR_TEXT_SCALES[index])
    end
    persistUserSettings()
end)

energyUnitDropdown:bind("selected", energyUnitIndex)
energyUnitDropdown:onSelect(function() persistUserSettings()
end)

rateUnitDropdown:bind("selected", rateUnitIndex)
rateUnitDropdown:onSelect(function() persistUserSettings()
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

-- Charge % – only visible for finite-capacity cores
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

-- Charge progress bar (also hidden for infinite cores)
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

-- Helper: one labeled rate row.
-- valueColorFn is optional; falls back to the static labelColor.
local function addRateRow(parent, labelText, labelColor, valueFn, valueColorFn)
    local row = parent:addRow({ width = W_RATE_LABEL + 1 + W_RATE, height = 1, gap = 1 })
    row:addLabel({ width = W_RATE_LABEL, text = labelText, foreground = labelColor })
    row:addLabel({
        width = W_RATE,
        text = basalt.computed(valueFn),
        foreground = valueColorFn and basalt.computed(valueColorFn) or labelColor,
    })
    return row
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

-- Graph header: title on the left, toggle/clear buttons on the right.
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

-- Graph widget (fills remaining space between header and footer).
graph = graphPanel:addPixelGraph({ width = basalt.fill(), height = basalt.fill(), minValue = 0, maxValue = 100 })

setupGraphSeries()
fillGraphFromHistory()

-- Button handlers
toggleInputBtn:onClick(function()
    showInputGraph:set(not showInputGraph:get())
    graph:setSeriesVisible("input", showInputGraph:get())
    updateGraphBounds()
    persistUserSettings()
end)

toggleOutputBtn:onClick(function()
    showOutputGraph:set(not showOutputGraph:get())
    graph:setSeriesVisible("output", showOutputGraph:get())
    updateGraphBounds()
    persistUserSettings()
end)

clearBtn:onClick(clearHistory)

-- ── Graph Footer ──────────────────────────────────────────

local graphFooter = graphPanel:addColumn({ width = basalt.fill(), height = 3 })

-- Helper: one statistics row showing IN / OUT / NET values and the sample count.
-- getLabelFn → string e.g. function() return "60S AVG" end
-- inFn / outFn → string formatted rate (no sign, with space)
-- netFn → string formatted net rate (with sign)
-- netColorFn → color
local function addFooterStatRow(parent, getLabelFn, inFn, outFn, netFn, netColorFn)
    local row = parent:addRow({ width = basalt.fill(), height = 1, gap = 1, justify = "spaceBetween" })

    row:addLabel({
        width = basalt.auto(),
        text = basalt.computed(getLabelFn),
        foreground = C.accent,
    })

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

    -- NET is a nested row so label and value can have independent colors.
    local netRow = row:addRow({ width = 3 + 1 + W_RATE, height = 1, gap = 1 })
    netRow:addLabel({ width = 3, text = "NET", foreground = C.net })
    netRow:addLabel({
        width = W_RATE,
        text = basalt.computed(netFn),
        foreground = basalt.computed(netColorFn),
    })

    -- Sample count: "NNN/MMM"
    row:addLabel({
        width = basalt.computed(function() return 2 * #tostring(historyLength:get()) + 1
        end),
        text = basalt.computed(function()
            local max = historyLength:get()
            return string.format("%" .. #tostring(max) .. "d/%d", #inputHistory, max)
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

local statusFooter = mainPage:addRow({ width = basalt.fill(), height = 1, background = C.panel })
statusFooter:addLabel({ x = 2, y = 1, text = "Ready", foreground = C.good })

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
        local delay = sampleIntervalSeconds:get() - elapsed
        sampleIntervalDelayMs:set(math.floor(elapsed * 1000))
        sleep(math.max(0, delay))
    end
end)

------------------------------------------------------------
-- Start
------------------------------------------------------------

basalt.run()

print("Energy Core Monitor stopped.")
