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

local DEFAULT_SAMPLE_INTERVAL_SECONDS = 1
local DEFAULT_HISTORY_LENGTH_SECONDS = 60

local SAMPLE_INTERVAL_OPTIONS = { 0.25, 0.5, 1, 5, 10 }
local FORMATTED_SAMPLE_INTERVAL_OPTIONS = {}
for _, v in ipairs(SAMPLE_INTERVAL_OPTIONS) do
    --FORMATTED_SAMPLE_INTERVAL_OPTIONS[#FORMATTED_SAMPLE_INTERVAL_OPTIONS + 1] = string.format("%2.2f Hz", v)
    FORMATTED_SAMPLE_INTERVAL_OPTIONS[#FORMATTED_SAMPLE_INTERVAL_OPTIONS + 1] = string.format("%2.2f s", v)
end
local HISTORY_LENGTH_OPTIONS = { 10, 60, 120, 300, 600 }
local FORMATTED_HISTORY_LENGTH_OPTIONS = {}
for _, v in ipairs(HISTORY_LENGTH_OPTIONS) do
    FORMATTED_HISTORY_LENGTH_OPTIONS[#FORMATTED_HISTORY_LENGTH_OPTIONS + 1] = string.format("%3d s", v)
end
local MAX_HISTORY_LENGTH = math.ceil(HISTORY_LENGTH_OPTIONS[#HISTORY_LENGTH_OPTIONS] / SAMPLE_INTERVAL_OPTIONS[1])

local function findDefaultOptionIndex(options, defaultValue)
    for index, value in ipairs(options) do
        if value == defaultValue then
            return index
        end
    end

    return 1
end

local DEFAULT_SAMPLE_INTERVAL_INDEX = findDefaultOptionIndex(SAMPLE_INTERVAL_OPTIONS, DEFAULT_SAMPLE_INTERVAL_SECONDS)
local DEFAULT_HISTORY_LENGTH_INDEX = findDefaultOptionIndex(HISTORY_LENGTH_OPTIONS, DEFAULT_HISTORY_LENGTH_SECONDS)

local DEFAULT_PERCENTAGE_NUMBER_LENGTH = #"100.00 %"
local DEFAULT_ENERGY_NUMBER_LENGTH = #"+999.99 kRF"
local DEFAULT_ENERGY_RATE_NUMBER_LENGTH = #"+999.99 kRF/t"
local DEFAULT_DATETIME_STRING_LENGTH = #"2026-08-25 16:14:33"

--local MONITOR_TEXT_SCALES = { 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0 }
local MONITOR_TEXT_SCALES = { 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0 }
-- multiply all scales by 2 so no decimals in the dropdown
local SCALED_MONITOR_TEXT_SCALES = {}
for i, v in ipairs(MONITOR_TEXT_SCALES) do
    SCALED_MONITOR_TEXT_SCALES[i] = v * 2
end
local FORMATTED_SCALED_MONITOR_TEXT_SCALES = {}
for _, v in ipairs(SCALED_MONITOR_TEXT_SCALES) do
    FORMATTED_SCALED_MONITOR_TEXT_SCALES[#FORMATTED_SCALED_MONITOR_TEXT_SCALES + 1] = string.format("x%d", v)
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

local SETTINGS_FILE_NAME = "de_energy_core_monitor.settings"
local SETTINGS_PATH = "/" .. SETTINGS_FILE_NAME
local HISTORY_FILE_NAME = "de_energy_core_monitor.history"
local HISTORY_PATH = "/" .. HISTORY_FILE_NAME

local function getUnixTimestamp()
    return os.time(os.date("*t"))
end

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

local DEFAULT_USER_SETTINGS = {
    monitorTextScaleIndex = 2,
    energyUnitIndex = 1,
    rateUnitIndex = 1,
    sampleIntervalIndex = DEFAULT_SAMPLE_INTERVAL_INDEX,
    historyLengthIndex = DEFAULT_HISTORY_LENGTH_INDEX,
    showInputGraph = true,
    showOutputGraph = true,
}

local function clamp(value, minimum, maximum)
    if value < minimum then
        return minimum
    end

    if value > maximum then
        return maximum
    end

    return value
end

local function sanitizeUserSettings(settings)
    settings = type(settings) == "table" and settings or {}

    return {
        monitorTextScaleIndex = clamp(tonumber(settings.monitorTextScaleIndex) or DEFAULT_USER_SETTINGS.monitorTextScaleIndex, 1, #MONITOR_TEXT_SCALES),
        energyUnitIndex = clamp(tonumber(settings.energyUnitIndex) or DEFAULT_USER_SETTINGS.energyUnitIndex, 1, #ENERGY_UNITS),
        rateUnitIndex = clamp(tonumber(settings.rateUnitIndex) or DEFAULT_USER_SETTINGS.rateUnitIndex, 1, #RATE_UNITS),
        sampleIntervalIndex = clamp(tonumber(settings.sampleIntervalIndex) or DEFAULT_USER_SETTINGS.sampleIntervalIndex, 1, #SAMPLE_INTERVAL_OPTIONS),
        historyLengthIndex = clamp(tonumber(settings.historyLengthIndex) or DEFAULT_USER_SETTINGS.historyLengthIndex, 1, #HISTORY_LENGTH_OPTIONS),
        showInputGraph = settings.showInputGraph == nil and DEFAULT_USER_SETTINGS.showInputGraph or not not settings.showInputGraph,
        showOutputGraph = settings.showOutputGraph == nil and DEFAULT_USER_SETTINGS.showOutputGraph or not not settings.showOutputGraph,
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
        print("Failed to load user settings from \"" .. SETTINGS_PATH .. "\".")
        return sanitizeUserSettings(nil)
    end

    return sanitizeUserSettings(settings)
end

local userSettings = loadUserSettings()

-- These four signals remain the primary live state.
local energy = basalt.signal(0)
local maxEnergy = basalt.signal(0)
local input = basalt.signal(0)
local output = basalt.signal(0)

local connected = basalt.signal(false)

local monitorTextScaleIndex = basalt.signal(userSettings.monitorTextScaleIndex)
--local monitorTextScale = basalt.signal(1)
local monitorTextScale = basalt.computed(function()
    return MONITOR_TEXT_SCALES[monitorTextScaleIndex:get()]
end)

local energyUnitIndex = basalt.signal(userSettings.energyUnitIndex)
--local energyUnit = basalt.signal("RF")
local energyUnit = basalt.computed(function()
    return ENERGY_UNITS[energyUnitIndex:get()]
end)
--local energyUnitFactor = basalt.signal(1)
local energyUnitFactor = basalt.computed(function()
    return ENERGY_UNIT_FACTORS[energyUnit:get()]
end)
local rateUnitIndex = basalt.signal(userSettings.rateUnitIndex)
--local rateUnit = basalt.signal("/t")
local rateUnit = basalt.computed(function()
    return RATE_UNITS[rateUnitIndex:get()]
end)
--local rateUnitFactor = basalt.signal(1)
local rateUnitFactor = basalt.computed(function()
    return RATE_UNIT_FACTORS[rateUnit:get()]
end)

local sampleIntervalIndex = basalt.signal(userSettings.sampleIntervalIndex)
local historyLengthIndex = basalt.signal(userSettings.historyLengthIndex)

local sampleIntervalSeconds = basalt.computed(function()
    return SAMPLE_INTERVAL_OPTIONS[sampleIntervalIndex:get()]
end)

local historyLengthSeconds = basalt.computed(function()
    return HISTORY_LENGTH_OPTIONS[historyLengthIndex:get()]
end)

local historyLength = basalt.computed(function()
    return math.ceil(historyLengthSeconds:get() / sampleIntervalSeconds:get())
end)

local showInputGraph = basalt.signal(userSettings.showInputGraph)
local showOutputGraph = basalt.signal(userSettings.showOutputGraph)

local function getUserSettings()
    return {
        monitorTextScaleIndex = monitorTextScaleIndex:get(),
        energyUnitIndex = energyUnitIndex:get(),
        rateUnitIndex = rateUnitIndex:get(),
        sampleIntervalIndex = sampleIntervalIndex:get(),
        historyLengthIndex = historyLengthIndex:get(),
        showInputGraph = showInputGraph:get(),
        showOutputGraph = showOutputGraph:get(),
    }
end

local function saveUserSettings()
    local handle = fs.open(SETTINGS_PATH, "w")

    if not handle then
        return false, "Unable to open settings file for writing"
    end

    handle.write(textutils.serialize(getUserSettings()))
    handle.close()

    return true
end

local function persistUserSettings()
    local ok, err = saveUserSettings()

    if not ok then
        print("Failed to save user settings: " .. tostring(err))
    end
end

local function sanitizeHistoryEntries(entries, nowTimestamp)
    local sanitizedEntries = {}
    local cutoffTimestamp = nowTimestamp - historyLengthSeconds:get()
    local selectedHistoryLength = historyLength:get()

    if type(entries) ~= "table" then
        return sanitizedEntries
    end

    for _, entry in ipairs(entries) do
        local timestamp = type(entry) == "table" and tonumber(entry.timestamp) or nil
        local value = type(entry) == "table" and tonumber(entry.value) or nil

        if timestamp and value and timestamp >= cutoffTimestamp and timestamp <= nowTimestamp then
            sanitizedEntries[#sanitizedEntries + 1] = {
                timestamp = math.floor(timestamp),
                value = value,
            }
        end
    end

    table.sort(sanitizedEntries, function(a, b)
        if a.timestamp == b.timestamp then
            return a.value < b.value
        end

        return a.timestamp < b.timestamp
    end)

    while #sanitizedEntries > selectedHistoryLength do
        table.remove(sanitizedEntries, 1)
    end

    return sanitizedEntries
end

local function normalizeHistoryPair(newInputHistory, newOutputHistory)
    local normalizedLength = math.min(#newInputHistory, #newOutputHistory)

    while #newInputHistory > normalizedLength do
        table.remove(newInputHistory, 1)
    end

    while #newOutputHistory > normalizedLength do
        table.remove(newOutputHistory, 1)
    end

    return newInputHistory, newOutputHistory
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
        print("Failed to load history from \"" .. HISTORY_PATH .. "\".")
        return {}, {}
    end

    local nowTimestamp = getUnixTimestamp()

    return normalizeHistoryPair(
        sanitizeHistoryEntries(data.inputHistory, nowTimestamp),
        sanitizeHistoryEntries(data.outputHistory, nowTimestamp)
    )
end

-- Rolling samples
local inputHistory, outputHistory = loadHistory()

local function saveHistory()
    local handle = fs.open(HISTORY_PATH, "w")

    if not handle then
        return false, "Unable to open history file for writing"
    end

    handle.write(textutils.serialize({
        inputHistory = inputHistory,
        outputHistory = outputHistory,
    }))
    handle.close()

    return true
end

local function persistHistory()
    local ok, err = saveHistory()

    if not ok then
        print("Failed to save history: " .. tostring(err))
    end
end

persistHistory()

local graph

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

    for _, entry in ipairs(inputHistory) do
        total = total + entry.value
    end

    return total / #inputHistory
end)

local averageOutput = basalt.computed(function()
    if #outputHistory == 0 then
        return 0
    end

    local total = 0

    for _, entry in ipairs(outputHistory) do
        total = total + entry.value
    end

    return total / #outputHistory
end)

local averageNet = basalt.computed(function()
    if #inputHistory == 0 then
        return 0
    end

    local total = 0

    for i, inputEntry in ipairs(inputHistory) do
        local outputEntry = outputHistory[i]
        local value = inputEntry.value - outputEntry.value
        total = total + value
    end

    return total / #inputHistory
end)

local maximumInput = basalt.computed(function()
    if #inputHistory == 0 then
        return 0
    end

    local maximum = 0

    for _, entry in ipairs(inputHistory) do
        maximum = math.max(maximum, entry.value)
    end

    return maximum
end)

local maximumOutput = basalt.computed(function()
    if #outputHistory == 0 then
        return 0
    end

    local maximum = 0

    for _, entry in ipairs(outputHistory) do
        maximum = math.max(maximum, entry.value)
    end

    return maximum
end)

local maximumNet = basalt.computed(function()
    if #inputHistory == 0 then
        return 0
    end

    local maximum = 0

    for i, inputEntry in ipairs(inputHistory) do
        local outputEntry = outputHistory[i]
        local value = inputEntry.value - outputEntry.value
        maximum = math.max(maximum, value)
    end

    return maximum
end)

local minimumInput = basalt.computed(function()
    if #inputHistory == 0 then
        return 0
    end

    local minimum = math.huge

    for _, entry in ipairs(inputHistory) do
        minimum = math.min(minimum, entry.value)
    end

    return minimum
end)

local minimumOutput = basalt.computed(function()
    if #outputHistory == 0 then
        return 0
    end

    local minimum = math.huge

    for _, entry in ipairs(outputHistory) do
        minimum = math.min(minimum, entry.value)
    end

    return minimum
end)

local minimumNet = basalt.computed(function()
    if #inputHistory == 0 then
        return 0
    end

    local minimum = math.huge

    for i, inputEntry in ipairs(inputHistory) do
        local outputEntry = outputHistory[i]
        local value = inputEntry.value - outputEntry.value
        minimum = math.min(minimum, value)
    end

    return minimum
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
    return withEnergyRateUnit(averageInput:get(), false, true)
end

local function averageOutputRateText()
    return withEnergyRateUnit(averageOutput:get(), false, true)
end

local function averageNetRateText()
    return withEnergyRateUnit(averageNet:get(), true)
end

-- Maximum energy rate values

local function maximumInputRateText()
    return withEnergyRateUnit(maximumInput:get(), false, true)
end

local function maximumOutputRateText()
    return withEnergyRateUnit(maximumOutput:get(), false, true)
end

local function maximumNetRateText()
    return withEnergyRateUnit(maximumNet:get(), true)
end

-- Minimum energy rate values

local function minimumInputRateText()
    return withEnergyRateUnit(minimumInput:get(), false, true)
end

local function minimumOutputRateText()
    return withEnergyRateUnit(minimumOutput:get(), false, true)
end

local function minimumNetRateText()
    return withEnergyRateUnit(minimumNet:get(), true)
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

local function push(history, timestamp, value)
    history[#history + 1] = {
        timestamp = timestamp,
        value = value,
    }

    while #history > historyLength:get() do
        table.remove(history, 1)
    end

    local cutoffTimestamp = timestamp - historyLengthSeconds:get()

    while #history > 0 and history[1].timestamp < cutoffTimestamp do
        table.remove(history, 1)
    end
end

local function updateGraphBounds()
    if not graph then
        return
    end

    local maximum = 1
    local minimum = math.huge

    if showInputGraph:get() then
        for _, entry in ipairs(inputHistory) do
            maximum = math.max(maximum, entry.value)
            minimum = math.min(minimum, entry.value)
        end
    end

    if showOutputGraph:get() then
        for _, entry in ipairs(outputHistory) do
            maximum = math.max(maximum, entry.value)
            minimum = math.min(minimum, entry.value)
        end
    end

    if minimum == math.huge then
        minimum = 0
    end

    graph.maxValue = math.max(maximum, minimum + 1)
    graph.minValue = minimum
end

local function setupGraphDisplay()
    if not graph then
        return
    end

    graph:addSeries("input", {
        color = C.input,
        pointCount = historyLength:get(),
        visible = showInputGraph:get(),
    })

    graph:addSeries("output", {
        color = C.output,
        pointCount = historyLength:get(),
        visible = showOutputGraph:get(),
    })
end

local function clearGraphDisplay()
    if not graph then
        return
    end
    --graph:clear("input")
    --graph:clear("output")
    graph:removeSeries("input")
    graph:removeSeries("output")
    setupGraphDisplay()
    graph.maxValue = 100
    graph.minValue = 0
end

local function fillGraphFromHistory()
    if not graph then
        return
    end

    clearGraphDisplay()

    for _, entry in ipairs(inputHistory) do
        graph:addPoint("input", entry.value)
    end

    for _, entry in ipairs(outputHistory) do
        graph:addPoint("output", entry.value)
    end

    updateGraphBounds()
end

local function clearHistory()
    inputHistory = {}
    outputHistory = {}

    clearGraphDisplay()
    persistHistory()
end

local function trimHistoryToCurrentSettings()
    local selectedHistoryLength = historyLength:get()
    local cutoffTimestamp = getUnixTimestamp() - historyLengthSeconds:get()

    while #inputHistory > selectedHistoryLength do
        table.remove(inputHistory, 1)
    end

    while #outputHistory > selectedHistoryLength do
        table.remove(outputHistory, 1)
    end

    while #inputHistory > 0 and inputHistory[1].timestamp < cutoffTimestamp do
        table.remove(inputHistory, 1)
    end

    while #outputHistory > 0 and outputHistory[1].timestamp < cutoffTimestamp do
        table.remove(outputHistory, 1)
    end

    inputHistory, outputHistory = normalizeHistoryPair(inputHistory, outputHistory)
    fillGraphFromHistory()
    persistHistory()
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

    local sampleTimestamp = getUnixTimestamp()

    push(inputHistory, sampleTimestamp, newInput)
    push(outputHistory, sampleTimestamp, newOutput)

    connected:set(true)

    -- PixelGraph is streaming state, so it is updated here.
    graph:addPoint("input", newInput)
    graph:addPoint("output", newOutput)

    --TODO This is probably bad for the performance, no?
    ---- Rebuild from persisted history so dynamic interval/history settings stay in sync.
    --fillGraphFromHistory()

    persistHistory()
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

local header = mainPage:addRow({
    width = basalt.fill(),
    height = 2,
    gap = 1,
    --padding = 1,
    justify = "spaceBetween",
    background = C.panel,
})

-- Header start column (title and status)

local headerStart = header:addColumn({
    width = basalt.auto(),
    height = basalt.fill(),
})

-- Title

headerStart:addLabel({
    text = "DRACONIC EVOLUTION ENERGY CORE",
    foreground = C.accent,
})

-- Status

headerStart:addLabel({
    width = basalt.auto(),
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

-- Header end column (sample interval, time and settings)

local headerEnd = header:addColumn({
    width = basalt.auto(),
    height = basalt.fill(),
})

-- Header end row (sample interval and time)

local headerEndData = headerEnd:addRow({
    width = basalt.fill(),
    height = basalt.fill(),
    gap = 1,
})

headerEndData:addLabel({
    width = 7,
    text = basalt.computed(function()
        return string.format("%4.0f ms", sampleIntervalDelayMs:get())
    end),
    foreground = basalt.computed(function()
        local value = sampleIntervalDelayMs:get()
        if not value then
            return C.muted
        end

        local valuePercentage = value / (sampleIntervalSeconds:get() * 1000)
        if valuePercentage < 0.5 then
            return C.good
        elseif valuePercentage < 1.0 then
            return C.warning
        end

        return C.danger
    end),
})

headerEndData:addLabel({
    width = DEFAULT_DATETIME_STRING_LENGTH,
    text = basalt.computed(function()
        return os.date("%Y-%m-%d %H:%M:%S")
    end),
    foreground = C.muted,
})

---- Header end row (settings)
--
--local headerEndSettings = headerEnd:addRow({
--    width = basalt.fill(),
--    height = basalt.fill(),
--    gap = 1,
--})

------------------------------------------------------------
-- Settings
------------------------------------------------------------

--FIXME When using this and opening a dropdown,
-- it always moves the selected dropdown to the right side,
-- no matter where the dropdown was
--local settingsRow = mainPage:addRow({
--    position = "absolute",
--    x = "{parent.width - (3 + 1 + 4 + 1 + 4) + 1}",
--    y = "{parent.y + 1}",
--    width = 3 + 1 + 4 + 1 + 4,
--    minHeight = 1,
--    maxHeight = 1 + math.max(#MONITOR_TEXT_SCALES, #ENERGY_UNITS, #RATE_UNITS),
--    gap = 1,
--    --padding = 1,
--    z = 10,
--})

-- Monitor text scale selector

--local sampleIntervalDropdown = settingsRow:addDropdown({
local sampleIntervalDropdown = mainPage:addDropdown({
    position = "absolute",
    --x = "{parent.width - (5+4 + 1 + 5+2 + 1 + 3+1 + 1 + 4 + 1 + 4) + 1}", -- Hz
    x = "{parent.width - (5+3 + 1 + 5+2 + 1 + 3+1 + 1 + 4 + 1 + 4) + 1}", -- s
    y = "{parent.y + 1}",
    --width = 5+4, -- Hz
    width = 5+3, -- s
    text = tostring(FORMATTED_SAMPLE_INTERVAL_OPTIONS[sampleIntervalIndex:get()]),
    dropHeight = #FORMATTED_SAMPLE_INTERVAL_OPTIONS,
    items = FORMATTED_SAMPLE_INTERVAL_OPTIONS,
    background = C.muted,
})

--local historyLengthDropdown = settingsRow:addDropdown({
local historyLengthDropdown = mainPage:addDropdown({
    position = "absolute",
    x = "{parent.width - (5+2 + 1 + 3+1 + 1 + 4 + 1 + 4) + 1}",
    y = "{parent.y + 1}",
    width = 5 + 2,
    text = tostring(FORMATTED_HISTORY_LENGTH_OPTIONS[historyLengthIndex:get()]),
    dropHeight = #FORMATTED_HISTORY_LENGTH_OPTIONS,
    items = FORMATTED_HISTORY_LENGTH_OPTIONS,
    background = C.muted,
})

--local monitorTextScaleDropdown = settingsRow:addDropdown({
local monitorTextScaleDropdown = mainPage:addDropdown({
    position = "absolute",
    x = "{parent.width - (3+1 + 1 + 4 + 1 + 4) + 1}",
    y = "{parent.y + 1}",
    width = 3 + 1,
    text = tostring(FORMATTED_SCALED_MONITOR_TEXT_SCALES[monitorTextScaleIndex:get()]),
    dropHeight = #FORMATTED_SCALED_MONITOR_TEXT_SCALES,
    items = FORMATTED_SCALED_MONITOR_TEXT_SCALES,
    background = C.muted,
})

monitorTextScaleDropdown:bind("selected", monitorTextScaleIndex)
monitorTextScaleDropdown:onSelect(function(self, index, item)
    if monitor then
        monitor.setTextScale(MONITOR_TEXT_SCALES[index])
    end
    persistUserSettings()
end)

-- Unit selectors

--local energyUnitDropdown = settingsRow:addDropdown({
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

--local rateUnitDropdown = settingsRow:addDropdown({
local rateUnitDropdown = mainPage:addDropdown({
    position = "absolute",
    x = "{parent.width - (4) + 1}",
    y = "{parent.y + 1}",
    width = 4,
    text = RATE_UNITS[rateUnitIndex:get()],
    dropHeight = #RATE_UNITS,
    items = RATE_UNITS,
    background = C.muted,
})

sampleIntervalDropdown:bind("selected", sampleIntervalIndex)
historyLengthDropdown:bind("selected", historyLengthIndex)

sampleIntervalDropdown:onSelect(function()
    trimHistoryToCurrentSettings()
    persistUserSettings()
end)

historyLengthDropdown:onSelect(function()
    trimHistoryToCurrentSettings()
    persistUserSettings()
end)

energyUnitDropdown:bind("selected", energyUnitIndex)
rateUnitDropdown:bind("selected", rateUnitIndex)

energyUnitDropdown:onSelect(function()
    persistUserSettings()
end)

rateUnitDropdown:onSelect(function()
    persistUserSettings()
end)

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
-- Graph Panel (with integrated footer content)
------------------------------------------------------------

local graphPanelContainer = contentPanel:addColumn({
    width = basalt.fill(),
    height = basalt.fill(),
    --gap = 1,
    --padding = 1,
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
    text = basalt.computed(function()
        return "RATE HISTORY - " .. historyLengthSeconds:get() .. " SECONDS"
    end),
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

local clearHistoryButton = graphButtons:addButton({
    width = basalt.auto(),
    height = 1,
    text = "CLEAR",
    foreground = C.text,
    background = C.muted,
})

graph = graphPanelContainer:addPixelGraph({
    width = basalt.fill(),
    height = basalt.fill(),
    minValue = 0,
    maxValue = 100,
})

setupGraphDisplay()

fillGraphFromHistory()

toggleVisibilityInputGraph:onClick(function()
    showInputGraph:set(not showInputGraph:get())
    graph:setSeriesVisible("input", showInputGraph:get())
    updateGraphBounds()
    persistUserSettings()
end)

toggleVisibilityOutputGraph:onClick(function()
    showOutputGraph:set(not showOutputGraph:get())
    graph:setSeriesVisible("output", showOutputGraph:get())
    updateGraphBounds()
    persistUserSettings()
end)

clearHistoryButton:onClick(function()
    clearHistory()
end)

------------------------------------------------------------
-- Graph Footer
------------------------------------------------------------

local graphFooter = graphPanelContainer:addColumn({
    width = basalt.fill(),
    height = 3,
})

-- Average

local graphFooterAverage = graphFooter:addRow({
    width = basalt.fill(),
    height = 1,
    gap = 1,
    --padding = 1,
    justify = "spaceBetween",
})

graphFooterAverage:addLabel({
    width = basalt.auto(),
    text = basalt.computed(function()
        return "" .. historyLengthSeconds:get() .. "S AVG"
    end),
    foreground = C.accent,
})

graphFooterAverage:addLabel({
    width = 2 + 1 + DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    text = basalt.computed(function()
        return "IN " .. averageInputRateText()
    end),
    foreground = C.input,
})

graphFooterAverage:addLabel({
    width = 3 + 1 + DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    text = basalt.computed(function()
        return "OUT " .. averageOutputRateText()
    end),
    foreground = C.output,
})

local graphFooterAverageNet = graphFooterAverage:addRow({
    width = 3 + 1 + DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    height = 1,
    gap = 1,
})

graphFooterAverageNet:addLabel({
    width = 3,
    text = "NET",
    foreground = C.net,
})

graphFooterAverageNet:addLabel({
    width = DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    text = basalt.computed(function()
        return averageNetRateText()
    end),
    foreground = basalt.computed(function()
        return averageNet:get() >= 0 and C.input or C.output
    end),
})

graphFooterAverage:addLabel({
    width = basalt.computed(function()
        return 2 * #tostring(historyLength:get()) + 1
    end),
    text = basalt.computed(function()
        local selectedHistoryLength = historyLength:get()
        local l = #tostring(selectedHistoryLength)
        return string.format("%"..l.."d/%d", #inputHistory, selectedHistoryLength)
    end),
    foreground = C.muted,
})

-- Maximum

local graphFooterMaximum = graphFooter:addRow({
    width = basalt.fill(),
    height = 1,
    gap = 1,
    --padding = 1,
    justify = "spaceBetween",
})

graphFooterMaximum:addLabel({
    width = basalt.auto(),
    text = basalt.computed(function()
        return "" .. historyLengthSeconds:get() .. "S MAX"
    end),
    foreground = C.accent,
})

graphFooterMaximum:addLabel({
    width = 2 + 1 + DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    text = basalt.computed(function()
        return "IN " .. maximumInputRateText()
    end),
    foreground = C.input,
})

graphFooterMaximum:addLabel({
    width = 3 + 1 + DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    text = basalt.computed(function()
        return "OUT " .. maximumOutputRateText()
    end),
    foreground = C.output,
})

local graphFooterMaximumNet = graphFooterMaximum:addRow({
    width = 3 + 1 + DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    height = 1,
    gap = 1,
})

graphFooterMaximumNet:addLabel({
    width = 3,
    text = "NET",
    foreground = C.net,
})

graphFooterMaximumNet:addLabel({
    width = DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    text = basalt.computed(function()
        return maximumNetRateText()
    end),
    foreground = basalt.computed(function()
        return maximumNet:get() >= 0 and C.input or C.output
    end),
})

graphFooterMaximum:addLabel({
    width = basalt.computed(function()
        return 2 * #tostring(historyLength:get()) + 1
    end),
    text = basalt.computed(function()
        local selectedHistoryLength = historyLength:get()
        local l = #tostring(selectedHistoryLength)
        return string.format("%"..l.."d/%d", #inputHistory, selectedHistoryLength)
    end),
    foreground = C.muted,
})

-- Minimum

local graphFooterMinimum = graphFooter:addRow({
    width = basalt.fill(),
    height = 1,
    gap = 1,
    --padding = 1,
    justify = "spaceBetween",
})

graphFooterMinimum:addLabel({
    width = basalt.auto(),
    text = basalt.computed(function()
        return "" .. historyLengthSeconds:get() .. "S MIN"
    end),
    foreground = C.accent,
})

graphFooterMinimum:addLabel({
    width = 2 + 1 + DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    text = basalt.computed(function()
        return "IN " .. minimumInputRateText()
    end),
    foreground = C.input,
})

graphFooterMinimum:addLabel({
    width = 3 + 1 + DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    text = basalt.computed(function()
        return "OUT " .. minimumOutputRateText()
    end),
    foreground = C.output,
})

local graphFooterMinimumNet = graphFooterMinimum:addRow({
    width = 3 + 1 + DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    height = 1,
    gap = 1,
})

graphFooterMinimumNet:addLabel({
    width = 3,
    text = "NET",
    foreground = C.net,
})

graphFooterMinimumNet:addLabel({
    width = DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    text = basalt.computed(function()
        return minimumNetRateText()
    end),
    foreground = basalt.computed(function()
        return minimumNet:get() >= 0 and C.input or C.output
    end),
})

graphFooterMinimum:addLabel({
    width = basalt.computed(function()
        return 2 * #tostring(historyLength:get()) + 1
    end),
    text = basalt.computed(function()
        local selectedHistoryLength = historyLength:get()
        local l = #tostring(selectedHistoryLength)
        return string.format("%"..l.."d/%d", #inputHistory, selectedHistoryLength)
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
        local delay = sampleIntervalSeconds:get() - sampleIntervalDelaySeconds
        sampleIntervalDelayMs:set(math.floor(sampleIntervalDelaySeconds * 1000))
        sleep(math.max(0, delay))
    end
end)

------------------------------------------------------------
-- Start Basalt
------------------------------------------------------------

basalt.run()

print("Energy Core Monitor stopped.")
