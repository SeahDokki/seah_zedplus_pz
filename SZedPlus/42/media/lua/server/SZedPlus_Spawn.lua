--- ZED+ : spawn-time classification.
---
--- A zombie's tier and path are rolled exactly once, when it is first created,
--- from the current apocalypse day. Everything downstream reads that decision;
--- nothing re-rolls it.
---
--- OnZombieCreate also fires when a chunk reloads and its zombies are
--- re-instantiated, but modData survives that, so the `initialized` guard makes
--- the handler idempotent. Keep this cheap: it runs for every zombie created.

--- Multiplayer: files under server/ are loaded on clients too. Zombie
--- classification is a world decision and must happen in exactly one place, or
--- every client would roll its own answer. This keeps it on the single-player
--- game, the co-op host and the dedicated server.
if isClient() then return end

SZedPlus = SZedPlus or {}
SZedPlus.Spawn = {}

-- shared/ is loaded before server/, so this is already populated.
local Keys = SZedPlus.Keys

--- Set by forceNext() and consumed by the next OnZombieCreate. Used by the
--- debug menu to spawn a chosen tier without waiting for the rarity roll.
local pendingSpec = nil

-- ----------------------------------------------------------------- apply --

--- Write a fully decided spec onto a zombie.
--- spec = { stage = 1..6, path = "fast", form = "witch", calamity = "host" }
---
--- Returns true if it was applied. Exposed so the debug tools and, later, the
--- promotion logic can share one writer for this state.
function SZedPlus.Spawn.applySpec(zombie, spec)
    if zombie == nil or spec == nil or spec.stage == nil then return false end

    local data = zombie:getModData()
    local day = SZedPlus.getCurrentDay()

    data[Keys.initialized] = true
    data[Keys.isSpecial] = true
    data[Keys.stage] = spec.stage
    data[Keys.path] = spec.path
    data[Keys.form] = spec.form
    data[Keys.calamityKind] = spec.calamity

    -- Recorded but not currently read: T5 is rolled at spawn rather than
    -- promoted, so there is no survival delay to measure. Kept because it
    -- costs a single number and it is the field a future promotion path would
    -- want - see getStageRangeForDay for why promotion was not built.
    if spec.stage == 4 then
        data[Keys.t4SpawnDay] = day
    end

    -- Appearance is claimed immediately: the engine dresses the zombie on a
    -- later tick and would replace anything put on before that.
    SZedPlus.Appearance.prepare(zombie)

    -- Stats are queued instead: the engine overwrites health as soon as this
    -- hook returns.
    SZedPlus.Behaviour.queue(zombie)
    SZedPlus.Senses.track(zombie)
    SZedPlus.FormBehaviour.track(zombie)

    -- A T5 is remembered in world ModData, because its own modData does not
    -- survive the population manager - see SZedPlus_Persistence.
    if SZedPlus.Persistence then SZedPlus.Persistence.remember(zombie) end

    SZedPlus.log("applied %s at day %d", SZedPlus.describe(zombie), day)
    return true
end

--- Force the next zombie created to match this spec, bypassing the rarity
--- roll. Consumed once, so it cannot leak into unrelated spawns.
function SZedPlus.Spawn.forceNext(spec)
    pendingSpec = spec
end

-- ------------------------------------------------------------------ roll --

--- Roll a stage for the current day, weighted so the mix climbs over time.
---
--- Not a uniform pick across the allowed band any more: that made a T5 as
--- likely as a T1 on the day T5 unlocked, and froze the mix from then on. The
--- weights come from Config.getStageWeightsForDay, which is where the shape of
--- the curve is explained.
local function rollStage(day)
    local weights = SZedPlus.Config.getStageWeightsForDay(day)
    if not weights then return nil end

    local total = 0
    for _, weight in pairs(weights) do total = total + weight end
    if total <= 0 then return nil end

    -- ZombRand is integer-only, so roll in hundredths to keep the fractional
    -- part of a half-ramped weight meaningful.
    local roll = ZombRand(math.floor(total * 100) + 1) / 100

    local running = 0
    for stage = 1, 5 do
        local weight = weights[stage]
        if weight then
            running = running + weight
            if roll <= running then return stage end
        end
    end

    -- Only reachable through floating-point drift at the very top of the
    -- range; fall back to the highest stage the day allows.
    local _, maxStage = SZedPlus.Config.getStageRangeForDay(day)
    return maxStage
end

