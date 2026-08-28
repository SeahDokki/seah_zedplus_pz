--- ZED+ : spawn-time classification.
---
--- A zombie's tier and path are rolled exactly once, when it is first created,
--- from the current apocalypse day. Everything downstream reads that decision;
--- nothing re-rolls it.
---
--- OnZombieCreate also fires when a chunk reloads and its zombies are
--- re-instantiated, but modData survives that, so the `initialized` guard makes
--- the handler idempotent. Keep this function cheap: it runs for every zombie
--- the game creates.

--- Multiplayer: files under server/ are loaded on clients too. Zombie
--- classification is a world decision and must happen in exactly one place, or
--- every client would roll its own answer. This keeps it on the single-player
--- game, the co-op host and the dedicated server.
if isClient() then return end

SZedPlus = SZedPlus or {}
SZedPlus.Spawn = {}

-- shared/ is loaded before server/, so this is already populated.
local Keys = SZedPlus.Keys

--- Roll a stage inside the band allowed by the current day.
local function rollStage(day)
    local minStage, maxStage = SZedPlus.Config.getStageRangeForDay(day)
    if not minStage then return nil end
    return minStage + ZombRand(maxStage - minStage + 1)
end

--- Turn an ordinary zombie into a Zed+ and stamp its state.
local function classify(zombie, day)
    local data = zombie:getModData()
    local stage = rollStage(day)
    if not stage then return false end

    -- The path only means anything from T3: below that a Zed+ is just a
    -- slightly tougher zombie with no specialisation.
    local path = nil
    if stage >= 3 then
        -- Only roll among paths the player left enabled. With all four off,
        -- there is no valid T3+ zombie, so fall back to the T1-T2 band.
        local enabledPaths = SZedPlus.Config.getEnabledPaths()
        if #enabledPaths == 0 then
            stage = 1 + ZombRand(2)
        else
            path = SZedPlus.pickRandom(enabledPaths)
        end
    end

    data[Keys.isSpecial] = true
    data[Keys.stage] = stage
    data[Keys.path] = path

    -- T4 is transitional. Record when it got there so the +4 day fallback to
    -- T5 can be measured later.
    if stage == 4 then
        data[Keys.t4SpawnDay] = day
    end

    SZedPlus.log("spawned T%d %s at day %d", stage, tostring(path or "-"), day)
    return true
end

--- Mark a zombie as processed. Ordinary zombies get the flag too, so the roll
--- is never repeated for them on a chunk reload.
local function markInitialized(zombie)
    zombie:getModData()[Keys.initialized] = true
end

--- Entry point: decide what this zombie is.
function SZedPlus.Spawn.onZombieCreate(zombie)
    if zombie == nil then return end
    if SZedPlus.isInitialized(zombie) then return end

    if SZedPlus.rollOneIn(SZedPlus.Config.get("SpawnRate")) then
        classify(zombie, SZedPlus.getCurrentDay())
    end

    markInitialized(zombie)
end

Events.OnZombieCreate.Add(SZedPlus.Spawn.onZombieCreate)
