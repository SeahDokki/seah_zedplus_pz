--- ZED+ : debug helpers.
---
--- These exist so the spawn logic can be verified in game without waiting for
--- the natural 1-in-400 roll. Call them from the in-game Lua console.
---
---   SZedPlus.Debug.countNearby(50)   -- how many Zed+ within 50 tiles
---   SZedPlus.Debug.describeNearby(50)
---   SZedPlus.Debug.makeNearestZedPlus(3, "fast")
---
--- Nothing here runs on its own.
---
--- MULTIPLAYER: a zombie's modData is written on the server and is NOT
--- replicated to clients, so these read nothing useful when connected to a
--- server. They work in single player and on a co-op host. On a dedicated
--- server, inspect state from the server console instead.

SZedPlus = SZedPlus or {}
SZedPlus.Debug = {}

--- Warn once if these are used where the data cannot be seen.
local function warnIfRemoteClient()
    if isClient() and not isServer() then
        print("[SZedPlus] WARNING: zombie modData is server-side and is not " ..
              "sent to clients. These debug helpers will report nothing here.")
        return true
    end
    return false
end

--- Walk the loaded zombie list once, calling `visitor(zombie, distance)` for
--- every zombie within `radius` tiles of the player.
local function forEachZombieNear(radius, visitor)
    local player = getPlayer()
    if not player then return 0 end

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

--- How many loaded zombies within `radius` are Zed+.
function SZedPlus.Debug.countNearby(radius)
    radius = radius or 50
    warnIfRemoteClient()
    local special, total = 0, 0

    forEachZombieNear(radius, function(zombie)
        total = total + 1
        if SZedPlus.isZedPlus(zombie) then
            special = special + 1
        end
    end)

    print(string.format("[SZedPlus] %d Zed+ out of %d zombies within %d tiles",
        special, total, radius))
    return special, total
end

--- Print one line per Zed+ nearby: stage, path and distance.
function SZedPlus.Debug.describeNearby(radius)
    radius = radius or 50
    warnIfRemoteClient()
    local found = 0

    forEachZombieNear(radius, function(zombie, distance)
        if SZedPlus.isZedPlus(zombie) then
            found = found + 1
            print(string.format("[SZedPlus]   T%s %s at %.1f tiles",
                tostring(SZedPlus.getStage(zombie)),
                tostring(SZedPlus.getPath(zombie) or "-"),
                distance))
        end
    end)

    if found == 0 then
        print(string.format("[SZedPlus] no Zed+ within %d tiles", radius))
    end
    return found
end

--- Force the nearest ordinary zombie to become a Zed+ of the given stage and
--- path, so a behaviour can be tested without waiting for the spawn roll.
function SZedPlus.Debug.makeNearestZedPlus(stage, path)
    stage = stage or 4
    warnIfRemoteClient()

    local nearest, nearestDistance = nil, math.huge
    forEachZombieNear(30, function(zombie, distance)
        if distance < nearestDistance and not SZedPlus.isZedPlus(zombie) then
            nearest, nearestDistance = zombie, distance
        end
    end)

    if not nearest then
        print("[SZedPlus] no ordinary zombie within 30 tiles")
        return nil
    end

    local data = nearest:getModData()
    data[SZedPlus.Keys.initialized] = true
    data[SZedPlus.Keys.isSpecial] = true
    data[SZedPlus.Keys.stage] = stage
    data[SZedPlus.Keys.path] = path or SZedPlus.pickRandom(SZedPlus.PathList)
    if stage == 4 then
        data[SZedPlus.Keys.t4SpawnDay] = SZedPlus.getCurrentDay()
    end

    print(string.format("[SZedPlus] promoted a zombie at %.1f tiles to T%d %s",
        nearestDistance, stage, tostring(data[SZedPlus.Keys.path])))
    return nearest
end

-- --------------------------------------------------------- model probing --

--- Force a model script onto the nearest zombie, to find out whether
--- setForceModelScript works at all on this build.
---
--- Two very different failures look identical in game - the model script not
--- being found, and the model changing but `scale` being ignored for animated
--- characters. Passing a visibly different vanilla model separates them:
---
---   SZedPlus.Debug.tryModel("Base.Female_Skeleton")  -- turns into a skeleton?
---   SZedPlus.Debug.tryModel("Base.SZedPlusBody_F_350")
---
--- If the skeleton works and ours does not, the model swap is fine and the
--- problem is our script. If neither works, the swap itself is unavailable.
function SZedPlus.Debug.tryModel(name)
    warnIfRemoteClient()

    local nearest, nearestDistance = nil, math.huge
    forEachZombieNear(30, function(zombie, distance)
        if distance < nearestDistance then
            nearest, nearestDistance = zombie, distance
        end
    end)

    if not nearest then
        print("[SZedPlus] no zombie within 30 tiles")
        return false
    end

    if getScriptManager():getModelScript(name) == nil then
        print("[SZedPlus] model script NOT FOUND: " .. tostring(name))
        return false
    end
    print("[SZedPlus] model script found: " .. tostring(name))

    local ok, err = pcall(function()
        nearest:getHumanVisual():setForceModelScript(name)
        nearest:resetModelNextFrame()
    end)
    if not ok then
        print("[SZedPlus] setForceModelScript threw: " .. tostring(err))
        return false
    end

    print(string.format("[SZedPlus] applied '%s' to a zombie at %.1f tiles",
        tostring(name), nearestDistance))
    return true
end

--- Report what the engine actually built for a model script.
---
---   SZedPlus.Debug.checkModel("SZedPlus.Bellwretch")
---   SZedPlus.Debug.checkModel("SZedPlus.BellwretchStatic")
---
--- Says whether the script resolved at all, which separates "the file is not
--- loaded" from "the file loaded and the rig is wrong".
function SZedPlus.Debug.checkModel(name)
    local script = getScriptManager():getModelScript(name)
    if script == nil then
        print("[SZedPlus] model script NOT FOUND: " .. tostring(name))
        return false
    end
    print("[SZedPlus] model script found: " .. tostring(name))
    return true
end
