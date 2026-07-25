-- hnn_models.lua

local M = {}
local dropMap = {}
local itemToMob = {}
local configuredDrops = nil

-- TODO Move this to a common utils file?
local function makeSet(list)
    local set = {}
    for _, v in ipairs(list) do
        set[v] = true
    end
    return set
end

local function scan(inv)
    local models = {}

    for slot in pairs(inv.list()) do
        local detail = inv.getItemDetail(slot)

        if detail then
            models[detail.displayName] = {
                slot = slot,
                detail = detail,
            }
        end
    end

    return models
end

--- Synchronize the datacenter so it contains exactly the requested models.
---
--- storage    Wrapped inventory containing all models.
--- datacenter Wrapped inventory connected to the HNN model port.
--- wanted     Array of mob ids, e.g. {"minecraft:creeper","minecraft:zombie"}
function M.sync(storage, datacenter, wanted)
    local wantedSet = makeSet(wanted)

    local storageName = peripheral.getName(storage)
    local dcName = peripheral.getName(datacenter)

    -- Remove unwanted models.
    local dcModels = scan(datacenter)

    for mob, info in pairs(dcModels) do
        if not wantedSet[mob] then
            datacenter.pushItems(storageName, info.slot)
            print("Removing data model of " .. mob .. " from datacenter")
        end
    end

    -- Refresh after removals.
    dcModels = scan(datacenter)
    local storageModels = scan(storage)

    -- Add missing models.
    for mob in pairs(wantedSet) do
        if not dcModels[mob] then
            local info = storageModels[mob]

            if not info then
                error(("Storage does not contain data model '%s'"):format(mob))
            end

            storage.pushItems(dcName, info.slot)
            print("Adding data model of " .. mob .. " to datacenter")
        end
    end
end

--- Loads the drop map and builds a reverse lookup.
---
--- itemToMob becomes:
--- {
---     ["minecraft:rotten_flesh"] = {
---         { mob = "minecraft:husk", count = 3 },
---         { mob = "minecraft:zombie", count = 2 },
---     },
--- }
---
--- Each list is sorted by descending count.
function M.loadDropMap(path)
    if not fs.exists(path) then
        error(("Drop map '%s' does not exist"):format(path))
    end

    local map = dofile(path)

    if type(map) ~= "table" then
        error("Drop map must return a table")
    end

    dropMap = map
    itemToMob = {}

    for mob, drops in pairs(dropMap) do
        if type(drops) ~= "table" then
            error(("Drops for '%s' must be a table"):format(mob))
        end

        for i, drop in ipairs(drops) do
            if type(drop) ~= "table" then
                error(("Drop #%d for '%s' must be a table"):format(i, mob))
            end

            if type(drop.item) ~= "string" then
                error(("Drop #%d for '%s' is missing 'item'"):format(i, mob))
            end

            if type(drop.count) ~= "number" then
                error(("Drop '%s' for '%s' is missing numeric 'count'")
                :format(drop.item, mob))
            end

            itemToMob[drop.item] = itemToMob[drop.item] or {}

            table.insert(itemToMob[drop.item], {
                mob = mob,
                count = drop.count,
            })
        end
    end

    -- Sort each candidate list by descending count.
    for _, candidates in pairs(itemToMob) do
        table.sort(candidates, function(a, b)
            return a.count > b.count
        end)
    end
end

--- Loads an optional map of which drop each mob is configured
--- to produce in this datacenter.
---
--- Example:
--- return {
---     ["minecraft:zombie"] = "minecraft:rotten_flesh",
---     ["minecraft:wither"] = "minecraft:nether_star",
--- }
function M.loadConfiguredDrops(path)
    if not fs.exists(path) then
        error(("Configured drop map '%s' does not exist"):format(path))
    end

    local map = dofile(path)

    if type(map) ~= "table" then
        error("Configured drop map must return a table")
    end

    configuredDrops = map
end

function M.clearConfiguredDrops()
    configuredDrops = nil
end

--- Returns all items that can currently be requested through syncItems().
---
--- Without a configured drop map:
---   returns every item in the drop map.
---
--- With a configured drop map:
---   returns only items that have at least one configured mob.
---
--- Returns an array:
--- {
---     "minecraft:nether_star",
---     "minecraft:dragon_egg",
--- }
function M.getSupportedItems()
    local result = {}
    local seen = {}

    for item, candidates in pairs(itemToMob) do
        local supported = false

        if not configuredDrops then
            supported = true
        else
            for _, candidate in ipairs(candidates) do
                if configuredDrops[candidate.mob] == item then
                    supported = true
                    break
                end
            end
        end

        if supported and not seen[item] then
            seen[item] = true
            result[#result + 1] = item
        end
    end

    table.sort(result)

    return result
end

--- Synchronize the datacenter based on desired items.
---
--- wantedItems = {
---     "minecraft:nether_star",
---     "minecraft:dragon_egg",
--- }
function M.syncItems(storage, datacenter, wantedItems)
    local wantedMobs = {}
    local seen = {}

    for _, item in ipairs(wantedItems) do
        local candidates = itemToMob[item]

        if not candidates then
            error(("Unknown item '%s'"):format(item))
        end

        local chosen

        for _, candidate in ipairs(candidates) do
            if not configuredDrops
            or configuredDrops[candidate.mob] == item then
                chosen = candidate.mob
                break
            end
        end

        if not chosen then
            error(("No configured mob can produce '%s'"):format(item))
        end

        if not seen[chosen] then
            seen[chosen] = true
            table.insert(wantedMobs, chosen)
        end
    end

    return M.sync(storage, datacenter, wantedMobs)
end

return M
