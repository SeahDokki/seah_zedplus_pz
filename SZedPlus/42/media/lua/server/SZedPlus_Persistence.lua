--- ZED+ : persistent identity ledger for T1-T5 zombies.
---
--- Project Zomboid's population manager does not preserve arbitrary zombie
--- modData while a zombie is virtualised outside the loaded area. ZED+ state
--- therefore cannot live only on IsoZombie:getModData(): stage/path/form would
--- disappear and the rebuilt zombie could be rolled again or become ordinary.
---
--- This module keeps the minimum gameplay identity in world ModData instead:
---     stage, path, form, durable form variant state, T4 spawn day, last known
---     position and fingerprints.
--- Every loaded Zed+ owns one stable persistId. When its IsoZombie disappears,
--- the record remains; a later OnZombieCreate can reclaim that record before
--- any new spawn roll happens.
---
--- Matching deliberately uses more than position. PZ exposes
--- IsoZombie:getSharedDescriptorID(), but public API documentation does not
--- establish that this value is the same descriptorID used by every ordinary
--- population-manager save path. It is therefore an opportunistic fingerprint,
--- not a claimed engine UUID. Position, persistent outfit id and sex remain
--- bounded fallbacks.
---
--- Files under server/ are loaded on clients too.
if isClient() then return end

SZedPlus = SZedPlus or {}
SZedPlus.Persistence = {}

local Keys = SZedPlus.Keys

local STORE_KEY = "SZedPlus"
local ENTRIES_FIELD = "identities"
local NEXT_ID_FIELD = "nextIdentityId"
local SCHEMA_FIELD = "identitySchema"
local SCHEMA_VERSION = 3

-- v0.1.0 Workshop persistence kept only T5 records here. They are migrated on
-- first load so existing saves do not lose remembered final forms.
local LEGACY_ENTRIES_FIELD = "forms"
local LEGACY_NEXT_ID_FIELD = "nextFormId"

--- Spatial fallback used when descriptor matching is unavailable or ambiguous.
local CLAIM_RADIUS = 6

--- Was 64, on the assumption that a shared descriptor is a stable engine identity
--- worth trusting far from the last sampled position. **It is not.** Measured in
--- game on 6 Sep 2026 over 536 paired samples: the value differs across a
--- reconstruction 94.6% of the time, it is byte-identical to
--- `getPersistentOutfitID()` in all 463 samples where both existed, and 43 distinct
--- identities collided on a shared value within a single session. It is the current
--- outfit's packed id, re-derived each time the engine redresses the zombie - not a
--- UUID. Held at the spatial radius until something proves otherwise; the wide
--- radius bought 15 claims out of 961 and every one of them was a gamble.
local DESCRIPTOR_CLAIM_RADIUS = 6

--- Runtime-only spatial index granularity. A 16-tile cell means a 6-tile
--- fallback query touches at most four cells in the common case and a bounded
--- 3x3 neighbourhood at cell edges. The persisted ledger itself stays flat.
local INDEX_CELL_SIZE = 16

--- Orphan records without a usable descriptor are intentionally short lived:
--- they are the ones most likely to be claimed incorrectly by position alone.
local STALE_DAYS = 14

--- Descriptor-backed records are substantially safer to retain for long-lived
--- worlds, but are still bounded in case the engine permanently removes a zombie
--- without producing OnZombieDead and later reuses descriptor values.
local DESCRIPTOR_STALE_DAYS = 180

--- Refresh position/fingerprint state roughly every five seconds at 60 ticks/s.
local REFRESH_TICKS = 5 * 60

local entries = nil
local nextId = 1
local dirty = false
local tickCounter = 0

--- Stale cleanup is intentionally incremental. The persisted ledger can become
--- large on long-running worlds, so EveryTenMinutes must not walk every remembered
--- identity at once. This is runtime-only tuning; it does not enter the save schema.
local CLEANUP_BATCH_SIZE = 256

--- Runtime-only circular doubly-linked rotation used by stale cleanup. Nodes are
--- indexed by persistId, so add/remove stay O(1) and deletion never leaves
--- tombstones behind. The whole rotation is rebuilt from the ledger on load.
local cleanupNodes = {}
local cleanupHead = nil
local cleanupCursor = nil
local cleanupCount = 0

