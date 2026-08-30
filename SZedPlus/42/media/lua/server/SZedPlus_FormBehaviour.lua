--- ZED+ : T5 final form behaviours - the logic.
---
--- One sweep over the tracked T5 zombies, a handful of ticks apart. Same shape
--- as SZedPlus_Senses and for the same reason: OnZombieUpdate would run for
--- every zombie in the world, this list is short and usually empty.
---
--- Per-zombie state lives in modData, so a form keeps its mind across a chunk
--- reload - a Witch that has screamed stays woken, a Mimic stays dormant.
---
--- Multiplayer: nothing here sends a position. Movement goes through
--- setTarget/pathToLocation and the engine replicates it, which is the rule
--- that keeps this from desyncing the way hand-streamed creatures do.
---
--- Files under server/ are loaded on clients too.
if isClient() then return end

SZedPlus = SZedPlus or {}
SZedPlus.FormBehaviour = {}

local Keys = SZedPlus.Keys

--- Ticks between sweeps. Behaviour reads as instant to a player well below
--- this, and it keeps the cost off the frame budget.
local SWEEP_INTERVAL_TICKS = 6

local tracked = {}
local trackedCount = 0
local tickCounter = 0

--- Colossi currently tracked. Kept apart because they need attention every
--- tick, not every sweep: a knockdown lands between two sweeps and the zombie
--- is already on the floor by the time the sweep comes round. OnHitZombie was
--- not enough either - the fall is decided after that hook returns.
local steadfast = {}
local steadfastCount = 0

local function holdSteadfast()
    if steadfastCount == 0 then return end

    local remaining = {}
    local remainingCount = 0

    for index = 1, steadfastCount do
        local zombie = steadfast[index]
        if zombie ~= nil and zombie:getSquare() ~= nil and not zombie:isDead() then
            pcall(function()
                zombie:setUnbalancedLevel(0.0)
                zombie:setStaggerBack(false)
                if zombie:isKnockedDown() then
                    zombie:setKnockedDown(false)
                    zombie:setCrawler(false)
                    zombie:setFallOnFront(false)
                end
            end)
            remainingCount = remainingCount + 1
            remaining[remainingCount] = zombie
        end
    end

    steadfast = remaining
    steadfastCount = remainingCount
end


-- --------------------------------------------------------------- helpers --

local function squaredDistance(a, b)
    local dx, dy = a:getX() - b:getX(), a:getY() - b:getY()
    return dx * dx + dy * dy
end

local function getPlayers()
    if isServer() then return getOnlinePlayers() end
    return IsoPlayer.getPlayers()
end

--- Nearest living player on the same floor, with the squared distance.
local function findNearestPlayer(zombie)
    local players = getPlayers()
    if players == nil then return nil, nil end

    local best, bestDistance = nil, nil
    for index = 0, players:size() - 1 do
        local player = players:get(index)
        if player and not player:isDead() and player:getZ() == zombie:getZ() then
            local distance = squaredDistance(zombie, player)
            if bestDistance == nil or distance < bestDistance then
                best, bestDistance = player, distance
            end
        end
    end
    return best, bestDistance
end

--- Make a noise the world reacts to.
---
--- addSound() is what the game uses for gunshots, so a scream really does pull
--- zombies in rather than merely playing a sound.
---
--- The coordinates MUST be integers: the signature is (Object, int, int, int,
--- int, int). Passing getX() straight through hands it a float, and the sound
--- either never registers or lands nowhere - which is why zombies ignored the
--- Scout's scream even though the log said it screamed.
local function makeNoise(zombie, radius, volume)
    local x = math.floor(zombie:getX())
    local y = math.floor(zombie:getY())
    local z = math.floor(zombie:getZ())

    local ok = pcall(function()
        getWorldSoundManager():addSound(zombie, x, y, z, radius, volume)
    end)
    if not ok then
        pcall(function() addSound(zombie, x, y, z, radius, volume) end)
    end
