--- ZED+ : draws acid pools on the ground.
---
--- Handed to the engine as grid-square markers rather than drawn by hand.
---
--- The first version projected each pool with isoToScreenX/Y and stamped the
--- texture at that point every frame. It never sat right: the pools rendered a
--- storey too high, and they slid across the ground as the camera zoomed. Both
--- are the same bug - reproducing the engine's isometric projection from Lua
--- means reproducing its zoom handling and its ground-depth handling too, and
--- getting either slightly wrong shows up as drift.
---
--- WorldMarkers is the engine doing all of that itself. addGridSquareMarker
--- takes a texture name and an IsoGridSquare, and its useGroundDepth flag is
--- exactly the "sit on the floor, not above it" behaviour that was missing. A
--- marker is placed once and left alone, so there is no per-frame work either.
---
--- Drawn with the engine's own untextured marker, one per tile.
---
--- Two richer approaches were tried and dropped, recorded so they are not
--- attempted a third time.
---
--- A textured marker cannot work: GridSquareMarker resolves a name through
--- IsoSpriteManager.getSprite(), which calls AddSprite() on a miss, and a sprite
--- built that way ignores its texture's alpha - the marker draws a solid
--- diamond. Vanilla's own "circle_orb" produced the same diamond, which settled
--- it: the fault was never in our artwork.
---
--- IsoObject on the square, the way the engine places its own floor blood, gets
--- the geometry right but not the colour: setCustomColor() had no visible effect
--- either before or after AddTileObject, so pools rendered blood red, and the
--- splats sat off the tiles they were added to.
---
--- What is left works everywhere: the plain marker, one per tile, tinted acid
--- green. Modest, correctly placed, immune to zoom.
---
--- Client-side by definition - the server owns where the pools are, this only
--- shows them. In single player the server code runs in this same process and
--- pushes them directly.

SZedPlus = SZedPlus or {}
SZedPlus.AcidRender = {}

--- Acid green, for the pool itself and for the accessibility outline.
local TINT_R, TINT_G, TINT_B = 0.55, 0.95, 0.25

--- Fluorescent green, so the debug footprint cannot be mistaken for the pool.
local DEBUG_R, DEBUG_G, DEBUG_B = 0.1, 1.0, 0.1

--- `size` is a DIAMETER in tiles, not a radius.
---
--- From GridSquareMarker: scaleRatio = 64 * Core.tileScale / texture:getWidth(),
--- and the sprite is drawn at texture width * scaleRatio * size - which comes to
--- 64 * tileScale * size, and 64 * tileScale is exactly one tile. So size 1.0
--- covers one tile across, and a pool of radius r needs 2r.
local DIAMETER = 2.0

--- Trim on the accessibility outline.
---
--- 2r is the geometrically exact figure, and it read a touch wide in game. The
--- circle is drawn centred on the tile the pool started on, while the damage is
--- measured from the pool's exact position within that tile - so the outline is
--- an approximation whatever number goes in, and erring slightly inside it is
--- the safer way to be approximate.
local OUTLINE_TRIM = 0.9

--- Live markers, keyed by the pool id the server side assigns: pool id -> array
--- of markers, one per tile the pool covers.
local markers = {}

--- Accessibility outlines, keyed the same way: an optional plain circle marking
--- exactly how far the pool reaches.
local circles = {}
local circlesWereOn = false

--- Debug footprint markers, keyed the same way.
local overlays = {}
local overlayWasOn = false

-- ---------------------------------------------------------------- markers --

--- Drop one marker, tolerating a build where the call is missing.
local function removeMarker(marker)
    pcall(function() getWorldMarkers():removeGridSquareMarker(marker) end)
end

