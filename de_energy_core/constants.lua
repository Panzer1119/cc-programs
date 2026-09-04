-- de_energy_core/constants.lua
-- All named constants. No mutable state, no side effects.
-- Requires utils.lua only for findIndex (used to compute default indices).

local utils = require("utils")

local M = {}

------------------------------------------------------------
-- Sampling / History
------------------------------------------------------------

M.SAMPLE_INTERVAL_SECONDS_OPTIONS = { 0.25, 0.5, 1, 5, 10 }
M.HISTORY_CAPACITY_OPTIONS = { 100, 200, 500, 1000 }
M.HISTORY_CUTOFF_THRESHOLD_SECONDS_OPTIONS = { 10, 60, 120, 300, 600 }
M.GRAPH_REFRESH_INTERVAL_SECONDS_OPTIONS = { 0.25, 0.5, 1, 2, 5, 10 }
M.GRAPH_WINDOW_SECONDS_OPTIONS = { 10, 60, 120, 300, 600 }

M.FORMATTED_SAMPLE_INTERVAL_SECONDS_OPTIONS = {}
for _, v in ipairs(M.SAMPLE_INTERVAL_SECONDS_OPTIONS) do
    M.FORMATTED_SAMPLE_INTERVAL_SECONDS_OPTIONS[#M.FORMATTED_SAMPLE_INTERVAL_SECONDS_OPTIONS + 1] =
        string.format("%5.2f s", v)
end

M.FORMATTED_HISTORY_CAPACITY_OPTIONS = {}
for _, v in ipairs(M.HISTORY_CAPACITY_OPTIONS) do
    M.FORMATTED_HISTORY_CAPACITY_OPTIONS[#M.FORMATTED_HISTORY_CAPACITY_OPTIONS + 1] =
        string.format("%4d", v)
end

M.FORMATTED_HISTORY_CUTOFF_THRESHOLD_SECONDS_OPTIONS = {}
for _, v in ipairs(M.HISTORY_CUTOFF_THRESHOLD_SECONDS_OPTIONS) do
    M.FORMATTED_HISTORY_CUTOFF_THRESHOLD_SECONDS_OPTIONS[#M.FORMATTED_HISTORY_CUTOFF_THRESHOLD_SECONDS_OPTIONS + 1] =
        string.format("%3d s", v)
end

M.FORMATTED_GRAPH_REFRESH_INTERVAL_SECONDS_OPTIONS = {}
for _, v in ipairs(M.GRAPH_REFRESH_INTERVAL_SECONDS_OPTIONS) do
    M.FORMATTED_GRAPH_REFRESH_INTERVAL_SECONDS_OPTIONS[#M.FORMATTED_GRAPH_REFRESH_INTERVAL_SECONDS_OPTIONS + 1] =
        string.format("%5.2f s", v)
end

M.FORMATTED_GRAPH_WINDOW_SECONDS_OPTIONS = {}
for _, v in ipairs(M.GRAPH_WINDOW_SECONDS_OPTIONS) do
    M.FORMATTED_GRAPH_WINDOW_SECONDS_OPTIONS[#M.FORMATTED_GRAPH_WINDOW_SECONDS_OPTIONS + 1] =
        string.format("%3d s", v)
end

M.DEFAULT_SAMPLE_INTERVAL_SECONDS = 0.5
M.DEFAULT_HISTORY_CAPACITY = 1000
M.DEFAULT_HISTORY_CUTOFF_THRESHOLD_SECONDS = 60
M.DEFAULT_GRAPH_REFRESH_INTERVAL_SECONDS = 0.5
M.DEFAULT_GRAPH_WINDOW_SECONDS = 60

M.DEFAULT_SAMPLE_INTERVAL_INDEX = utils.findIndex(M.SAMPLE_INTERVAL_SECONDS_OPTIONS, M.DEFAULT_SAMPLE_INTERVAL_SECONDS)
M.DEFAULT_HISTORY_CAPACITY_INDEX = utils.findIndex(M.HISTORY_CAPACITY_OPTIONS, M.DEFAULT_HISTORY_CAPACITY)
M.DEFAULT_HISTORY_CUTOFF_THRESHOLD_INDEX =
    utils.findIndex(M.HISTORY_CUTOFF_THRESHOLD_SECONDS_OPTIONS, M.DEFAULT_HISTORY_CUTOFF_THRESHOLD_SECONDS)
M.DEFAULT_GRAPH_REFRESH_INTERVAL_INDEX =
    utils.findIndex(M.GRAPH_REFRESH_INTERVAL_SECONDS_OPTIONS, M.DEFAULT_GRAPH_REFRESH_INTERVAL_SECONDS)
M.DEFAULT_GRAPH_WINDOW_SECONDS_INDEX = utils.findIndex(M.GRAPH_WINDOW_SECONDS_OPTIONS, M.DEFAULT_GRAPH_WINDOW_SECONDS)

-- Minimum seconds between automatic history saves (throttles disk I/O).
-- Explicit saves triggered by trim() / clear() are always written immediately.
M.DEFAULT_HISTORY_SAVE_INTERVAL_SECONDS = 3

-- Theoretical window size implied by settings options (before the hard cap).
M.MAX_GRAPH_POINT_COUNT = math.ceil(
    M.GRAPH_WINDOW_SECONDS_OPTIONS[#M.GRAPH_WINDOW_SECONDS_OPTIONS] /
    M.GRAPH_REFRESH_INTERVAL_SECONDS_OPTIONS[1]
)
-- hard cap on history length to avoid OOM
M.MAX_HISTORY_CAPACITY = 10000

------------------------------------------------------------
-- Display column widths (characters needed for right-aligned fields)
------------------------------------------------------------

M.W_PCT = #"100.00 %"
M.W_ENERGY = #"+999.99 kRF"
M.W_RATE = #"+999.99 kRF/t"
M.W_DATETIME = #"2026-08-25 16:14:33"

------------------------------------------------------------
-- Monitor text scales
------------------------------------------------------------

M.MONITOR_TEXT_SCALES = { 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0 }
M.SCALED_MONITOR_TEXT_SCALES = {}
M.FORMATTED_SCALED_MONITOR_TEXT_SCALES = {}

for i, v in ipairs(M.MONITOR_TEXT_SCALES) do
-- Multiply by 2 so every dropdown entry is a whole number (x1, x2, …).
    M.SCALED_MONITOR_TEXT_SCALES[i] = v * 2
    M.FORMATTED_SCALED_MONITOR_TEXT_SCALES[i] = string.format("x%d", v * 2)
end

M.DEFAULT_MONITOR_TEXT_SCALE = 1.0
M.DEFAULT_MONITOR_TEXT_SCALE_INDEX = utils.findIndex(M.MONITOR_TEXT_SCALES, M.DEFAULT_MONITOR_TEXT_SCALE)

------------------------------------------------------------
-- Peripheral type names (tried in order until one is found)
------------------------------------------------------------

M.ENERGY_CORE_TYPES = { "draconic_rf_storage", "draconicRfStorage", "energy_pylon", "energyPylon" }

------------------------------------------------------------
-- Energy units
------------------------------------------------------------

M.ENERGY_UNITS = { "RF", "FE", "OP", "AE", "EU", "J" }
M.ENERGY_UNIT_FACTORS = { RF = 1, FE = 1, OP = 1, AE = 2, EU = 16, J = 2.5 }

M.DEFAULT_ENERGY_UNIT = "RF"
M.DEFAULT_ENERGY_UNIT_INDEX = utils.findIndex(M.ENERGY_UNITS, M.DEFAULT_ENERGY_UNIT)

------------------------------------------------------------
-- Rate units
------------------------------------------------------------

M.RATE_UNITS = { "/t", "/s", "/m", "/h", "/d" }
M.RATE_UNIT_FACTORS = {
    ["/t"] = 1,
    ["/s"] = 20,
    ["/m"] = 20 * 60,
    ["/h"] = 20 * 60 * 60,
    ["/d"] = 20 * 60 * 60 * 24,
}

M.DEFAULT_RATE_UNIT = "/t"
M.DEFAULT_RATE_UNIT_INDEX = utils.findIndex(M.RATE_UNITS, M.DEFAULT_RATE_UNIT)

------------------------------------------------------------
-- Draconic Evolution energy-core tier capacities (RF → tier number)
------------------------------------------------------------

M.TIER_CAPACITY = {
    [45500000] = 1,
    [273000000] = 2,
    [1640000000] = 3,
    [9880000000] = 4,
    [59300000000] = 5,
    [356000000000] = 6,
    [2140000000000] = 7,
    [-1] = 8, -- effectively infinite
}

------------------------------------------------------------
-- File paths for persistent data
------------------------------------------------------------

M.SETTINGS_PATH = "/de_energy_core_monitor.settings"
M.HISTORY_PATH = "/de_energy_core_monitor.history"

------------------------------------------------------------
-- UI colors
------------------------------------------------------------

M.C = {
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
-- Default settings values
------------------------------------------------------------

M.DEFAULT_SETTINGS = {
    monitorTextScale = M.DEFAULT_MONITOR_TEXT_SCALE,
    energyUnit = M.DEFAULT_ENERGY_UNIT,
    rateUnit = M.DEFAULT_RATE_UNIT,
    sampleIntervalSeconds = M.DEFAULT_SAMPLE_INTERVAL_SECONDS,
    historyCapacity = M.DEFAULT_HISTORY_CAPACITY,
    historyCutoffThresholdSeconds = M.DEFAULT_HISTORY_CUTOFF_THRESHOLD_SECONDS,
    graphRefreshIntervalSeconds = M.DEFAULT_GRAPH_REFRESH_INTERVAL_SECONDS,
    graphWindowSeconds = M.DEFAULT_GRAPH_WINDOW_SECONDS,
    showInputGraph = true,
    showOutputGraph = true,
}

return M