end

--- Force a walk type outright, for forms whose speed is a promise rather than
--- a modifier. Re-asserted every sweep: the engine rewrites walkType when a
--- zombie changes state, so setting it once at spawn does not hold.
local function enforceWalkType(zombie, walkType)
    if walkType == nil then return end
    if zombie:getWalkType() == walkType then return end
    pcall(function()
        zombie:setWalkType(walkType)
        zombie:setSpeedTypeFromWalkType()
    end)
end

--- Lock a zombie onto a player and keep it there.
local function chase(zombie, player)
    zombie:addAggro(player, 100.0)
    zombie:setTarget(player)
end

-- -------------------------------------------------------------- routines --

--- Is the zombie inside the player's field of view?
---
--- Dot product between where the player faces and the direction to the zombie.
--- Both vectors normalised, so the result is the cosine of the angle between
--- them: 1 is dead ahead, 0 is straight out to the side, -1 is directly behind.
local function isWatchedBy(zombie, player, halfAngleDegrees)
    local fx, fy = player:getForwardDirectionX(), player:getForwardDirectionY()
    if fx == nil or fy == nil then return false end

    local dx = zombie:getX() - player:getX()
    local dy = zombie:getY() - player:getY()
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.001 then return true end

    local cosine = (fx * dx + fy * dy) / length
    return cosine >= math.cos(math.rad(halfAngleDegrees))
end

--- Witch: motionless until something gets close, then one scream and a chase
--- that never ends. `relentless` is re-asserted every sweep, which is what
--- makes driving away pointless.
--- Move a zombie somewhere else outright.
---
--- A one-off jump, not streamed movement: the engine picks the new position up
--- and replicates it like any other, so this does not break the "never send
--- positions" rule the way per-tick nudging would.
local function relocate(zombie, x, y, z)
    local cell = getCell()
    if cell == nil then return false end

    local square = cell:getGridSquare(math.floor(x), math.floor(y), math.floor(z))
    if square == nil or not square:isFree(false) then return false end

    local ok = pcall(function()
        zombie:setX(x)
        zombie:setY(y)
        zombie:setZ(z)
        zombie:setLastX(x)
        zombie:setLastY(y)
        zombie:setCurrentSquare(square)
    end)
    return ok
end

local function runAmbush(zombie, rule, data, player, distance)
    enforceWalkType(zombie, rule.forceWalkType)

    if data[Keys.formTriggered] then
        -- Once she has someone, she has them. The target is never cleared -
        -- only her death or theirs ends it.
        if player == nil then return end
        chase(zombie, player)

        -- Too far to ever catch up on foot: close the gap, but only while she
        -- is not being looked at. She is never seen to appear.
        if rule.teleportDist and distance
            and distance > rule.teleportDist * rule.teleportDist
            and not isWatchedBy(zombie, player, 70) then

            local fx = player:getForwardDirectionX() or 0
            local fy = player:getForwardDirectionY() or 0
            local behind = rule.teleportBehind or 15
            if relocate(zombie,
                player:getX() - fx * behind,
                player:getY() - fy * behind,
                player:getZ()) then
                SZedPlus.log("witch closed the distance")
            end
        end
        return
    end

    if player == nil or distance == nil then return end
    if distance > rule.triggerDist * rule.triggerDist then
        -- Not yet noticed: sit still and forget anything the engine picked up.
        zombie:setTarget(nil)
        zombie:clearAggroList()
        if rule.sitWhileWaiting then
            -- Re-asserted every sweep: the engine clears this as soon as the
            -- zombie changes state, so setting it once never held.
            pcall(function()
                zombie:setSitAgainstWall(true)
                zombie:setCanWalk(false)
            end)
        end
        return
    end

    data[Keys.formTriggered] = true
    pcall(function()
        zombie:setSitAgainstWall(false)
        zombie:setCanWalk(true)
    end)
    makeNoise(zombie, rule.screamRadius, rule.screamVolume)
    chase(zombie, player)
    SZedPlus.log("witch woke and screamed")
