-- hnn_models.lua

local M = {}
local dropMap = {}
local itemToMob = {}
local configuredDrops = nil
local dataModels = {
    nameToMobName = {},
    mobNameToName = {},
    nameToDisplayName = {},
    displayNameToName = {},
}

-- TODO Move this to a common utils file?
local function makeSet(list)
    local set = {}
    for _, v in ipairs(list) do
        set[v] = true
    end
    return set
end

local function makeWantedSets(wantedMobNames)
    local dataModelNamesSet = {}
    local dataModelDisplayNamesSet = {}
    for _, mobName in ipairs(wantedMobNames) do
        local dataModelName = dataModels.mobNameToName[mobName]
        if dataModelName then
            local dataModelDisplayName = dataModels.nameToDisplayName[dataModelName]
            if dataModelDisplayName then
                dataModelNamesSet[dataModelName] = true
                dataModelDisplayNamesSet[dataModelDisplayName] = true
            else
                print("Could not resolve data model name '" .. dataModelName .. "' to data model display name")
            end
        else
            print("Could not resolve mob name '" .. mobName .. "' to data model name")
        end
    end
    return dataModelNamesSet, dataModelDisplayNamesSet
end

local function scanDC(datacenter)
    local ok, items = pcall(datacenter.list)
    if not ok then
        print("Failed to scan data center:")
        print(items)
        return {}
    end

    items = items or {}

    print("Found " .. #items .. " data model items in data center") --TODO Remove this debug line?

    local models = {}
    for slot in pairs(items) do
        local ok2, detail = pcall(datacenter.getItemDetail, slot)
        if not ok2 then
            print("Failed to get item detail of slot " .. slot .. ":")
            print(detail)
        end

        if detail then
            models[detail.displayName] = {
                slot = slot,
                detail = detail,
            }
        end
    end

    print("Found " .. #models .. " data models in data center") --TODO Remove this debug line?

    return models
end

local function scanME(meBridge)
    local ok, items = pcall(meBridge.getItems, {name = "hostilenetworks:data_model"})
    if not ok then
        print("Failed to scan ME system:")
        print(items)
        return {}
    end

    items = items or {}

    print("Found " .. #items .. " data model items in ME system") --TODO Remove this debug line?

    local models = {}
    for k, info in pairs(items) do
        local components = info.components
        if components then
            local dataModelName = components["hostilenetworks:data_model"]
            if dataModelName then
                models[dataModelName] = info
            end
        end
    end

    print("Found " .. #items .. " data models in ME system") --TODO Remove this debug line?

    return models
end

local function removeFromDC(meBridge, dataModelDisplayName, dcInfo)
--TODO Does this work with the displayName filter? Maybe use the nbt instead?
    print("Removing " .. dataModelDisplayName .. " from data center...")
    local ok, err = pcall(meBridge.importItem, {nbt = dcInfo.nbt}, "down")
    if not ok then
        print("Failed to remove " .. dataModelDisplayName .. " from data center via nbt")
        print(err)
        print("Trying to remove via displayName instead...")
        local ok2, err2 = pcall(meBridge.importItem, {name = "hostilenetworks:data_model", displayName = dataModelDisplayName}, "down")
        if not ok2 then
            print("Failed to remove " .. dataModelDisplayName .. " from data center via displayName")
            print(err2)
            return
        end
    end
    print("Removed  " .. dataModelDisplayName .. " from data center")
end

local function addToDC(meBridge, dataModelDisplayName, meInfo)
    print("Adding " .. dataModelDisplayName .. " to data center...")
    local ok, err = pcall(meBridge.exportItem, {fingerprint = meInfo.fingerprint}, "down")
    if not ok then
        print("Failed to add " .. dataModelDisplayName .. " to data center via fingerprint")
        print(err)
        print("Trying to add via displayName instead...")
        local ok2, err2 = pcall(meBridge.exportItem, {name = "hostilenetworks:data_model", displayName = dataModelDisplayName}, "down")
        if not ok2 then
            print("Failed to add " .. dataModelDisplayName .. " to data center via displayName")
            print(err2)
            return
        end
    end
    print("Added  " .. dataModelDisplayName .. " to data center")
end

local function clearDC(meBridge)
    local ok, err = pcall(meBridge.importItem, {name = "hostilenetworks:data_model"}, "down")
    if not ok then
        print("Failed to clear data center:")
        print(err)
    end
end

--- Synchronize the data center so it contains exactly the requested models.
---
--- meBridge       Wrapped me bridge containing all models.
--- datacenter     Wrapped inventory connected to the HNN model port.
--- wantedMobNames Array of mob ids, e.g. {"minecraft:creeper","minecraft:zombie"}
function M.sync(meBridge, datacenter, wantedMobNames)
    local wantedDataModelNamesSet, wantedDataModelDisplayNamesSet = makeWantedSets(wantedMobNames)

    -- Scan data center.
    local dcModels = scanDC(datacenter)
    print("Found " .. #dcModels .. " data models in the data center") --TODO Remove this debug line

    -- Remove unwanted models.
    for dataModelDisplayName, dcInfo in pairs(dcModels) do
        if not wantedDataModelDisplayNamesSet[dataModelDisplayName] then
            removeFromDC(meBridge, dataModelDisplayName, dcInfo)
        end
    end

    -- Refresh after removals.
    dcModels = scanDC(datacenter)
    local meModels = scanME(meBridge)
    print("Found " .. #meModels .. " data models in the ME system") --TODO Remove this debug line

    -- Add missing models.
    for dataModelName in pairs(wantedDataModelNamesSet) do
        local dataModelDisplayName = dataModels.nameToDisplayName[dataModelName]
        if not dcModels[dataModelDisplayName] then
            local meInfo = meModels[dataModelName]

            if not meInfo then
                error(("ME system does not contain data model '%s'"):format(dataModelName))
            end

            addToDC(meBridge, dataModelDisplayName, meInfo)
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

function M.loadDataModelMaps(path)
    if not fs.exists(path) then
        error(("Data model maps '%s' does not exist"):format(path))
    end

    local map = dofile(path)

    if type(map) ~= "table" then
        error("Data model maps must return a table")
    end

    dataModels.nameToMobName = map.nameToMobName
    dataModels.mobNameToName = map.mobNameToName
    dataModels.nameToDisplayName = map.nameToDisplayName
    dataModels.displayNameToName = map.displayNameToName
end

--- Loads an optional map of which drop each mob is configured
--- to produce in this data center.
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

--- Synchronize the data center based on desired items.
---
--- wantedItems = {
---     "minecraft:nether_star",
---     "minecraft:dragon_egg",
--- }
function M.syncItems(meBridge, datacenter, wantedItems)
    local wantedMobNames = {}
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
            table.insert(wantedMobNames, chosen)
        end
    end

    return M.sync(meBridge, datacenter, wantedMobNames)
end

M.loadDropMap("drops.lua")
M.loadDataModelMaps("dataModelMaps.lua")

return M
