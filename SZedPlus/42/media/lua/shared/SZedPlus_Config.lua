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

    FormWitch = true,
    FormVolatile = false,
    FormColossus = true,
    FormBoomer = true,
    FormSneaker = true,
    FormMimic = true,
    FormSpitter = true,
    FormScout = true,

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
--- Only T1-T4 are ever rolled at spawn. T5 and T6 are reached by evolving a
--- T4, so their day thresholds are checked at promotion time, not here.
function SZedPlus.Config.getStageRangeForDay(day)
    local get = SZedPlus.Config.get
    if day >= get("DayTier3") then
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

--- Maps each T5 form to the option that gates it.
local FORM_OPTIONS = {
    witch    = "FormWitch",
    volatile = "FormVolatile",
    colossus = "FormColossus",
    boomer   = "FormBoomer",
    stalker  = "FormSneaker",
    mimic    = "FormMimic",
    spitter  = "FormSpitter",
    scout    = "FormScout",
}

function SZedPlus.Config.isFormEnabled(form)
    local option = FORM_OPTIONS[form]
    if not option then return false end
    return SZedPlus.Config.get(option) == true
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
