local hnn = require("hnn_models")

local me = peripheral.find("me_bridge") or peripheral.find("meBridge")
local storage = peripheral.wrap("minecraft:barrel_0") --TODO What name to use?
local datacenter = peripheral.wrap("hostileneuralnetworks:datacenter_io_port") --TODO What name to use?

hnn.loadDropMap("drops.lua")

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
        table.insert(set, k)
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
    local ok, supportedItems = pcall(hnn, getSupportedItems)
    if not ok then
        print("Failed to get supported items:")
        print(supportedItems)
        return {}
    end
    return supportedItems
end

local function getRequestedItems(supportedItems)
    local ok, craftingCPUs = pcall(me, getCraftingCPUs)
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
            local job = v.craftingJob
            local resource = job.resource
            local name = resource.name
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
    local ok, err = pcall(hnn.syncItems, storage, datacenter, requestedItems)
    if not ok then
        print("Failed to sync items:")
        print(err)
    end
end

while true do
    loadConfiguredDrops()
    local supportedItems = getSupportedItems()
    local requestedItems = getRequestedItems(supportedItems)
    reconcile(requestedItems)
    sleep(1)
end
