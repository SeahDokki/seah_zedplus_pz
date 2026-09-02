--- ZED+ : dresses T5 zombies in their form's outfit.
---
--- Applied once per zombie and remembered in modData: worn items are saved with
--- the zombie, so re-dressing on every chunk reload would pile up clothing and
--- reset the damage.
---
--- Only T5 gets a distinctive outfit. Below that a Zed+ must be visually
--- indistinguishable from an ordinary zombie - that is the whole premise.
---
--- Files under server/ are loaded on clients too.
if isClient() then return end

SZedPlus = SZedPlus or {}
SZedPlus.Appearance = {}

local Keys = SZedPlus.Keys

-- ---------------------------------------------------------------- helpers --

--- Resolve a BloodBodyPartType by name, tolerating parts a build may not have.
local function bodyPart(name)
    local ok, part = pcall(function() return BloodBodyPartType[name] end)
    if ok then return part end
    return nil
end

--- Apply a { parts, amount } block through one HumanVisual setter.
local function applyToParts(visual, block, setter)
    if block == nil or visual == nil then return end
    for _, name in ipairs(block.parts or {}) do
        local part = bodyPart(name)
        if part then
            pcall(setter, visual, part, block.amount or 1.0)
        end
    end
end

--- Punch holes through whatever clothing covers the given parts.
---
--- Goes through the character, not through a visual. HumanVisual has getHole
--- but no setHole - the setter lives on ItemVisual, one per garment - so the
--- obvious-looking visual:setHole() was a no-op swallowed by its pcall, and the
--- Boomer's torn suit came out pristine.
---
--- IsoGameCharacter:addHole() finds the garment covering that part itself. It
--- is what the game calls from its own OnHitZombie, three times per hit, which
--- is also where the repeat count below comes from: one call is barely visible.
local function applyHoles(zombie, parts, count)
    if parts == nil or zombie == nil then return end
    for _, name in ipairs(parts) do
        local part = bodyPart(name)
        if part then
            for _ = 1, count or 3 do
                pcall(function() zombie:addHole(part) end)
            end
        end
    end
end

--- Blood on the clothing rather than on the skin underneath it.
---
--- Same trap as the holes: HumanVisual:setBlood() paints the body, which is
--- entirely hidden under a hazmat suit. The character-level call is the one
--- that marks what the zombie is wearing. Booleans copied from the vanilla
--- debug scenarios, which call it repeatedly to build the stain up.
local function applyClothingBlood(zombie, block)
    if block == nil or zombie == nil then return end
    local passes = math.max(1, math.floor((block.amount or 1.0) * 4))
    for _, name in ipairs(block.parts or {}) do
        local part = bodyPart(name)
        if part then
            for _ = 1, passes do
                pcall(function() zombie:addBlood(part, true, true, false) end)
            end
        end
    end
end

--- Walk the garments a zombie is wearing.
---
--- Not getWornItems(): a zombie does not use worn items at all. IsoZombie has
--- isUsingWornItems() precisely because the normal case is the other one - it
--- carries ItemVisuals, and real InventoryItems only materialise on the corpse
--- when it dies. Every loop that went through getWornItems() therefore ran zero
--- times, which is why the two Boomer variants looked identical and why the
--- blast reported "0 destroyed, 0 ruined".
local function forEachGarment(zombie, fn)
    pcall(function()
        local visuals = zombie:getItemVisuals()
        if visuals == nil then return end
        for index = 0, visuals:size() - 1 do
            local visual = visuals:get(index)
            if visual then fn(visual) end
        end
    end)
end
SZedPlus.Appearance.forEachGarment = forEachGarment

--- Wear one item, returning it so the caller can age it.
---
--- The item goes into the zombie's inventory first: setWornItem expects an item
--- that exists, and the body location comes from the item itself rather than
--- being guessed.
local function wearItem(zombie, itemName)
    local inventory = zombie:getInventory()
    if inventory == nil then return nil end

    local ok, item = pcall(function() return inventory:AddItem("Base." .. itemName) end)
    if not ok or item == nil then
        SZedPlus.logError("unknown clothing item '%s'", tostring(itemName))
        return nil
    end

    local location = item:getBodyLocation()
    if location == nil or location == "" then
        SZedPlus.logError("item '%s' has no body location", tostring(itemName))
        return nil
    end

    local ok2 = pcall(function() zombie:setWornItem(location, item) end)
    if not ok2 then
        SZedPlus.logError("setWornItem failed for '%s' at location '%s'",
            tostring(itemName), tostring(location))
        return nil
    end

    -- Read it back: setWornItem can refuse silently when the slot is taken by
    -- something the engine considers incompatible.
    local check = zombie:getWornItem(location)
    if check == nil then
        SZedPlus.logError("'%s' did not stay on at location '%s'",
            tostring(itemName), tostring(location))
        return nil
    end

    return item
end

