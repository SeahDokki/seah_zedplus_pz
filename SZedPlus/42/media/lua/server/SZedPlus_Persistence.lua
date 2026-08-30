--- ZED+ : keeps T5 forms alive across the player leaving the area.
---
--- A zombie's modData does NOT survive the population manager. When the player
--- moves away, zombies are handed to it and reduced to
--- ZombiePopulationManager$ZombieSaveData, whose entire contents are
---     descriptorID, dir, state, x, y, z
--- with no modData among them. Everything this mod writes on a zombie is
--- discarded there, and what comes back later is an ordinary zombie. Driving
--- away from a Witch and returning to a plain shambler is exactly that.
---
--- So the identity is kept somewhere the engine does not own: the same world
--- ModData store the Calamity registry uses. A T5 is recorded by form and
--- position, its position refreshed while it is loaded, and the record is
--- claimed by the first unclassified zombie to appear near it. The zombie is
--- not the same object - it cannot be - but the form, the outfit and the
--- behaviour come back where they were left.
---
--- Deliberately loose. Matching a rebuilt zombie to a record can only ever be
--- "near enough", so this claims the nearest one within a few tiles and drops
--- records that no longer make sense, rather than pretending to an accuracy it
--- does not have.
---
--- Files under server/ are loaded on clients too.
if isClient() then return end

SZedPlus = SZedPlus or {}
SZedPlus.Persistence = {}

local Keys = SZedPlus.Keys

local STORE_KEY = "SZedPlus"
local ENTRIES_FIELD = "forms"
local NEXT_ID_FIELD = "nextFormId"

--- How close a rebuilt zombie has to appear to claim a record.
---
--- The population manager puts them back roughly where they were, not exactly,
--- and the record itself is only refreshed periodically. Too tight and the form
--- is lost anyway; too loose and an unrelated zombie inherits it.
local CLAIM_RADIUS = 6

--- Records older than this, in days, are dropped. A T5 the player killed while
--- it was loaded is unregistered directly; this only catches the ones lost some
--- other way, so that the store cannot grow without bound.
local STALE_DAYS = 14

--- How often a loaded T5 refreshes its recorded position, in ticks.
local REFRESH_TICKS = 5 * 60

local entries = nil
local nextId = 1
local dirty = false
local tickCounter = 0

-- ------------------------------------------------------------ persistence --

local function getStore()
    return ModData.getOrCreate(STORE_KEY)
end

function SZedPlus.Persistence.load()
    local store = getStore()
    entries = store[ENTRIES_FIELD] or {}
    nextId = store[NEXT_ID_FIELD] or 1
    dirty = false

    local count = 0
    for _ in pairs(entries) do count = count + 1 end
    SZedPlus.log("persistence loaded, %d remembered T5 form(s)", count)
end

function SZedPlus.Persistence.flush(force)
    if entries == nil then return end
    if not dirty and not force then return end

    local store = getStore()
    store[ENTRIES_FIELD] = entries
    store[NEXT_ID_FIELD] = nextId
    dirty = false
end

-- ----------------------------------------------------------------- record --

--- Remember a T5, so it can come back after the area unloads.
function SZedPlus.Persistence.remember(zombie)
    if entries == nil or zombie == nil then return end

    local data = zombie:getModData()
    if data[Keys.stage] ~= 5 then return end

    local form = data[Keys.form]
    if form == nil then return end

    -- Already remembered: this fires again every time the zombie is rebuilt.
    if data[Keys.persistId] and entries[tostring(data[Keys.persistId])] then
        return
    end

    local id = nextId
    nextId = nextId + 1

    entries[tostring(id)] = {
        form = form,
        path = data[Keys.path],
        x = zombie:getX(),
        y = zombie:getY(),
        z = zombie:getZ(),
        day = SZedPlus.getCurrentDay(),
    }
    data[Keys.persistId] = id
    dirty = true

    SZedPlus.log("remembering T5 %s as #%d", tostring(form), id)
end

--- Forget one, once it is dead.
function SZedPlus.Persistence.forget(zombie)
    if entries == nil or zombie == nil then return end

    local id = zombie:getModData()[Keys.persistId]
    if id == nil then return end

    if entries[tostring(id)] then
        entries[tostring(id)] = nil
        dirty = true
        SZedPlus.log("forgetting T5 #%s", tostring(id))
    end
end

--- Move a record to where its zombie now is.
local function refresh(zombie)
    if entries == nil then return end

    local id = zombie:getModData()[Keys.persistId]
    if id == nil then return end

    local entry = entries[tostring(id)]
    if entry == nil then return end

    entry.x, entry.y, entry.z = zombie:getX(), zombie:getY(), zombie:getZ()
    dirty = true
end

-- ------------------------------------------------------------------ claim --

--- Can this zombie take over a remembered form?
---
--- Returns the record and its key, or nil. Only called for zombies that carry
--- no classification of their own, so it can never steal one from a live Zed+.
function SZedPlus.Persistence.findClaim(zombie)
    if entries == nil or zombie == nil then return nil end

    local zx, zy, zz = zombie:getX(), zombie:getY(), zombie:getZ()
    local bestKey, bestEntry, bestDistance = nil, nil, nil

    for key, entry in pairs(entries) do
        if entry.z == zz then
            local dx, dy = zx - entry.x, zy - entry.y
            local distance = dx * dx + dy * dy
            if distance <= CLAIM_RADIUS * CLAIM_RADIUS
                and (bestDistance == nil or distance < bestDistance) then
                bestKey, bestEntry, bestDistance = key, entry, distance
            end
        end
    end

    return bestEntry, bestKey
end

--- Take the record. Consumed on the spot so two zombies cannot share it.
function SZedPlus.Persistence.consume(key)
    if entries == nil or key == nil then return end
    entries[key] = nil
    dirty = true
end

-- ----------------------------------------------------------------- upkeep --

local function dropStale()
    if entries == nil then return end

    local today = SZedPlus.getCurrentDay()
    for key, entry in pairs(entries) do
        if entry.day and today - entry.day > STALE_DAYS then
            entries[key] = nil
            dirty = true
        end
    end
end

--- Refresh the recorded position of everything currently loaded.
---
--- Through the form behaviour's own list rather than a world scan: it already
--- holds exactly the T5s that are loaded, and it is empty almost always.
local function onTick()
    tickCounter = tickCounter + 1
    if tickCounter < REFRESH_TICKS then return end
    tickCounter = 0

    if SZedPlus.FormBehaviour and SZedPlus.FormBehaviour.forEachTracked then
        SZedPlus.FormBehaviour.forEachTracked(refresh)
    end
end

--- A killed T5 must release its record at once.
---
--- Otherwise the form outlives the zombie: the player kills a Witch, leaves,
--- comes back, and the next zombie to wander past that spot becomes her.
Events.OnZombieDead.Add(function(zombie)
    SZedPlus.Persistence.forget(zombie)
    SZedPlus.Persistence.flush(true)
end)

Events.OnInitGlobalModData.Add(SZedPlus.Persistence.load)
Events.EveryTenMinutes.Add(function()
    dropStale()
    SZedPlus.Persistence.flush()
end)
Events.OnTick.Add(onTick)
