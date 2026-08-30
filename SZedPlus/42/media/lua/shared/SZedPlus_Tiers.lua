--- ZED+ : per-tier stat modifiers.
---
--- Data only - SZedPlus_Behaviour applies it. Keeping the numbers here means
--- balance can be retuned without touching the logic.
---
--- Loaded after SZedPlus_Core (alphabetical), before anything in server/.

SZedPlus = SZedPlus or {}
SZedPlus.Tiers = {}

--- Speed families, as the engine numbers them in IsoZombie.speedType.
--- Confirmed in game: a zombie on "sprint1" reported 1, one on a bare "1"
--- reported 2. Note the ordering is inverted - a LOWER number is FASTER.
SZedPlus.Tiers.SPEED_SPRINTER = 1
SZedPlus.Tiers.SPEED_FAST_SHAMBLER = 2
SZedPlus.Tiers.SPEED_SHAMBLER = 3

--- The full speed scale, slowest to fastest.
---
--- IsoZombie's documentation lists only "slow1-3 if it's a shambler, or
--- sprint1-5 if it's a sprinter" and omits the middle family entirely. It is
--- `walk1-3`, confirmed in game: a T4 Fast moved from slow2 to walk1 and
--- reported speedType 2, the fast shambler family.
---
--- With the middle filled in, a step is meaningful again: +2 from slow2 lands
--- on walk1, one family up, instead of jumping straight to a sprinter.
---
--- Validated at runtime against the engine's own mapping, so an entry the game
--- does not recognise is dropped rather than silently breaking a shift.
SZedPlus.Tiers.WALK_SCALE = {
    "slow1", "slow2", "slow3",
    "walk1", "walk2", "walk3",
    "sprint1", "sprint2", "sprint3", "sprint4", "sprint5",
}

--- Speed rules per path and stage.
---
--- `steps`   : positions moved along WALK_SCALE, clamped at both ends.
--- `floor`   : the zombie ends up at least this fast, whatever the steps gave.
--- `ceiling` : the zombie ends up at most this fast.
---
--- T3 and T4 use steps, so the effect is relative to the world the player
--- chose: +2 turns a slow2 shambler into a walk1 fast shambler, and a world
--- already running fast shamblers gets something faster still.
---
--- T5 uses a bound instead, because a final form is a promise, not a nudge: a
--- Witch is a sprinter regardless of the sandbox speed setting. Bounds are
--- applied after steps, and only ever in the intended direction, so a Fast Zed+
--- can never come out slower than the zombies around it.
SZedPlus.Tiers.SPEED_BY_PATH = {
    fast = {
        [3] = { steps = 1 },
        [4] = { steps = 2 },
        [5] = { steps = 2, floor = SZedPlus.Tiers.SPEED_SPRINTER },
    },
    tank = {
        [3] = { steps = -1 },
        [4] = { steps = -2 },
        [5] = { steps = -2, ceiling = SZedPlus.Tiers.SPEED_SHAMBLER },
    },
}

--- The speed rule for a stage and path, or nil when there is nothing to do.
function SZedPlus.Tiers.getSpeedRule(stage, path)
    local byPath = path and SZedPlus.Tiers.SPEED_BY_PATH[path]
    if byPath == nil then return nil end
    return byPath[stage]
end

--- Modifiers per stage, for the plain Reinforced tiers.
---
--- `health` multiplies the zombie's health as the game rolled it, so the
--- player's Toughness sandbox setting is still respected - a Zed+ is relative
--- to the world it spawns in, never an absolute value.
---
SZedPlus.Tiers.BY_STAGE = {
    [1] = { health = 1.15 },
    [2] = { health = 1.30 },
    [3] = { health = 1.30 },
    [4] = { health = 1.45 },
    [5] = { health = 1.60 },
}

--- Modifiers per path, applied on top of the stage modifiers.
---
--- T3 is the milder version of T4: `scale` multiplies how far the path pushes
--- away from an ordinary zombie, so a T3 Tank is tough, a T4 Tank is tougher.
---
--- Stealth and Ranged trade nothing in health: their axis is perception, see
--- SENSES_BY_PATH below.
SZedPlus.Tiers.BY_PATH = {
    fast = {
        health = 0.70,      -- faster, but noticeably easier to put down
    },
    tank = {
        health = 2.20,
    },
    stealth = {
        health = 1.0,
    },
    ranged = {
        health = 1.0,
    },
}

--- Perception rules, the Stealth/Ranged axis.
---
--- The same trade as Fast/Tank, on a different stat: Stealth barely notices
--- you, Ranged notices you from across the street.
---
--- `mode`         : "dull" drops a target beyond the radius, "keen" acquires
---                  one within it.
--- `aggroRadius`  : in tiles.
--- `aggroStrength`: weight passed to addAggro, "keen" only.
---
--- The engine's own per-zombie perception is NOT usable here. `hearing` and
--- `sight` are public int fields on IsoZombie with no setters, and Project
--- Zomboid's Lua binding does not expose Java fields - reading and writing both
--- fail at runtime (verified in game, not assumed). The Hearing and Sight
--- sandbox options are applied engine-side and cannot be overridden per zombie.
---
--- So the aggro is driven directly, which is what a perception change would
--- have produced anyway - and it gives exact distances instead of the three
--- coarse levels the sandbox exposes. An ordinary zombie notices a player at
--- roughly 10-20 tiles, so 4 tiles is "you can walk past it" and 32 is "it saw
--- you first".
SZedPlus.Tiers.SENSES_BY_PATH = {
    stealth = {
        [3] = { mode = "dull", aggroRadius = 7 },
        [4] = { mode = "dull", aggroRadius = 4 },
    },
    ranged = {
        [3] = { mode = "keen", aggroRadius = 20, aggroStrength = 1.0 },
        [4] = { mode = "keen", aggroRadius = 32, aggroStrength = 1.0 },
    },
}

--- The perception rule for a stage and path, or nil when there is nothing
--- to manage - which is the common case, and lets the sweep skip most zombies.
function SZedPlus.Tiers.getSenseRule(stage, path)
    local byPath = path and SZedPlus.Tiers.SENSES_BY_PATH[path]
    if byPath == nil then return nil end
    return byPath[stage]
end

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

--- Resolve the health modifier for a classified zombie.
--- Speed and perception are separate: see getSpeedRule() and getSenseRule().
function SZedPlus.Tiers.resolve(stage, path)
    local result = { health = 1.0 }

    local byStage = SZedPlus.Tiers.BY_STAGE[stage]
    if byStage then
        result.health = byStage.health
    end

    local byPath = path and SZedPlus.Tiers.BY_PATH[path]
    if byPath then
        local scale = SZedPlus.Tiers.PATH_SCALE[stage] or 1.0
        result.health = result.health * scaleMultiplier(byPath.health, scale)
    end

    return result
end
