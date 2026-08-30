--- ZED+ : T5 final form behaviours - the numbers.
---
--- Data only; SZedPlus_FormBehaviour runs it. Every value the design bible
--- states for a final form lives here, so balance can be retuned without
--- touching logic.
---
--- Loaded after SZedPlus_Core (alphabetical), before anything in server/.

SZedPlus = SZedPlus or {}
SZedPlus.Forms = {}

--- How each form behaves. Fields are read by the behaviour sweep; a form only
--- needs the ones its design calls for.
---
--- `mode`        drives which routine runs each sweep.
--- `triggerDist` tiles at which the form reacts to a player.
--- `screamRadius`/`screamVolume` feed addSound(), the same call the game uses
---               for gunshots, so the noise really does pull zombies in.
SZedPlus.Forms.BY_FORM = {

    -- Stands still until disturbed, screams once, then never lets go.
    -- The permanence is the whole point: distance does not break the chase.
    witch = {
        mode = "ambush",
        triggerDist = 8,
        screamRadius = 30,
        screamVolume = 30,
        relentless = true,
        -- Sits until something disturbs her, which is what makes her read as
        -- scenery right up until she does not.
        sitWhileWaiting = true,
        -- Beyond this she closes the gap outright, but only while unobserved:
        -- she is never seen to appear. Driving away buys distance, not safety.
        teleportDist = 120,
        -- Where she reappears, in tiles behind the player.
        teleportBehind = 15,
        -- Forced outright rather than left to the speed rule: she is the
        -- fastest thing in the game once she moves.
        forceWalkType = "sprint5",
    },

    -- Not designed yet: simulated flight has no implementation, and the design
    -- bible still lists its post-alert lifespan as an open question. Left out
    -- rather than half-built.
    volatile = nil,

    -- A wall of flesh. Stagger barely registers, so hitting it does not buy
    -- the space it usually would.
    colossus = {
        mode = "unstoppable",
        noStagger = true,
    },

    -- Closes in, stops a few tiles short, screams, then detonates.
    boomer = {
        mode = "bomb",
        -- Drops at arm's length, not across the street: it has to reach you
        -- before it goes off, or it is free to ignore.
        triggerDist = 2,
        fuseTicks = 4 * 60,     -- the design's four seconds, at 60 ticks/s
        screamRadius = 20,
        screamVolume = 20,
        -- No fire. The design calls for an acid burst, and IsoFireManager's
        -- explosion sets the ground alight, which reads as something else
        -- entirely. Damage is dealt directly instead.
        blastRadius = 4.0,
        blastDamage = 40.0,
        -- Fewer pools, but wide ones: a ring of large puddles all around it
        -- rather than a scatter of small marks.
        acidPools = 5,
        acidSpread = 2.5,
        acidRadius = 2.2,
        -- Only when it is carrying the bottle, hence the power sitting here
        -- rather than being applied unconditionally.
        explosionPower = 60,
        -- Shooting it sets it off whatever its health. The fuse is shorter:
        -- there is no time to walk away from a bullet's worth of warning.
        primeOnGunshot = true,
        shotFuseTicks = 2 * 60,
        -- How far it will follow a player at all. Without a bound it locked
        -- onto whoever was nearest on the floor, however far away.
        chaseDist = 25,
        -- What the blast does to its own gear: destroyed outright this often,
        -- ruined but present the rest of the time. Either way, no free hazmat
        -- suit for killing one.
        gearDestroyedChance = 20,
    },

    -- The Stalker. Freezes the moment it is looked at, and only moves while
    -- the player's back is turned.
    --
    -- Replaces the Sneaker, which tried to circle around behind the player and
    -- could not: a PZ zombie with a target walks straight at it and overwrites
    -- any path we set, and without a target it loses interest entirely. There
    -- is no "approach from that side" state to borrow. Freezing, on the other
    -- hand, works reliably - so this leans on interrupting the AI rather than
    -- fighting it.
    stalker = {
        mode = "stalk",
        triggerDist = 30,
        -- Half-angle of the player's vision, in degrees. 60 gives a 120-degree
        -- cone, which is roughly what a player watching their front covers.
        visionAngle = 60,
        -- Seen this close, it stops pretending and rushes: being cornered
        -- should not make it harmless.
        commitDist = 3,
        -- It only stalks. Its speed is in the moments you are not looking.
        forceWalkType = "sprint5",
    },

    -- Lies among the corpses until stepped on, then becomes a crawler.
    mimic = {
        mode = "dormant",
        wakeDist = 1.5,
        -- Goes back to playing dead once the player is well away again.
        sleepDist = 12,
        -- It stays on the floor grabbing at ankles until it actually puts the
        -- player down. Only then does it get up.
        floorRange = 2.0,
        grabIntervalTicks = 45,
        -- Bites and scratches are suppressed while it is down: it is meant to
        -- trip you, not to nibble your arm from the floor.
        grabOnly = true,
    },

    -- Throws acid at range. The pools are the threat, not the zombie.
    spitter = {
        mode = "spitter",
        triggerDist = 10,
        cooldownTicks = 6 * 60,
        -- One pool, straight under the player's feet. Leading the target meant
        -- it landed where they were going rather than where they stood, which
        -- read as missing.
        acidPools = 1,
        acidSpread = 0.3,
        acidRadius = 1.0,
        -- It plants itself to spit, which is the window to close on it.
        spitRootTicks = 90,
    },

    -- Runs at you screaming. The horde it calls is the danger.
    -- Runs at you screaming. The horde it calls is the danger, not the Scout.
    scout = {
        mode = "alarm",
        triggerDist = 25,
        forceWalkType = "sprint5",
        screamRadius = 60,
        screamVolume = 60,
        repeatTicks = 3 * 60,
        -- The scream also hands the player to every zombie in this radius,
        -- directly. Sound alone is at the mercy of walls and hearing rolls;
        -- this is the design's promise made literal.
        callRadius = 150,
        -- It calls, it does not fight: it keeps its distance rather than
        -- closing to bite.
        keepDistance = 4,
    },
}

--- The behaviour for a form, or nil when it has none yet.
function SZedPlus.Forms.get(form)
    if form == nil then return nil end
    return SZedPlus.Forms.BY_FORM[form]
end

--- True if any T5 behaviour needs to track this zombie.
function SZedPlus.Forms.needsTracking(stage, form)
    return stage == 5 and SZedPlus.Forms.get(form) ~= nil
end
