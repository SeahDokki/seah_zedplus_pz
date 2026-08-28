--- ZED+ : per-tier stat modifiers.
---
--- Data only - SZedPlus_Behaviour applies it. Keeping the numbers here means
--- balance can be retuned without touching the logic.
---
--- Loaded after SZedPlus_Core (alphabetical), before anything in server/.

SZedPlus = SZedPlus or {}
SZedPlus.Tiers = {}

--- The engine's walk types, slowest to fastest.
---
--- From IsoZombie's own documentation: "This Zed's walking type. slow1-3 if
--- it's a shambler, or sprint1-5 if it's a sprinter." The ordering within each
--- family is inferred, not documented; the debug stats panel shows the live
--- value so it can be checked in game.
SZedPlus.Tiers.WALK_SPEEDS = {
    "slow1", "slow2", "slow3",
    "sprint1", "sprint2", "sprint3", "sprint4", "sprint5",
}

--- Reverse lookup, built once.
SZedPlus.Tiers.WALK_SPEED_INDEX = {}
for index, name in ipairs(SZedPlus.Tiers.WALK_SPEEDS) do
    SZedPlus.Tiers.WALK_SPEED_INDEX[name] = index
end

--- Modifiers per stage, for the plain Reinforced tiers.
---
--- `health` multiplies the zombie's health as the game rolled it, so the
--- player's Toughness sandbox setting is still respected - a Zed+ is relative
--- to the world it spawns in, never an absolute value.
---
--- `speedSteps` shifts the walk type along WALK_SPEEDS. Relative for the same
--- reason: on a Shamblers world a Fast Zed+ becomes a quicker shambler, it does
--- not suddenly sprint.
SZedPlus.Tiers.BY_STAGE = {
    [1] = { health = 1.15, speedSteps = 0 },
    [2] = { health = 1.30, speedSteps = 0 },
    [3] = { health = 1.30, speedSteps = 0 },
    [4] = { health = 1.45, speedSteps = 0 },
}

--- Modifiers per path, applied on top of the stage modifiers.
---
--- `hearing` is DESIGN INTENT ONLY and currently has no effect: IsoZombie
--- exposes `hearing` as a field with no setter, so it cannot be changed per
--- zombie from Lua. Kept here because the Stealth behaviour will need the
--- intent; see the note at the end of SZedPlus_Behaviour.lua.
---
--- T3 is the milder version of T4: `scale` multiplies how far the path pushes
--- away from an ordinary zombie, so a T3 Tank is tough, a T4 Tank is tougher.
SZedPlus.Tiers.BY_PATH = {
    fast = {
        health = 0.70,      -- faster, but noticeably easier to put down
        speedSteps = 1,
        hearing = 1.0,
    },
    tank = {
        health = 2.20,
        speedSteps = -1,
        hearing = 1.0,
    },
    stealth = {
        health = 1.0,
        speedSteps = 0,
        hearing = 0.25,     -- only reacts from very close
    },
    ranged = {
        health = 1.0,
        speedSteps = 0,
        hearing = 1.0,
    },
}

--- How strongly the path modifier counts at each stage.
SZedPlus.Tiers.PATH_SCALE = {
    [3] = 0.5,
    [4] = 1.0,
}

--- Blend a multiplier towards 1 according to `scale`.
--- scale 1 keeps the value, scale 0.5 applies half the deviation from neutral.
local function scaleMultiplier(value, scale)
    return 1.0 + (value - 1.0) * scale
end

--- Resolve the final modifiers for a classified zombie.
--- Returns a table { health, speedSteps, hearing }.
function SZedPlus.Tiers.resolve(stage, path)
    local result = { health = 1.0, speedSteps = 0, hearing = 1.0 }

    local byStage = SZedPlus.Tiers.BY_STAGE[stage]
    if byStage then
        result.health = byStage.health
        result.speedSteps = byStage.speedSteps
    end

    local byPath = path and SZedPlus.Tiers.BY_PATH[path]
    if byPath then
        local scale = SZedPlus.Tiers.PATH_SCALE[stage] or 1.0
        result.health = result.health * scaleMultiplier(byPath.health, scale)
        result.hearing = scaleMultiplier(byPath.hearing, scale)

        -- Speed steps are whole positions on the scale, so round rather than
        -- blend: half a step would be meaningless.
        local steps = byPath.speedSteps * scale
        result.speedSteps = result.speedSteps
            + (steps >= 0 and math.floor(steps + 0.5) or -math.floor(-steps + 0.5))
    end

    return result
end

--- Shift a walk type by `steps` along the speed scale, clamped at both ends.
--- Returns the original value when it is not a name we know.
function SZedPlus.Tiers.shiftWalkType(walkType, steps)
    if steps == 0 then return walkType end

    local index = SZedPlus.Tiers.WALK_SPEED_INDEX[walkType]
    if index == nil then return walkType end

    local target = index + steps
    if target < 1 then target = 1 end
    if target > #SZedPlus.Tiers.WALK_SPEEDS then target = #SZedPlus.Tiers.WALK_SPEEDS end

    return SZedPlus.Tiers.WALK_SPEEDS[target]
end
