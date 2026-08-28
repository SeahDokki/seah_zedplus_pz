--- ZED+ : debug context menu.
---
--- Adds "Zed+" inside the vanilla right-click > Debug submenu, next to
--- "Zombies", so a tier can be spawned on demand instead of waiting for the
--- rarity roll.
---
---   Debug > Zed+ > Spawn > T3 - Specialised > Fast
---
--- The menu only builds the request. The spawn itself is a world operation and
--- happens on the server: in multiplayer through a client command, in single
--- player and on a co-op host by calling the server function directly.

SZedPlus = SZedPlus or {}
SZedPlus.DebugMenu = {}

local MODULE = "SZedPlus"

-- ------------------------------------------------------------- dispatch --

--- Run a debug action where the world lives.
local function request(playerNum, command, args)
    local player = getSpecificPlayer(playerNum)
    if player == nil then return end

    if isClient() then
        sendClientCommand(player, MODULE, command, args or {})
        return
    end

    -- Single player or co-op host: the server files live in this same process,
    -- so call straight through. Keep this a table rather than a chain of
    -- elseifs, so a new command cannot be wired into the menu and silently do
    -- nothing outside multiplayer.
    local handlers = SZedPlus.DebugSpawn
    if handlers == nil then
        print("[SZedPlus][ERROR] debug server functions are not loaded")
        return
    end

    local direct = {
        spawn = handlers.spawn,
        inspect = handlers.inspect,
        removeNearby = handlers.removeNearby,
        getStats = handlers.sendStats,
    }

    local handler = direct[command]
    if handler == nil then
        print("[SZedPlus][ERROR] no local handler for debug command '" .. tostring(command) .. "'")
        return
    end
    handler(player, args)
end

function SZedPlus.DebugMenu.onSpawn(playerNum, spec)
    request(playerNum, "spawn", spec)
end

function SZedPlus.DebugMenu.onInspect(playerNum)
    request(playerNum, "inspect")
end

function SZedPlus.DebugMenu.onRemoveNearby(playerNum)
    request(playerNum, "removeNearby")
end

--- Ask for the stats of a zombie, identified by where it stands.
function SZedPlus.DebugMenu.onGetStats(playerNum, target)
    request(playerNum, "getStats", target)
end

-- ---------------------------------------------------------------- layout --

--- Tiers offered by the Spawn submenu, in display order.
--- `children` names the second level, if the tier needs one.
local TIERS = {
    { stage = 1, label = "IGUI_SZedPlus_Tier1" },
    { stage = 2, label = "IGUI_SZedPlus_Tier2" },
    { stage = 3, label = "IGUI_SZedPlus_Tier3", children = "paths" },
    { stage = 4, label = "IGUI_SZedPlus_Tier4", children = "paths" },
    { stage = 5, label = "IGUI_SZedPlus_Tier5", children = "forms" },
    { stage = 6, label = "IGUI_SZedPlus_Tier6", children = "calamities" },
}

local PATHS = {
    { key = "fast",    label = "IGUI_SZedPlus_PathFast" },
    { key = "tank",    label = "IGUI_SZedPlus_PathTank" },
    { key = "stealth", label = "IGUI_SZedPlus_PathStealth" },
    { key = "ranged",  label = "IGUI_SZedPlus_PathRanged" },
}

local FORMS = {
    { key = "witch",    path = "fast",    label = "IGUI_SZedPlus_FormWitch" },
    { key = "volatile", path = "fast",    label = "IGUI_SZedPlus_FormVolatile" },
    { key = "colossus", path = "tank",    label = "IGUI_SZedPlus_FormColossus" },
    { key = "boomer",   path = "tank",    label = "IGUI_SZedPlus_FormBoomer" },
    { key = "sneaker",  path = "stealth", label = "IGUI_SZedPlus_FormSneaker" },
    { key = "mimic",    path = "stealth", label = "IGUI_SZedPlus_FormMimic" },
    { key = "spitter",  path = "ranged",  label = "IGUI_SZedPlus_FormSpitter" },
    { key = "scout",    path = "ranged",  label = "IGUI_SZedPlus_FormScout" },
}

local CALAMITIES = {
    { key = "host",    label = "IGUI_SZedPlus_CalamityHost" },
    { key = "mist",    label = "IGUI_SZedPlus_CalamityMist" },
    { key = "leader",  label = "IGUI_SZedPlus_CalamityLeader" },
    { key = "centaur", label = "IGUI_SZedPlus_CalamityCentaur" },
}

