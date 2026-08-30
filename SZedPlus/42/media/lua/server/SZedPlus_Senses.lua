--- ZED+ : the Stealth and Ranged senses.
---
--- Stealth barely notices you; Ranged notices you from far away. Together with
--- Fast (quick, fragile) and Tank (slow, tough), each path is one stat traded
--- against its opposite.
---
--- IsoZombie exposes `hearing` and the vision radius as fields with no setters,
--- so neither can be tuned per zombie. What IS exposed is the outcome those
--- would produce: setTarget(), addAggro() and clearAggroList(). So rather than
--- adjusting perception and hoping, this drives the aggro directly:
---
---   Stealth : drop the target while the player is beyond a short radius
---   Ranged  : acquire the player well beyond normal detection range
---
--- Files under server/ are loaded on clients too.
if isClient() then return end

SZedPlus = SZedPlus or {}
SZedPlus.Senses = {}

local Keys = SZedPlus.Keys

--- Ticks between sweeps. Aggro does not need per-tick precision, and this runs
--- over every tracked zombie, so it is deliberately coarse.
local SWEEP_INTERVAL_TICKS = 6

--- Zombies whose senses need managing, keyed by an incrementing id so entries
--- can be removed while iterating.
local tracked = {}
local trackedCount = 0
local tickCounter = 0

-- --------------------------------------------------------------- tracking --

--- Whether this zombie needs the sweep at all.
local function needsTracking(zombie)
    local path = zombie:getModData()[Keys.path]
    return SZedPlus.Tiers.getSenseRule(zombie:getModData()[Keys.stage], path) ~= nil
end

--- Start managing this zombie's senses, if its path calls for it.
function SZedPlus.Senses.track(zombie)
    if zombie == nil then return end
    if not SZedPlus.isZedPlus(zombie) then return end
    if not needsTracking(zombie) then return end

    trackedCount = trackedCount + 1
    tracked[trackedCount] = zombie
end

-- ----------------------------------------------------------------- sweep --

--- Squared distance between two objects, avoiding a square root per pair.
local function squaredDistance(a, b)
    local dx, dy = a:getX() - b:getX(), a:getY() - b:getY()
    return dx * dx + dy * dy
end

--- Every player the server knows about, single player included.
local function getPlayers()
    if isServer() then
        return getOnlinePlayers()
    end
    return IsoPlayer.getPlayers()
end

--- The nearest living player on the same floor, and its squared distance.
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

--- Stealth: forget anything further away than the rule allows.
---
--- Clearing the aggro list as well as the target matters - leaving the list
--- populated makes the zombie re-acquire on the next engine update, and the
--- zombie would visibly stutter between chasing and idling.
local function applyDeafness(zombie, rule, nearestDistance)
    if zombie:getTarget() == nil then return end

    local limit = rule.aggroRadius * rule.aggroRadius
    if nearestDistance == nil or nearestDistance > limit then
        zombie:setTarget(nil)
        zombie:clearAggroList()
    end
end

--- Ranged: notice a player far outside normal detection range.
---
--- Only acts when the zombie has no target, so it grants awareness without
--- overriding whatever the engine decided to chase.
local function applyKeenSenses(zombie, rule, player, nearestDistance)
    if player == nil or nearestDistance == nil then return end
    if zombie:getTarget() ~= nil then return end

    local limit = rule.aggroRadius * rule.aggroRadius
    if nearestDistance <= limit then
        zombie:addAggro(player, rule.aggroStrength or 1.0)
        zombie:setTarget(player)
    end
end

--- One pass over every tracked zombie. Compacts the list as it goes, dropping
--- zombies that died or whose chunk unloaded.
local function sweep()
    if trackedCount == 0 then return end

    local remaining = {}
    local remainingCount = 0

    for index = 1, trackedCount do
        local zombie = tracked[index]
        local alive = zombie ~= nil and zombie:getSquare() ~= nil and not zombie:isDead()

        if alive then
            local data = zombie:getModData()
            local rule = SZedPlus.Tiers.getSenseRule(data[Keys.stage], data[Keys.path])
            if rule then
                local player, distance = findNearestPlayer(zombie)
                if rule.mode == "dull" then
                    applyDeafness(zombie, rule, distance)
                elseif rule.mode == "keen" then
                    applyKeenSenses(zombie, rule, player, distance)
                end

                remainingCount = remainingCount + 1
                remaining[remainingCount] = zombie
            end
        end
    end

    tracked = remaining
    trackedCount = remainingCount
end

local function onTick()
    tickCounter = tickCounter + 1
    if tickCounter < SWEEP_INTERVAL_TICKS then return end
    tickCounter = 0
    sweep()
end

Events.OnTick.Add(onTick)

--- How many zombies are currently managed, for the debug tools.
function SZedPlus.Senses.count()
    return trackedCount
end
