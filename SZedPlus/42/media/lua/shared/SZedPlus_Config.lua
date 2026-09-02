--- ZED+ : configuration.
---
--- Every tunable comes from the sandbox options (media/sandbox-options.txt).
--- Nothing else in the mod should read SandboxVars directly: this layer applies
--- a fallback for every value, so the mod still runs when an option is missing
--- (a save made before the option existed, a server that overrides only part of
--- the set, or the options file failing to load).
---
--- Multiplayer: sandbox options are authored on the server and replicated to
--- every client, so both sides read the same values here. They can change when
--- a server admin edits them, hence refresh() rather than a one-off read.
---
--- Loaded first (alphabetically before SZedPlus_Core), depends on nothing.

SZedPlus = SZedPlus or {}
SZedPlus.Config = {}

--- Fallbacks. These must match the `default =` lines in sandbox-options.txt.
---
--- The Volatile and every Calamity default to OFF: they are not implemented.
--- The Volatile has no behaviour table at all (SZedPlus_Forms lists it as nil)
--- and the Calamities are parked on the custom-creature animation problem, so
--- leaving them on shipped a switch that promised something and did nothing.
local DEFAULTS = {
    SpawnRate = 400,

    DayTier1 = 0,
    DayTier3 = 7,
    DayTier5 = 21,
    DayTier6 = 30,
    T4SurvivalDays = 4,

    Debug = false,
    AcidOverlay = false,
    AcidSimpleZone = false,

    PathFast = true,
    PathTank = true,
    PathStealth = true,
    PathRanged = true,

    -- Relative weights, 0-100. A form at 0 never spawns, which is what the
    -- old on/off switches did - so they are gone and this replaces them. The
    -- numbers are relative to each other WITHIN a path, not percentages: a
    -- path only ever picks between its own two forms.
    WeightWitch = 100,
    WeightVolatile = 0,
    WeightColossus = 100,
    WeightBoomer = 100,
    WeightStalker = 100,
    WeightMimic = 100,
    WeightSpitter = 100,
    WeightScout = 100,

    CalamitiesEnabled = false,
    CalamityHost = false,
    CalamityMist = false,
    CalamityLeader = false,
    CalamityCentaur = false,
    CalamityRadius = 150,
    CalamityMinZombies = 25,
    CalamityPrePlaced = false,

    ThrillerEnabled = true,
    ThrillerRarity = 5000,
}

--- Resolved values, filled by refresh().
SZedPlus.Config.values = {}

--- Read one sandbox option, falling back to its default.
local function readOption(name)
    local vars = SandboxVars and SandboxVars.SZedPlus
    if vars == nil then return DEFAULTS[name] end

    local value = vars[name]
    if value == nil then return DEFAULTS[name] end
    return value
end

--- Re-read every option. Called at load and whenever sandbox options change.
function SZedPlus.Config.refresh()
    local values = SZedPlus.Config.values
    for name in pairs(DEFAULTS) do
        values[name] = readOption(name)
    end
end

--- Re-read one option right now.
---
--- refresh() runs at load and at OnGameStart, and there is no engine event for
--- "sandbox options changed" - so an option toggled from the in-game sandbox
--- editor was invisible to the mod until a restart. That is fine for options
--- read once at spawn, and wrong for anything a player expects to take effect
--- immediately, which is what the debug overlay showed: the option was on and
--- the mod still saw the value it had cached at load.
function SZedPlus.Config.reread(name)
    SZedPlus.Config.values[name] = readOption(name)
    return SZedPlus.Config.get(name)
end

--- Accessor. Use this everywhere instead of touching .values directly, so a
--- typo raises rather than silently returning nil.
function SZedPlus.Config.get(name)
    local value = SZedPlus.Config.values[name]
    if value == nil then
        if DEFAULTS[name] == nil then
            error("SZedPlus: unknown config option '" .. tostring(name) .. "'", 2)
        end
        return DEFAULTS[name]
    end
    return value
end

-- ------------------------------------------------------------ derived --

--- Which stage band may be rolled on a given apocalypse day.
--- Returns the inclusive [min, max] stage range, or nil if no Zed+ can spawn.
---
--- T5 is rolled at spawn, not reached by promoting a T4.
---
--- The bible specifies promotion after four days of survival, and that cannot
--- be built as written: a zombie's modData does not survive the player leaving
--- the area - the population manager discards it - so a T4's survival clock
--- would reset every time you walked away. SZedPlus_Persistence exists purely
--- to work around that for T5, and it can only ever match "near enough".
---
--- Rolling at spawn is indistinguishable to the player, because they never
--- meet the same zombie twice. What it costs is the evolution narrative, which
--- nobody could observe anyway. T4SurvivalDays is consequently unused.
---
--- T6 is still unreachable: the Calamities are not implemented.
function SZedPlus.Config.getStageRangeForDay(day)
    local get = SZedPlus.Config.get
    if day >= get("DayTier5") then
        return 1, 5
    elseif day >= get("DayTier3") then
        return 1, 4
    elseif day >= get("DayTier1") then
        return 1, 2
    end
    return nil, nil
