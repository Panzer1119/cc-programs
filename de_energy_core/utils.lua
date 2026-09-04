-- de_energy_core/utils.lua
-- Pure utility functions with no external dependencies.

local M = {}

-- Clamp `value` to the inclusive range [minimum, maximum].
function M.clamp(value, minimum, maximum)
    if value < minimum then
        return minimum
    end
    if value > maximum then
        return maximum
    end
    return value
end

-- Return the index of the first occurrence of `value` in array `t`,
-- or 1 (a safe fallback) when not found.
function M.findIndex(t, value)
    for i, v in ipairs(t) do
        if v == value then
            return i
        end
    end
    return 1
end

-- Format a number with an SI prefix, e.g. 1 500 000 → " 1.50 M<unit>".
-- Supports sub-unit prefixes (m=milli, u=micro, n=nano, p=pico, f=femto) for
-- values with absolute magnitude < 1.
-- forceSign – prepend "+" for positive numbers (aligns signed columns).
-- forceSpace – reserve sign space without actually printing a sign.
function M.si(n, unit, forceSign, forceSpace)
    if not n then
        return "N/A"
    end
    -- Replace Joules per Second with Watts
    if unit == "J/s" then
        unit = "W"
    end
    -- Prefixes ordered from quecto (10^-30) to quetta (10^30).
    -- Index OFFSET corresponds to the empty prefix (×10^0).
    local prefixes = { "q", "r", "y", "z", "a", "f", "p", "n", "u", "m", "", "k", "M", "G", "T", "P", "E", "Z", "Y", "R", "Q" }
    local OFFSET = 11 -- index of "" (no prefix)
    local i = OFFSET
    if n ~= 0 then
        while math.abs(n) >= 1000 and i < #prefixes do
            n = n / 1000
            i = i + 1
        end
        while math.abs(n) < 1 and i > 1 do
            n = n * 1000
            i = i - 1
        end
    end
    local fmt = forceSign and "%+7.2f %s%s"
    or forceSpace and "%7.2f %s%s"
    or "%6.2f %s%s"
    return string.format(fmt, n, prefixes[i], unit or "")
end

-- Current wall-clock Unix timestamp in seconds.
-- Uses CC:Tweaked's millisecond epoch when available so sub-second sampling
-- intervals can be represented accurately, and falls back to integer seconds
-- in plain Lua environments.
function M.getUnixTimestamp()
    if os.epoch then
        return os.epoch("utc") / 1000
    end
    return os.time(os.date("*t"))
end

--TODO Is this correct?
function M.getClockTick()
    return os.clock() * 20
end

return M
