-- de_energy_core/config.lua
-- All configuration constants for the DE Energy Core Monitor.
-- Pure data: no external dependencies, no business logic.

------------------------------------------------------------
-- Sampling / History
------------------------------------------------------------

local SAMPLE_INTERVAL_OPTIONS = { 0.25, 0.5, 1, 5, 10 }
local HISTORY_LENGTH_OPTIONS = { 10, 60, 120, 300, 600 }

local FORMATTED_SAMPLE_INTERVAL_OPTIONS = {}
for _, v in ipairs(SAMPLE_INTERVAL_OPTIONS) do
    FORMATTED_SAMPLE_INTERVAL_OPTIONS[#FORMATTED_SAMPLE_INTERVAL_OPTIONS + 1] = string.format("%2.2f s", v)
end

local FORMATTED_HISTORY_LENGTH_OPTIONS = {}
for _, v in ipairs(HISTORY_LENGTH_OPTIONS) do
    FORMATTED_HISTORY_LENGTH_OPTIONS[#FORMATTED_HISTORY_LENGTH_OPTIONS + 1] = string.format("%3d s", v)
end

-- Upper bound on samples stored (worst case: shortest interval × longest window)
local MAX_HISTORY_LENGTH = math.ceil(
    HISTORY_LENGTH_OPTIONS[#HISTORY_LENGTH_OPTIONS] / SAMPLE_INTERVAL_OPTIONS[1]
)

local function findIndex(list, value, defaultIndex)
    for i, v in ipairs(list) do
        if v == value then
            return i
        end
    end
    return defaultIndex or 1
end

local DEFAULT_SAMPLE_INTERVAL_SECONDS = 1
local DEFAULT_HISTORY_LENGTH_SECONDS = 60
local DEFAULT_SAMPLE_INTERVAL_INDEX = findIndex(SAMPLE_INTERVAL_OPTIONS, DEFAULT_SAMPLE_INTERVAL_SECONDS)
local DEFAULT_HISTORY_LENGTH_INDEX = findIndex(HISTORY_LENGTH_OPTIONS, DEFAULT_HISTORY_LENGTH_SECONDS)

------------------------------------------------------------
-- Fixed display widths (used to right-align number columns)
------------------------------------------------------------

local DEFAULT_PERCENTAGE_NUMBER_LENGTH = #"100.00 %"
local DEFAULT_ENERGY_NUMBER_LENGTH = #"+999.99 kRF"
local DEFAULT_ENERGY_RATE_NUMBER_LENGTH = #"+999.99 kRF/t"
local DEFAULT_DATETIME_STRING_LENGTH = #"2026-08-25 16:14:33"

------------------------------------------------------------
-- Monitor text scales
------------------------------------------------------------

local MONITOR_TEXT_SCALES = { 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0 }
local SCALED_MONITOR_TEXT_SCALES = {}
local FORMATTED_SCALED_MONITOR_TEXT_SCALES = {}

for i, v in ipairs(MONITOR_TEXT_SCALES) do
-- Multiply by 2 so dropdown entries are whole numbers (e.g. "x1", "x2", ...)
    SCALED_MONITOR_TEXT_SCALES[i] = v * 2
    FORMATTED_SCALED_MONITOR_TEXT_SCALES[i] = string.format("x%d", v * 2)
end

local DEFAULT_MONITOR_TEXT_SCALE = 1.0
local DEFAULT_MONITOR_TEXT_SCALE_INDEX = findIndex(MONITOR_TEXT_SCALES, DEFAULT_MONITOR_TEXT_SCALE)

------------------------------------------------------------
-- Peripheral type names (tried in order)
------------------------------------------------------------

local ENERGY_CORE_TYPES = { "draconic_rf_storage", "draconicRfStorage", "energy_pylon", "energyPylon" }

------------------------------------------------------------
-- Energy units
------------------------------------------------------------

local ENERGY_UNITS = { "RF", "FE", "OP", "AE", "EU" }
local ENERGY_UNIT_FACTORS = { RF = 1, FE = 1, OP = 1, AE = 2, EU = 16 }

local DEFAULT_ENERGY_UNIT = "RF"
local DEFAULT_ENERGY_UNIT_INDEX = findIndex(ENERGY_UNITS, DEFAULT_ENERGY_UNIT)

------------------------------------------------------------
-- Rate units
------------------------------------------------------------

local RATE_UNITS = { "/t", "/s", "/m", "/h", "/d" }
local RATE_UNIT_FACTORS = {
    ["/t"] = 1,
    ["/s"] = 20,
    ["/m"] = 20 * 60,
    ["/h"] = 20 * 60 * 60,
    ["/d"] = 20 * 60 * 60 * 24,
}

local DEFAULT_RATE_UNIT = "/t"
local DEFAULT_RATE_UNIT_INDEX = findIndex(RATE_UNITS, DEFAULT_RATE_UNIT)

------------------------------------------------------------
-- Draconic Evolution energy core tier capacities (RF → tier)
------------------------------------------------------------

local TIER_CAPACITY = {
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
-- Persistence file paths
------------------------------------------------------------

local SETTINGS_FILE_NAME = "de_energy_core_monitor.settings"
local SETTINGS_PATH = "/" .. SETTINGS_FILE_NAME
local HISTORY_FILE_NAME = "de_energy_core_monitor.history"
local HISTORY_PATH = "/" .. HISTORY_FILE_NAME

------------------------------------------------------------
-- UI colors
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
-- Default user settings
------------------------------------------------------------

local DEFAULT_USER_SETTINGS = {
    monitorTextScaleIndex = DEFAULT_MONITOR_TEXT_SCALE_INDEX,
    energyUnitIndex = DEFAULT_ENERGY_UNIT_INDEX,
    rateUnitIndex = DEFAULT_RATE_UNIT_INDEX,
    sampleIntervalIndex = DEFAULT_SAMPLE_INTERVAL_INDEX,
    historyLengthIndex = DEFAULT_HISTORY_LENGTH_INDEX,
    showInputGraph = true,
    showOutputGraph = true,
}

------------------------------------------------------------

return {
    SAMPLE_INTERVAL_OPTIONS = SAMPLE_INTERVAL_OPTIONS,
    HISTORY_LENGTH_OPTIONS = HISTORY_LENGTH_OPTIONS,
    FORMATTED_SAMPLE_INTERVAL_OPTIONS = FORMATTED_SAMPLE_INTERVAL_OPTIONS,
    FORMATTED_HISTORY_LENGTH_OPTIONS = FORMATTED_HISTORY_LENGTH_OPTIONS,
    MAX_HISTORY_LENGTH = MAX_HISTORY_LENGTH,
    PERCENTAGE_NUMBER_LENGTH = DEFAULT_PERCENTAGE_NUMBER_LENGTH,
    ENERGY_NUMBER_LENGTH = DEFAULT_ENERGY_NUMBER_LENGTH,
    ENERGY_RATE_NUMBER_LENGTH = DEFAULT_ENERGY_RATE_NUMBER_LENGTH,
    DATETIME_STRING_LENGTH = DEFAULT_DATETIME_STRING_LENGTH,
    MONITOR_TEXT_SCALES = MONITOR_TEXT_SCALES,
    SCALED_MONITOR_TEXT_SCALES = SCALED_MONITOR_TEXT_SCALES,
    FORMATTED_SCALED_MONITOR_TEXT_SCALES = FORMATTED_SCALED_MONITOR_TEXT_SCALES,
    ENERGY_CORE_TYPES = ENERGY_CORE_TYPES,
    ENERGY_UNITS = ENERGY_UNITS,
    ENERGY_UNIT_FACTORS = ENERGY_UNIT_FACTORS,
    RATE_UNITS = RATE_UNITS,
    RATE_UNIT_FACTORS = RATE_UNIT_FACTORS,
    TIER_CAPACITY = TIER_CAPACITY,
    SETTINGS_FILE_NAME = SETTINGS_FILE_NAME,
    SETTINGS_PATH = SETTINGS_PATH,
    HISTORY_FILE_NAME = HISTORY_FILE_NAME,
    HISTORY_PATH = HISTORY_PATH,
    C = C,
    DEFAULT_USER_SETTINGS = DEFAULT_USER_SETTINGS,
    findIndex = findIndex,
}

