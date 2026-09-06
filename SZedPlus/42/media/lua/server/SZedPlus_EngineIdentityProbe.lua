--- ZED+ TEMPORARY ENGINE IDENTITY PROBE 2
---
--- Diagnostic-only server-side probe for Project Zomboid B42 zombie lifecycle.
--- It does NOT classify zombies, persist ordinary zombies, alter ZED+ identity
--- matching, change spawn probabilities, or write probe values into ModData.
---
--- The client-side debug menu can arm a bounded world-space test area. While
--- armed, this module snapshots zombies already loaded in that area, logs
--- OnZombieCreate observations, and logs one post-create snapshot on the next
--- tick. Spawn.lua also calls noteNaturalRoll() immediately before the existing
--- natural SpawnRate roll so we can prove whether a reconstructed ordinary
--- zombie re-enters that lottery.
---
--- Remove this file, its matching client probe menu, and the one diagnostic
--- Spawn.lua call before making a release build.

if isClient() then return end

SZedPlus = SZedPlus or {}
SZedPlus.EngineIdentityProbe = {}

local Probe = SZedPlus.EngineIdentityProbe
local Keys = SZedPlus.Keys
local MODULE = "SZedPlusEngineProbe"
local DEFAULT_RADIUS = 30
local MAX_RADIUS = 80
local POST_CREATE_DELAY_TICKS = 1

local state = {
    enabled = false,
    label = nil,
    anchorX = nil,
    anchorY = nil,
    anchorZ = nil,
    radius = DEFAULT_RADIUS,
    session = 0,
    sequence = 0,
    tick = 0,
}

local pendingPostCreate = {}

-- --------------------------------------------------------------- helpers --

local function clean(value)
    if value == nil then return "nil" end
    local text = tostring(value)
    text = text:gsub("[\r\n\t]", " ")
    text = text:gsub("|", "/")
    return text
end

