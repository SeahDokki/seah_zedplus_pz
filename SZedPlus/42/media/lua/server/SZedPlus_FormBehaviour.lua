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
            local data = zombie:getModData()
            local rule = SZedPlus.Forms.get(data[Keys.form])

            if rule and rule.holdStill and data[Keys.formTriggered] ~= true then
                -- Held every tick, not every sweep.
                --
                -- The sweep runs every six ticks, which is far too coarse to
                -- hold anything: a sprinter crosses real ground in six frames
                -- and the engine re-acquires its target long before the next
                -- pass clears it. That is why the Stalker kept charging however
                -- its freeze was written, and why a dormant Mimic still noticed
                -- players and started crawling. The Colossus was held per tick
                -- from the start, which is exactly why it always worked.
                pcall(function()
                    zombie:setTarget(nil)
                    zombie:clearAggroList()
                    zombie:setCanWalk(false)
                end)
            elseif rule and rule.noStagger then
                pcall(function()
                    zombie:setUnbalancedLevel(0.0)
                    zombie:setStaggerBack(false)
                    if zombie:isKnockedDown() then
                        zombie:setKnockedDown(false)
                        zombie:setCrawler(false)
                        zombie:setFallOnFront(false)
                    end
                end)
            end
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
--- Knock a player off their feet, the way the engine does it.
---
--- All four calls are needed. BumpFall on its own starts nothing: the bump type
--- and clearing BumpDone are what let the animation begin.
---
--- BumpFallType takes "pushedFront" or "pushedBehind" and nothing else - those
--- are the only two the animation sets define. "pushedBack" looked reasonable,
--- is not one of them, and left the player in a bump with no state to leave by:
--- frozen for good, session unplayable. Do not invent a third.
--- Put a player on the ground.
---
--- `fromBehind` is where the blow came from, which is what BumpFallType names:
--- pushed in the back means falling forwards, pushed in the chest means going
--- over backwards. Getting that backwards is what made the Colossus drop
--- players onto their face when they were looking straight at it.
local function knockDownPlayer(player, fromBehind)
    if player == nil then return end
    pcall(function()
        player:setBumpType("stagger")
        player:setVariable("BumpDone", false)
        player:setVariable("BumpFall", true)
        player:setVariable("BumpFallType",
            fromBehind and "pushedBehind" or "pushedFront")
    end)
end

--- Log a state change once, not on every sweep that reasserts it.
---
--- A Mimic flipping between two states wrote twenty lines a second and the
--- game stuttered badly enough that aiming stopped working. The loop is fixed,
--- but a log that can only fire on an actual change cannot cause that again.
local function logOnce(data, message)
    if data[Keys.formLastLog] == message then return end
    data[Keys.formLastLog] = message
    SZedPlus.log("%s", message)
end

--- Is the zombie inside the player's vision cone?
---
--- Measured from the direction the player's sprite faces, not from a forward
--- vector. getDotWithForwardDirection reported a steady -0.2 to -0.3 while the
--- player looked straight at the zombie, where +1 was expected - it does not
--- describe where the character is looking. getDir() does: it is the eight-way
--- facing drawn on screen, so it agrees with what the player believes they can
--- see, which is the only thing that matters for a form built on being watched.
---
--- Eight-way is coarse, and that is fine: a 45-degree step either way is well
--- inside the cone the rule asks for.
local FACING = {
    N  = {  0, -1 }, NE = {  1, -1 }, E  = {  1,  0 }, SE = {  1,  1 },
    S  = {  0,  1 }, SW = { -1,  1 }, W  = { -1,  0 }, NW = { -1, -1 },
}

local function facingVector(character)
    local name = nil

    -- By name, not by comparing the enum values.
    --
    -- `dir == IsoDirections.N` looked right and could never be trusted: Kahlua
    -- compares those by identity, and a value coming back from Java need not be
    -- the same object as the one read off the global table. When it silently
    -- matched nothing, facingVector returned nil, every check answered "not
    -- watched", and the Stalker sprinted no matter how the freeze was written.
    -- tostring() on a Java enum gives its name, which is stable.
    pcall(function() name = tostring(character:getDir()) end)
    if name == nil then return nil end

    SZedPlus.watchFacing = name
    local vector = FACING[name]
    if vector == nil then return nil end

    local fx, fy = vector[1], vector[2]
    local scale = math.sqrt(fx * fx + fy * fy)
    return fx / scale, fy / scale
