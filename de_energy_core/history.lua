-- de_energy_core/history.lua
-- Manages the rolling sample array and file persistence.
--
-- IMPORTANT: this module is intentionally unaware of Basalt / PixelGraph.
-- All graph rendering is handled by the caller (de_energy_core_monitor.lua).
--
-- Usage:
--   local history = require("history")
--   history.init(historyLength, historyLengthSeconds) -- pass basalt signals
--   history.load()
--   history.save() -- flush sanitized state back to disk on startup
--
-- After init, use history.samples for the live array.
-- Always access it through the module table (history.samples), never cache
-- it in a local variable, because clear() replaces the table reference.

local const = require("constants")
local utils = require("utils")

local M = {}

-- Public sample array. Each entry:
--   { timestamp = int, energy = number, maxEnergy = number, input = number, output = number, transfer = number }
M.samples = {}

-- Basalt signal references set by M.init(). Required before any other call.
local _capacity
local _cutoffThresholdSeconds

-- Tracks the os.clock() time of the last successful disk write.
-- Initialised to -infinity so the very first maybeSave() always writes.
local _lastSaveTime = -math.huge

------------------------------------------------------------
-- Initialisation
------------------------------------------------------------

-- Must be called once after the signals have been created, before load().
function M.init(capacity, cutoffThresholdSeconds)
    _capacity = capacity
    _cutoffThresholdSeconds = cutoffThresholdSeconds
end

------------------------------------------------------------
-- Private helpers
------------------------------------------------------------

local function sanitizeEntries(entries, nowTs)
-- Validate, filter to the current time window, sort, and cap length.
    local result = {}
    --local cutoff = nowTs - _cutoffThresholdSeconds:get()
    local maxLen = math.min(_capacity:get(), const.MAX_HISTORY_ELEMENTS)

    if type(entries) ~= "table" then
        return result
    end

    for _, e in ipairs(entries) do
        local t = type(e) == "table" and tonumber(e.timestamp) or nil
        --if t and t >= cutoff and t <= nowTs then
        result[#result + 1] = {
            timestamp = t,
            energy = tonumber(e.energy) or 0,
            maxEnergy = tonumber(e.maxEnergy) or 0,
            input = tonumber(e.input) or 0,
            output = tonumber(e.output) or 0,
            transfer = tonumber(e.transfer) or 0,
        }
    --end
    end

    table.sort(result, function(a, b) return a.timestamp < b.timestamp
    end)

    while #result > maxLen do
        table.remove(result, 1)
    end
    return result
end

------------------------------------------------------------
-- Persistence
------------------------------------------------------------

