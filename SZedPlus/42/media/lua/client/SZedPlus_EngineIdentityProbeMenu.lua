--- ZED+ TEMPORARY ENGINE IDENTITY PROBE 2 - client debug controls.
---
--- Adds a small menu under the vanilla Debug context menu. All actual zombie
--- inspection happens server-side in SZedPlus_EngineIdentityProbe.lua.
--- Nothing here changes zombie classification or persistence.

SZedPlus = SZedPlus or {}
SZedPlus.EngineIdentityProbeMenu = {}

local Menu = SZedPlus.EngineIdentityProbeMenu
local MODULE = "SZedPlusEngineProbe"

local function request(playerNum, command, args)
    local player = getSpecificPlayer(playerNum)
    if player == nil then return end

    if isClient() then
        sendClientCommand(player, MODULE, command, args or {})
        return
    end

    if SZedPlus.EngineIdentityProbe == nil then
        print("[SZedPlus][ENGINE_PROBE] server probe module not loaded")
        return
    end
    SZedPlus.EngineIdentityProbe.handleLocalCommand(command, player, args or {})
end

local function findTarget(playerNum, worldobjects)
    local square = nil
    for _, object in ipairs(worldobjects or {}) do
        square = object:getSquare()
        if square then break end
    end

    if square then
        local movingObjects = square:getMovingObjects()
        for i = 0, movingObjects:size() - 1 do
            local object = movingObjects:get(i)
            if instanceof(object, "IsoZombie") then
                return { x = object:getX(), y = object:getY(), z = object:getZ(), radius = 1 }
            end
        end
        return { x = square:getX(), y = square:getY(), z = square:getZ(), radius = 3 }
    end

    local player = getSpecificPlayer(playerNum)
    if player then
        return { x = player:getX(), y = player:getY(), z = player:getZ(), radius = 6 }
    end
    return nil
end

function Menu.start(playerNum, label, radius)
    local player = getSpecificPlayer(playerNum)
    if player == nil then return end
    request(playerNum, "start", {
        label = label,
        radius = radius,
        x = player:getX(),
        y = player:getY(),
        z = player:getZ(),
    })
end

function Menu.checkpoint(playerNum)
    request(playerNum, "checkpoint", { label = "MANUAL" })
end

function Menu.stop(playerNum)
    request(playerNum, "stop", {})
end

function Menu.status(playerNum)
    request(playerNum, "status", {})
end

function Menu.snapshotTarget(playerNum, target)
    request(playerNum, "snapshotTarget", target or {})
end

local function findDebugSubMenu(context, playerNum)
    local debugLabel = getText("ContextMenu_Debug")
    local root = getPlayerContextMenu(playerNum)
    if root == nil or root.instanceMap == nil then return nil end

    for _, option in ipairs(context.options) do
        if option.name == debugLabel and option.subOption then
            return root.instanceMap[option.subOption]
        end
    end
    return nil
end

local function isDebugAllowed(player)
    if isClient() then
        local ok, allowed = pcall(function()
            return player:getRole():hasCapability(Capability.UseDebugContextMenu)
        end)
        return ok and allowed == true
    end
    return isDebugEnabled()
end

local START_PROBES = {
    { label = "P1_ORDINARY_ISOLATED", radius = 12, text = "Start P1 - isolated ordinary (12 tiles)" },
    { label = "P2_ORDINARY_GROUP", radius = 30, text = "Start P2 - ordinary group (30 tiles)" },
    { label = "P3_FRESH_VS_REBUILT", radius = 30, text = "Start P3 - fresh vs rebuilt (30 tiles)" },
    { label = "P4_NEGATIVE_REROLL", radius = 30, text = "Start P4 - negative reroll (30 tiles)" },
    { label = "P5_DESCRIPTOR", radius = 30, text = "Start P5 - descriptor tracking (30 tiles)" },
    { label = "P6_ZEDPLUS_CONTINUITY", radius = 30, text = "Start P6 - ZED+ continuity (30 tiles)" },
}

local function build(parentMenu, playerNum, worldobjects)
    local rootOption = parentMenu:addOption("ZED+ Engine Identity Probe 2", nil, nil)
    local rootMenu = ISContextMenu:getNew(parentMenu)
    parentMenu:addSubMenu(rootOption, rootMenu)

    local startOption = rootMenu:addOption("Start probe", nil, nil)
    local startMenu = ISContextMenu:getNew(rootMenu)
    rootMenu:addSubMenu(startOption, startMenu)

    for _, entry in ipairs(START_PROBES) do
        startMenu:addOption(entry.text, playerNum, Menu.start, entry.label, entry.radius)
    end

    rootMenu:addOption("Checkpoint active area", playerNum, Menu.checkpoint)
    rootMenu:addOption("Snapshot clicked/nearest zombie", playerNum,
        Menu.snapshotTarget, findTarget(playerNum, worldobjects))
    rootMenu:addOption("Probe status", playerNum, Menu.status)
    rootMenu:addOption("Stop probe", playerNum, Menu.stop)
end

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if test then return end
    local player = getSpecificPlayer(playerNum)
    if player == nil or not isDebugAllowed(player) then return end

    local debugMenu = findDebugSubMenu(context, playerNum)
    if debugMenu ~= nil then
        build(debugMenu, playerNum, worldobjects)
    else
        build(context, playerNum, worldobjects)
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
