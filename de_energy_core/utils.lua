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
-- forceSign – prepend "+" for positive numbers (aligns signed columns).
-- forceSpace – reserve sign space without actually printing a sign.
function M.si(n, unit, forceSign, forceSpace)
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
    local fmt = forceSign and "%+7.2f %s%s"
    or forceSpace and "%7.2f %s%s"
    or "%6.2f %s%s"
    return string.format(fmt, n, prefixes[i], unit or "")
end

-- Current wall-clock Unix timestamp (integer seconds).
function M.getUnixTimestamp()
    return os.time(os.date("*t"))
end

return M