end

--- Colossus: neither pushed back nor knocked down.
---
--- Three things, because setStaggerBack alone is not enough - it stops the
--- recoil animation but not the fall. `unbalancedLevel` is what builds up to a
--- knockdown, so it is zeroed every sweep, and `alwaysKnockedDown` is cleared
--- in case something set it.
local function runUnstoppable(zombie, rule)
    if not rule.noStagger then return end

    pcall(function()
        zombie:setStaggerBack(false)
        zombie:setUnbalancedLevel(0.0)
        zombie:setAlwaysKnockedDown(false)
    end)

    -- Already down: put it back on its feet rather than let it crawl.
    if zombie:isKnockedDown() then
        pcall(function()
            zombie:setKnockedDown(false)
            zombie:setCrawler(false)
        end)
    end
end

--- Boomer: close in, stop short, scream, detonate after the fuse.
--- Where the blast tears its own suit open. Restricted to regions the hazmat
--- suit can actually show damage on - it declares
---   BloodLocation = Trousers;Jumper;Head;Neck;Hands;Shoes
--- and a hole asked for anywhere else is silently dropped.
local BLAST_HOLES = {
    "Torso_Upper", "Torso_Lower",
    "UpperArm_L", "UpperArm_R", "ForeArm_L", "ForeArm_R",
    "UpperLeg_L", "UpperLeg_R", "LowerLeg_L", "LowerLeg_R",
    "Hand_L", "Hand_R", "Neck", "Head",
}