--- Build a spec for a natural spawn, or nil if no Zed+ can appear today.
---
--- Falls back rather than failing. Every "cannot" here is a legitimate
--- configuration, not an error: a player who disables all four paths, or zeroes
--- both forms of every path, should still get the tiers below rather than no
--- Zed+ at all.
local function rollSpec(day)
    local stage = rollStage(day)
    if not stage then return nil end

    local path = nil
    local form = nil

    if stage == 5 then
        -- A T5 needs a path that still has a form to become. Both its forms
        -- zeroed means that path cannot produce one, so pick among the paths
        -- that can; if none can, this is a T4 instead.
        local able = SZedPlus.Config.getPathsThatCanFormT5()
        if #able == 0 then
            stage = 4
        else
            path = SZedPlus.pickRandom(able)
            form = SZedPlus.Config.pickFormForPath(path)
            -- Belt and braces: pickFormForPath already returned non-nil for
            -- every path in `able`, but the weights are read live and a server
            -- admin can change them between those two calls.
            if not form then stage = 4 end
        end
    end

    if stage >= 3 and not path then
        -- Only roll among paths the player left enabled. With all four off,
        -- there is no valid T3+ zombie, so fall back to the T1-T2 band.
        local enabledPaths = SZedPlus.Config.getEnabledPaths()
        if #enabledPaths == 0 then
            stage = 1 + ZombRand(2)
        else
            path = SZedPlus.pickRandom(enabledPaths)
        end
    end

    return { stage = stage, path = path, form = form }
end

-- ----------------------------------------------------------------- hooks --

--- Is this "zombie" actually a bandit from the Bandits mod?
---
--- Bandits are implemented as IsoZombies carrying a "Bandit" animation
--- variable, so every zombie hook in this mod sees them. Classifying one as a
--- Zed+ would give a human NPC zombie stats, a T5 outfit and a T5 behaviour -
--- and the freeze and hold logic fights the bandit AI for control of the same
--- character.
---
--- Reported by IronLungs on the Workshop page, who had it from Slayer's own mod
--- page. Unconfirmed as an observed conflict, but the check costs nothing and
--- the failure mode if it is real is bad, so it goes in either way.
---
--- getVariableBoolean returns false for a variable that was never set, so this
--- is safe with the Bandits mod absent. Wrapped anyway: it runs on every single
--- zombie creation, and this hook is not a place to risk a throw.
local function isBandit(zombie)
    local ok, bandit = pcall(function()
        return zombie:getVariableBoolean("Bandit")
    end)
    return ok and bandit == true
end

--- Entry point: decide what this zombie is.
function SZedPlus.Spawn.onZombieCreate(zombie)
    if zombie == nil then return end

    -- Bandits are not zombies, whatever the class says. Leave them alone
    -- entirely - before the forced-spec branch, so the debug menu cannot turn
    -- one into a Zed+ by accident either.
    if isBandit(zombie) then return end

    -- A forced spec wins over everything, including the initialized guard:
    -- the debug menu spawns a zombie and claims the very next creation.
    if pendingSpec ~= nil then
        local spec = pendingSpec
        pendingSpec = nil
        SZedPlus.Spawn.applySpec(zombie, spec)
        return
    end

    -- Already classified. This fires again whenever a chunk brings its zombies
    -- back, which is exactly when the modifiers need re-applying: the engine
    -- rebuilds the zombie, modData survives, the stats do not necessarily.
    if SZedPlus.isInitialized(zombie) then
        if SZedPlus.isZedPlus(zombie) then
            -- Re-dress if the clothes are gone.
            --
            -- modData survives a save and reload - the chunk writes it - so the
            -- "already dressed" flag comes back set. The engine does not
            -- restore what it was wearing though: it rebuilds the zombie from a
            -- descriptor, and a T5 came back in its own clothes. Asking the
            -- zombie what it is wearing settles it, rather than trusting a flag
            -- that outlived the thing it described.
            local naked = false
            pcall(function()
                local visuals = zombie:getItemVisuals()
                naked = visuals == nil or visuals:size() == 0
            end)
            if naked then
                zombie:getModData()[Keys.outfitApplied] = nil
                SZedPlus.Appearance.prepare(zombie)
            end

            SZedPlus.Behaviour.queue(zombie)
            SZedPlus.Senses.track(zombie)
            SZedPlus.FormBehaviour.track(zombie)
            if SZedPlus.Persistence then SZedPlus.Persistence.remember(zombie) end
        end
        return
    end

    -- Before rolling: this zombie may be standing where a T5 was left. The
    -- object is new - the old one was discarded with its modData - but the form
    -- belongs to the place, so it is handed over rather than lost.
    if SZedPlus.Persistence then
        local claim, key = SZedPlus.Persistence.findClaim(zombie)
        if claim then
            SZedPlus.Persistence.consume(key)
            SZedPlus.Spawn.applySpec(zombie, {
                stage = 5, path = claim.path, form = claim.form,
            })
            SZedPlus.log("a T5 %s reclaimed its form here", tostring(claim.form))
            return
        end
    end

    if SZedPlus.rollOneIn(SZedPlus.Config.get("SpawnRate")) then
        local spec = rollSpec(SZedPlus.getCurrentDay())
        if spec then
            SZedPlus.Spawn.applySpec(zombie, spec)
        end
    end

    -- Ordinary zombies get the flag too, so the roll is never repeated for
    -- them when their chunk reloads.
    zombie:getModData()[Keys.initialized] = true
end

Events.OnZombieCreate.Add(SZedPlus.Spawn.onZombieCreate)
