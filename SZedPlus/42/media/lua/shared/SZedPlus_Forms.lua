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
        -- Re-asserted every tick. The sweep alone let the engine drop a distant
        -- target between passes, so she quietly gave up - the opposite of what
        -- the form promises.
        holdTarget = true,
        -- Sits until something disturbs her, which is what makes her read as
        -- scenery right up until she does not.
        sitWhileWaiting = true,
        -- Beyond this she closes the gap outright, but only while unobserved:
        -- she is never seen to appear. Driving away buys distance, not safety.
        --
        -- Well inside the loaded area, and that is the point rather than a
        -- balance choice. At 120 she was culled before she ever teleported: the
        -- engine removes zombies whose chunk unloads, and a player in a car
        -- outruns that easily. She came back as an ordinary zombie because it
        -- was a different zombie - hers had been deleted, modData and all.
        -- Closing at 40 keeps her inside the simulated region, where she still
        -- exists to do the chasing the form promises.
        teleportDist = 40,
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
        -- A connected blow puts the player on the ground. Being hit by a wall
        -- of flesh should cost more than health.
        floorOnHit = true,
        hitRange = 1.6,
        -- Long enough that a player who goes down can get back up and move,
        -- rather than being pinned by a zombie that never stops swinging.
        floorCooldownTicks = 5 * 60,
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

    -- The Stalker. Freezes the moment it is looked at, and sprints the instant
    -- it is not - the coil head rule.
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
        -- Held still every tick while watched. The sweep alone cannot hold a
        -- sprinter: it crosses ground and re-acquires its target between two
        -- passes, which is why every version of the freeze failed.
        --
        -- Its target is deliberately KEPT while frozen. Clearing it made it
        -- wander off in a straight line - a zombie with nothing to chase does
        -- not stand still, it roams.
        holdStill = true,
        holdClearsTarget = false,
    },

    -- Lies among the corpses and never gets up. Bites at ankles.
    --
    -- The knockdown is gone. It was built three ways - BumpFall by hand, then
    -- the engine's LungeState - and none held: the hand-rolled fall left the
    -- player stuck in an animation with no exit, and LungeState throws
    -- "Forward Direction cannot be zero length vector" every frame on a prone
    -- zombie, which is what froze the game on spawn. Biting ankles needs none
    -- of that machinery and is nastier to walk into.
    mimic = {
        mode = "dormant",
        -- Only at arm's length: it is scenery until stepped on.
        wakeDist = 1.5,
        -- And back to scenery as soon as the player is clear.
        sleepDist = 4,
        -- Never stands, whatever happens.
        biteIntervalTicks = 75,
        -- Reach for an ankle, a little past waking distance so backing off one
        -- step is enough to be safe.
        biteRange = 1.6,
        -- One bite in five. The rest tear rather than break the skin - still
        -- bleeding, still an infection risk, but not the death sentence.
        biteChance = 20,
        -- Held inert every tick while dormant, for the same reason. Its target
        -- does go: a corpse must not be onto anyone.
        holdStill = true,
        holdClearsTarget = true,
        -- And now and then it takes the leg out from under them.
        tripChance = 25,
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
