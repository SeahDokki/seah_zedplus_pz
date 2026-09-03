--- ZED+ : the Thriller easter egg.
---
--- A ring of zombies turning slowly on the spot in the middle of a road, one of
--- them in a prison jumpsuit at the centre. They aggro like any other zombie the
--- moment you get close, and the dance stops.
---
--- Deliberately outside the Zed+ system: these are ordinary zombies, the event
--- is rolled from where the player walks rather than from a tier, and nothing
--- here reads or writes a Zed+ tier. It has its own two sandbox options.
---
--- The loop plays from the lead's own emitter, so it is positional: it comes
--- from the middle of the ring, gets louder as you approach, and dies with him.
--- It cuts the moment the lead stops dancing, which is the moment he notices
--- you - the joke ends exactly when it stops being funny.
---
--- Files under server/ are loaded on clients too.
if isClient() then return end

SZedPlus = SZedPlus or {}
SZedPlus.Thriller = {}

-- ------------------------------------------------------------- constants --

--- Ticks between "has the player changed square?" checks. The roll is per road
--- square entered, so this only has to be finer than the time it takes to walk
--- one tile - half a second is far finer than that and costs two comparisons.
local CHECK_EVERY_TICKS = 30

--- Ticks between dance steps. One eighth turn each time: slow enough to read as
--- swaying rather than spinning.
local DANCE_EVERY_TICKS = 20

--- How far from the player the ring is placed, and the radius of the ring.
local PLACE_MIN, PLACE_MAX = 7, 12
local RING_RADIUS = 2

--- How many zombies stand in the ring, before the one in the middle.
local RING_MIN, RING_MAX = 5, 8

--- How close a player has to get before the dance breaks up.
---
--- Proximity rather than aggro, and that is not a shortcut. A dancer is held
--- with its target cleared every tick, so it can never acquire one - the same
--- position the dormant Mimic is in, and the same reason it wakes on distance.
--- Waiting for aggro on a zombie that is forbidden from having any would leave
--- the troupe frozen forever, which is the failure mode this mod keeps finding.
local WAKE_DIST = 6

--- The centre dancer's outfit: Boilersuit_Prisoner, which is the orange one.
--- Inmate is in the male outfit list only, so the gender has to match or the
--- lookup silently dresses nobody - see the note in SZedPlus_Appearance.
local LEAD_OUTFIT = "Inmate"

--- The looping track, declared in media/scripts/SZedPlus_Sounds.txt.
local LEAD_SOUND = "SZedPlus_Thriller"

--- The eight facings, in turning order. Held by name because a Java enum value
--- read from the global table cannot be compared by identity in Kahlua, which
--- cost several rounds on the Stalker - see facingVector in FormBehaviour.
local TURN_ORDER = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

-- ----------------------------------------------------------------- state --

--- The dancers currently on stage: { zombie, step } per entry.
local dancers = {}
local dancerCount = 0

--- Last square each player was standing on, keyed by player number, so the roll
--- happens once per square entered rather than once per check.
local lastSquare = {}

local ticks = 0

-- --------------------------------------------------------------- helpers --

--- Every player to consider. getPlayer() does not exist on a dedicated server,
--- and IsoPlayer.getPlayers() is not the list there - same split as Acid and
--- FormBehaviour, kept identical on purpose.
local function livePlayers()
    if isServer() then return getOnlinePlayers() end
    return IsoPlayer.getPlayers()
end

--- Is this square part of a road?
---
--- There is no engine method for it - IsoGridSquare has isSolidFloor and
--- hasNaturalFloor but nothing about roads - so this goes by the floor tile's
--- name. Every road surface in the game is named through one of the "street"
--- tilesets (blends_street_01, floors_exterior_street_01, street_curbs_01),
--- which makes a substring match on "street" both simple and accurate.
local function isRoad(square)
    if square == nil then return false end

    local name = nil
    pcall(function()
        local floor = square:getFloor()
        if floor then name = floor:getSprite():getName() end
    end)

    if name == nil then return false end
    return string.find(name, "street", 1, true) ~= nil
end

--- A free road square between PLACE_MIN and PLACE_MAX tiles from the player.
--- Returns nil rather than settling for somewhere unsuitable: a dance in a
--- hedge is worse than no dance.
local function findStage(player)
    local cell = getCell()
    if cell == nil then return nil end

    local px, py, pz = player:getX(), player:getY(), player:getZ()

    for _ = 1, 20 do
        local angle = ZombRand(360) * math.pi / 180
        local distance = PLACE_MIN + ZombRand(PLACE_MAX - PLACE_MIN + 1)
        local x = math.floor(px + math.cos(angle) * distance)
        local y = math.floor(py + math.sin(angle) * distance)

        local square = cell:getGridSquare(x, y, pz)
        if square and square:isFree(false) and isRoad(square) then
            return square
        end
    end

    return nil
end

