--- ZED+ : acid pools.
---
--- Shared by the Spitter, which throws them, and the Boomer, which leaves one
--- where it detonates - the design bible asks for the same effect in both.
---
--- There is no ground-effect system in the game to hang this on, so a pool is
--- an entry in a list with a position and a lifetime, checked against players
--- on the same sweep as everything else. SZedPlus_AcidRender draws them: the
--- engine's blood decals are hardcoded to BloodOverlay.png and cannot be
--- pointed at another texture.
---
--- Damage is deliberately not instant. The design gives the player half a
--- second inside the pool before anything happens, so crossing quickly is free
--- and standing in it is not.
---
--- Files under server/ are loaded on clients too.
if isClient() then return end

SZedPlus = SZedPlus or {}
SZedPlus.Acid = {}

--- Ticks between checks. Matches the other sweeps.
local SWEEP_INTERVAL_TICKS = 6

--- How long a pool lasts, and its default reach in tiles.
local POOL_LIFETIME_TICKS = 25 * 60
local POOL_RADIUS = 1.0

--- Fully waterproof footwear keeps acid off the feet. Wellies report
--- WaterResistance 1.0, which is a property of the item rather than a name we
--- have to keep a list of - anything genuinely waterproof protects.
local WATERPROOF_THRESHOLD = 0.95

--- Ticks a player must stay in before it bites - the design's half second.
local GRACE_TICKS = 30

--- Damage per sweep once the grace period has passed.
---
--- The sweep runs ten times a second, so this is multiplied by a lot very
--- quickly: the first pass at 1.6 was killing a player in about a second and
--- destroying their clothes outright. It is meant to punish standing in acid,
--- not to be a death sentence for touching it.
local DAMAGE_PER_SWEEP = 0.12

--- Burn accumulated per sweep on uncovered skin, and the ceiling it stops at.
--- Capped so a puddle leaves a nasty burn rather than a fatal one.
local BURN_PER_SWEEP = 0.15
local BURN_CEILING = 25.0

--- Condition lost by a worn item per sweep. Clothing has 0-10 condition, so
--- taking a whole point per pass shredded an outfit instantly.
local CLOTHING_WEAR_CHANCE = 12

--- Active pools: { id, x, y, z, ticks, radius }.
---
--- The id is what lets the renderer keep a marker alive across sweeps instead
--- of tearing it down and rebuilding it ten times a second.
local pools = {}
local poolCount = 0
local nextPoolId = 1

--- How long each player has been standing in acid, keyed by username so the
--- count survives a player object being rebuilt.
local exposure = {}

local tickCounter = 0

-- ----------------------------------------------------------------- pools --

--- Drop a pool at a position. Called by the Spitter and by the Boomer's blast.
function SZedPlus.Acid.spawn(x, y, z, lifetimeTicks, radius)
    poolCount = poolCount + 1
    pools[poolCount] = {
        id = nextPoolId,
        x = x, y = y, z = z,
        ticks = lifetimeTicks or POOL_LIFETIME_TICKS,
        radius = radius or POOL_RADIUS,
    }
    nextPoolId = nextPoolId + 1
    SZedPlus.log("acid pool r%.1f at %.1f,%.1f (%d pools)",
        radius or POOL_RADIUS, x, y, poolCount)
end

--- Splash several pools around a point, for an explosion.
function SZedPlus.Acid.splash(x, y, z, count, spread, radius)
    for _ = 1, count or 4 do
        local offsetX = (ZombRand(spread * 200) / 100) - spread
        local offsetY = (ZombRand(spread * 200) / 100) - spread
        SZedPlus.Acid.spawn(x + offsetX, y + offsetY, z, nil, radius)
    end
end

function SZedPlus.Acid.count()
    return poolCount
end

-- ---------------------------------------------------------------- effect --

local function getPlayers()
    if isServer() then return getOnlinePlayers() end
    return IsoPlayer.getPlayers()
end

--- Corrode what the player is wearing, and burn what is not covered.
---
--- Uncovered parts take the damage directly; covered ones lose condition on the
--- clothing instead. That is the design's trade: armour protects, and pays.
--- True if the player's footwear keeps acid out.
---
--- Read from the item rather than matched against a list of names: anything
--- genuinely waterproof - wellies, waders, a hazmat suit's boots - protects,
--- and a mod adding its own gets the same treatment for free.
local function hasWaterproofFootwear(player)
    local protected = false

    -- Walk the worn items rather than calling getWornItem("Shoes"): that
    -- overload takes an ItemBodyLocation object, not a string, and throws when
    -- handed one.
    pcall(function()
        local worn = player:getWornItems()
        for index = 0, worn:size() - 1 do
            local item = worn:getItemByIndex(index)
            if item and item.getBodyLocation
                and tostring(item:getBodyLocation()) == "Shoes" then

                local resistance = 0
                if item.getWaterResistance then
                    resistance = item:getWaterResistance() or 0
                end

                -- Ruined boots let it through, which keeps them a consumable
                -- rather than a permanent answer.
                local condition = 10
                if item.getCondition then condition = item:getCondition() or 10 end

                protected = resistance >= WATERPROOF_THRESHOLD and condition > 0
                return
            end
        end
    end)

    return protected