--- The squares a pool covers: every tile whose centre is inside its radius.
---
--- This is the same test the damage sweep applies to a player's position, so
--- anything drawn from this list is drawn exactly where it hurts.
local function footprintSquares(pool)
    local radius = pool.radius or 1.0
    local reach = math.ceil(radius)
    local z = math.floor(pool.z)
    local squares = {}

    for ix = math.floor(pool.x - reach), math.floor(pool.x + reach) do
        for iy = math.floor(pool.y - reach), math.floor(pool.y + reach) do
            local dx = (ix + 0.5) - pool.x
            local dy = (iy + 0.5) - pool.y
            if dx * dx + dy * dy <= radius * radius then
                local square = getCell():getGridSquare(ix, iy, z)
                if square then squares[#squares + 1] = square end
            end
        end
    end

    return squares
end

--- Slightly over one tile so neighbours overlap into one spill rather than a
--- grid of separate discs. Only used by the fallback.
local TILE_OVERLAP = 1.15

--- Our own splat, registered as a sprite and placed as a tile object.
---
--- This is the one route left that can show custom artwork. The marker's
--- textured overload cannot (its sprite ignores alpha), and vanilla's blood
--- sprites placed as tile objects came out red because setCustomColor had no
--- effect. Registering OUR texture sidesteps both: nothing needs tinting,
--- because the artwork is already the right colour.
local SPRITE_PATH = "media/textures/SZedPlus/SZedPlus_AcidPool.png"
local SPLAT_FLAG = "SZedPlus_acid"

--- Tells this session's splats from ones left in the save by an earlier one.
---
--- The cleanup below cannot just remove everything carrying the flag: a chunk
--- that streams back in while a pool is live would have its splats deleted, and
--- the pool then covered only the tiles whose squares never reloaded. Stamping
--- the session makes "left over from before" answerable.
local SESSION = tostring(getTimestampMs and getTimestampMs() or os.time())

local spriteReady = nil

--- Register the sprite once, and say what was found.
---
--- The size report is the point: a tile object draws its sprite at native size,
--- so if the splat comes out too big or too small the vanilla figure printed
--- beside ours says exactly what to author it at, instead of another guess.
local function ensureSprite()
    if spriteReady ~= nil then return spriteReady end

    spriteReady = false
    pcall(function()
        local ours = getTexture(SPRITE_PATH)
        if ours == nil then
            SZedPlus.logError("acid texture missing: %s", SPRITE_PATH)
            return
        end

        IsoSpriteManager.instance:AddSprite(SPRITE_PATH)
        spriteReady = true

        local reference = getTexture("blood_floor_med_01")
        SZedPlus.log("acid sprite %dx%d (vanilla blood_floor_med_01 is %s)",
            ours:getWidth(), ours:getHeight(),
            reference and (reference:getWidth() .. "x" .. reference:getHeight())
                       or "unavailable")
    end)

    return spriteReady
end

--- Draw a pool as one splat per tile it covers.
local function addSplats(pool)
    local squares = footprintSquares(pool)
    if #squares == 0 then return nil end

    local textured = ensureSprite()
    local placed = {}

    for _, square in ipairs(squares) do
        local thing = nil

        if textured then
            pcall(function()
                local object = IsoObject.new(square, SPRITE_PATH)
                object:getModData()[SPLAT_FLAG] = SESSION
                square:AddTileObject(object)
                thing = object
            end)
        end

        -- Fallback: the engine's plain marker. Correctly placed and immune to
        -- zoom, just a disc rather than a splat.
        if thing == nil then
            pcall(function()
                thing = getWorldMarkers():addGridSquareMarker(
                    square, TINT_R, TINT_G, TINT_B, true, TILE_OVERLAP)
            end)
        end

        if thing then placed[#placed + 1] = thing end
    end

    if #placed == 0 then
        SZedPlus.logError("could not place acid at %.1f,%.1f", pool.x, pool.y)
        return nil
    end
    return placed
end

--- Take one splat back, whichever kind it turned out to be.
local function removeSplat(thing)
    if thing == nil then return end
    if not pcall(function() thing:removeFromSquare() end) then
        removeMarker(thing)
    end
end

--- Sweep a loading square for splats left behind by an earlier session.
---
--- A tile object is serialised with its chunk, so a pool present when the game
--- saves would come back permanently. Pools are removed on expiry, but a green
--- stain that never goes away is not a risk worth carrying.
---
--- Only splats stamped by an earlier session go: removing this session's too
--- deleted live pools whenever their chunk reloaded, which is why some affected
--- tiles ended up with no decal on them.
local function onLoadGridsquare(square)
    if square == nil then return end
    pcall(function()
        local objects = square:getObjects()
        for index = objects:size() - 1, 0, -1 do
            local object = objects:get(index)
            local stamp = object and object.getModData
                and object:getModData()[SPLAT_FLAG]
            if stamp and stamp ~= SESSION then
                object:removeFromSquare()
            end
        end
    end)
end

Events.LoadGridsquare.Add(onLoadGridsquare)

-- ------------------------------------------------------- accessibility --

--- Is the simplified outline on?
---
--- Reread rather than read: this is a display option a player expects to take
--- effect the moment they tick it, and the cached value only updates at load.
local function outlineEnabled()
    return SZedPlus.AcidRender.isOn("AcidSimpleZone")
end

--- A single circle over the pool, at exactly the pool's radius.
---
--- The pool itself is drawn tile by tile with a deliberate overlap, so its
--- outer edge is ragged and sits a little past where the damage stops. This one
--- circle is drawn over that, at the true figure, for a player who needs to see
--- the boundary rather than infer it. Added on top, never instead.
local function addCircle(pool, square)
    -- The true diameter, trimmed slightly: the honest edge of the damage zone.
    local marker = nil
    pcall(function()
        marker = getWorldMarkers():addGridSquareMarker(
            square, TINT_R, TINT_G, TINT_B, true,
            (pool.radius or 1.0) * DIAMETER * OUTLINE_TRIM)
    end)
    return marker
end

--- Drop every outline. Used when the option is switched off mid-game.
local function clearCircles()
    for id, marker in pairs(circles) do
        if marker then removeMarker(marker) end
        circles[id] = nil
    end
end

-- ------------------------------------------------------------ footprint --

--- Is the footprint overlay on?
---
--- Two gates, both required. The sandbox option is the switch a player sees;
--- -debug is what keeps it out of a normal game even if the option is left on
--- in a shared save, which is the situation the option alone cannot protect
--- against.
--- Runtime overrides for the two display options.
---
--- Sandbox options do not change while a game is running - the engine has no
--- event for it, and in single player there is no in-game editor writing back
--- to SandboxVars either, so re-reading them is not enough. These let the debug
--- menu flip a setting now. nil means "follow the sandbox option".
local overrides = {}

--- Flip one display option, and return what it is now.
function SZedPlus.AcidRender.toggle(key, current)
    overrides[key] = not current
    return overrides[key]
end

--- What a display option currently resolves to: the override if one is set,
--- otherwise the sandbox value.
function SZedPlus.AcidRender.isOn(key)
    if overrides[key] ~= nil then return overrides[key] end
    local value = false
    pcall(function() value = SZedPlus.Config.reread(key) == true end)
    return value
end

local overlayReported = nil

local function overlayEnabled()
    local debug = false
    pcall(function() debug = isDebugEnabled() end)

    local option = SZedPlus.AcidRender.isOn("AcidOverlay")

    -- Say once which of the two gates is shut. Two conditions with no feedback
    -- is a bad way to debug a debug tool: a silent overlay looks the same
    -- whether the option is off or the game was launched without -debug.
    local state = tostring(debug) .. "/" .. tostring(option)
    if overlayReported ~= state then
        overlayReported = state
        SZedPlus.log("acid overlay: -debug=%s option=%s -> %s",
            tostring(debug), tostring(option),
            (debug and option) and "on" or "off")
    end

    return debug and option
end

--- Highlight every tile the pool actually damages.
---
--- Recomputed from the pool's centre and radius: the point of the overlay is to
--- show what the damage check covers, so it can be compared against what is
--- drawn. Both now come from footprintSquares, so a disagreement would mean a
--- real bug rather than a rendering approximation.
---
--- A tile counts when its centre falls inside the radius, which is the same
--- test the sweep applies to a player's position - a player standing in the
--- middle of a green tile takes damage.
local function addOverlay(pool)
    local placed = {}
    for _, square in ipairs(footprintSquares(pool)) do
        local marker = nil
        pcall(function()
            marker = getWorldMarkers():addGridSquareMarker(
                square, DEBUG_R, DEBUG_G, DEBUG_B, true, 1.0)
        end)
        if marker then placed[#placed + 1] = marker end
    end
    return placed
end

--- Drop one pool's footprint.
local function removeOverlay(id)
    for _, marker in ipairs(overlays[id] or {}) do
        removeMarker(marker)
    end
    overlays[id] = nil
end

--- Drop every footprint. Used when the option is switched off mid-game.
local function clearOverlays()
    for id in pairs(overlays) do removeOverlay(id) end
end

--- Replace the drawn set.
---
--- Called on every sweep, ten times a second, so it reconciles rather than
--- rebuilding: markers already placed are left alone and only their alpha is
--- updated, which is what lets a pool fade out without flickering.
function SZedPlus.AcidRender.setPools(list)
    list = list or {}

    local seen = {}

    -- Both options are read once per sweep so they can be toggled in game.
    local overlay = overlayEnabled()
    if overlayWasOn and not overlay then clearOverlays() end
    overlayWasOn = overlay

    local outline = outlineEnabled()
    if circlesWereOn and not outline then clearCircles() end
    circlesWereOn = outline

    for _, pool in ipairs(list) do
        local id = pool.id
        if id then
            seen[id] = true

            if markers[id] == nil then
                markers[id] = addSplats(pool)
            end

            -- The outline goes on the square the pool started from.
            if outline and circles[id] == nil then
                local square = getCell():getGridSquare(
                    math.floor(pool.x), math.floor(pool.y), math.floor(pool.z))
                if square then circles[id] = addCircle(pool, square) end
            end
            if circles[id] then
                pcall(function() circles[id]:setAlpha(pool.alpha or 0.8) end)
            end

            -- The footprint never moves, so it is built once and left alone.
            if overlay and overlays[id] == nil then
                overlays[id] = addOverlay(pool)
            end
        end
    end

    -- Anything no longer in the set has expired.
    for id, placed in pairs(markers) do
        if not seen[id] then
            for _, object in ipairs(placed or {}) do removeSplat(object) end
            markers[id] = nil

            if circles[id] then removeMarker(circles[id]) end
            circles[id] = nil

            removeOverlay(id)
        end
    end
end

--- Drop every marker. Called when the world goes away, so markers do not
--- outlive the pools they belong to.
function SZedPlus.AcidRender.clear()
    for id, placed in pairs(markers) do
        for _, object in ipairs(placed or {}) do removeSplat(object) end
        markers[id] = nil
    end
    clearCircles()
    clearOverlays()
end

Events.OnPlayerDeath.Add(SZedPlus.AcidRender.clear)