--- Age an item so it reads as worn rather than freshly bought.
local function ageItem(item, outfit)
    if item == nil then return end

    if outfit.condition then
        pcall(function() item:setCondition(outfit.condition) end)
    end
    if outfit.blood then
        pcall(function() item:setBloodLevel(outfit.blood.amount or 1.0) end)
    end
    if outfit.dirt then
        -- 0-1, per the admin item editor which registers it with that range.
        pcall(function() item:setDirtiness(outfit.dirt.amount or 1.0) end)
    end
    if outfit.tint then
        pcall(function()
            item:getVisual():setTint(ImmutableColor.new(
                outfit.tint.r, outfit.tint.g, outfit.tint.b, 1.0))
        end)
    end
end

-- ---------------------------------------------------------------- prepare --

--- Claim the zombie's appearance before the engine dresses it.
---
--- Must run from OnZombieCreate, not from the delayed queue. The engine logs
--- "Spawning new Male Zed, Dressed in No Outfit" at creation and then dresses
--- the zombie on a later tick - after our clothes were already on, which is why
--- a Witch kept coming out in a t-shirt and jeans despite the code reporting
--- success.
---
--- Gender is forced here too, for the same reason: the engine picks it at
--- creation, and changing it later rebuilds the model and drops what it wears.
function SZedPlus.Appearance.prepare(zombie)
    if zombie == nil then return end

    local outfit = SZedPlus.Outfits.get(zombie:getModData()[Keys.form])
    if outfit == nil then return end

    pcall(function() zombie:setDressInRandomOutfit(false) end)

    if outfit.female ~= nil then
        pcall(function() zombie:setFemaleEtc(outfit.female) end)
    end
end

-- ------------------------------------------------------------------ apply --

--- True if this outfit asks for any clothing at all. A form that only tints or
--- bloodies the body has nothing to verify.
local function wantsClothing(outfit)
    if outfit == nil then return false end
    if outfit.outfit ~= nil then return true end
    return #(outfit.items or {}) > 0
end