--- Add one leaf entry that spawns `spec`.
local function addSpawnOption(menu, playerNum, label, spec)
    menu:addOption(getText(label), playerNum, SZedPlus.DebugMenu.onSpawn, spec)
end

--- Build the second level under one tier, if it has one.
local function addTierChildren(parentMenu, option, playerNum, tier)
    local submenu = ISContextMenu:getNew(parentMenu)
    parentMenu:addSubMenu(option, submenu)

    if tier.children == "paths" then
        for _, entry in ipairs(PATHS) do
            addSpawnOption(submenu, playerNum, entry.label,
                { stage = tier.stage, path = entry.key })
        end
    elseif tier.children == "forms" then
        for _, entry in ipairs(FORMS) do
            addSpawnOption(submenu, playerNum, entry.label,
                { stage = tier.stage, path = entry.path, form = entry.key })
        end
    elseif tier.children == "calamities" then
        for _, entry in ipairs(CALAMITIES) do
            addSpawnOption(submenu, playerNum, entry.label,
                { stage = tier.stage, calamity = entry.key })
        end
    end
end

--- The zombie the player right-clicked on, if any.
---
--- worldobjects only carries map objects, not characters, so the zombie has to
--- be looked up on the clicked square. Falls back to the nearest zombie around
--- the player, which is what you want when clicking bare ground next to one.
local function findTargetZombie(playerNum, worldobjects)
    local square = nil
    for _, object in ipairs(worldobjects) do
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
        -- No zombie exactly there: let the server look around that spot.
        return { x = square:getX(), y = square:getY(), z = square:getZ(), radius = 3 }
    end

    local player = getSpecificPlayer(playerNum)
    if player then
        return { x = player:getX(), y = player:getY(), z = player:getZ(), radius = 6 }
    end
    return nil
end

--- Build "Zed+" and everything under it, into the menu it is given.
function SZedPlus.DebugMenu.build(parentMenu, playerNum, worldobjects)
    local rootOption = parentMenu:addOption(getText("IGUI_SZedPlus_DebugMenu"), nil, nil)
    local rootMenu = ISContextMenu:getNew(parentMenu)
    parentMenu:addSubMenu(rootOption, rootMenu)

    local spawnOption = rootMenu:addOption(getText("IGUI_SZedPlus_DebugSpawn"), nil, nil)
    local spawnMenu = ISContextMenu:getNew(rootMenu)
    rootMenu:addSubMenu(spawnOption, spawnMenu)

    for _, tier in ipairs(TIERS) do
        if tier.children then
            local option = spawnMenu:addOption(getText(tier.label), nil, nil)
            addTierChildren(spawnMenu, option, playerNum, tier)
        else
            addSpawnOption(spawnMenu, playerNum, tier.label, { stage = tier.stage })
        end
    end

    rootMenu:addOption(getText("IGUI_SZedPlus_DebugGetStats"), playerNum,
        SZedPlus.DebugMenu.onGetStats, findTargetZombie(playerNum, worldobjects or {}))
    rootMenu:addOption(getText("IGUI_SZedPlus_DebugInspect"), playerNum,
        SZedPlus.DebugMenu.onInspect)
    rootMenu:addOption(getText("IGUI_SZedPlus_DebugRemove"), playerNum,
        SZedPlus.DebugMenu.onRemoveNearby)
end

-- ------------------------------------------------------------- attaching --

--- Find the vanilla Debug submenu inside a freshly built context menu.
---
--- ISContextMenu stores submenus on the root menu, keyed by the number kept in
--- option.subOption, so an option can be walked back to its submenu. Returns
--- nil if the Debug entry is absent, which is the normal case when debug mode
--- is off.
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

--- Same gate as the vanilla debug menu: an admin capability in multiplayer,
--- the debug flag otherwise.
local function isDebugAllowed(player)
    if isClient() then
        return player:getRole():hasCapability(Capability.UseDebugContextMenu)
    end
    return isDebugEnabled()
end

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if test then return end

    local player = getSpecificPlayer(playerNum)
    if player == nil or not isDebugAllowed(player) then return end

    local debugMenu = findDebugSubMenu(context, playerNum)
    if debugMenu ~= nil then
        SZedPlus.DebugMenu.build(debugMenu, playerNum, worldobjects)
    else
        -- The vanilla Debug submenu was not found - engine change, or another
        -- mod rebuilt the menu. Fall back to a top-level debug entry so the
        -- tools stay reachable rather than disappearing silently.
        SZedPlus.DebugMenu.build(context, playerNum, worldobjects)
    end
end

-- Runs after the vanilla handler, so the Debug submenu already exists.
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