end

--- Is the zombie in front of the player, rather than behind them?
local function isInFrontOf(zombie, player)
    local fx, fy = facingVector(player)
    if fx == nil then return false end

    local dx = zombie:getX() - player:getX()
    local dy = zombie:getY() - player:getY()
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.001 then return true end

    return (fx * dx + fy * dy) / length > 0
end

local function isWatchedBy(zombie, player, halfAngleDegrees)
    local dx = zombie:getX() - player:getX()
    local dy = zombie:getY() - player:getY()
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.001 then return true end

    local fx, fy = facingVector(player)
    if fx == nil then return false end

    local cosine = (fx * dx + fy * dy) / length
    SZedPlus.watchDot = cosine
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

            -- getForwardDirection() returns a Vector2. The X/Y getters used
            -- before are equally valid; this form just avoids assuming which
            -- of the two the class offers.
            local fx, fy = 0, 0
            pcall(function()
                local forward = player:getForwardDirection()
                fx, fy = forward:getX(), forward:getY()
            end)

            local behind = rule.teleportBehind or 15
            if (fx ~= 0 or fy ~= 0) and relocate(zombie,
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
local function runUnstoppable(zombie, rule, data, player, distance)
    -- Gets you on the ground first, then feeds.
    --
    -- Waiting for getAttackDidDamage put the knockdown half a second after the
    -- blow, which read as a delayed reaction rather than a shove: the flag only
    -- appears once the swing has resolved. Tripping on arrival instead makes it
    -- the opener - you go down, and then it is on top of you, which is what a
    -- wall of flesh reaching you should feel like.
    if rule.floorOnHit and player and distance
        and distance <= (rule.hitRange or 1.6) ^ 2 then

        local cooldown = (data[Keys.formCooldown] or 0) - SWEEP_INTERVAL_TICKS
        if cooldown > 0 then
            data[Keys.formCooldown] = cooldown
        else
            -- Only worth doing to someone still on their feet. Once they are
            -- down it just attacks, and they get the room to stand up again.
            local standing = false
            pcall(function() standing = not player:isKnockedDown() end)
            if standing then
                data[Keys.formCooldown] = rule.floorCooldownTicks or (5 * 60)
                -- BumpFallType names where the push COMES FROM, not where you
                -- land: "pushedBehind" is a shove in the back, so you go over
                -- forwards. Facing it therefore has to send "pushedFront".
                --
                -- Which also settles shoving it: you have to be facing
                -- something to shove it, so that case falls out of the same
                -- rule rather than needing one of its own.
                knockDownPlayer(player, not isInFrontOf(zombie, player))
                SZedPlus.log("colossus floored the player")
            end
        end
    end

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
                        knockDownPlayer(nearby)
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
        logOnce(data, "stalker out of range")
        return
    end

    -- Close enough that freezing would be absurd: it commits.
    --
    -- This branch was silent, and it is the one a debug spawn lands in: a
    -- zombie placed a couple of tiles away is already inside commitDist, so it
    -- charges whatever the player is looking at - which looks exactly like the
    -- freeze never working.
    if distance <= rule.commitDist * rule.commitDist then
        pcall(function() zombie:setCanWalk(true) end)
        chase(zombie, player)
        logOnce(data, string.format("stalker committed (%.1f tiles, commit at %.1f)",
            math.sqrt(distance), rule.commitDist))
        data[Keys.formTriggered] = true
        return
    end

    if isWatchedBy(zombie, player, rule.visionAngle) then
        -- Watched: stop dead. Nothing else - no turning, no wandering.
        --
        -- Walking away was tried and cannot be built: a zombie is driven by its
        -- target and nothing else, so pathToLocationF is ignored with one and
        -- does nothing without one, and Wander() did not move it either. This
        -- is the coil-head rule instead, and it only needs the zombie to hold
        -- still, which is the one thing that always works.
        pcall(function()
            zombie:setCanWalk(false)
            zombie:setTarget(nil)
            zombie:clearAggroList()
        end)

        logOnce(data, string.format("stalker frozen (facing %s, dot %.2f, need %.2f)",
            SZedPlus.watchFacing or "?", SZedPlus.watchDot or -9,
            math.cos(math.rad(rule.visionAngle))))
        data[Keys.formTriggered] = false
        return
    end

    -- Unwatched: close the distance, fast.
    --
    -- chase() re-aggros from scratch every sweep, so looking away always brings
    -- it back. It cannot lose you permanently by having been seen once, which
    -- is what clearing the aggro list on its own would have caused.
    enforceWalkType(zombie, rule.forceWalkType)
    pcall(function() zombie:setCanWalk(true) end)
    chase(zombie, player)
    logOnce(data, string.format("stalker sprinting (facing %s, dot %.2f, need %.2f)",
        SZedPlus.watchFacing or "?", SZedPlus.watchDot or -9,
        math.cos(math.rad(rule.visionAngle))))
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

    -- Always a crawler, but only told so when it is not one already.
    -- Re-asserting it on every sweep restarted the change each time and its
    -- movement came out stuttering.
    pcall(function()
        if not zombie:isCrawling() then zombie:setCrawler(true) end
    end)

    -- Dormant: flat and inert until something stands on it.
    if not awake then
        pcall(function()
            zombie:knockDown(false)
            zombie:setCanWalk(false)
            zombie:setTarget(nil)
            zombie:clearAggroList()
        end)

        if player and distance and distance <= rule.wakeDist * rule.wakeDist then
            data[Keys.formTriggered] = true
            chase(zombie, player)
            logOnce(data, "mimic woke")
        end
        return
    end

    -- Lost them: back to scenery.
    if player == nil or distance == nil
        or distance > rule.sleepDist * rule.sleepDist then
        data[Keys.formTriggered] = nil
        data[Keys.formCooldown] = nil
        pcall(function()
            zombie:setCanWalk(false)
            zombie:setTarget(nil)
            zombie:clearAggroList()
        end)
        logOnce(data, "mimic went dormant")
        return
    end

    -- Awake: crawl after them, still on the floor.
    pcall(function() zombie:setCanWalk(true) end)
    chase(zombie, player)

    if distance > rule.biteRange * rule.biteRange then return end

    local cooldown = (data[Keys.formCooldown] or 0) - SWEEP_INTERVAL_TICKS
    if cooldown > 0 then
        data[Keys.formCooldown] = cooldown
        return
    end
    data[Keys.formCooldown] = rule.biteIntervalTicks or 75

    -- Bite an ankle. Which one is picked at random, so repeated attacks spread
    -- rather than stacking on the same part.
    local parts = { "Foot_L", "Foot_R", "LowerLeg_L", "LowerLeg_R" }
    local partName = parts[ZombRand(#parts) + 1]
    local bite = ZombRand(100) < (rule.biteChance or 20)

    pcall(function()
        local part = player:getBodyDamage():getBodyPart(BodyPartType[partName])
        if part == nil then return end

        if bite then
            part:SetBitten(true, true)
        else
            -- The tearing wound: bleeds, hurts, and carries the same infection
            -- risk a zombie's claws always do - just not the certainty a bite
            -- brings.
            part:setScratched(true, true)
        end
    end)

    -- And sometimes it takes the leg out from under them. The same knockdown
    -- the Boomer's blast uses - which does work; the earlier attempts here
    -- never reached it, because LungeState returned successfully and only threw
    -- later, so the fallback that would have called this was skipped.
    if ZombRand(100) < (rule.tripChance or 0) then
        -- Forwards: it has hold of an ankle, so the player goes over the front.
        knockDownPlayer(player, false)
        SZedPlus.log("mimic %s the player's %s and tripped them",
            bite and "bit" or "lacerated", partName)
        return
    end

    SZedPlus.log("mimic %s the player's %s",
        bite and "bit" or "lacerated", partName)
end

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
    if rule and (rule.noStagger or rule.holdStill) then
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