end

--- Is this body part covered by anything the player is wearing?
---
--- Clothing takes the corrosion in place of the skin, which is the design's
--- trade: gear protects, and pays for it.
local function isCovered(player, partType)
    local covered = false
    pcall(function()
        local worn = player:getWornItems()
        for index = 0, worn:size() - 1 do
            local item = worn:getItemByIndex(index)
            if item and item.getCoveredParts then
                local parts = item:getCoveredParts()
                if parts then
                    for partIndex = 0, parts:size() - 1 do
                        if parts:get(partIndex) == partType then
                            covered = true
                            return
                        end
                    end
                end
            end
        end
    end)
    return covered
end

local function burn(player)
    -- Plastic boots keep it off the feet entirely.
    if hasWaterproofFootwear(player) then return end

    -- Clothing corrodes slowly, and only sometimes: a point of condition per
    -- sweep would ruin an outfit in under a second.
    if ZombRand(CLOTHING_WEAR_CHANCE) == 0 then
        pcall(function()
            local worn = player:getWornItems()
            for index = 0, worn:size() - 1 do
                local item = worn:getItemByIndex(index)
                if item and item.getCondition and item.setCondition then
                    local condition = item:getCondition()
                    if condition and condition > 0 then
                        item:setCondition(condition - 1)
                    end
                end
            end
        end)
    end

    -- Only the parts standing in it: legs and feet. Burning the whole body from
    -- a puddle was both wrong and lethal.
    pcall(function()
        local body = player:getBodyDamage()
        for _, name in ipairs({ "Foot_L", "Foot_R", "LowerLeg_L", "LowerLeg_R" }) do
            local partType = BodyPartType[name]
            local part = body:getBodyPart(partType)
            if part then
                part:AddDamage(DAMAGE_PER_SWEEP)
                part:setAdditionalPain(2.0)

                -- Bare skin burns; covered skin only aches. A light burn, not
                -- a fire: it accumulates while standing in it and stops as soon
                -- as the player steps out.
                if not isCovered(player, partType) then
                    local burnTime = part:getBurnTime() or 0
                    part:setBurnTime(math.min(burnTime + BURN_PER_SWEEP, BURN_CEILING))
                end
            end
        end
    end)
end

--- One pass: age the pools, drop the expired ones, and burn anyone standing in
--- one for long enough.
local function sweep()
    if poolCount == 0 then
        exposure = {}
        if SZedPlus.AcidRender then SZedPlus.AcidRender.setPools({}) end
        return
    end

    local remaining = {}
    local remainingCount = 0

    for index = 1, poolCount do
        local pool = pools[index]
        pool.ticks = pool.ticks - SWEEP_INTERVAL_TICKS
        if pool.ticks > 0 then
            remainingCount = remainingCount + 1
            remaining[remainingCount] = pool
        end
    end

    pools = remaining
    poolCount = remainingCount

    -- Hand the drawable set to the client renderer. Only position and a fade,
    -- never anything it could decide for itself.
    if SZedPlus.AcidRender then
        local drawable = {}
        for index = 1, poolCount do
            local pool = pools[index]
            drawable[index] = {
                id = pool.id,
                x = pool.x, y = pool.y, z = pool.z,
                radius = pool.radius,
                -- Fades over the last few seconds of its life.
                alpha = math.min(1.0, pool.ticks / 180) * 0.85,
            }
        end
        SZedPlus.AcidRender.setPools(drawable)
    end

    local players = getPlayers()
    if players == nil then return end

    for index = 0, players:size() - 1 do
        local player = players:get(index)
        if player and not player:isDead() then
            local key = tostring(player:getUsername() or index)
            local inside = false

            for poolIndex = 1, poolCount do
                local pool = pools[poolIndex]
                if pool.z == player:getZ() then
                    local dx = player:getX() - pool.x
                    local dy = player:getY() - pool.y
                    local reach = pool.radius or POOL_RADIUS
                    if dx * dx + dy * dy <= reach * reach then
                        inside = true
                        break
                    end
                end
            end

            if inside then
                local held = (exposure[key] or 0) + SWEEP_INTERVAL_TICKS
                exposure[key] = held
                if held >= GRACE_TICKS then
                    burn(player)
                end
            else
                exposure[key] = nil
            end
        end
    end
end

local function onTick()
    tickCounter = tickCounter + 1
    if tickCounter < SWEEP_INTERVAL_TICKS then return end
    tickCounter = 0
    sweep()
end

Events.OnTick.Add(onTick)
