local hnn = require("hnn_models")

local me = peripheral.find("me_bridge") or peripheral.find("meBridge")
local datacenter = peripheral.wrap("bottom") --TODO What name to use?

-- TODO Move this to a common utils file?
local function makeSet(list)
    local set = {}
    for _, v in ipairs(list) do
        set[v] = true
    end
    return set
end

-- TODO Move this to a common utils file?
local function convertSetToList(set)
    local list = {}
    for k,_ in pairs(set) do
        table.insert(list, k)
    end
    return list
end

local function loadConfiguredDrops()
    local ok, err = pcall(hnn.loadConfiguredDrops, "configuredDrops.lua")
    if not ok then
        print("Failed to load configured drops:")
        print(err)
    end
end


local function getSupportedItems()
    local ok, supportedItems = pcall(hnn.getSupportedItems)
    if not ok then
        print("Failed to get supported items:")
        print(supportedItems)
        return {}
    end
    return supportedItems
end

local function getRequestedItems(supportedItems)
    local ok, craftingCPUs = pcall(me.getCraftingCPUs)
    if not ok then
        print("Failed to get crafting cpus:")
        print(craftingCPUs)
        return {}
    end
    if craftingCPUs == nil then
        return {}
    end
    local supportedItemsSet = makeSet(supportedItems)
    local requestedItemsSet = {}
    for k,v in pairs(craftingCPUs) do
        if v.isBusy then
            --print(textutils.serialize(v))
            local job = v.craftingJob
            local resource = job.resource
            local name = resource.name
            print(name)
            print(supportedItemsSet[name])
            -- If the item is supported, request it
            if supportedItemsSet[name] then
                requestedItemsSet[name] = true
            end
        end
    end
    return convertSetToList(requestedItemsSet)
end

local function reconcile(requestedItems)
    table.sort(requestedItems)
    local ok, err = pcall(hnn.syncItems, me, datacenter, requestedItems)
    if not ok then
        print("Failed to sync items:")
        print(err)
    end
end

while true do
    loadConfiguredDrops()
    local supportedItems = getSupportedItems()
    print("Found " .. #supportedItems .. " supported items") --TODO Remove this debug line?
    local requestedItems = getRequestedItems(supportedItems)
    print("Found " .. #requestedItems .. " requested items") --TODO Remove this debug line?
    reconcile(requestedItems)
    sleep(1)
end
