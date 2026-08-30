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
--- Client-side by definition - the server owns where the pools are, this only
--- shows them. In single player the server code runs in this same process and
--- pushes them directly.

SZedPlus = SZedPlus or {}
SZedPlus.AcidRender = {}

--- The marker takes a bare NAME, and the file has to live in one exact folder.
---
--- WorldMarkers$GridSquareMarker.init builds its path from a string-concat
--- recipe that is in the class constant pool in full:
---     'media/textures/highlights/.png'
--- so it does getSharedTexture("media/textures/highlights/" .. name .. ".png"),
--- with "circle_center" as its default. No directory and no extension in the
--- name, and the PNG must sit in media/textures/highlights/ - our mod's copy of
--- that folder merges with the game's.
---
--- Two earlier guesses failed here, both because the check did not match what
--- init actually does. Handed an absolute disk path, getSharedTexture() returns
--- a texture quite happily, so the name looked valid and the marker still threw
---   NullPointerException: Cannot invoke "Texture.getWidth()" because "tex" is
---   null at WorldMarkers$GridSquareMarker.init
--- The lesson: verify a name by performing the *engine's* lookup, not a lookup
--- that merely resembles it. nameWorks() below builds the same path init does.
---
--- Sprite names are a flat global namespace shared with every other mod, hence
--- the prefixed filename.
--- Which artwork the pool is drawn with.
---
--- "circle_orb" is vanilla's, already in media/textures/highlights/. It is set
--- here deliberately, and it is a test as much as a default.
---
--- The custom splat renders as a solid diamond however it is authored. It now
--- matches vanilla's marker artwork on every property that can be measured -
--- RGBA, white RGB under the transparent pixels, not premultiplied, 512x256 -
--- so the difference is no longer in the file. The remaining suspect is the
--- sprite: ours is created on demand by IsoSpriteManager.AddSprite, while
--- vanilla's may be registered at boot with blend flags a bare IsoSprite does
--- not get.
---
--- circle_orb settles it, because it is a loose PNG in that folder too and so
--- takes the same AddSprite path:
---   * it renders as an orb  -> the code path is fine, the fault is in our PNG
---   * it renders as a diamond -> auto-created sprites do not blend, and no
---     custom texture can work here whatever we do to the file
---
--- Either way the pool looks right in the meantime: a soft round orb tinted
--- acid green is a perfectly good pool.
local TEXTURE_NAME = "circle_orb"

--- The custom splat, kept for when the question above is answered.
local CUSTOM_TEXTURE_NAME = "SZedPlus_AcidPool"

--- Where the engine will look for it, and so where the file must be.
local TEXTURE_DIR = "media/textures/highlights/"

--- Acid green, for the shapes with no artwork of their own - the accessibility
--- outline and the plain fallback marker.
local TINT_R, TINT_G, TINT_B = 0.55, 0.95, 0.25

--- `size` is a DIAMETER in tiles, not a radius.
---
--- From GridSquareMarker: scaleRatio = 64 * Core.tileScale / texture:getWidth(),
--- and the sprite is drawn at texture width * scaleRatio * size - which comes to
--- 64 * tileScale * size, and 64 * tileScale is exactly one tile. So size 1.0
--- covers one tile across, and a pool of radius r needs 2r.
---
--- Passing the radius straight through drew every zone at half the width it
--- damages, which is the wrong half to be wrong on.
local DIAMETER = 2.0

--- Trim on the accessibility outline.
---
--- 2r is the geometrically exact figure, and it read a touch wide in game. The
--- circle is drawn centred on the tile the pool started on, while the damage is
--- measured from the pool's exact position within that tile - so the outline is
--- an approximation whatever number goes in, and erring slightly inside it is
--- the safer way to be approximate.
local OUTLINE_TRIM = 0.9

--- Live markers, keyed by the pool id the server side assigns.
local markers = {}

--- Accessibility outlines, keyed the same way: an optional plain circle drawn
--- over the splat, marking exactly how far the pool reaches.
local circles = {}
local circlesWereOn = false

--- Debug footprint markers, keyed the same way: pool id -> array of markers,
--- one per tile the pool actually damages.
local overlays = {}
local overlayWasOn = false

--- Fluorescent green, so the footprint cannot be mistaken for the pool itself.
local DEBUG_R, DEBUG_G, DEBUG_B = 0.1, 1.0, 0.1

-- ---------------------------------------------------------------- texture --

local resolvedName = nil
local resolveFailed = false

--- Exactly the lookup GridSquareMarker.init performs.
local function nameWorks(name)
    if name == nil or name == "" then return false end
    local texture = nil
    pcall(function()
        texture = Texture.getSharedTexture(TEXTURE_DIR .. name .. ".png")
    end)
    return texture ~= nil
end