local function safe(label, fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return "<ERR:" .. clean(label) .. ":" .. clean(value) .. ">"
end

local function safeModData(zombie)
    local ok, data = pcall(function() return zombie:getModData() end)
    if ok then return data end
    return nil
end

local function worldAgeHours()
    return safe("worldAgeHours", function()
        local gameTime = getGameTime()
        if gameTime == nil then return nil end
        return gameTime:getWorldAgeHours()
    end)
end

local function timestampMs()
    if type(getTimestampMs) ~= "function" then return nil end
    return safe("timestampMs", function() return getTimestampMs() end)
end

local function virtualReused(zombie)
    return safe("isReused", function()
        if VirtualZombieManager == nil or VirtualZombieManager.instance == nil then
            return nil
        end
        return VirtualZombieManager.instance:isReused(zombie)
    end)
end

local function zombieInfoSummary(zombie)
    if type(getZombieInfo) ~= "function" then return "<UNAVAILABLE>" end

    local ok, info = pcall(function() return getZombieInfo(zombie) end)
    if not ok then return "<ERR:getZombieInfo:" .. clean(info) .. ">" end
    if info == nil then return "nil" end

    local parts = {}
    local iterOk, iterErr = pcall(function()
        for key, value in pairs(info) do
            local valueType = type(value)
            if valueType == "string" or valueType == "number" or valueType == "boolean" or value == nil then
                parts[#parts + 1] = clean(key) .. "=" .. clean(value)
            else
                parts[#parts + 1] = clean(key) .. "=<" .. valueType .. ":" .. clean(value) .. ">"
            end
        end
    end)

    if not iterOk then
        return "<ERR:iterateZombieInfo:" .. clean(iterErr) .. ">"
    end

    table.sort(parts)
    if #parts > 40 then
        local truncated = {}
        for i = 1, 40 do truncated[i] = parts[i] end
        truncated[#truncated + 1] = "<TRUNCATED total=" .. tostring(#parts) .. ">"
        parts = truncated
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function withinAnchor(zombie)
    if not state.enabled or zombie == nil then return false end
    local x = safe("x", function() return zombie:getX() end)
    local y = safe("y", function() return zombie:getY() end)
    local z = safe("z", function() return zombie:getZ() end)
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return false end
    if z ~= state.anchorZ then return false end
    local dx, dy = x - state.anchorX, y - state.anchorY
    return dx * dx + dy * dy <= state.radius * state.radius
end

local function snapshot(zombie)
    local data = safeModData(zombie)
    local persistentOutfitInitBefore = safe("isPersistentOutfitInit_before", function()
        return zombie:isPersistentOutfitInit()
    end)
    local persistentOutfitId = safe("getPersistentOutfitID", function()
        return zombie:getPersistentOutfitID()
    end)
    local persistentOutfitInitAfter = safe("isPersistentOutfitInit_after", function()
        return zombie:isPersistentOutfitInit()
    end)

    local result = {
        x = safe("x", function() return zombie:getX() end),
        y = safe("y", function() return zombie:getY() end),
        z = safe("z", function() return zombie:getZ() end),
        exists = safe("exists", function() return zombie:isExistInTheWorld() end),
        initialized = data and data[Keys.initialized] or nil,
        isSpecial = data and data[Keys.isSpecial] or nil,
        persistId = data and data[Keys.persistId] or nil,
        stage = data and data[Keys.stage] or nil,
        path = data and data[Keys.path] or nil,
        form = data and data[Keys.form] or nil,
        uid = safe("getUID", function() return zombie:getUID() end),
        objectId = safe("getID", function() return zombie:getID() end),
        entityNetId = safe("getEntityNetID", function() return zombie:getEntityNetID() end),
        onlineId = safe("getOnlineID", function() return zombie:getOnlineID() end),
        sharedDescriptorId = safe("getSharedDescriptorID", function() return zombie:getSharedDescriptorID() end),
        persistentOutfitInitBefore = persistentOutfitInitBefore,
        persistentOutfitId = persistentOutfitId,
        persistentOutfitInitAfter = persistentOutfitInitAfter,
        outfitName = safe("getOutfitName", function() return zombie:getOutfitName() end),
        female = safe("isFemale", function() return zombie:isFemale() end),
        reanimatedPlayer = safe("isReanimatedPlayer", function() return zombie:isReanimatedPlayer() end),
        firstUpdate = safe("isFirstUpdate", function() return zombie:isFirstUpdate() end),
        reused = virtualReused(zombie),
        zombieInfo = zombieInfoSummary(zombie),
    }

    return result
end

local function logLine(eventLabel, zombie, extra)
    state.sequence = state.sequence + 1
    local s = snapshot(zombie)

    local line = string.format(
        "[SZedPlus][ENGINE_PROBE] session=%d test=%s seq=%d tick=%d event=%s " ..
        "worldAgeHours=%s timestampMs=%s pos=%s,%s,%s exists=%s " ..
        "initialized=%s special=%s persistId=%s stage=%s path=%s form=%s " ..
        "uid=%s objectId=%s entityNetId=%s onlineId=%s sharedDescriptorId=%s " ..
        "persistentOutfitInitBefore=%s persistentOutfitId=%s persistentOutfitInitAfter=%s " ..
        "outfit=%s female=%s reanimatedPlayer=%s firstUpdate=%s reused=%s " ..
        "zombieInfo=%s%s",
        state.session,
        clean(state.label),
        state.sequence,
        state.tick,
        clean(eventLabel),
        clean(worldAgeHours()),
        clean(timestampMs()),
        clean(s.x), clean(s.y), clean(s.z), clean(s.exists),
        clean(s.initialized), clean(s.isSpecial), clean(s.persistId),
        clean(s.stage), clean(s.path), clean(s.form),
        clean(s.uid), clean(s.objectId), clean(s.entityNetId), clean(s.onlineId),
        clean(s.sharedDescriptorId), clean(s.persistentOutfitInitBefore),
        clean(s.persistentOutfitId), clean(s.persistentOutfitInitAfter), clean(s.outfitName),
        clean(s.female), clean(s.reanimatedPlayer), clean(s.firstUpdate), clean(s.reused),
        clean(s.zombieInfo),
        extra and (" " .. clean(extra)) or ""
    )

    print(line)
    return s
end

local function forEachZombieInAnchor(visitor)
    local cell = getCell()
    if cell == nil then return 0 end
    local zombies = cell:getZombieList()
    if zombies == nil then return 0 end

    local count = 0
    for i = 0, zombies:size() - 1 do
        local zombie = zombies:get(i)
        if zombie ~= nil and withinAnchor(zombie) then
            count = count + 1
            visitor(zombie)
        end
    end
    return count
end

local function clampRadius(value)
    value = tonumber(value) or DEFAULT_RADIUS
    if value < 3 then value = 3 end
    if value > MAX_RADIUS then value = MAX_RADIUS end
    return value
end

local function findZombieAt(x, y, z, radius)
    local cell = getCell()
    if cell == nil then return nil end
    local zombies = cell:getZombieList()
    if zombies == nil then return nil end

    local best = nil
    local bestDistanceSq = (radius or 3) * (radius or 3)
    for i = 0, zombies:size() - 1 do
        local zombie = zombies:get(i)
        if zombie ~= nil and zombie:getZ() == z then
            local dx, dy = zombie:getX() - x, zombie:getY() - y
            local distanceSq = dx * dx + dy * dy
            if distanceSq <= bestDistanceSq then
                best = zombie
                bestDistanceSq = distanceSq
            end
        end
    end
    return best
end

-- --------------------------------------------------------------- actions --

function Probe.start(player, args)
    if player == nil then return false end
    args = args or {}

    state.session = state.session + 1
    state.sequence = 0
    state.tick = 0
    state.label = tostring(args.label or "UNLABELLED")
    state.anchorX = tonumber(args.x) or player:getX()
    state.anchorY = tonumber(args.y) or player:getY()
    state.anchorZ = tonumber(args.z) or player:getZ()
    state.radius = clampRadius(args.radius)
    state.enabled = true
    pendingPostCreate = {}

    print(string.format(
        "[SZedPlus][ENGINE_PROBE] START session=%d test=%s anchor=%.2f,%.2f,%s radius=%s diagnosticOnly=true",
        state.session, clean(state.label), state.anchorX, state.anchorY,
        clean(state.anchorZ), clean(state.radius)))

    local count = forEachZombieInAnchor(function(zombie)
        logLine("BASELINE", zombie)
    end)

    print(string.format(
        "[SZedPlus][ENGINE_PROBE] BASELINE_COMPLETE session=%d test=%s count=%d",
        state.session, clean(state.label), count))
    return true
end

function Probe.checkpoint(player, args)
    if not state.enabled then
        print("[SZedPlus][ENGINE_PROBE] CHECKPOINT_IGNORED reason=not_enabled")
        return false
    end

    local suffix = args and args.label and tostring(args.label) or "MANUAL"
    local count = forEachZombieInAnchor(function(zombie)
        logLine("CHECKPOINT_" .. suffix, zombie)
    end)
    print(string.format(
        "[SZedPlus][ENGINE_PROBE] CHECKPOINT_COMPLETE session=%d test=%s label=%s count=%d",
        state.session, clean(state.label), clean(suffix), count))
    return true
end

function Probe.stop(player, args)
    if not state.enabled then
        print("[SZedPlus][ENGINE_PROBE] STOP_IGNORED reason=not_enabled")
        return false
    end

    Probe.checkpoint(player, { label = "STOP" })
    print(string.format(
        "[SZedPlus][ENGINE_PROBE] STOP session=%d test=%s totalSeq=%d",
        state.session, clean(state.label), state.sequence))

    state.enabled = false
    pendingPostCreate = {}
    return true
end

function Probe.snapshotTarget(player, args)
    if player == nil then return false end
    args = args or {}
    local x = tonumber(args.x) or player:getX()
    local y = tonumber(args.y) or player:getY()
    local z = tonumber(args.z) or player:getZ()
    local radius = clampRadius(args.radius or 3)
    local zombie = findZombieAt(x, y, z, radius)
    if zombie == nil then
        print(string.format(
            "[SZedPlus][ENGINE_PROBE] TARGET_NOT_FOUND test=%s pos=%s,%s,%s radius=%s",
            clean(state.label), clean(x), clean(y), clean(z), clean(radius)))
        return false
    end
    logLine("TARGET", zombie)
    return true
end

function Probe.status()
    print(string.format(
        "[SZedPlus][ENGINE_PROBE] STATUS enabled=%s session=%d test=%s anchor=%s,%s,%s radius=%s seq=%d tick=%d",
        clean(state.enabled), state.session, clean(state.label), clean(state.anchorX),
        clean(state.anchorY), clean(state.anchorZ), clean(state.radius),
        state.sequence, state.tick))
    return state.enabled
end

--- Called only by the temporary diagnostic hook in Spawn.lua.
--- This path is deliberately minimal because it executes immediately before
--- the production rarity RNG. Do not call snapshot(), logLine(), or any
--- exploratory engine identity getter from here.
function Probe.noteNaturalRoll(zombie, spawnRate)
    if not state.enabled or not withinAnchor(zombie) then return end

    state.sequence = state.sequence + 1

    local data = nil
    if zombie ~= nil then
        local ok, value = pcall(function() return zombie:getModData() end)
        if ok then data = value end
    end

    local x, y, z = nil, nil, nil
    if zombie ~= nil then
        local okX, valueX = pcall(function() return zombie:getX() end)
        local okY, valueY = pcall(function() return zombie:getY() end)
        local okZ, valueZ = pcall(function() return zombie:getZ() end)
        if okX then x = valueX end
        if okY then y = valueY end
        if okZ then z = valueZ end
    end

    print(string.format(
        "[SZedPlus][ENGINE_PROBE] session=%d test=%s seq=%d tick=%d event=NATURAL_ROLL_REACHED " ..
        "worldAgeHours=%s timestampMs=%s spawnRate=%s pos=%s,%s,%s " ..
        "initialized=%s special=%s persistId=%s stage=%s path=%s form=%s",
        state.session,
        clean(state.label),
        state.sequence,
        state.tick,
        clean(worldAgeHours()),
        clean(timestampMs()),
        clean(spawnRate),
        clean(x), clean(y), clean(z),
        clean(data and data[Keys.initialized] or nil),
        clean(data and data[Keys.isSpecial] or nil),
        clean(data and data[Keys.persistId] or nil),
        clean(data and data[Keys.stage] or nil),
        clean(data and data[Keys.path] or nil),
        clean(data and data[Keys.form] or nil)
    ))
end

-- --------------------------------------------------------------- events --

local function onZombieCreate(zombie)
    if not state.enabled or zombie == nil or not withinAnchor(zombie) then return end

    logLine("CREATE_EVENT", zombie)
    pendingPostCreate[#pendingPostCreate + 1] = {
        zombie = zombie,
        dueTick = state.tick + POST_CREATE_DELAY_TICKS,
    }
end

local function onTick()
    if not state.enabled then return end
    state.tick = state.tick + 1

    if #pendingPostCreate == 0 then return end
    local keep = {}
    for _, pending in ipairs(pendingPostCreate) do
        if pending.dueTick <= state.tick then
            if pending.zombie ~= nil then
                logLine("POST_CREATE", pending.zombie)
            end
        else
            keep[#keep + 1] = pending
        end
    end
    pendingPostCreate = keep
end

Events.OnZombieCreate.Add(onZombieCreate)
Events.OnTick.Add(onTick)

-- ------------------------------------------------------ command bridge --

local HANDLERS = {
    start = Probe.start,
    checkpoint = Probe.checkpoint,
    stop = Probe.stop,
    snapshotTarget = Probe.snapshotTarget,
    status = function(player, args) return Probe.status() end,
}

function Probe.handleLocalCommand(command, player, args)
    local handler = HANDLERS[command]
    if handler == nil then
        print("[SZedPlus][ENGINE_PROBE] unknown local command=" .. clean(command))
        return false
    end
    return handler(player, args or {})
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE then return end

    local handler = HANDLERS[command]
    if handler == nil then return end

    local allowed = false
    local ok = pcall(function()
        allowed = player:getRole():hasCapability(Capability.UseDebugContextMenu)
    end)
    if not ok or not allowed then
        print("[SZedPlus][ENGINE_PROBE] refused command=" .. clean(command) .. " reason=no_debug_capability")
        return
    end

    handler(player, args or {})
end

Events.OnClientCommand.Add(onClientCommand)
