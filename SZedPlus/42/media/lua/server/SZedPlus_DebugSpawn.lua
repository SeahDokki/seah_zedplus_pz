--- ZED+ : server side of the debug tools.
---
--- Spawning and inspecting zombies are world operations, so they run here even
--- when triggered from the client menu. In multiplayer the menu sends a client
--- command; in single player and on a co-op host it calls these directly.
---
--- Loads before SZedPlus_Registry and SZedPlus_Spawn (alphabetical order), so
--- it only ever touches them from inside a function, never at load time.

--- Files under server/ are loaded on clients too.
if isClient() then return end

SZedPlus = SZedPlus or {}
SZedPlus.DebugSpawn = {}

local MODULE = "SZedPlus"

--- How far from the player a debug zombie appears, and how far the cleanup and
--- inspection helpers reach.
local SPAWN_DISTANCE = 6
local INSPECT_RADIUS = 40

-- --------------------------------------------------------------- helpers --

--- A square a few tiles in front of the player, falling back to the player's
--- own square when that one is not walkable.
local function findSpawnSquare(player)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local angle = player:getForwardDirection()

    local targetX = px
    local targetY = py
    if angle then
        targetX = px + angle:getX() * SPAWN_DISTANCE
        targetY = py + angle:getY() * SPAWN_DISTANCE
    end

    local cell = getCell()
    if not cell then return nil end

    local square = cell:getGridSquare(math.floor(targetX), math.floor(targetY), pz)
    if square and square:isFree(false) then
        return square
    end

    return cell:getGridSquare(math.floor(px), math.floor(py), pz)
end

--- Walk the loaded zombies near a player.
local function forEachZombieNear(player, radius, visitor)
    local cell = getCell()
    if not cell then return 0 end

    local zombies = cell:getZombieList()
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local visited = 0

    for i = 0, zombies:size() - 1 do
        local zombie = zombies:get(i)
        if zombie and zombie:getZ() == pz then
            local dx, dy = zombie:getX() - px, zombie:getY() - py
            local distance = math.sqrt(dx * dx + dy * dy)
            if distance <= radius then
                visitor(zombie, distance)
                visited = visited + 1
            end
        end
    end
    return visited
end

-- --------------------------------------------------------------- actions --

--- Spawn one zombie already classified as the requested spec.
---
--- The tier is claimed through Spawn.forceNext rather than written after the
--- fact: addZombiesInOutfit fires OnZombieCreate synchronously, so the normal
--- classification would otherwise run first and roll something else.
function SZedPlus.DebugSpawn.spawn(player, spec)
    if player == nil or spec == nil then return end

    local square = findSpawnSquare(player)
    if square == nil then
        SZedPlus.logError("debug spawn: no square available")
        return
    end

    SZedPlus.Spawn.forceNext(spec)
    addZombiesInOutfit(square:getX(), square:getY(), square:getZ(), 1, nil, nil)

    -- If the engine refused to create anything, drop the claim so it does not
    -- attach itself to the next natural spawn.
    SZedPlus.Spawn.forceNext(nil)

    SZedPlus.logAlways("debug: spawned T%s %s at %d,%d,%d",
        tostring(spec.stage),
        tostring(spec.calamity or spec.form or spec.path or "-"),
        square:getX(), square:getY(), square:getZ())
end

--- Print every Zed+ around the player.
function SZedPlus.DebugSpawn.inspect(player)
    if player == nil then return end
    local found = 0

    forEachZombieNear(player, INSPECT_RADIUS, function(zombie, distance)
        if SZedPlus.isZedPlus(zombie) then
            found = found + 1
            SZedPlus.logAlways("  %s at %.1f tiles", SZedPlus.describe(zombie), distance)
        end
    end)

    SZedPlus.logAlways("debug: %d Zed+ within %d tiles", found, INSPECT_RADIUS)
end