local function resolveTextureName()
    if resolvedName then return resolvedName end
    if resolveFailed then return nil end

    -- Seed the cache: a mod texture is loaded on demand, and the shared lookup
    -- only finds what has already been loaded.
    pcall(function() getTexture(TEXTURE_DIR .. TEXTURE_NAME .. ".png") end)
    pcall(function() getTexture(TEXTURE_DIR .. CUSTOM_TEXTURE_NAME .. ".png") end)

    for _, name in ipairs({ TEXTURE_NAME, TEXTURE_NAME:lower() }) do
        if nameWorks(name) then
            resolvedName = name
            SZedPlus.log("acid texture resolved as '%s' (%s%s.png)",
                name, TEXTURE_DIR, name)
            return resolvedName
        end
    end

    SZedPlus.log("no marker texture at %s%s.png; using the engine's plain marker",
        TEXTURE_DIR, TEXTURE_NAME)
    resolveFailed = true
    return nil
end

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

--- Draw a pool as one marker per tile it covers.
---
--- Not one big marker: that was a running fight with the engine's geometry. A
--- single marker had to be sized in tiles from a radius, which meant getting
--- the diameter conversion right; it had to be drawn from artwork authored for
--- the whole footprint; and at six tiles across it was clipped at chunk
--- boundaries, which is what made it appear to crop as the camera moved.
---
--- Per tile, every one of those goes away. size 1.0 is exactly one tile by
--- definition, so there is no conversion to get wrong; the shape follows the
--- damage footprint because it IS the damage footprint, computed by the same
--- test; and each quad is one tile, far too small to straddle a chunk.
---
--- Slightly over one tile so neighbours overlap and read as one spill rather
--- than a grid of separate blobs. Kept modest: the artwork carries its own soft
--- edge, and too much overlap merges the tiles back into a solid mass - which
--- is what a generated mask covering 98% of its frame produced, and why the
--- pools drew as filled diamonds.
local TILE_OVERLAP = 1.15

local function addMarker(pool)
    local squares = footprintSquares(pool)
    if #squares == 0 then return nil end

    local name = resolveTextureName()
    local placed = {}

    for _, square in ipairs(squares) do
        local marker = nil

        -- Preferred: our own splat. A nil overlay name is not allowed - the
        -- engine looks that one up too, and the null it gets back is the
        -- NullPointerException thrown from inside addGridSquareMarker.
        if name then
            pcall(function()
                marker = getWorldMarkers():addGridSquareMarker(
                    name, name, square,
                    TINT_R, TINT_G, TINT_B,
                    true,               -- useGroundDepth: lie on the floor
                    TILE_OVERLAP)
            end)
            if marker == nil then
                SZedPlus.logError("texture '%s' rejected by the marker", name)
                resolvedName, resolveFailed = nil, true
                name = nil
            end
        end

        -- Fallback: the engine's own marker, no texture. Placed by the same
        -- code that places every other marker in the game, so it cannot go
        -- missing.
        if marker == nil then
            pcall(function()
                marker = getWorldMarkers():addGridSquareMarker(
                    square, TINT_R, TINT_G, TINT_B, true, TILE_OVERLAP)
            end)
        end

        if marker then placed[#placed + 1] = marker end
    end

    if #placed == 0 then
        SZedPlus.logError("could not place acid markers at %.1f,%.1f", pool.x, pool.y)
        return nil
    end
    return placed
end

-- ------------------------------------------------------- accessibility --

--- Is the simplified outline on?
---
--- Reread rather than read: this is a display option a player expects to take
--- effect the moment they tick it, and the cached value only updates at load.
local function outlineEnabled()
    return SZedPlus.AcidRender.isOn("AcidSimpleZone")
end

--- A plain circle over the pool, at exactly the pool's radius.
---
--- The engine's untextured marker, which is a filled disc with a bright rim -
--- the rim is the point, since the splat texture has soft edges and a player
--- cannot tell from it where the damage actually stops. Added on top of the
--- splat, never instead of it.
local function addCircle(pool, square)
    -- The true diameter, with no generosity applied: this is the honest edge of
    -- the damage zone, which is exactly what the splat above it is not.
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
--- Deliberately recomputed from the pool's centre and radius rather than read
--- off the drawn texture: the whole point of the overlay is to show what the
--- damage check covers, so that it can be compared against what is drawn. If
--- the green tiles and the splat disagree, the splat is wrong.
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

            local placed = markers[id]
            if placed == nil then
                placed = addMarker(pool)
                markers[id] = placed
            end

            for _, marker in ipairs(placed or {}) do
                pcall(function() marker:setAlpha(pool.alpha or 0.8) end)
            end

            -- The outline goes on the same square, over the splat.
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
            for _, marker in ipairs(placed or {}) do removeMarker(marker) end
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
        for _, marker in ipairs(placed or {}) do removeMarker(marker) end
        markers[id] = nil
    end
    clearCircles()
    clearOverlays()
end

Events.OnPlayerDeath.Add(SZedPlus.AcidRender.clear)
