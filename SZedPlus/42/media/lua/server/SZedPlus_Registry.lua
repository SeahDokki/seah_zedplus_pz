--- ZED+ : the Calamity registry.
---
--- Per-zombie state lives in zombie:getModData() and is saved with the chunk.
--- That cannot answer a *global* question ("is there already a Calamity within
--- 150 tiles?"), because the zombie holding the answer may be in an unloaded
--- chunk. So active Calamities are tracked here instead: an in-memory table
--- mirrored into world ModData, which survives saving and unloading.
---
--- Loaded before SZedPlus_Spawn (alphabetical order), which depends on it.

--- Multiplayer: files under server/ are loaded on clients too. The registry is
--- authoritative world state and must exist in exactly one place.
if isClient() then return end

SZedPlus = SZedPlus or {}
SZedPlus.Registry = {}

local STORE_KEY = "SZedPlus"
local ENTRIES_FIELD = "calamities"
local NEXT_ID_FIELD = "nextCalamityId"

--- In-memory working copy. Nil until the world is loaded.
local entries = nil
local nextId = 1
local dirty = false

-- ------------------------------------------------------------ persistence --

local function getStore()
    return ModData.getOrCreate(STORE_KEY)
end

--- Read the registry out of world ModData into memory.
function SZedPlus.Registry.load()
    local store = getStore()
    entries = store[ENTRIES_FIELD] or {}
    nextId = store[NEXT_ID_FIELD] or 1
    dirty = false

    local count = 0
    for _ in pairs(entries) do count = count + 1 end
    SZedPlus.log("registry loaded, %d active calamity/ies", count)
end

--- Write the in-memory registry back into world ModData.
--- Called on a timer rather than on every change: this runs on the server and
--- the table can be walked by the zone test many times per minute.
function SZedPlus.Registry.flush(force)
    if entries == nil then return end
    if not dirty and not force then return end

    local store = getStore()
    store[ENTRIES_FIELD] = entries
    store[NEXT_ID_FIELD] = nextId
    dirty = false
    SZedPlus.log("registry flushed")
end

-- ---------------------------------------------------------------- queries --

--- Squared distance, to avoid a square root in the hot path.
local function squaredDistance(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return dx * dx + dy * dy
end

--- True if any registered Calamity sits within the exclusion radius of (x, y).
--- Only compares positions on the same z level.
function SZedPlus.Registry.hasCalamityNear(x, y, z)
    if entries == nil then return false end

    local radius = SZedPlus.Config.get("CalamityRadius")
    local radiusSquared = radius * radius

    for _, entry in pairs(entries) do
        if entry.z == z and squaredDistance(x, y, entry.x, entry.y) <= radiusSquared then
            return true
        end
    end
    return false
end

--- Number of Calamities currently registered.
function SZedPlus.Registry.count()
    if entries == nil then return 0 end
    local count = 0
    for _ in pairs(entries) do count = count + 1 end
    return count
end

-- ----------------------------------------------------------------- writes --

--- Claim the regional slot at (x, y, z) for a Calamity of the given kind.
--- Returns the new entry id, or nil if the slot is already taken.
function SZedPlus.Registry.register(kind, x, y, z)
    if entries == nil then
        SZedPlus.logError("registry.register called before the world loaded")
        return nil
    end
    if SZedPlus.Registry.hasCalamityNear(x, y, z) then
        return nil
    end

    local id = nextId
    nextId = nextId + 1

    entries[tostring(id)] = {
        kind = kind,
        x = x,
        y = y,
        z = z,
        day = SZedPlus.getCurrentDay(),
    }
    dirty = true

    SZedPlus.log("registered calamity '%s' as #%d at %d,%d,%d", kind, id, x, y, z)
    return id
end

--- Release a slot, once its Calamity is dead.
function SZedPlus.Registry.unregister(id)
    if entries == nil or id == nil then return end

    local key = tostring(id)
    if entries[key] then
        entries[key] = nil
        dirty = true
        SZedPlus.log("unregistered calamity #%s", key)
    end
end

--- Look up one entry.
function SZedPlus.Registry.get(id)
    if entries == nil or id == nil then return nil end
    return entries[tostring(id)]
end

-- ------------------------------------------------------------------ hooks --

local function onInitGlobalModData()
    SZedPlus.Registry.load()
end

local function onEveryTenMinutes()
    SZedPlus.Registry.flush(false)
end

--- Flush unconditionally before the world is written to disk.
local function onSave()
    SZedPlus.Registry.flush(true)
end

Events.OnInitGlobalModData.Add(onInitGlobalModData)
Events.EveryTenMinutes.Add(onEveryTenMinutes)
Events.OnSave.Add(onSave)