--- Spawn one zombie on a square, optionally in a named outfit.
--- Returns it by reading the square back, since addZombiesInOutfit returns
--- nothing useful.
local function spawnDancer(square, outfit, female)
    local before = square:getMovingObjects():size()

    pcall(function()
        addZombiesInOutfit(square:getX(), square:getY(), square:getZ(),
            1, outfit, female)
    end)

    local objects = square:getMovingObjects()
    if objects:size() <= before then return nil end

    local candidate = objects:get(objects:size() - 1)
    if candidate and instanceof(candidate, "IsoZombie") then return candidate end
    return nil
end

--- Point a zombie at one of the eight compass directions.
local function face(zombie, step)
    local name = TURN_ORDER[(step % #TURN_ORDER) + 1]
    pcall(function() zombie:setDir(IsoDirections[name]) end)
end

-- ----------------------------------------------------------------- event --

--- Put on the show, centred on `square`.
function SZedPlus.Thriller.stage(square)
    if square == nil then return false end

    -- The lead, in the middle, in orange. Male because the outfit only exists
    -- in the male list.
    local lead = spawnDancer(square, LEAD_OUTFIT, 0.0)
    if lead == nil then
        SZedPlus.log("thriller: could not spawn the lead, cancelled")
        return false
    end

    -- The music comes from the lead rather than from the square: an emitter
    -- attached to him is positional for free, and it stops when he does.
    --
    -- playSound, not playSoundLooped. The looping one exists on
    -- BaseSoundEmitter but NOT on CharacterSoundEmitter, which is what a
    -- character's getEmitter() actually returns, and Kahlua resolves against the
    -- concrete class - so calling it threw. The loop is declared on the sound
    -- itself in SZedPlus_Sounds.txt instead, which is where it belongs: whether
    -- a track repeats is a property of the track, not of the call site.
    --
    -- Same trap as setHearing and forceModelScript: a method that exists
    -- somewhere in the hierarchy is not a method you can call.
    local handle = nil
    pcall(function() handle = lead:getEmitter():playSound(LEAD_SOUND) end)
    if handle == nil then
        SZedPlus.logError("thriller: '%s' would not play - is the sound script loaded?",
            LEAD_SOUND)
    end

    dancerCount = dancerCount + 1
    dancers[dancerCount] = { zombie = lead, step = 0, lead = true, sound = handle }

    -- The ring, evenly spaced around it. A position that is not free is simply
    -- skipped: a gap in the circle is fine, a zombie inside a wall is not.
    local cell = getCell()
    local wanted = RING_MIN + ZombRand(RING_MAX - RING_MIN + 1)
    local placed = 0

    for index = 0, wanted - 1 do
        local angle = (index / wanted) * math.pi * 2
        local x = math.floor(square:getX() + math.cos(angle) * RING_RADIUS)
        local y = math.floor(square:getY() + math.sin(angle) * RING_RADIUS)

        local spot = cell and cell:getGridSquare(x, y, square:getZ())
        if spot and spot:isFree(false) then
            local zombie = spawnDancer(spot, nil, nil)
            if zombie then
                placed = placed + 1
                dancerCount = dancerCount + 1
                -- Offset by position so the ring turns as one shape rather
                -- than every zombie facing the same way at once.
                dancers[dancerCount] = { zombie = zombie, step = index }
            end
        end
    end

    SZedPlus.logAlways("thriller: %d dancer(s) at %d,%d,%d",
        placed + 1, square:getX(), square:getY(), square:getZ())
    return true
end

--- Stage the show near this player, on demand, ignoring the rarity roll.
---
--- Driven from the debug menu. It prefers a road, because that is where the
--- event belongs and the placement rules are worth exercising, but falls back
--- to any free square: someone testing this indoors or in a field still wants
--- to see it, and refusing would look like a broken menu entry rather than a
--- deliberate rule.
function SZedPlus.Thriller.spawnNear(player)
    if player == nil then return false end

    local square = findStage(player)
    if square ~= nil then
        return SZedPlus.Thriller.stage(square)
    end

    local cell = getCell()
    local px, py, pz = player:getX(), player:getY(), player:getZ()

    for _ = 1, 30 do
        local angle = ZombRand(360) * math.pi / 180
        local distance = PLACE_MIN + ZombRand(PLACE_MAX - PLACE_MIN + 1)
        local candidate = cell and cell:getGridSquare(
            math.floor(px + math.cos(angle) * distance),
            math.floor(py + math.sin(angle) * distance), pz)
        if candidate and candidate:isFree(false) then
            SZedPlus.logAlways("thriller: no road nearby, staging on open ground")
            return SZedPlus.Thriller.stage(candidate)
        end
    end

    SZedPlus.logError("thriller: nowhere to put the dancers")
    return false
end

--- Roll for the event as this player enters a new square.
local function considerPlayer(player)
    if player == nil or player:isDead() then return end
    if not SZedPlus.Config.get("ThrillerEnabled") then return end

    local square = player:getCurrentSquare()
    if square == nil then return end

    local key = player:getPlayerNum()
    local id = square:getX() .. "," .. square:getY() .. "," .. square:getZ()
    if lastSquare[key] == id then return end
    lastSquare[key] = id

    if not isRoad(square) then return end

    local rarity = SZedPlus.Config.get("ThrillerRarity")
    if rarity == nil or rarity < 1 then return end
    if ZombRand(rarity) ~= 0 then return end

    local stage = findStage(player)
    if stage == nil then return end

    SZedPlus.Thriller.stage(stage)
end

-- ----------------------------------------------------------------- dance --

--- Nearest live player to this zombie, and how far in tiles. nil if there is
--- nobody to measure against.
local function nearestPlayer(zombie)
    local players = livePlayers()
    if players == nil then return nil, nil end

    local best, bestDist = nil, nil
    for index = 0, players:size() - 1 do
        local player = players:get(index)
        if player ~= nil and not player:isDead() then
            local dx = player:getX() - zombie:getX()
            local dy = player:getY() - zombie:getY()
            local squared = dx * dx + dy * dy
            if bestDist == nil or squared < bestDist then
                best, bestDist = player, squared
            end
        end
    end

    if best == nil then return nil, nil end
    return best, math.sqrt(bestDist)
end

--- Let a dancer go: unlock everything the freeze locked, and never take it back.
---
--- Releasing matters more than freezing. A zombie left with a locked state
--- machine is inert permanently, so every exit from the routine has to come
--- through here - the Stalker learned that the hard way and its freeze has the
--- same rule.
local function release(zombie)
    if zombie == nil then return end
    pcall(function()
        zombie:setStateMachineLocked(false)
        zombie:setCanWalk(true)
    end)
end

--- Hold a dancer still. Called every tick, because six was already too coarse.
---
--- Two cadences on purpose, copied from how the Stalker holds:
---   every tick  - setCanWalk(false) and a cleared target, which is what the AI
---                 overrides fastest;
---   every step  - idle plus a locked state machine, which is the part the AI
---                 cannot walk out of and does not need re-applying as often.
---
--- setCanWalk(false) alone is NOT a freeze, and this is the third form to need
--- saying so: the AI keeps its own state and walks anyway. That is what had
--- dancers drifting out of the ring, the lead included.
local function hold(zombie, relock)
    pcall(function()
        zombie:setTarget(nil)
        zombie:clearAggroList()
        zombie:setCanWalk(false)
        if relock then
            zombie:changeState(ZombieIdleState.instance())
            zombie:setStateMachineLocked(true)
        end
    end)
end

--- Hold the troupe, turn it, and break it up when someone gets close.
---
--- The whole ring goes at once rather than one dancer at a time. They are all
--- looking at the same thing, so them all stopping together is both simpler and
--- the better moment: the music cuts, and eight zombies turn round.
local function danceStep(turn)
    if dancerCount == 0 then return end

    -- Anyone close enough ends it for everybody.
    local broken = false
    for index = 1, dancerCount do
        local zombie = dancers[index].zombie
        if zombie ~= nil and not zombie:isDead() and zombie:getSquare() ~= nil then
            local _, distance = nearestPlayer(zombie)
            if distance ~= nil and distance <= WAKE_DIST then
                broken = true
                break
            end

            -- Shot from out there, or otherwise onto someone despite the
            -- clearing: that counts too.
            local hasTarget = false
            pcall(function() hasTarget = zombie:getTarget() ~= nil end)
            if hasTarget then
                broken = true
                break
            end
        end
    end

    local remaining = {}
    local remainingCount = 0

    for index = 1, dancerCount do
        local entry = dancers[index]
        local zombie = entry.zombie
        local alive = zombie ~= nil and not zombie:isDead()
            and zombie:getSquare() ~= nil

        if alive and not broken then
            hold(zombie, turn)

            if turn then
                -- The lead turns the other way. Small thing, but it reads as a
                -- performance rather than eight zombies with the same twitch.
                entry.step = entry.step + (entry.lead and -1 or 1)
                face(zombie, entry.step)
            end

            remainingCount = remainingCount + 1
            remaining[remainingCount] = entry
        else
            -- Off the list for good: released, and the music with it.
            release(zombie)
            if entry.sound ~= nil then
                pcall(function() zombie:getEmitter():stopSound(entry.sound) end)
                entry.sound = nil
            end
        end
    end

    if broken and dancerCount > 0 then
        SZedPlus.log("thriller: the dance broke up")
    end

    dancers = remaining
    dancerCount = remainingCount
end

-- ------------------------------------------------------------------ tick --

local function onTick()
    ticks = ticks + 1

    -- Every tick, because a hold re-asserted any less often is not a hold.
    -- `turn` is what happens on the slower beat.
    danceStep(ticks % DANCE_EVERY_TICKS == 0)

    if ticks % CHECK_EVERY_TICKS ~= 0 then return end

    local players = livePlayers()
    if players == nil then return end

    for index = 0, players:size() - 1 do
        considerPlayer(players:get(index))
    end
end

Events.OnTick.Add(onTick)
