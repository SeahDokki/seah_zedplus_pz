--- ZED+ : applies tier and path modifiers to a classified zombie.
---
--- Two things learned the hard way, both of which shape this file:
---
--- 1. The engine finishes initialising a zombie AFTER OnZombieCreate returns,
---    and overwrites its health in the process. Applying stats straight from
---    that hook silently loses them. So classification still happens there, but
---    the stats are queued and applied on a later tick.
---
--- 2. Perception CANNOT be set per zombie. `hearing` and `sight` are public
---    int fields on IsoZombie with no setters, and Project Zomboid's Lua
---    binding does not expose Java fields at all - reading and writing both
---    fail. Verified in game. SZedPlus_Senses drives the aggro directly
---    instead, which is the outcome those levels would have produced.
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

--- Ticks to wait before applying stats. One is enough for the engine to finish
--- the zombie, but a small margin costs nothing and covers slower paths such as
--- a chunk streaming in.
local STATS_DELAY_TICKS = 2

--- Clothing waits considerably longer. The engine dresses a zombie well after
--- creation - long after the health pass - and anything worn before that is
--- replaced. SZedPlus_Appearance.prepare() already tells it not to, this is the
--- belt to that pair of braces.
local OUTFIT_DELAY_TICKS = 15

--- How many times dressing is retried before handing the zombie back to the
--- engine's own random outfit. Five attempts backing off by OUTFIT_DELAY_TICKS
--- each covers about seven seconds, which is far longer than any spawn observed
--- - and the point is to stop, not to keep trying forever.
local OUTFIT_MAX_ATTEMPTS = 5

--- How long to wait before asking whether the clothes are still on.
---
--- Dressing has to be checked LATER, not at the end of the dressing itself:
--- the engine finishes building a naturally spawned zombie after the mod has
--- had its turn, and clears its clothing then. Three checks in a row were
--- fooled by running too early - the last of them read getOutfitName(), which
--- still names the requested outfit on a zombie wearing nothing.
---
--- Two seconds at 60fps. Long enough to be after the engine rather than in the
--- middle of it, which is the property that matters; the exact number is not
--- load-bearing, because a failed check redresses and checks again.
local OUTFIT_VERIFY_TICKS = 120

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
    -- The speed family, kept because the walk type alone may not identify it -
    -- see normaliseWalkType.
    if data[Keys.baseSpeedType] == nil then
        data[Keys.baseSpeedType] = zombie:getSpeedType()
    end
end

-- ----------------------------------------------------------------- speed --

--- Walk-type families, keyed by the speedType the engine reports for them.
--- IsoZombie holds "slow", "walk" and "sprint" as three separate strings and
--- appends the variant number, which is why a name can arrive without one.
local FAMILY_BY_SPEED_TYPE = { [1] = "sprint", [2] = "walk", [3] = "slow" }

--- Walk types already reported as unusable, so the log gets one line and not
--- one per zombie.
local warnedWalkTypes = {}

--- The usable speed scale, resolved once: { walkType, speedType } slowest
--- first, plus a lookup from walk type back to its position.
local scale = nil
local scaleIndex = nil

--- Which speed family a walk type belongs to, per the engine.
---
--- getSpeedTypeFromWalkType is STATIC, so it is called on the class, not on an
--- instance: `zombie:getSpeedTypeFromWalkType(x)` passes the zombie as the
--- first argument and throws. Checked with tools/methodsig.py, which prints
--- access modifiers alongside descriptors.
local function speedTypeOf(walkType)
    local ok, speedType = pcall(IsoZombie.getSpeedTypeFromWalkType, walkType)
    if ok then return speedType end
    return nil
end