-- Load M.samples from disk, replacing whatever is currently held.
-- Accepts both the current file format ({ samples }) and the legacy
-- format ({ input/inputHistory, output/outputHistory }) for backward
-- compatibility (energy/maxEnergy will default to 0 in that case).
function M.load()
    local handle = fs.open(const.HISTORY_PATH, "r")
    if not handle then
        return
    end

    local content = handle.readAll()
    handle.close()

    if not content or content == "" then
        return
    end

    local ok, data = pcall(textutils.unserialize, content)
    if not ok or type(data) ~= "table" then
        print('Failed to parse history from "' .. const.HISTORY_PATH .. '", starting fresh.')
        return
    end

    local now = utils.getUnixTimestamp()

    if data.samples then
    -- Current format.
        M.samples = sanitizeEntries(data.samples, now)
    elseif data.input or data.inputHistory then
    -- Legacy two-array format: merge by index (energy/maxEnergy unknown).
        local inp = data.input or data.inputHistory or {}
        local out = data.output or data.outputHistory or {}
        local len = math.min(#inp, #out)
        --local cutoff = now - _cutoffThresholdSeconds:get()
        local merged = {}
        for i = 1, len do
            local t = tonumber(inp[i].timestamp)
            --if t and t >= cutoff and t <= now then
            merged[#merged + 1] = {
                timestamp = t,
                energy = 0,
                maxEnergy = 0,
                input = tonumber(inp[i].value) or 0,
                output = tonumber(out[i].value) or 0,
                transfer = (tonumber(inp[i].value) or 0) - (tonumber(out[i].value) or 0),
            }
        --end
        end
        M.samples = merged
    end
end

-- Persist M.samples to disk unconditionally.
-- Returns true on success, false on failure.
function M.save()
    local handle = fs.open(const.HISTORY_PATH, "w")
    if not handle then
        print('Failed to open "' .. const.HISTORY_PATH .. '" for writing.')
        return false
    end
    handle.write(textutils.serialize({ samples = M.samples }))
    handle.close()
    _lastSaveTime = os.clock()
    return true
end

-- Persist M.samples to disk only when the configured throttle interval
-- has elapsed since the last write. Returns true if a write was performed,
-- false if the call was skipped or the write failed.
function M.maybeSave()
    if os.clock() - _lastSaveTime < const.HISTORY_SAVE_INTERVAL_SECONDS then
        return false
    end
    return M.save()
end

------------------------------------------------------------
-- Mutation
------------------------------------------------------------

-- Append one sample and trim to the current history-length window.
function M.push(timestamp, energy, maxEnergy, input, output, transfer)
    return M.append({
        timestamp = timestamp,
        energy = energy,
        maxEnergy = maxEnergy,
        input = input,
        output = output,
        transfer = transfer,
    })
end

-- Append one prebuilt sample object and trim to the current limits.
function M.append(sample)
    if type(sample) ~= "table" then
        return false
    end

    local timestamp = tonumber(sample.timestamp) or utils.getUnixTimestamp()
    --local cutoff = timestamp - _cutoffThresholdSeconds:get()
    local maxLen = math.min(_capacity:get(), const.MAX_HISTORY_ELEMENTS)
    local input = tonumber(sample.input) or 0
    local output = tonumber(sample.output) or 0

    M.samples[#M.samples + 1] = {
        timestamp = timestamp,
        energy = tonumber(sample.energy) or 0,
        maxEnergy = tonumber(sample.maxEnergy) or 0,
        input = input,
        output = output,
        transfer = tonumber(sample.transfer) or (input - output),
    }
    while #M.samples > maxLen do
        table.remove(M.samples, 1)
    end
    --while #M.samples > 0 and M.samples[1].timestamp < cutoff do
    --    table.remove(M.samples, 1)
    --end
    return true
end

-- Drop all entries outside the current settings window and persist.
-- The caller should redraw the graph after this call.
function M.trim()
    local maxLen = math.min(_capacity:get(), const.MAX_HISTORY_ELEMENTS)
    --local cutoff = utils.getUnixTimestamp() - _cutoffThresholdSeconds:get()

    while #M.samples > maxLen do
        table.remove(M.samples, 1)
    end
    --while #M.samples > 0 and M.samples[1].timestamp < cutoff do
    --    table.remove(M.samples, 1)
    --end
    M.save()
end

-- Replace the array with an empty table and persist.
-- The caller should clear / redraw the graph after this call.
function M.clear()
    M.samples = {}
    M.save()
end

------------------------------------------------------------
-- Statistics (pure read-only helpers over M.samples)
--
-- `field` is the sample key to aggregate: "input", "output",
-- "energy", or "maxEnergy".
------------------------------------------------------------

function M.avg(field)
    if #M.samples == 0 then
        return 0
    end
    local total = 0
    for _, s in ipairs(M.samples) do
        total = total + (s[field] or 0)
    end
    return total / #M.samples
end

function M.max(field)
    if #M.samples == 0 then
        return 0
    end
    local m = 0
    for _, s in ipairs(M.samples) do
        m = math.max(m, s[field] or 0)
    end
    return m
end

function M.min(field)
    if #M.samples == 0 then
        return 0
    end
    local m = math.huge
    for _, s in ipairs(M.samples) do
        m = math.min(m, s[field] or 0)
    end
    return m
end

return M
