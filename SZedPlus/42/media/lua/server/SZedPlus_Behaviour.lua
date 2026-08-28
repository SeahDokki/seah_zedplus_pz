--- ZED+ : applies tier and path modifiers to a classified zombie.
---
--- Two things learned the hard way, both of which shape this file:
---
--- 1. The engine finishes initialising a zombie AFTER OnZombieCreate returns,
---    and overwrites its health in the process. Applying stats straight from
---    that hook silently loses them. So classification still happens there, but
---    the stats are queued and applied on a later tick.
---
--- 2. IsoZombie has a `hearing` field but no setHearing() method, so per-zombie
---    hearing cannot be changed from Lua. The Stealth path's short aggro range
---    needs a different mechanism - see the note at the bottom.
---
--- Idempotent by construction: the zombie's original health and walk type are
--- captured once into modData, and modifiers are always computed from those, so
--- re-applying after a chunk reload gives the same result instead of stacking.
---
--- Files under server/ are loaded on clients too.
if isClient() then return end

SZedPlus = SZedPlus or {}
SZedPlus.Behaviour = {}

local Keys = SZedPlus.Keys

--- Zombies waiting for their stats. Kept as a list rather than a per-zombie
--- flag checked in OnZombieUpdate: that hook runs for every zombie on every
--- tick, and this queue is empty almost all the time.
local pending = {}
local pendingCount = 0

--- Ticks to wait before applying. One is enough for the engine to finish the
--- zombie, but a small margin costs nothing and covers slower paths such as a
--- chunk streaming in.
local APPLY_DELAY_TICKS = 2

-- --------------------------------------------------------------- capture --

--- Record the zombie's untouched values, once.
--- Called at apply time, not at classification time, for the reason above: the
--- values are not final until the engine has finished with the zombie.
local function captureBaseline(zombie, data)
    if data[Keys.baseHealth] == nil then
        data[Keys.baseHealth] = zombie:getHealth()
    end
    if data[Keys.baseWalkType] == nil then
        data[Keys.baseWalkType] = zombie:getWalkType()
    end
end

-- ----------------------------------------------------------------- apply --

--- Apply every modifier this zombie's stage and path call for.
--- Safe to call repeatedly on the same zombie.
function SZedPlus.Behaviour.apply(zombie)
    if zombie == nil then return false end
    if not SZedPlus.isZedPlus(zombie) then return false end

    local data = zombie:getModData()
    local stage = data[Keys.stage]
    if stage == nil then return false end

    captureBaseline(zombie, data)

    local modifiers = SZedPlus.Tiers.resolve(stage, data[Keys.path])

    -- Health, always recomputed from the captured baseline.
    local baseHealth = data[Keys.baseHealth]
    if baseHealth then
        zombie:setHealth(baseHealth * modifiers.health)
    end

    -- Walk speed, shifted along the scale from the captured baseline so the
    -- world's own speed setting is preserved.
    local baseWalkType = data[Keys.baseWalkType]
    if baseWalkType and modifiers.speedSteps ~= 0 then
        local walkType = SZedPlus.Tiers.shiftWalkType(baseWalkType, modifiers.speedSteps)
        if walkType and walkType ~= zombie:getWalkType() then
            zombie:setWalkType(walkType)
            zombie:setSpeedTypeFromWalkType()
        end
    end

    return true
end

-- ----------------------------------------------------------------- queue --

--- Ask for this zombie's stats to be applied shortly.
function SZedPlus.Behaviour.queue(zombie)
    if zombie == nil then return end
    pendingCount = pendingCount + 1
    pending[pendingCount] = { zombie = zombie, ticks = APPLY_DELAY_TICKS }
end

--- Drain the queue. Cheap when empty, which is the normal case.
local function onTick()
    if pendingCount == 0 then return end

    local remaining = {}
    local remainingCount = 0

    for index = 1, pendingCount do
        local entry = pending[index]
        entry.ticks = entry.ticks - 1

        if entry.ticks > 0 then
            remainingCount = remainingCount + 1
            remaining[remainingCount] = entry
        else
            -- The zombie may have been removed while waiting.
            local zombie = entry.zombie
            if zombie:getSquare() ~= nil then
                SZedPlus.Behaviour.apply(zombie)
            end
        end
    end

    pending = remaining
    pendingCount = remainingCount
end

Events.OnTick.Add(onTick)

-- ----------------------------------------------------------------- stats --

--- Read back what a zombie currently is, for the debug stats panel.
--- Works on ordinary zombies too, so a Zed+ can be compared against one.
function SZedPlus.Behaviour.readStats(zombie)
    if zombie == nil then return nil end

    local data = zombie:getModData()
    local stats = {
        isZedPlus = SZedPlus.isZedPlus(zombie),
        stage = data[Keys.stage],
        path = data[Keys.path],
        form = data[Keys.form],
        calamity = data[Keys.calamityKind],

        health = zombie:getHealth(),
        baseHealth = data[Keys.baseHealth],
        walkType = zombie:getWalkType(),
        baseWalkType = data[Keys.baseWalkType],
        speedType = zombie:getSpeedType(),
        crawling = zombie:isCrawling(),
        knockedDown = zombie:isKnockedDown(),
    }

    if stats.stage then
        local modifiers = SZedPlus.Tiers.resolve(stats.stage, stats.path)
        stats.healthMultiplier = modifiers.health
        stats.speedSteps = modifiers.speedSteps
        -- What the health should be. Shown next to the live value so a mismatch
        -- is visible rather than something to work out by hand.
        if stats.baseHealth then
            stats.expectedHealth = stats.baseHealth * modifiers.health
        end
    end

    return stats
end

-- NOTE (Stealth path): "only aggros from very close" is not implemented.
-- IsoZombie exposes `hearing` as a field with no setter, so it cannot be
-- lowered per zombie from Lua. The options are to clear the zombie's target
-- while the player is beyond a threshold, or to drive it through vision
-- instead. To be settled when the Stealth behaviour is built.