local function runBomb(zombie, rule, data, player, distance)
    local fuse = data[Keys.formFuse]

    if fuse then
        fuse = fuse - SWEEP_INTERVAL_TICKS
        if fuse > 0 then
            data[Keys.formFuse] = fuse
            -- Rooted while the fuse burns. setCanWalk alone does not hold it:
            -- the engine re-acquires the player and walks again, so the target
            -- is cleared every sweep as well.
            pcall(function()
                zombie:setCanWalk(false)
                zombie:setTarget(nil)
                zombie:clearAggroList()
            end)
            return
        end

        data[Keys.formFuse] = nil

        -- Wreck what it was wearing, BEFORE anything else. A hazmat suit is
        -- valuable and killing a Boomer should not be a free way to get one.
        --
        -- Order matters: the explosion can kill the zombie itself, and the
        -- corpse copies its clothing the moment it dies. Ruining the gear after
        -- the blast was ruining a zombie that no longer owned it, which is why
        -- the suit kept coming out pristine.
        --
        -- Through ItemVisuals, not getWornItems(): a zombie carries visuals,
        -- not worn items, so the old loop ran zero times and reported
        -- "0 destroyed, 0 ruined" while the suit came out untouched. The real
        -- InventoryItems only exist once the corpse is built, which is after
        -- this point - so the damage has to be written onto the visual, which
        -- is what the corpse is built from.
        local destroyed = ZombRand(100) < (rule.gearDestroyedChance or 20)
        local holed = 0

        SZedPlus.Appearance.forEachGarment(zombie, function(visual)
            if destroyed then
                -- Nothing left to loot: strip the garment outright.
                pcall(function() visual:clear() end)
            else
                -- Shredded but still on the corpse. Holes everywhere, which is
                -- both what the player sees and what the looted item inherits.
                for _, name in ipairs(BLAST_HOLES) do
                    local part = BloodBodyPartType[name]
                    if part then
                        for _ = 1, 3 do
                            pcall(function() zombie:addHole(part) end)
                            pcall(function() zombie:addBlood(part, true, true, false) end)
                        end
                        holed = holed + 1
                    end
                end
            end
        end)

        pcall(function() zombie:resetModelNextFrame() end)
        SZedPlus.log("boomer gear: %s (%d holes)",
            destroyed and "destroyed" or "shredded", holed)


        -- Acid always. Fire only if it was carrying the bottle - that is the
        -- whole point of the 25% roll, and the difference is worth seeing.
        SZedPlus.Acid.splash(zombie:getX(), zombie:getY(), zombie:getZ(),
            rule.acidPools or 5, rule.acidSpread or 2.0, rule.acidRadius)

        if data[Keys.formBottle] then
            local square = zombie:getSquare()
            if square then
                pcall(function()
                    IsoFireManager.explode(getCell(), square,
                        rule.explosionPower or 60)
                end)
            end
            SZedPlus.log("boomer went up with the bottle")
        end

        -- Direct damage to anyone caught in the blast, since there is no
        -- explosion doing it for us any more.
        local radius = rule.blastRadius or 4.0
        local players = getPlayers()
        if players then
            for index = 0, players:size() - 1 do
                local nearby = players:get(index)
                if nearby and not nearby:isDead()
                    and nearby:getZ() == zombie:getZ()
                    and squaredDistance(zombie, nearby) <= radius * radius then
                    pcall(function()
                        nearby:getBodyDamage():getBodyParts():get(0)
                            :AddDamage(rule.blastDamage or 40.0)
                        nearby:setVariable("BumpFall", true)
                        nearby:setVariable("BumpFallType", "pushedFront")
                    end)
                end
            end
        end

        SZedPlus.log("boomer detonated")
        pcall(function() zombie:Kill(nil) end)
        return
    end

    if player == nil or distance == nil then return end

    -- Out of range entirely: leave it alone. findNearestPlayer has no range
    -- limit, so without this the Boomer was permanently locked onto whoever was
    -- nearest anywhere on the floor.
    local chaseDist = rule.chaseDist or 25
    if distance > chaseDist * chaseDist then return end

    if distance <= rule.triggerDist * rule.triggerDist then
        -- Proximity is not enough: it has to have actually seen you. Walking up
        -- behind an unaware Boomer set it off, which made sneaking past one
        -- impossible and rewarded nothing.
        local spotted = false
        pcall(function()
            spotted = zombie:getTarget() ~= nil and zombie:isTargetVisible()
        end)
        if not spotted then return end

        data[Keys.formFuse] = rule.fuseTicks
        makeNoise(zombie, rule.screamRadius, rule.screamVolume)

        -- Drop it where it stands. A zombie on the ground cannot walk, which
        -- holds it far more reliably than setCanWalk ever did - and it reads
        -- as the thing swelling up before it goes off.
        pcall(function()
            zombie:setFallOnFront(true)
            zombie:knockDown(true)
            zombie:setCanWalk(false)
        end)
        SZedPlus.log("boomer primed")
    else
        chase(zombie, player)
    end
end

--- Stalker: still while watched, quick while not.
---
--- The whole form rests on one thing the engine does reliably - stopping a
--- zombie dead. It is never seen moving, only closer than it was. Cornered at
--- close range it gives up the act and rushes, so backing into a wall does not
--- neutralise it.
local function runStalk(zombie, rule, data, player, distance)
    enforceWalkType(zombie, rule.forceWalkType)

    if player == nil or distance == nil then return end
    if distance > rule.triggerDist * rule.triggerDist then
        zombie:setTarget(nil)
        zombie:clearAggroList()
        pcall(function() zombie:setCanWalk(true) end)
        return
    end

    -- Close enough that freezing would be absurd: it commits.
    if distance <= rule.commitDist * rule.commitDist then
        pcall(function() zombie:setCanWalk(true) end)
        chase(zombie, player)
        data[Keys.formTriggered] = true
        return
    end

    if isWatchedBy(zombie, player, rule.visionAngle) then
        -- Watched: stop completely. Keeping the target would leave it edging
        -- forward, which is exactly what gives the trick away.
        pcall(function() zombie:setCanWalk(false) end)
        zombie:setTarget(nil)
        data[Keys.formTriggered] = false
        return
    end

    -- Unwatched: close the distance, fast.
    pcall(function() zombie:setCanWalk(true) end)
    chase(zombie, player)
    data[Keys.formTriggered] = true
