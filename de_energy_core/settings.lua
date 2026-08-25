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
        monitorTextScale = const.MONITOR_TEXT_SCALES[utils.findIndex(const.MONITOR_TEXT_SCALES, s.monitorTextScale)],
        energyUnit = const.ENERGY_UNITS[utils.findIndex(const.ENERGY_UNITS, s.energyUnit)],
        rateUnit = const.RATE_UNITS[utils.findIndex(const.RATE_UNITS, s.rateUnit)],
        sampleInterval = const.SAMPLE_INTERVAL_OPTIONS[utils.findIndex(const.SAMPLE_INTERVAL_OPTIONS, s.sampleInterval)],
        graphRefreshInterval = const.GRAPH_REFRESH_INTERVAL_OPTIONS[
            utils.findIndex(const.GRAPH_REFRESH_INTERVAL_OPTIONS, s.graphRefreshInterval)
        ],
        historyLength = const.HISTORY_LENGTH_OPTIONS[utils.findIndex(const.HISTORY_LENGTH_OPTIONS, s.historyLength)],
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