end

--- Paths currently enabled, as a fresh array. Empty if the player disabled
--- all four, in which case no Zed+ can go past T2.
function SZedPlus.Config.getEnabledPaths()
    local get = SZedPlus.Config.get
    local enabled = {}
    if get("PathFast")    then enabled[#enabled + 1] = "fast" end
    if get("PathTank")    then enabled[#enabled + 1] = "tank" end
    if get("PathStealth") then enabled[#enabled + 1] = "stealth" end
    if get("PathRanged")  then enabled[#enabled + 1] = "ranged" end
    return enabled
end

--- Which T5 forms each path can become, and the option carrying each weight.
---
--- The pairing is the bible's evolution tree, and it is also what the sandbox
--- labels tell the player ("Witch (Fast)", "Colossus (Tank)", ...). A path only
--- ever picks between its own two forms, which is why the weights are relative
--- within a path rather than across all eight.
local FORMS_BY_PATH = {
    fast    = { { "witch",    "WeightWitch"    }, { "volatile", "WeightVolatile" } },
    tank    = { { "colossus", "WeightColossus" }, { "boomer",   "WeightBoomer"   } },
    stealth = { { "stalker",  "WeightStalker"  }, { "mimic",    "WeightMimic"    } },
    ranged  = { { "spitter",  "WeightSpitter"  }, { "scout",    "WeightScout"    } },
}

--- The weight a form is currently set to, clamped to 0-100. Zero means never.
function SZedPlus.Config.getFormWeight(form)
    for _, forms in pairs(FORMS_BY_PATH) do
        for _, entry in ipairs(forms) do
            if entry[1] == form then
                local weight = SZedPlus.Config.get(entry[2])
                if type(weight) ~= "number" then return 0 end
                if weight < 0 then return 0 end
                if weight > 100 then return 100 end
                return weight
            end
        end
    end
    return 0
end

function SZedPlus.Config.isFormEnabled(form)
    return SZedPlus.Config.getFormWeight(form) > 0
end

--- Pick a T5 form for `path`, weighted. nil if the player zeroed both of them,
--- which the caller treats as "this path cannot produce a T5" rather than as an
--- error - it is a legitimate configuration.
function SZedPlus.Config.pickFormForPath(path)
    local forms = FORMS_BY_PATH[path]
    if not forms then return nil end

    local total = 0
    for _, entry in ipairs(forms) do
        total = total + SZedPlus.Config.getFormWeight(entry[1])
    end
    if total <= 0 then return nil end

    local roll = ZombRand(total)
    local seen = 0
    for _, entry in ipairs(forms) do
        seen = seen + SZedPlus.Config.getFormWeight(entry[1])
        if roll < seen then return entry[1] end
    end

    -- Unreachable unless the weights changed mid-loop; take the last non-zero.
    for i = #forms, 1, -1 do
        if SZedPlus.Config.getFormWeight(forms[i][1]) > 0 then return forms[i][1] end
    end
    return nil
end

--- Paths that can currently produce a T5 at all: enabled, and with at least
--- one of their two forms above zero.
function SZedPlus.Config.getPathsThatCanFormT5()
    local able = {}
    for _, path in ipairs(SZedPlus.Config.getEnabledPaths()) do
        if SZedPlus.Config.pickFormForPath(path) ~= nil then
            able[#able + 1] = path
        end
    end
    return able
end

--- Maps each Calamity to the option that gates it.
local CALAMITY_OPTIONS = {
    host    = "CalamityHost",
    mist    = "CalamityMist",
    leader  = "CalamityLeader",
    centaur = "CalamityCentaur",
}

--- A Calamity needs both the master switch and its own switch.
function SZedPlus.Config.isCalamityEnabled(kind)
    if not SZedPlus.Config.get("CalamitiesEnabled") then return false end
    local option = CALAMITY_OPTIONS[kind]
    if not option then return false end
    return SZedPlus.Config.get(option) == true
end

--- True if any Calamity at all can spawn. Lets the promotion check bail out
--- early when the player turned the whole tier off.
function SZedPlus.Config.anyCalamityEnabled()
    if not SZedPlus.Config.get("CalamitiesEnabled") then return false end
    for kind in pairs(CALAMITY_OPTIONS) do
        if SZedPlus.Config.isCalamityEnabled(kind) then return true end
    end
    return false
end

-- -------------------------------------------------------------- hooks --

-- Read once at load, so anything running before OnGameStart still sees values.
SZedPlus.Config.refresh()

-- Sandbox options are only final once the game (or the server connection) has
-- started, so read them again then.
Events.OnGameStart.Add(SZedPlus.Config.refresh)

-- And periodically after that. A server admin can change options mid-session,
-- and the replicated values arrive without any event to tell us.
Events.EveryTenMinutes.Add(SZedPlus.Config.refresh)