end

--- Mimic: plays dead, then fights from the floor until it puts the player
--- down. Only once they are on the ground does it get up.
---
--- Three states, in modData so they survive a chunk reload:
---   dormant  - flat, no target, indistinguishable from a corpse
---   grabbing - awake but still on the floor, going for the ankles
---   upright  - the player went down, so it does too... upwards
local function runDormant(zombie, rule, data, player, distance)
    local awake = data[Keys.formTriggered]
    local floored = data[Keys.formFloored]

    -- Dormant: flat and inert until something stands on it.
    if not awake then
        pcall(function()
            zombie:setCrawler(true)
            zombie:knockDown(false)
            zombie:setCanWalk(false)
        end)
        zombie:setTarget(nil)
        zombie:clearAggroList()

        if player and distance and distance <= rule.wakeDist * rule.wakeDist then
            data[Keys.formTriggered] = true
            SZedPlus.log("mimic woke")
        end
        return
    end

    -- Lost the player: back down, and stay down. Not merely dormant - it does
    -- not shuffle off looking for anyone.
    if player == nil or distance == nil
        or distance > rule.sleepDist * rule.sleepDist then
        data[Keys.formTriggered] = nil
        data[Keys.formFloored] = nil
        pcall(function()
            zombie:setCrawler(true)
            zombie:setCanWalk(false)
        end)
        zombie:setTarget(nil)
        zombie:clearAggroList()
        SZedPlus.log("mimic went dormant")
        return
    end

    -- Already brought the player down: get up and fight normally.
    if floored then
        pcall(function()
            zombie:setCrawler(false)
            zombie:setCanWalk(true)
            zombie:setUseless(false)
        end)
        chase(zombie, player)
        return
    end

    -- Still on the floor, grabbing at whatever comes close. It crawls after
    -- the player rather than standing, which is the whole idea.
    --
    -- setUseless stops it biting and scratching while it is down: it was
    -- clawing at an arm from the floor, which made no sense and let it stand up
    -- on a hit that was never meant to count.
    pcall(function()
        zombie:setCrawler(true)
        zombie:setCanWalk(true)
        if rule.grabOnly then zombie:setUseless(true) end
    end)
    chase(zombie, player)

    if distance > rule.floorRange * rule.floorRange then return end

    local cooldown = (data[Keys.formCooldown] or 0) - SWEEP_INTERVAL_TICKS
    if cooldown > 0 then
        data[Keys.formCooldown] = cooldown
        return
    end
    data[Keys.formCooldown] = rule.grabIntervalTicks

    -- Try to take them down. Fitness resists: a strong survivor shrugs off
    -- more attempts before going over.
    local fitness = 5
    pcall(function()
        fitness = player:getPerkLevel(Perks.Fitness) or 5
    end)

    -- 10 fitness resists most attempts, 0 almost none.
    if ZombRand(10) >= fitness then
        data[Keys.formFloored] = true
        pcall(function()
            player:setVariable("BumpFall", true)
            player:setVariable("BumpFallType", "pushedBack")
            player:fallenOnKnees()
        end)
        SZedPlus.log("mimic floored the player (fitness %d)", fitness)
    else
        SZedPlus.log("mimic grab resisted (fitness %d)", fitness)
    end
end