--- Remove every Zed+ around the player, leaving ordinary zombies alone.
--- Useful between two tests so old subjects do not pollute the next one.
function SZedPlus.DebugSpawn.removeNearby(player)
    if player == nil then return end

    local doomed = {}
    forEachZombieNear(player, INSPECT_RADIUS, function(zombie)
        if SZedPlus.isZedPlus(zombie) then
            doomed[#doomed + 1] = zombie
        end
    end)

    -- Collect first, then remove: mutating the cell list while walking it
    -- skips entries.
    for _, zombie in ipairs(doomed) do
        zombie:removeFromWorld()
        zombie:removeFromSquare()
    end

    SZedPlus.logAlways("debug: removed %d Zed+", #doomed)
end

--- Find the zombie closest to a world position, within `radius` tiles.
---
--- The client identifies its target by position rather than by object: in
--- multiplayer the two sides hold different instances, and a zombie's online id
--- is not reliably exposed to Lua on both ends.
local function findZombieAt(player, x, y, z, radius)
    local cell = getCell()
    if not cell then return nil end

    local zombies = cell:getZombieList()
    local best, bestDistance = nil, radius or 3

    for i = 0, zombies:size() - 1 do
        local zombie = zombies:get(i)
        if zombie and zombie:getZ() == z then
            local dx, dy = zombie:getX() - x, zombie:getY() - y
            local distance = math.sqrt(dx * dx + dy * dy)
            if distance <= bestDistance then
                best, bestDistance = zombie, distance
            end
        end
    end

    return best
end

--- Read the stats of the zombie the player pointed at and send them back.
function SZedPlus.DebugSpawn.sendStats(player, args)
    if player == nil then return end

    local stats, messageKey = nil, nil

    if args and args.x then
        local zombie = findZombieAt(player, args.x, args.y, args.z, args.radius or 3)
        if zombie then
            stats = SZedPlus.Behaviour.readStats(zombie)
        else
            messageKey = "IGUI_SZedPlus_StatsNoTarget"
        end
    else
        messageKey = "IGUI_SZedPlus_StatsNoTarget"
    end

    -- A translation key travels, not a translated string: a dedicated server
    -- has no reason to share the player's language, and getText there would
    -- resolve against the wrong locale, or not at all.
    --
    -- isClient() is always false in this file (guarded at the top), so the
    -- test that matters is whether a server is running: on a dedicated server
    -- and a co-op host the answer goes back over the wire, in single player it
    -- is displayed directly.
    if isServer() then
        sendServerCommand(player, MODULE, "stats", { stats = stats, messageKey = messageKey })
    else
        SZedPlus.showStats(stats, messageKey and getText(messageKey) or nil)
    end
end

--- Spawn a ZED+ creature - an animal species, not a zombie.
---
--- Uses addAnimal(cell, x, y, z, type, breed), the same call the vanilla debug
--- menu uses. The species must have been registered on OnGameBoot; if it was
--- not, say so rather than letting addAnimal fail obscurely.
function SZedPlus.DebugSpawn.spawnCreature(player, args)
    if player == nil or args == nil or args.type == nil then return end

    if not SZedPlus.Creatures.isRegistered(args.type) then
        SZedPlus.logError("creature '%s' is not registered - check the OnGameBoot log",
            tostring(args.type))
        return
    end

    local square = findSpawnSquare(player)
    if square == nil then
        SZedPlus.logError("creature spawn: no square available")
        return
    end

    -- Two ways in. addAnimal() is what the vanilla debug menu uses;
    -- IsoAnimal.new() is what the reference dinosaur mod uses. Try both, and
    -- report the actual error text - a bare "failed" says nothing useful.
    local ok, result = pcall(addAnimal, getCell(),
        square:getX(), square:getY(), square:getZ(),
        args.type, args.breed or "default")

    if not ok then
        SZedPlus.logError("addAnimal('%s') threw: %s", tostring(args.type), tostring(result))

        ok, result = pcall(IsoAnimal.new, getCell(),
            square:getX(), square:getY(), square:getZ(),
            args.type, args.breed or "default")
        if not ok then
            SZedPlus.logError("IsoAnimal.new('%s') threw: %s",
                tostring(args.type), tostring(result))
            return
        end
        SZedPlus.logAlways("IsoAnimal.new worked where addAnimal did not")
    end

    if result == nil then
        SZedPlus.logError("creature '%s' created nothing", tostring(args.type))
        return
    end

    SZedPlus.logAlways("debug: spawned creature '%s' at %d,%d,%d",
        tostring(args.type), square:getX(), square:getY(), square:getZ())
end

-- ------------------------------------------------- multiplayer entry point --

--- Redress every Zed+ with a form near the player, and rebuild its model.
---
--- This exists to separate two things that reading the engine cannot: whether
--- the clothes are wrong, or whether the model showing them is stale. Click it
--- next to a naked T5. If it puts clothes on, the data was always fine and only
--- the timing of the rebuild is at fault; if it does not, ItemVisuals are not
--- what the zombie is drawn from and the persistent outfit id in the log is the
--- thing to chase instead.
function SZedPlus.DebugSpawn.redressNearby(player)
    if player == nil then return end

    local zombies = player:getCell():getZombieList()
    local touched = 0

    for index = 0, zombies:size() - 1 do
        local zombie = zombies:get(index)
        if zombie ~= nil and SZedPlus.isZedPlus(zombie)
            and zombie:getModData()[SZedPlus.Keys.form] ~= nil then
            SZedPlus.Appearance.redressNow(zombie)
            touched = touched + 1
        end
    end

    SZedPlus.logAlways("debug: redressed %d Zed+ with a form", touched)
end

local HANDLERS = {
    spawn = function(player, args) SZedPlus.DebugSpawn.spawn(player, args) end,
    inspect = function(player) SZedPlus.DebugSpawn.inspect(player) end,
    removeNearby = function(player) SZedPlus.DebugSpawn.removeNearby(player) end,
    getStats = function(player, args) SZedPlus.DebugSpawn.sendStats(player, args) end,
    redressNearby = function(player) SZedPlus.DebugSpawn.redressNearby(player) end,
    spawnCreature = function(player, args) SZedPlus.DebugSpawn.spawnCreature(player, args) end,
}

--- Debug commands from a multiplayer client.
---
--- These spawn zombies, so they must not be callable by an ordinary player.
--- The client menu is already gated on the debug capability, but a crafted
--- packet would not be, hence the check here as well.
local function onClientCommand(module, command, player, args)
    if module ~= MODULE then return end

    local handler = HANDLERS[command]
    if handler == nil then return end

    if not player:getRole():hasCapability(Capability.UseDebugContextMenu) then
        SZedPlus.logError("refused debug command '%s' from %s: no debug capability",
            command, tostring(player:getUsername()))
        return
    end

    handler(player, args)
end

Events.OnClientCommand.Add(onClientCommand)