--- Build the scale, keeping only the entries the engine actually recognises.
---
--- Hardcoding the list would mean trusting that walk1-3 exists on every build;
--- probing it means an entry the game rejects is simply dropped, and the shift
--- still works over what remains.
local function getScale()
    if scale ~= nil then return scale end

    scale = {}
    scaleIndex = {}
    for _, walkType in ipairs(SZedPlus.Tiers.WALK_SCALE) do
        local speedType = speedTypeOf(walkType)
        if speedType ~= nil then
            scale[#scale + 1] = { walkType = walkType, speedType = speedType }
            scaleIndex[walkType] = #scale
        end
    end

    local names = {}
    for _, entry in ipairs(scale) do
        names[#names + 1] = string.format("%s(%d)", entry.walkType, entry.speedType)
    end
    SZedPlus.log("speed scale: %s", table.concat(names, " "))

    return scale
end

--- Turn whatever getWalkType() returned into a name that is on the scale.
---
--- It can come back as a bare variant number - "1" through "5" - rather than
--- the family-prefixed name the scale is built from. That placed no zombie on
--- the scale, so every speed rule was skipped: 144 times in a single session,
--- which had quietly disabled the T1-T4 speed modifier altogether while the
--- health modifier beside it worked fine. The log said so plainly, once per
--- zombie, and it went unread.
---
--- The family is what the number is missing, and getSpeedType() supplies it, so
--- the name can be rebuilt from two values the engine gave us. Then it is
--- CHECKED against getSpeedTypeFromWalkType: the engine has to agree that the
--- rebuilt name belongs to that family. A reconstruction that validates against
--- the engine is worth keeping; one that merely looks plausible is a guess, and
--- guessing at this exact spot is what the previous rounds cost.
local function normaliseWalkType(walkType, speedType)
    if walkType == nil then return nil end

    -- Already a name we know.
    if scaleIndex[walkType] then return walkType end

    local variant = string.match(tostring(walkType), "^(%d+)$")
    if variant == nil then return nil end

    local family = FAMILY_BY_SPEED_TYPE[speedType]
    if family == nil then return nil end

    local rebuilt = family .. variant
    if scaleIndex[rebuilt] == nil then return nil end
    if speedTypeOf(rebuilt) ~= speedType then return nil end

    return rebuilt
end

--- First position on the scale that is at least as fast as `speedType`.
local function firstPositionAtLeast(speedType)
    for index, entry in ipairs(getScale()) do
        if entry.speedType <= speedType then return index end
    end
    return nil
end

--- Last position on the scale that is at most as fast as `speedType`.
local function lastPositionAtMost(speedType)
    local found = nil
    for index, entry in ipairs(getScale()) do
        if entry.speedType >= speedType then found = index end
    end
    return found
end

--- Apply the path's speed rule.
---
--- Steps first, then the bound: the step expresses "faster than the world",
--- the bound expresses "this form is always a sprinter". Applying the bound
--- last means it wins when the two disagree.
local function applySpeed(zombie, data, stage)
    local rule = SZedPlus.Tiers.getSpeedRule(stage, data[Keys.path])
    if rule == nil then return end

    local baseWalkType = data[Keys.baseWalkType]
    if baseWalkType == nil then return end

    local entries = getScale()

    -- Saves written before the speed family was captured have no baseline for
    -- it. Reading it now is correct for exactly those zombies: the rule they
    -- needed it for was being skipped, so their speed was never touched and the
    -- current family is still the original one.
    local baseSpeedType = data[Keys.baseSpeedType]
    if baseSpeedType == nil then
        baseSpeedType = zombie:getSpeedType()
        data[Keys.baseSpeedType] = baseSpeedType
    end

    local resolved = normaliseWalkType(baseWalkType, baseSpeedType)
    local position = resolved and scaleIndex[resolved] or nil
    if position == nil then
        -- Still unplaceable: leave the zombie alone rather than guess. Once per
        -- walk type, because the alternative was 144 identical lines.
        if not warnedWalkTypes[tostring(baseWalkType)] then
            warnedWalkTypes[tostring(baseWalkType)] = true
            SZedPlus.log("walk type '%s' (speed family %s) is not on the scale, "
                .. "speed rule skipped", tostring(baseWalkType), tostring(baseSpeedType))
        end
        return
    end

    if rule.steps then
        position = position + rule.steps
        if position < 1 then position = 1 end
        if position > #entries then position = #entries end
    end

    -- A lower speedType is faster, so a floor caps the number and a ceiling
    -- raises it.
    if rule.floor and entries[position].speedType > rule.floor then
        position = firstPositionAtLeast(rule.floor) or position
    end
    if rule.ceiling and entries[position].speedType < rule.ceiling then
        position = lastPositionAtMost(rule.ceiling) or position
    end

    local walkType = entries[position].walkType
    if walkType ~= zombie:getWalkType() then
        zombie:setWalkType(walkType)
        zombie:setSpeedTypeFromWalkType()
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

    applySpeed(zombie, data, stage)

    return true
end

-- ----------------------------------------------------------------- queue --

--- Ask for this zombie's stats and clothing to be applied shortly.
---
--- Separate entries, because they need very different delays - and dressing
--- adds a third of its own once it has run, to check the clothes are still
--- there. See OUTFIT_VERIFY_TICKS.
function SZedPlus.Behaviour.queue(zombie)
    if zombie == nil then return end

    pendingCount = pendingCount + 1
    pending[pendingCount] = { zombie = zombie, ticks = STATS_DELAY_TICKS, what = "stats" }

    -- Only a zombie with a form has clothing to put on, and only T5 has a
    -- form. Queuing the other tiers put every ordinary Zed+ through the
    -- dressing path to be told there was nothing to dress - harmless in
    -- itself, but it is most of the zombies in the queue for no reason.
    if zombie:getModData()[Keys.form] ~= nil then
        pendingCount = pendingCount + 1
        pending[pendingCount] = { zombie = zombie, ticks = OUTFIT_DELAY_TICKS, what = "outfit" }
    end
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
                if entry.what == "outfit" then
                    -- Retried until the clothes verifiably stick.
                    --
                    -- On a naturally spawned zombie the engine finishes
                    -- dressing it AFTER this first runs and strips what was
                    -- put on, so one attempt at a fixed delay is a coin toss -
                    -- and it was losing. Appearance.apply now reports whether
                    -- anything landed, and this backs off and tries again
                    -- rather than trusting a bigger magic number.
                    if SZedPlus.Appearance.apply(zombie) then
                        -- Dressed, as far as this instant can tell - which is
                        -- not far. Queue a check for once the engine has
                        -- finished with the zombie.
                        remainingCount = remainingCount + 1
                        remaining[remainingCount] = {
                            zombie = zombie,
                            ticks = OUTFIT_VERIFY_TICKS,
                            what = "verify",
                            attempts = entry.attempts or 1,
                        }
                    else
                        entry.attempts = (entry.attempts or 1) + 1
                        if entry.attempts <= OUTFIT_MAX_ATTEMPTS then
                            -- Back off: each attempt waits longer than the
                            -- last, so a slow spawn is caught without holding
                            -- every zombie in the queue for the same duration.
                            entry.ticks = OUTFIT_DELAY_TICKS * entry.attempts
                            remainingCount = remainingCount + 1
                            remaining[remainingCount] = entry
                        else
                            SZedPlus.Appearance.abandon(zombie)
                        end
                    end
                elseif entry.what == "verify" then
                    -- The authoritative dressing, and the reason it is late.
                    --
                    -- The engine dresses zombies itself, after the mod has had
                    -- its turn, and the log showed both ways that goes wrong.
                    -- Some T5s were still in their own outfit and rendering as
                    -- bare bodies, because the model had been built before the
                    -- clothes went on and was never built again. Others were
                    -- wearing a random civilian outfit the engine had put on
                    -- over ours - a Witch in a t-shirt, denim shorts and
                    -- glasses. One cause, two symptoms, and the early attempt
                    -- loses the race either way.
                    --
                    -- Telling the two apart would mean recognising our outfit
                    -- among the garments, and half of these outfits have no
                    -- garment a random one could not also have:
                    -- ConstructionWorker guarantees a belt, denim trousers,
                    -- heavy socks and work boots and nothing else. Four checks
                    -- have now been fooled by asking an approximate question,
                    -- so this one does not ask. It dresses the zombie again,
                    -- here, where the engine has already finished, and rebuilds
                    -- the model immediately afterwards.
                    --
                    -- Once per zombie. dressInNamedOutfit replaces rather than
                    -- adds, so this cannot stack clothing, but repeating it on
                    -- every chunk reload would reset the damage on what the
                    -- zombie is wearing.
                    local data = zombie:getModData()
                    if not data[Keys.outfitFinal] then
                        data[Keys.outfitFinal] = true
                        SZedPlus.Appearance.reset(zombie)
                        SZedPlus.Appearance.apply(zombie)

                        -- resetModel() rather than resetModelNextFrame():
                        -- immediate, and by now there is nothing left to race.
                        pcall(function() zombie:resetModel() end)
                    end

                    local worn, list = SZedPlus.Appearance.wornSummary(zombie)

                    if SZedPlus.Appearance.isDressed(zombie) then
                        -- Logged with the garment list, on purpose. Every round
                        -- of this bug was spent inferring what a T5 was wearing
                        -- from something that was not that; the list is cheap,
                        -- and it is what finally identified the random outfits.
                        SZedPlus.log("%s dressed for good: %d garment(s) [%s]",
                            SZedPlus.describe(zombie), worn, list)
                    else
                        entry.attempts = (entry.attempts or 1) + 1
                        SZedPlus.log("%s has no clothes after the late dressing "
                            .. "- attempt %d", SZedPlus.describe(zombie), entry.attempts)

                        if entry.attempts <= OUTFIT_MAX_ATTEMPTS then
                            data[Keys.outfitFinal] = nil
                            SZedPlus.Appearance.reset(zombie)
                            remainingCount = remainingCount + 1
                            remaining[remainingCount] = {
                                zombie = zombie,
                                ticks = OUTFIT_DELAY_TICKS,
                                what = "outfit",
                                attempts = entry.attempts,
                            }
                        else
                            SZedPlus.Appearance.abandon(zombie)
                        end
                    end
                else
                    SZedPlus.Behaviour.apply(zombie)
                end
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
        hasTarget = zombie:getTarget() ~= nil,
    }

    if stats.stage then
        local modifiers = SZedPlus.Tiers.resolve(stats.stage, stats.path)
        stats.healthMultiplier = modifiers.health

        local rule = SZedPlus.Tiers.getSpeedRule(stats.stage, stats.path)
        if rule then
            local parts = {}
            if rule.steps then parts[#parts + 1] = string.format("%+d", rule.steps) end
            if rule.floor then parts[#parts + 1] = "floor " .. rule.floor end
            if rule.ceiling then parts[#parts + 1] = "ceiling " .. rule.ceiling end
            stats.speedRule = table.concat(parts, ", ")

            -- Whether the rule is satisfied as things stand. Lets the panel
            -- tell "nothing left to do" apart from "could not be done".
            local current = stats.speedType
            stats.speedRuleMet = current ~= nil
                and not (rule.floor and current > rule.floor)
                and not (rule.ceiling and current < rule.ceiling)
        end

        local formRule = SZedPlus.Forms.get(stats.form)
        if formRule then
            stats.formMode = formRule.mode
            stats.formTriggered = data[Keys.formTriggered] == true
            stats.formFuse = data[Keys.formFuse]
            stats.formBottle = data[Keys.formBottle] == true
        end

        local senses = SZedPlus.Tiers.getSenseRule(stats.stage, stats.path)
        if senses then
            stats.senseMode = senses.mode
            stats.senseRadius = senses.aggroRadius
        end
        -- What the health should be. Shown next to the live value so a mismatch
        -- is visible rather than something to work out by hand.
        if stats.baseHealth then
            stats.expectedHealth = stats.baseHealth * modifiers.health
        end
    end

    return stats
end