--- Spitter: keeps its distance and throws acid at the player's feet.
---
--- It aims slightly ahead of where the player stands, so walking into it is the
--- mistake rather than standing still.
local function runSpitter(zombie, rule, data, player, distance)
    if player == nil or distance == nil then return end
    if distance > rule.triggerDist * rule.triggerDist then
        -- Out of range: drop everything, including a half-finished spit.
        data[Keys.formRoot] = nil
        pcall(function() zombie:setCanWalk(true) end)
        return
    end

    -- Only spits at something it has actually noticed. Without this it threw
    -- acid at a player it had never aggroed, purely on distance.
    if zombie:getTarget() == nil and not zombie:isTargetVisible() then
        return
    end

    -- Planted while spitting: this is the window to close the distance on it.
    local rooted = data[Keys.formRoot]
    if rooted then
        rooted = rooted - SWEEP_INTERVAL_TICKS
        if rooted > 0 then
            data[Keys.formRoot] = rooted
            pcall(function()
                zombie:setCanWalk(false)
                zombie:setTarget(nil)
            end)
            return
        end
        data[Keys.formRoot] = nil
        pcall(function() zombie:setCanWalk(true) end)
    end

    chase(zombie, player)

    local cooldown = (data[Keys.formCooldown] or 0) - SWEEP_INTERVAL_TICKS
    if cooldown > 0 then
        data[Keys.formCooldown] = cooldown
        return
    end
    data[Keys.formCooldown] = rule.cooldownTicks
    data[Keys.formRoot] = rule.spitRootTicks

    -- Straight under their feet, not ahead of them: leading the target made it
    -- land where they were heading, which read as a miss.
    SZedPlus.Acid.splash(player:getX(), player:getY(), player:getZ(),
        rule.acidPools or 1, rule.acidSpread or 0.3, rule.acidRadius)
    makeNoise(zombie, 8, 8)
    SZedPlus.log("spitter spat")
end

--- Hand the player to every zombie around, directly.
---
--- A world sound is at the mercy of walls, weather and each zombie's hearing
--- roll, which is why the scream alone barely moved the horde. This is the
--- design's promise made literal: within the radius, they all know.
local function callHorde(zombie, player, radius)
    local cell = getCell()
    if cell == nil then return 0 end

    local zombies = cell:getZombieList()
    local radiusSquared = radius * radius
    local called = 0

    for index = 0, zombies:size() - 1 do
        local other = zombies:get(index)
        if other and other ~= zombie and other:getZ() == zombie:getZ() then
            local dx = other:getX() - zombie:getX()
            local dy = other:getY() - zombie:getY()
            if dx * dx + dy * dy <= radiusSquared then
                pcall(function()
                    other:addAggro(player, 50.0)
                    other:setTarget(player)
                end)
                called = called + 1
            end
        end
    end
    return called
end

--- Scout: spots the player from far off, runs at them screaming, and hands
--- them to everything nearby. It calls rather than fights - it hangs back
--- instead of closing to bite.
local function runAlarm(zombie, rule, data, player, distance)
    enforceWalkType(zombie, rule.forceWalkType)

    if player == nil or distance == nil then return end
    if distance > rule.triggerDist * rule.triggerDist then
        -- Out of range: no target, and no screaming into an empty street.
        zombie:setTarget(nil)
        zombie:clearAggroList()
        return
    end

    -- Closes in, but stops short: the horde does the killing.
    if distance > (rule.keepDistance or 4) * (rule.keepDistance or 4) then
        chase(zombie, player)
    else
        zombie:setTarget(nil)
        pcall(function()
            zombie:pathToLocationF(
                zombie:getX() + (zombie:getX() - player:getX()),
                zombie:getY() + (zombie:getY() - player:getY()),
                zombie:getZ())
        end)
    end

    local cooldown = (data[Keys.formCooldown] or 0) - SWEEP_INTERVAL_TICKS
    if cooldown > 0 then
        data[Keys.formCooldown] = cooldown
        return
    end

    data[Keys.formCooldown] = rule.repeatTicks
    makeNoise(zombie, rule.screamRadius, rule.screamVolume)
    local called = callHorde(zombie, player, rule.callRadius or 150)
    SZedPlus.log("scout screamed, %d zombie(s) sent", called)
end

local ROUTINES = {
    ambush = runAmbush,
    unstoppable = runUnstoppable,
    bomb = runBomb,
    stalk = runStalk,
    dormant = runDormant,
    spitter = runSpitter,
    alarm = runAlarm,
}

