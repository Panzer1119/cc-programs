-- de_energy_core/history.lua
-- Manages the rolling input/output sample arrays and their file persistence.
--
-- IMPORTANT: this module is intentionally unaware of Basalt / PixelGraph.
-- All graph rendering is handled by the caller (de_energy_core_monitor.lua).
--
-- Usage:
--   local history = require("history")
--   history.init(historyLength, historyLengthSeconds) -- pass basalt signals
--   history.load()
--   history.save() -- flush initial state to disk
--
-- After init, use history.input and history.output for the live arrays.
-- Always access them through the module table (history.input), never cache
-- them in a local variable, because clear() replaces the table references.

local const = require("constants")
local utils = require("utils")

local M = {}

-- Public sample arrays. Each entry: { timestamp = int, value = number }.
M.input = {}
M.output = {}

-- Basalt signal references set by M.init(). Required before any other call.
local _historyLength
local _historyLengthSeconds

------------------------------------------------------------
-- Initialisation
------------------------------------------------------------

-- Must be called once after the signals have been created, before load().
function M.init(historyLength, historyLengthSeconds)
    _historyLength = historyLength
    _historyLengthSeconds = historyLengthSeconds
end

------------------------------------------------------------
-- Private helpers
------------------------------------------------------------

local function normalizePair(inp, out)
-- Trim the longer array from the front so both stay the same length.
    local len = math.min(#inp, #out)
    while #inp > len do
        table.remove(inp, 1)
    end
    while #out > len do
        table.remove(out, 1)
    end
    return inp, out
end

local function sanitizeEntries(entries, nowTs)
-- Validate, filter to the current time window, sort, and cap length.
    local result = {}
    local cutoff = nowTs - _historyLengthSeconds:get()
    local maxLen = _historyLength:get()

    if type(entries) ~= "table" then
        return result
    end

    for _, e in ipairs(entries) do
        local t = type(e) == "table" and tonumber(e.timestamp) or nil
        local v = type(e) == "table" and tonumber(e.value) or nil
        if t and v and t >= cutoff and t <= nowTs then
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

------------------------------------------------------------
-- Persistence
------------------------------------------------------------

-- Load M.input / M.output from disk, replacing whatever is currently held.
-- Accepts both the current file format ({ input, output }) and the legacy
-- format ({ inputHistory, outputHistory }) for backward compatibility.
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
    M.input, M.output = normalizePair(
        sanitizeEntries(data.input or data.inputHistory, now),
        sanitizeEntries(data.output or data.outputHistory, now)
    )
end

-- Persist M.input / M.output to disk.
-- Returns true on success, false on failure.
function M.save()
    local handle = fs.open(const.HISTORY_PATH, "w")
    if not handle then
        print('Failed to open "' .. const.HISTORY_PATH .. '" for writing.')
        return false
    end
    handle.write(textutils.serialize({ input = M.input, output = M.output }))
    handle.close()
    return true
end

------------------------------------------------------------
-- Mutation
------------------------------------------------------------

-- Append one paired sample (iVal = input RF/t, oVal = output RF/t) and
-- trim both arrays to the current history-length window.
function M.push(timestamp, iVal, oVal)
    local cutoff = timestamp - _historyLengthSeconds:get()
    local maxLen = _historyLength:get()

    local function pushOne(h, v)
        h[#h + 1] = { timestamp = timestamp, value = v }
        while #h > maxLen do
            table.remove(h, 1)
        end
        while #h > 0 and h[1].timestamp < cutoff do
            table.remove(h, 1)
        end
    end

    pushOne(M.input, iVal)
    pushOne(M.output, oVal)
end

-- Drop all entries outside the current settings window and re-align both
-- arrays. Persists the result to disk.
-- The caller should redraw the graph after this call.
function M.trim()
    local maxLen = _historyLength:get()
    local cutoff = utils.getUnixTimestamp() - _historyLengthSeconds:get()

    while #M.input > maxLen do
        table.remove(M.input, 1)
    end
    while #M.output > maxLen do
        table.remove(M.output, 1)
    end
    while #M.input > 0 and M.input[1].timestamp < cutoff do
        table.remove(M.input, 1)
    end
    while #M.output > 0 and M.output[1].timestamp < cutoff do
        table.remove(M.output, 1)
    end

    M.input, M.output = normalizePair(M.input, M.output)
    M.save()
end

-- Replace both arrays with empty tables and persist.
-- The caller should clear / redraw the graph after this call.
function M.clear()
    M.input = {}
    M.output = {}
    M.save()
end

------------------------------------------------------------
-- Statistics (pure read-only helpers over a single history array)
------------------------------------------------------------

function M.avg(h)
    if #h == 0 then
        return 0
    end
    local total = 0
    for _, e in ipairs(h) do
        total = total + e.value
    end
    return total / #h
end

function M.max(h)
    if #h == 0 then
        return 0
    end
    local m = 0
    for _, e in ipairs(h) do
        m = math.max(m, e.value)
    end
    return m
end

function M.min(h)
    if #h == 0 then
        return 0
    end
    local m = math.huge
    for _, e in ipairs(h) do
        m = math.min(m, e.value)
    end
    return m
end

return M