--- Dress a zombie according to its T5 form. Does nothing for any other tier,
--- for a form with no outfit, or for a zombie already dressed.
---
--- RETURNS FALSE ONLY TO ASK FOR A RETRY. Every other outcome, including having
--- nothing to do at all, is true.
---
--- That distinction is the whole contract and it was got wrong once. This used
--- to return false for "no form", "no outfit" and "already dressed" as a way of
--- saying "did not dress anything" - harmless while nobody read the value. Once
--- the caller started retrying on false, every T1-T4 Zed+ (which has no form,
--- so no outfit) burned five attempts and then had a random outfit forced on it
--- with an error in the log: "could not dress nil". If a new early exit is added
--- here, it returns true unless a later attempt could genuinely succeed.
function SZedPlus.Appearance.apply(zombie)
    -- Nothing to retry: there is no zombie.
    if zombie == nil then return true end

    local data = zombie:getModData()

    -- Already wearing it.
    if data[Keys.outfitApplied] then return true end

    -- No form, or a form with no outfit. This is every T1-T4 Zed+, which is
    -- most of them, and it is a normal outcome rather than a failure.
    local outfit = SZedPlus.Outfits.get(data[Keys.form])
    if outfit == nil then return true end

    -- Some forms come in two states, and the state decides more than looks: a
    -- Boomer with its bottle still attached explodes differently. Roll it here,
    -- fold the chosen variant into the outfit, and remember the answer.
    if outfit.bottleChance then
        local hasBottle = ZombRand(100) < outfit.bottleChance
        data[Keys.formBottle] = hasBottle

        local variant = hasBottle and outfit.withBottle or outfit.withoutBottle
        if variant then
            local merged = {}
            for key, value in pairs(outfit) do merged[key] = value end
            for key, value in pairs(variant) do merged[key] = value end
            outfit = merged
        end
        SZedPlus.log("boomer %s its bottle", hasBottle and "still has" or "already lost")
    end

    -- Gender and the auto-dress flag were handled by prepare() at creation.
    -- Re-assert the flag: the engine can set it again while the zombie is
    -- being built.
    pcall(function() zombie:setDressInRandomOutfit(false) end)

    -- The named outfit first, and it replaces everything: this is the engine's
    -- own dressing path, the same one it runs for every zombie it spawns, so
    -- the clothes stick and actually render. Placing worn items by hand did
    -- not survive - they ended up on the ground as IsoFallingClothing.
    if outfit.outfit then
        local ok = pcall(function() zombie:dressInNamedOutfit(outfit.outfit) end)
        if not ok then
            SZedPlus.logError("unknown outfit '%s'", tostring(outfit.outfit))
        end
    end

    local worn = 0
    for _, itemName in ipairs(outfit.items or {}) do
        local item = wearItem(zombie, itemName)
        if item then
            ageItem(item, outfit)
            worn = worn + 1
        end
    end

    -- Report loudly if the form asked for clothing and got none: a silently
    -- naked T5 is worse than a line in the console.
    if worn == 0 and outfit.outfit == nil and #(outfit.items or {}) > 0 then
        SZedPlus.logError("dressing %s: no item could be worn",
            tostring(data[Keys.form]))
    end

    -- Dirty the garments the named outfit put on. Runs over ItemVisuals, since
    -- that is what a zombie actually wears - see forEachGarment.
    if outfit.dirt then
        local amount = outfit.dirt.amount or 1.0
        forEachGarment(zombie, function(visual)
            for _, name in ipairs(outfit.dirt.parts or {}) do
                local part = bodyPart(name)
                if part then pcall(function() visual:setDirt(part, amount) end) end
            end
        end)
    end

    -- Re-colour items the outfit chose. Done after dressing, because the outfit
    -- decides which item lands in the slot and randomises its tint.
    if outfit.tintWorn then
        local rule = outfit.tintWorn
        forEachGarment(zombie, function(visual)
            local itemType = tostring(visual:getItemType() or "")
            if string.find(itemType, rule.match, 1, true) then
                pcall(function()
                    visual:setTint(ImmutableColor.new(rule.r, rule.g, rule.b, 1.0))
                end)
            end
        end)
    end

    -- A texture painted onto the body itself, through the system the game uses
    -- for hair stubble and its own ZedDmg_* wounds. setSkinTextureName looked
    -- like the obvious route but nothing reads it - this is the one that works.
    if outfit.bodyVisual then
        local ok = pcall(function()
            zombie:addBodyVisualFromItemType(outfit.bodyVisual)
        end)
        if not ok then
            SZedPlus.logError("could not apply body visual '%s'",
                tostring(outfit.bodyVisual))
        end
    end

    -- Skin underneath: only shows through the holes, but that is the point of
    -- punching them.
    local visual = zombie:getHumanVisual()
    applyToParts(visual, outfit.blood, function(v, part, amount) v:setBlood(part, amount) end)
    applyToParts(visual, outfit.dirt, function(v, part, amount) v:setDirt(part, amount) end)

    -- Then the clothing, through the character rather than the visual.
    applyClothingBlood(zombie, outfit.blood)
    applyHoles(zombie, outfit.holes)

    -- Rebuild the model so the changes show without waiting for another event.
    pcall(function() zombie:resetModelNextFrame() end)

    -- Did any of that actually stick?
    --
    -- On a naturally spawned zombie it often does not. The engine finishes
    -- building the zombie after OnZombieCreate returns - the same reason stats
    -- are queued rather than set - and for clothing that can land AFTER this
    -- runs, stripping what was just put on. The flag was set anyway, so nothing
    -- ever retried and the T5 stayed naked for the rest of its life.
    --
    -- Debug-spawned zombies never showed it because they arrive fully built,
    -- and reloaded ones recovered by accident: the reload path clears the flag
    -- and re-queues, which is a retry by another name. That asymmetry is what
    -- identified this.
    --
    -- So verify instead of assuming, and let the caller retry. A bigger delay
    -- would only be a different guess; asking the zombie what it is wearing is
    -- the same principle already used on the reload path.
    if wantsClothing(outfit) then
        local visuals = 0
        pcall(function()
            local list = zombie:getItemVisuals()
            visuals = list and list:size() or 0
        end)

        if visuals == 0 then
            SZedPlus.log("dressing %s: nothing stuck yet, will retry",
                tostring(data[Keys.form]))
            return false
        end
    end

    data[Keys.outfitApplied] = true
    SZedPlus.log("dressed %s: outfit '%s' + %d item(s)",
        SZedPlus.describe(zombie), tostring(outfit.outfit or "-"), worn)
    return true
end

--- Give up on dressing this zombie and let the engine do it instead.
---
--- Called once the retries are exhausted. prepare() turned the engine's own
--- random dressing off, so abandoning without undoing that leaves a naked
--- zombie - which is worse than a T5 in the wrong clothes, because it reads as
--- a broken mod rather than an unlucky outfit.
function SZedPlus.Appearance.abandon(zombie)
    if zombie == nil then return end

    -- Only a form that actually wanted clothes can fail to get them. Reaching
    -- here without one means the retry contract has been broken again, so say
    -- so plainly instead of forcing a random outfit onto an ordinary Zed+.
    local form = zombie:getModData()[Keys.form]
    if form == nil then
        SZedPlus.logError("abandon() called on a zombie with no form - "
            .. "Appearance.apply returned false for something it had nothing to do")
        return
    end

    SZedPlus.logError("could not dress %s - falling back to a random outfit",
        tostring(form))

    pcall(function() zombie:setDressInRandomOutfit(true) end)
    pcall(function() zombie:dressInRandomOutfit() end)
    pcall(function() zombie:resetModelNextFrame() end)
end