-- --------------------------------------------------------------- tracking --

--- Start running this zombie's form behaviour, if it has one.
function SZedPlus.FormBehaviour.track(zombie)
    if zombie == nil then return end
    if not SZedPlus.isZedPlus(zombie) then return end

    local data = zombie:getModData()
    if not SZedPlus.Forms.needsTracking(data[Keys.stage], data[Keys.form]) then
        return
    end

    trackedCount = trackedCount + 1
    tracked[trackedCount] = zombie

    local rule = SZedPlus.Forms.get(data[Keys.form])
    if rule and rule.noStagger then
        steadfastCount = steadfastCount + 1
        steadfast[steadfastCount] = zombie
    end
end

local function sweep()
    if trackedCount == 0 then return end

    local remaining = {}
    local remainingCount = 0

    for index = 1, trackedCount do
        local zombie = tracked[index]
        local alive = zombie ~= nil and zombie:getSquare() ~= nil and not zombie:isDead()

        if alive then
            local data = zombie:getModData()
            local rule = SZedPlus.Forms.get(data[Keys.form])
            local routine = rule and ROUTINES[rule.mode]

            if routine then
                local player, distance = findNearestPlayer(zombie)
                routine(zombie, rule, data, player, distance)

                remainingCount = remainingCount + 1
                remaining[remainingCount] = zombie
            end
        end
    end

    tracked = remaining
    trackedCount = remainingCount
end

local function onTick()
    -- Every tick, not every sweep: this is the only cadence fast enough to
    -- refuse a knockdown, and the list is empty unless a Colossus is around.
    holdSteadfast()

    tickCounter = tickCounter + 1
    if tickCounter < SWEEP_INTERVAL_TICKS then return end
    tickCounter = 0
    sweep()
end

Events.OnTick.Add(onTick)

--- Cancel a Colossus knockdown the instant it is hit.
---
--- The sweep runs every few ticks, which is far too late: the zombie is already
--- on the ground by the time it comes round. OnHitZombie fires on the blow
--- itself, which is the only moment early enough to refuse the fall.
--- The argument order is the engine's, and it is not the obvious one: the
--- zombie comes first and the attacker second. Vanilla's own handler reads
---     DamageModelDefinitions.OnHitZombie = function(zombie, wielder, ...)
--- and having them the other way round meant isZedPlus() was being asked about
--- the player, returned false, and every hit was dropped on the first line.
local function onHitZombie(zombie, wielder, bodyPart, weapon)
    if zombie == nil then return end
    if not SZedPlus.isZedPlus(zombie) then return end

    local data = zombie:getModData()
    local rule = SZedPlus.Forms.get(data[Keys.form])
    if rule == nil then return end

    -- A Boomer that is shot goes off, however much health it had left. Shooting
    -- the thing full of acid should be the mistake, not the safe answer.
    if rule.primeOnGunshot and data[Keys.formFuse] == nil then
        local shot = false
        pcall(function() shot = weapon ~= nil and weapon:isRanged() end)

        if shot then
            data[Keys.formFuse] = rule.shotFuseTicks or rule.fuseTicks
            makeNoise(zombie, rule.screamRadius, rule.screamVolume)
            pcall(function()
                zombie:setFallOnFront(true)
                zombie:knockDown(true)
                zombie:setCanWalk(false)
            end)
            SZedPlus.log("boomer primed by gunfire")
            return
        end
    end

    if not rule.noStagger then return end

    pcall(function()
        zombie:setStaggerBack(false)
        zombie:setUnbalancedLevel(0.0)
        zombie:setKnockedDown(false)
        zombie:setCrawler(false)
        zombie:setFallOnFront(false)
    end)
end

Events.OnHitZombie.Add(onHitZombie)

--- How many T5 are running a behaviour, for the debug tools.
function SZedPlus.FormBehaviour.count()
    return trackedCount
end
