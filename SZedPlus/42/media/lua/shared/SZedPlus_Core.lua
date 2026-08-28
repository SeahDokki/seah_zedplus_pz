--- ZED+ : shared constants, modData accessors and logging.
--- Loaded after SZedPlus_Config, before anything in client/ or server/.

SZedPlus = SZedPlus or {}

SZedPlus.MOD_ID = "SZedPlus"
SZedPlus.VERSION = "0.1.0"

--- modData key names. Never inline these strings anywhere else: they are a
--- save-file schema, and a typo silently creates a second, empty field.
SZedPlus.Keys = {
    initialized     = "SZedPlus_initialized",
    isSpecial       = "SZedPlus_isSpecial",
    stage           = "SZedPlus_stage",
    path            = "SZedPlus_path",
    t4SpawnDay      = "SZedPlus_t4SpawnDay",
    calamityRefused = "SZedPlus_calamityRefused",
    calamityId      = "SZedPlus_calamityId",
}

--- The four T3-T4 specialisation paths.
SZedPlus.Path = {
    FAST    = "fast",
    TANK    = "tank",
    STEALTH = "stealth",
    RANGED  = "ranged",
}

--- Indexed copy of every path, ignoring the sandbox switches.
--- To roll a path, use SZedPlus.Config.getEnabledPaths() instead.
SZedPlus.PathList = {
    SZedPlus.Path.FAST,
    SZedPlus.Path.TANK,
    SZedPlus.Path.STEALTH,
    SZedPlus.Path.RANGED,
}

--- Which two T5 forms each path can reach.
SZedPlus.FormsByPath = {
    [SZedPlus.Path.FAST]    = { "witch", "volatile" },
    [SZedPlus.Path.TANK]    = { "colossus", "boomer" },
    [SZedPlus.Path.STEALTH] = { "sneaker", "mimic" },
    [SZedPlus.Path.RANGED]  = { "spitter", "scout" },
}

--- Which two Calamities each path can reach. Mirrors the design bible:
--- every Calamity has two classes, every class appears in two Calamities.
SZedPlus.CalamitiesByPath = {
    [SZedPlus.Path.FAST]    = { "mist", "centaur" },
    [SZedPlus.Path.TANK]    = { "leader", "centaur" },
    [SZedPlus.Path.STEALTH] = { "host", "mist" },
    [SZedPlus.Path.RANGED]  = { "host", "leader" },
}

-- ------------------------------------------------------------- contexts --

--- True where world state is authoritative: single player, co-op host, and
--- dedicated server. False on a multiplayer client.
---
--- Files under server/ are loaded on multiplayer clients too, so anything that
--- decides world state must be guarded with `if isClient() then return end`.
--- This is the same test, named for what it means.
function SZedPlus.isAuthoritative()
    return not isClient()
end

--- True in a single-player game (no server, no client).
function SZedPlus.isSinglePlayer()
    return not isServer() and not isClient()
end

--- True on a dedicated server, where there is no local player to look at.
function SZedPlus.isDedicatedServer()
    return isServer() and not isClient()
end

-- ---------------------------------------------------------------- logging --

--- Console log, gated on the Debug sandbox option so the spawn path stays
--- quiet during normal play.
function SZedPlus.log(message, ...)
    if not SZedPlus.Config.get("Debug") then return end
    if select("#", ...) > 0 then
        message = string.format(message, ...)
    end
    print("[SZedPlus] " .. tostring(message))
end

--- Always printed. For conditions that mean the mod is misconfigured or broken.
function SZedPlus.logError(message, ...)
    if select("#", ...) > 0 then
        message = string.format(message, ...)
    end
    print("[SZedPlus][ERROR] " .. tostring(message))
end

-- ------------------------------------------------------------------ time --

--- Days since the start of the apocalypse.
function SZedPlus.getCurrentDay()
    local gameTime = getGameTime()
    if not gameTime then return 0 end
    return gameTime:getNightsSurvived()
end

-- --------------------------------------------------------------- modData --

--- True if this zombie has already been through the spawn roll.
--- Zombies are re-instantiated whenever their chunk reloads, so every hook
--- must check this before doing anything.
function SZedPlus.isInitialized(zombie)
    local data = zombie:getModData()
    return data[SZedPlus.Keys.initialized] == true
end

--- True only for zombies the roll turned into a Zed+.
function SZedPlus.isZedPlus(zombie)
    local data = zombie:getModData()
    return data[SZedPlus.Keys.isSpecial] == true
end

--- Current stage (1-6), or nil for an ordinary zombie.
function SZedPlus.getStage(zombie)
    return zombie:getModData()[SZedPlus.Keys.stage]
end

--- Specialisation path, or nil below T3.
function SZedPlus.getPath(zombie)
    return zombie:getModData()[SZedPlus.Keys.path]
end

-- ---------------------------------------------------------------- random --

--- Pick one entry of an array-like table at random. ZombRand(n) returns 0..n-1.
function SZedPlus.pickRandom(list)
    if not list or #list == 0 then return nil end
    return list[ZombRand(#list) + 1]
end

--- True with a 1-in-`denominator` chance.
function SZedPlus.rollOneIn(denominator)
    if not denominator or denominator < 1 then return false end
    return ZombRand(denominator) == 0
end