--- Loaded representatives only. Values are short-lived strong references to the
--- current IsoZombie; they are cleared as soon as isExistInTheWorld() becomes
--- false. This prevents a still-loaded Zed+ record being stolen by a neighbour.
local active = {}

--- Runtime-only indexes. They are rebuilt from the flat persisted ledger on
--- load, so no derived index data enters GlobalModData or the save schema.
local descriptorIndex = {}
local spatialIndex = {}
local indexState = {}

-- -------------------------------------------------------------- utilities --

local function getStore()
    return ModData.getOrCreate(STORE_KEY)
end

local function currentDay()
    return SZedPlus.getCurrentDay()
end

local function squaredDistance(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return dx * dx + dy * dy
end

local function safeSharedDescriptorId(zombie)
    local ok, value = pcall(function()
        return zombie:getSharedDescriptorID()
    end)
    if not ok or type(value) ~= "number" or value <= 0 then return nil end
    return value
end

local function safePersistentOutfitId(zombie)
    local ok, value = pcall(function()
        return zombie:getPersistentOutfitID()
    end)
    if not ok or type(value) ~= "number" or value == 0 then return nil end
    return value
end

local function safeFemale(zombie)
    local ok, value = pcall(function()
        return zombie:isFemale()
    end)
    if not ok then return nil end
    return value == true
end

local function zombieExists(zombie)
    if zombie == nil then return false end
    local ok, value = pcall(function()
        return zombie:isExistInTheWorld()
    end)
    return ok and value == true
end

local function normalizeId(id)
    if id == nil then return nil end
    return tostring(id)
end

--- True only while `zombie` still owns this exact persisted ZED+ identity.
---
--- `isExistInTheWorld()` alone is not enough: PZ can leave a Java object alive
--- briefly after its ZED+ modData has been cleared/reused. Treating that stale
--- object as the owner would block the real rebuilt zombie from reclaiming the
--- ledger record. Keep this predicate as the single ownership contract used by
--- both immediate claim protection and periodic active-table cleanup.
local function ownsActiveIdentity(key, zombie)
    key = normalizeId(key)
    if key == nil or entries == nil or entries[key] == nil then return false end
    if not zombieExists(zombie) then return false end

    local ok, data = pcall(function()
        return zombie:getModData()
    end)
    if not ok or data == nil then return false end
    if data[Keys.isSpecial] ~= true then return false end

    return normalizeId(data[Keys.persistId]) == key
end

local function isActive(key)
    key = normalizeId(key)
    if key == nil then return false end

    local zombie = active[key]
    if zombie == nil then return false end
    if ownsActiveIdentity(key, zombie) then return true end

    active[key] = nil
    return false
end

local function idForModData(key)
    local number = tonumber(key)
    if number ~= nil then return number end
    return key
end

local function maxNumericKey(tableValue)
    local maximum = 0
    if tableValue == nil then return maximum end
    for key in pairs(tableValue) do
        local number = tonumber(key)
        if number and number > maximum then maximum = number end
    end
    return maximum
end

local function validStage(stage)
    return type(stage) == "number" and stage >= 1 and stage <= 5
end

local function cellKey(x, y, z)
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    local cx = math.floor(x / INDEX_CELL_SIZE)
    local cy = math.floor(y / INDEX_CELL_SIZE)
    return tostring(z) .. ":" .. tostring(cx) .. ":" .. tostring(cy)
end

local function addBucket(index, bucketKey, key)
    if bucketKey == nil then return end
    local bucket = index[bucketKey]
    if bucket == nil then
        bucket = {}
        index[bucketKey] = bucket
    end
    bucket[key] = true
end

local function removeBucket(index, bucketKey, key)
    if bucketKey == nil then return end
    local bucket = index[bucketKey]
    if bucket == nil then return end
    bucket[key] = nil

    -- `next` is not callable here - PZ's Kahlua raises "Object tried to call nil"
    -- on it, 3340 times in one session before this was found. `pairs` is the only
    -- portable way to ask whether a table still holds anything.
    for _ in pairs(bucket) do return end
    index[bucketKey] = nil
end

local function unindexKey(key)
    local state = indexState[key]
    if state == nil then return end
    if state.descriptorId ~= nil then
        removeBucket(descriptorIndex, state.descriptorId, key)
    end
    if state.cell ~= nil then
        removeBucket(spatialIndex, state.cell, key)
    end
    indexState[key] = nil
end

local function indexEntry(key, entry)
    if key == nil or entry == nil or not validStage(entry.stage) then return end
    key = tostring(key)

    local descriptorId = entry.descriptorId
    if type(descriptorId) ~= "number" or descriptorId <= 0 then descriptorId = nil end
    local cell = cellKey(entry.x, entry.y, entry.z)

    if descriptorId ~= nil then addBucket(descriptorIndex, descriptorId, key) end
    if cell ~= nil then addBucket(spatialIndex, cell, key) end
    indexState[key] = { descriptorId = descriptorId, cell = cell }
end

local function rebuildIndexes()
    descriptorIndex = {}
    spatialIndex = {}
    indexState = {}
    if entries == nil then return end
    for key, entry in pairs(entries) do
        indexEntry(tostring(key), entry)
    end
end

-- --------------------------------------------------------- cleanup rotation --

local function cleanupLink(key)
    key = normalizeId(key)
    if key == nil or cleanupNodes[key] ~= nil then return end

    if cleanupHead == nil then
        cleanupNodes[key] = { prev = key, next = key }
        cleanupHead = key
        cleanupCursor = key
        cleanupCount = 1
        return
    end

    local headNode = cleanupNodes[cleanupHead]
    local tailKey = headNode.prev
    local tailNode = cleanupNodes[tailKey]

    cleanupNodes[key] = { prev = tailKey, next = cleanupHead }
    tailNode.next = key
    headNode.prev = key
    cleanupCount = cleanupCount + 1
end

local function cleanupUnlink(key)
    key = normalizeId(key)
    if key == nil then return false end

    local node = cleanupNodes[key]
    if node == nil then return false end

    if cleanupCount <= 1 then
        cleanupNodes[key] = nil
        cleanupHead = nil
        cleanupCursor = nil
        cleanupCount = 0
        return true
    end

    local prevNode = cleanupNodes[node.prev]
    local nextNode = cleanupNodes[node.next]
    if prevNode ~= nil then prevNode.next = node.next end
    if nextNode ~= nil then nextNode.prev = node.prev end

    if cleanupHead == key then cleanupHead = node.next end
    if cleanupCursor == key then cleanupCursor = node.next end

    cleanupNodes[key] = nil
    cleanupCount = cleanupCount - 1
    return true
end

local function rebuildCleanupRotation()
    cleanupNodes = {}
    cleanupHead = nil
    cleanupCursor = nil
    cleanupCount = 0

    if entries == nil then return end
    for key in pairs(entries) do
        cleanupLink(tostring(key))
    end
end

--- Remove one identity everywhere it exists. Keeping deletion centralized prevents
--- stale descriptor/spatial/GC references from outliving the ledger record.
local function removeIdentity(key)
    key = normalizeId(key)
    if key == nil then return false end

    local existed = entries ~= nil and entries[key] ~= nil
    active[key] = nil
    unindexKey(key)
    cleanupUnlink(key)

    if existed then
        entries[key] = nil
        dirty = true
    end
    return existed
end

local function copyLegacyEntry(old, today)
    if old == nil then return nil end
    return {
        stage = 5,
        path = old.path,
        form = old.form,
        x = old.x,
        y = old.y,
        z = old.z,
        createdDay = old.day or today,
        -- `day` in v0.1.0 was creation time rather than a true last-seen time.
        -- Grant migrated records a fresh grace period instead of deleting an old
        -- but still legitimate T5 immediately on upgrade.
        lastSeenDay = today,
    }
end

local function normalizeEntry(entry, today)
    if entry == nil then return false end
    local changed = false

    -- Defensive support for a copied legacy record inside the new field.
    if not validStage(entry.stage) and entry.form ~= nil then
        entry.stage = 5
        changed = true
    end

    if entry.createdDay == nil then
        entry.createdDay = entry.day or today
        changed = true
    end
    if entry.lastSeenDay == nil then
        entry.lastSeenDay = entry.day or today
        changed = true
    end

    if entry.day ~= nil then
        entry.day = nil
        changed = true
    end

    return changed
end

local function updateEntryFromZombie(entry, zombie, touchSeenDay)
    if entry == nil or zombie == nil then return end

    local data = zombie:getModData()
    entry.stage = data[Keys.stage]
    entry.path = data[Keys.path]
    entry.form = data[Keys.form]
    -- Boomer bottle state is a rolled gameplay variant, not a transient timer.
    -- Preserve false as a real value; nil means this identity has never rolled it.
    if data[Keys.form] == "boomer" and type(data[Keys.formBottle]) == "boolean" then
        entry.formBottle = data[Keys.formBottle]
    else
        entry.formBottle = nil
    end
    entry.t4SpawnDay = data[Keys.t4SpawnDay]
    entry.x, entry.y, entry.z = zombie:getX(), zombie:getY(), zombie:getZ()
    entry.descriptorId = safeSharedDescriptorId(zombie)
    entry.persistentOutfitId = safePersistentOutfitId(zombie)
    entry.female = safeFemale(zombie)
    if touchSeenDay then entry.lastSeenDay = currentDay() end
end

-- ------------------------------------------------------------ persistence --

function SZedPlus.Persistence.load()
    local store = getStore()
    local today = currentDay()
    local migrated = false
    local legacy = store[LEGACY_ENTRIES_FIELD]
    local legacyNextId = store[LEGACY_NEXT_ID_FIELD]
    local legacyPresent = legacy ~= nil or legacyNextId ~= nil

    entries = store[ENTRIES_FIELD]
    if entries == nil then
        entries = {}

        if legacy ~= nil then
            for key, old in pairs(legacy) do
                local copied = copyLegacyEntry(old, today)
                if copied ~= nil then entries[tostring(key)] = copied end
            end
            migrated = true
        end
    end

    nextId = store[NEXT_ID_FIELD]
        or legacyNextId
        or (maxNumericKey(entries) + 1)

    local minimumNext = maxNumericKey(entries) + 1
    if type(nextId) ~= "number" or nextId < minimumNext then
        nextId = minimumNext
        migrated = true
    end

    for _, entry in pairs(entries) do
        if normalizeEntry(entry, today) then migrated = true end
    end

    active = {}
    rebuildIndexes()
    rebuildCleanupRotation()
    dirty = migrated or store[SCHEMA_FIELD] ~= SCHEMA_VERSION

    if legacyPresent then
        -- `identities` is authoritative once present. Never retain a second
        -- legacy `forms` registry alongside it: a mixed-schema save could
        -- otherwise resurrect obsolete T5 positions as ghosts later. When the
        -- new registry did not exist above, legacy entries were copied first.
        store[LEGACY_ENTRIES_FIELD] = nil
        store[LEGACY_NEXT_ID_FIELD] = nil
        migrated = true
        dirty = true
    end

    local count = 0
    for _ in pairs(entries) do count = count + 1 end
    SZedPlus.log("identity persistence loaded, %d remembered Zed+(s)", count)

    if dirty then SZedPlus.Persistence.flush(true) end
end

function SZedPlus.Persistence.flush(force)
    if entries == nil then return end
    if not dirty and not force then return end

    local store = getStore()
    store[ENTRIES_FIELD] = entries
    store[NEXT_ID_FIELD] = nextId
    store[SCHEMA_FIELD] = SCHEMA_VERSION
    dirty = false
end

-- ---------------------------------------------------------------- record --

--- Remember or refresh any T1-T5 Zed+ and bind its stable persistence id.
function SZedPlus.Persistence.remember(zombie)
    if entries == nil or zombie == nil then return nil end

    local data = zombie:getModData()
    local stage = data[Keys.stage]
    if data[Keys.isSpecial] ~= true or not validStage(stage) then return nil end

    local key = normalizeId(data[Keys.persistId])
    local entry = key and entries[key] or nil

    if entry == nil then
        if key == nil then
            key = tostring(nextId)
            nextId = nextId + 1
        else
            local numeric = tonumber(key)
            if numeric and numeric >= nextId then nextId = numeric + 1 end
        end

        entry = {
            createdDay = currentDay(),
            lastSeenDay = currentDay(),
        }
        entries[key] = entry
        cleanupLink(key)
        data[Keys.persistId] = idForModData(key)
        SZedPlus.log("remembering %s as identity #%s", SZedPlus.describe(zombie), key)
    end

    unindexKey(key)
    updateEntryFromZombie(entry, zombie, true)
    indexEntry(key, entry)
    active[key] = zombie
    dirty = true
    return idForModData(key)
end

--- Forget a persisted Zed+ once it is known dead. Returns true on mutation.
--- Persist the Boomer bottle roll as soon as Appearance decides it. This is
--- deliberately narrower than remember(): appearance runs after OnZombieCreate,
--- and this path must not perform extra identity/fingerprint sampling just to
--- store one already-decided gameplay variant.
function SZedPlus.Persistence.rememberFormBottle(zombie)
    if entries == nil or zombie == nil then return false end

    local data = zombie:getModData()
    if data[Keys.form] ~= "boomer" or type(data[Keys.formBottle]) ~= "boolean" then
        return false
    end

    local key = normalizeId(data[Keys.persistId])
    local entry = key and entries[key] or nil
    if entry == nil then return false end

    if entry.formBottle == data[Keys.formBottle] then return true end
    entry.formBottle = data[Keys.formBottle]
    dirty = true
    return true
end

function SZedPlus.Persistence.forget(zombie)
    if entries == nil or zombie == nil then return false end

    local key = normalizeId(zombie:getModData()[Keys.persistId])
    if key == nil then return false end

    if not removeIdentity(key) then return false end
    SZedPlus.log("forgetting Zed+ identity #%s", key)
    return true
end

-- ------------------------------------------------------------------ claim --

--- Find the best inactive identity record for a newly rebuilt zombie.
--- Returns entry, key, reason or nil.
function SZedPlus.Persistence.findClaim(zombie)
    if entries == nil or zombie == nil then return nil end

    local zx, zy, zz = zombie:getX(), zombie:getY(), zombie:getZ()
    local descriptorId = safeSharedDescriptorId(zombie)
    local outfitId = safePersistentOutfitId(zombie)
    local female = safeFemale(zombie)

    -- First query only identities carrying the same shared descriptor. This is
    -- O(matches-for-this-descriptor), not O(all remembered Zed+).
    if descriptorId ~= nil then
        local bucket = descriptorIndex[descriptorId]
        local bestKey, bestEntry, bestDistance = nil, nil, nil
        if bucket ~= nil then
            for key in pairs(bucket) do
                local entry = entries[key]
                if entry ~= nil and validStage(entry.stage) and not isActive(key)
                    and entry.z == zz then
                    local distance = squaredDistance(zx, zy, entry.x, entry.y)
                    if distance <= DESCRIPTOR_CLAIM_RADIUS * DESCRIPTOR_CLAIM_RADIUS
                        and (bestDistance == nil or distance < bestDistance) then
                        bestKey, bestEntry, bestDistance = key, entry, distance
                    end
                end
            end
        end
        if bestEntry ~= nil then return bestEntry, bestKey, "descriptor" end
    end

    -- Descriptor matching was unavailable or found nothing. Query only spatial
    -- cells intersecting the six-tile fallback radius. Valid descriptor
    -- conflicts remain a hard veto so OnZombieCreate order cannot let a nearby
    -- different zombie steal a descriptor-backed identity.
    local minCx = math.floor((zx - CLAIM_RADIUS) / INDEX_CELL_SIZE)
    local maxCx = math.floor((zx + CLAIM_RADIUS) / INDEX_CELL_SIZE)
    local minCy = math.floor((zy - CLAIM_RADIUS) / INDEX_CELL_SIZE)
    local maxCy = math.floor((zy + CLAIM_RADIUS) / INDEX_CELL_SIZE)
    local bestKey, bestEntry, bestScore = nil, nil, nil

    for cx = minCx, maxCx do
        for cy = minCy, maxCy do
            local bucketKey = tostring(zz) .. ":" .. tostring(cx) .. ":" .. tostring(cy)
            local bucket = spatialIndex[bucketKey]
            if bucket ~= nil then
                for key in pairs(bucket) do
                    local entry = entries[key]
                    if entry ~= nil and validStage(entry.stage) and not isActive(key)
                        and entry.z == zz then
                        local distance = squaredDistance(zx, zy, entry.x, entry.y)

                        -- No descriptor veto. Measured 6 Sep 2026 over 536 paired
                        -- samples: the id differs across a reconstruction 94.6% of
                        -- the time, so vetoing on a mismatch would reject almost
                        -- every legitimate reclaim - and silently, since a vetoed
                        -- candidate never reaches the log.
                        if distance <= CLAIM_RADIUS * CLAIM_RADIUS then
                            local score = distance

                            -- A match still means something on the 5.4% where the id
                            -- survives, so keep the bonus. A mismatch means nothing,
                            -- so it carries no penalty: `descriptorId` and
                            -- `persistentOutfitId` were identical in all 463 samples
                            -- where both existed, so this is one signal, not two.
                            if descriptorId ~= nil and entry.descriptorId ~= nil
                                and descriptorId == entry.descriptorId then
                                score = score - 24
                            elseif outfitId ~= nil and entry.persistentOutfitId ~= nil
                                and outfitId == entry.persistentOutfitId then
                                score = score - 8
                            end

                            if female ~= nil and entry.female ~= nil then
                                if female == entry.female then
                                    score = score - 2
                                else
                                    score = score + 12
                                end
                            end

                            if bestScore == nil or score < bestScore then
                                bestKey, bestEntry, bestScore = key, entry, score
                            end
                        end
                    end
                end
            end
        end
    end

    if bestEntry ~= nil then return bestEntry, bestKey, "spatial" end
    return nil
end

--- Bind a selected identity to its rebuilt IsoZombie without consuming it.
--- Keeping the same record/id closes the old consume->recreate window and makes
--- identity continuity observable in logs and future diagnostics.
function SZedPlus.Persistence.attachClaim(zombie, key)
    if entries == nil or zombie == nil or key == nil then return nil end
    key = tostring(key)

    local entry = entries[key]
    if entry == nil or isActive(key) then return nil end

    zombie:getModData()[Keys.persistId] = idForModData(key)
    active[key] = zombie
    unindexKey(key)

    -- TEMP ENGINE_IDENTITY_PROBE2: the whole 64-tile descriptor radius rests on
    -- the descriptor surviving virtualisation, which is assumed, not documented.
    -- This is the direct measurement: what the record stored, against what the
    -- engine just rebuilt. Remove with the probe.
    local wasDescriptor = entry.descriptorId
    local nowDescriptor = safeSharedDescriptorId(zombie)
    local drift = squaredDistance(zombie:getX(), zombie:getY(), entry.x, entry.y)
    SZedPlus.log("PROBE2 claim #%s desc %s -> %s (%s) outfit %s -> %s dist %.1f",
        tostring(key), tostring(wasDescriptor), tostring(nowDescriptor),
        (wasDescriptor == nil and "none-stored")
            or (nowDescriptor == nil and "none-now")
            or (wasDescriptor == nowDescriptor and "STABLE" or "CHANGED"),
        tostring(entry.persistentOutfitId), tostring(safePersistentOutfitId(zombie)),
        math.sqrt(drift))

    -- Refresh fingerprints to what the engine actually rebuilt. Stage/path/form
    -- are intentionally left untouched until Spawn.applySpec restores them.
    entry.x, entry.y, entry.z = zombie:getX(), zombie:getY(), zombie:getZ()
    entry.descriptorId = safeSharedDescriptorId(zombie)
    entry.persistentOutfitId = safePersistentOutfitId(zombie)
    entry.female = safeFemale(zombie)
    entry.lastSeenDay = currentDay()
    indexEntry(key, entry)
    dirty = true

    return entry
end

-- --------------------------------------------------------------- probes --

--- Read-only runtime snapshot for manual unload/reload diagnostics. Nothing in
--- production calls this automatically; it exists so a server-side probe can
--- compare the same observed zombie before and after population virtualisation
--- without enabling global per-zombie logging.
function SZedPlus.Persistence.getProbeSnapshot(zombie)
    if zombie == nil then return nil end

    local ok, data = pcall(function() return zombie:getModData() end)
    if not ok or data == nil then return nil end

    local snapshot = {
        descriptorId = safeSharedDescriptorId(zombie),
        persistentOutfitId = safePersistentOutfitId(zombie),
        female = safeFemale(zombie),
        initialized = data[Keys.initialized] == true,
        isSpecial = data[Keys.isSpecial] == true,
        persistId = normalizeId(data[Keys.persistId]),
    }

    pcall(function()
        snapshot.x, snapshot.y, snapshot.z = zombie:getX(), zombie:getY(), zombie:getZ()
    end)
    pcall(function() snapshot.onlineId = zombie:getOnlineID() end)
    return snapshot
end

--- Convenience logger for the manual descriptor/ordinary-reroll runtime probe.
--- Explicit invocation only; no spawn hook or periodic logging is added.
function SZedPlus.Persistence.logProbe(label, zombie)
    local probe = SZedPlus.Persistence.getProbeSnapshot(zombie)
    if probe == nil then
        SZedPlus.log("PERSISTENCE_PROBE %s unavailable", tostring(label))
        return nil
    end

    SZedPlus.log(
        "PERSISTENCE_PROBE %s pos=(%s,%s,%s) descriptor=%s outfit=%s female=%s online=%s initialized=%s special=%s persistId=%s",
        tostring(label), tostring(probe.x), tostring(probe.y), tostring(probe.z),
        tostring(probe.descriptorId), tostring(probe.persistentOutfitId),
        tostring(probe.female), tostring(probe.onlineId), tostring(probe.initialized),
        tostring(probe.isSpecial), tostring(probe.persistId)
    )
    return probe
end

-- ----------------------------------------------------------------- upkeep --

local function refreshActive()
    if entries == nil then return end

    for key, zombie in pairs(active) do
        if ownsActiveIdentity(key, zombie) then
            unindexKey(key)
            updateEntryFromZombie(entries[key], zombie, true)
            indexEntry(key, entries[key])
            dirty = true
        else
            active[key] = nil
        end
    end
end

local function dropStaleBatch()
    if entries == nil or cleanupCount <= 0 or cleanupCursor == nil then return 0 end

    local today = currentDay()
    -- Inspect each identity at most once in this event even if deletions shrink the
    -- ring while we walk it. Newly-added identities join future rotations.
    local toInspect = math.min(CLEANUP_BATCH_SIZE, cleanupCount)
    local inspected = 0

    while inspected < toInspect and cleanupCursor ~= nil do
        local key = cleanupCursor
        local node = cleanupNodes[key]

        -- Runtime corruption should not force a full rebuild in the hot path. If a
        -- node disappeared unexpectedly, restart from the current head and let the
        -- next load rebuild all derived state from the authoritative ledger.
        if node == nil then
            cleanupCursor = cleanupHead
            break
        end

        local nextKey = node.next
        local entry = entries[key]
        inspected = inspected + 1

        if entry == nil then
            removeIdentity(key)
        elseif not isActive(key) then
            local lastSeen = entry.lastSeenDay or entry.createdDay or today
            local maxAge = entry.descriptorId ~= nil and DESCRIPTOR_STALE_DAYS or STALE_DAYS
            if today - lastSeen > maxAge then
                local age = today - lastSeen
                if removeIdentity(key) then
                    SZedPlus.log("dropping stale Zed+ identity #%s after %d day(s)",
                        tostring(key), age)
                end
            else
                cleanupCursor = nextKey
            end
        else
            cleanupCursor = nextKey
        end
    end

    return inspected
end

local function onTick()
    tickCounter = tickCounter + 1
    if tickCounter < REFRESH_TICKS then return end
    tickCounter = 0
    refreshActive()
end

Events.OnZombieDead.Add(function(zombie)
    if SZedPlus.Persistence.forget(zombie) then
        SZedPlus.Persistence.flush(true)
    end
end)

--- TEMP ENGINE_IDENTITY_PROBE2: ledger census. Going from T5-only to T1-T5
--- multiplies what is remembered, and the growth curve is the thing to watch on
--- a long session. Also reports descriptor coverage, since a ledger where almost
--- nothing carries a descriptor means the 64-tile path is dead weight anyway.
--- Remove with the probe.
local function census()
    if entries == nil then return end

    local total, withDescriptor, byStage = 0, 0, {}
    for _, entry in pairs(entries) do
        total = total + 1
        if entry.descriptorId ~= nil then withDescriptor = withDescriptor + 1 end
        local stage = entry.stage or 0
        byStage[stage] = (byStage[stage] or 0) + 1
    end

    local activeCount = 0
    for _ in pairs(active) do activeCount = activeCount + 1 end

    SZedPlus.log("PROBE2 census total=%d withDescriptor=%d active=%d "
        .. "T1=%d T2=%d T3=%d T4=%d T5=%d other=%d",
        total, withDescriptor, activeCount,
        byStage[1] or 0, byStage[2] or 0, byStage[3] or 0,
        byStage[4] or 0, byStage[5] or 0, byStage[0] or 0)
end

Events.OnInitGlobalModData.Add(SZedPlus.Persistence.load)
Events.EveryTenMinutes.Add(function()
    refreshActive()
    dropStaleBatch()
    census()
    SZedPlus.Persistence.flush()
end)
Events.OnSave.Add(function()
    refreshActive()
    SZedPlus.Persistence.flush(true)
end)
Events.OnTick.Add(onTick)
