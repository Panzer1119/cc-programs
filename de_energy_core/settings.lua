-- de_energy_core/settings.lua
-- Handles loading and saving the application settings to/from disk.
-- Validation/clamping is done on load so the rest of the program always
-- receives well-formed values regardless of what is stored on disk.

local const = require("constants")
local utils = require("utils")

local M = {}

-- Validate and clamp a raw settings table, filling in defaults for any
-- missing or out-of-range keys.
local function sanitize(s)
    s = type(s) == "table" and s or {}
    local d = const.DEFAULT_SETTINGS
    return {
        monitorTextScaleIndex = utils.clamp(tonumber(s.monitorTextScaleIndex) or d.monitorTextScaleIndex, 1, #const.MONITOR_TEXT_SCALES),
        energyUnitIndex = utils.clamp(tonumber(s.energyUnitIndex) or d.energyUnitIndex, 1, #const.ENERGY_UNITS),
        rateUnitIndex = utils.clamp(tonumber(s.rateUnitIndex) or d.rateUnitIndex, 1, #const.RATE_UNITS),
        sampleIntervalIndex = utils.clamp(tonumber(s.sampleIntervalIndex) or d.sampleIntervalIndex, 1, #const.SAMPLE_INTERVAL_OPTIONS),
        historyLengthIndex = utils.clamp(tonumber(s.historyLengthIndex) or d.historyLengthIndex, 1, #const.HISTORY_LENGTH_OPTIONS),
        showInputGraph = s.showInputGraph == nil and d.showInputGraph or not not s.showInputGraph,
        showOutputGraph = s.showOutputGraph == nil and d.showOutputGraph or not not s.showOutputGraph,
    }
end

-- Load settings from disk and return a sanitized table.
-- Falls back to defaults silently when the file is absent, and with a
-- diagnostic message when the file exists but cannot be parsed.
function M.load()
    local handle = fs.open(const.SETTINGS_PATH, "r")
    if not handle then
        return sanitize({})
    end

    local content = handle.readAll()
    handle.close()

    if not content or content == "" then
        return sanitize({})
    end

    local ok, raw = pcall(textutils.unserialize, content)
    if not ok or type(raw) ~= "table" then
        print('Failed to parse settings from "' .. const.SETTINGS_PATH .. '", using defaults.')
        return sanitize({})
    end

    return sanitize(raw)
end

-- Persist a settings table to disk. The caller is responsible for
-- constructing the table from the current signal values.
-- Returns true on success, false on failure.
function M.save(values)
    local handle = fs.open(const.SETTINGS_PATH, "w")
    if not handle then
        print('Failed to open "' .. const.SETTINGS_PATH .. '" for writing.')
        return false
    end
    handle.write(textutils.serialize(values))
    handle.close()
    return true
end

return M
