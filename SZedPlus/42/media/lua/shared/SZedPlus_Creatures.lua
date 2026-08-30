--- ZED+ : custom creatures, registered as animal species.
---
--- A zombie cannot be resized from Lua; an animal can, because its size comes
--- from its species' model script. So the T6 Calamities - and any T5 that needs
--- to stop looking human - are declared here as species.
---
--- The definitions are not written from scratch. A species carries a long tail
--- of husbandry fields (milk, eggs, pregnancy, domestication) and missing one
--- can crash the animal UI, so an existing wild species is cloned and the parts
--- we do not want are switched off. The deer is the closest starting point:
--- wild, walks, has no products.
---
--- Registered on OnGameBoot, which is when AnimalDefinitions exists and before
--- anything can spawn.

SZedPlus = SZedPlus or {}
SZedPlus.Creatures = {}

--- Species that ZED+ adds. `type` is what addAnimal() is given.
---
--- Behaviour is deliberately minimal for now: the creature walks around and
--- does nothing else. Everything that makes a Leader a Leader comes later, in
--- its own AI - this is only the plumbing, so the model can be seen standing in
--- the world at the right size.
SZedPlus.Creatures.SPECIES = {
    {
        type = "szedplus_leader",
        breed = "default",
        model = "SZedPlus.Bellwretch",

        -- Resolved against media/textures/Body/, the same layout the reference
        -- dinosaur mod uses. The GLB embeds its textures too, but the
        -- definition wants a path of its own for the skeleton and butchering
        -- variants, and a nil there throws far from here.
        texture = "SZedPlus/Bellwretch",

        -- Our own animset, in media/AnimSets/bellwretch/. Inheriting the
        -- deer's does not work: it names deer clips (DeerStag_Idle01) that this
        -- mesh does not have, and driving a foreign skeleton with them tore the
        -- model apart on screen. Each node here points at a clip the GLB
        -- actually ships.
        animset = "bellwretch",

        -- Size is carried by the model script's `scale`, so these stay at 1:
        -- letting the animal grow would fight the value measured there.
        minSize = 1.0,
        maxSize = 1.0,

        -- Gameplay footprint, independent of the visual scale. The T-Rex in the
        -- reference dinosaur mod uses 1.8 against a raptor's 0.55.
        animalSize = 1.8,
        collisionSize = 0.6,

        minWeight = 300,
        maxWeight = 400,
    },
}

--- Species whose definition failed to build, so the debug tools can say so
--- instead of silently spawning nothing.
SZedPlus.Creatures.registered = {}

-- ------------------------------------------------------------------ clone --

local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = deepCopy(v) end
    return copy
end

--- A wild species to clone. Deer first, then anything at all rather than
--- failing outright.
local function findSourceDefinition()
    if AnimalDefinitions == nil or AnimalDefinitions.animals == nil then return nil end

    for _, name in ipairs({ "buck", "doe", "deer" }) do
        if AnimalDefinitions.animals[name] then
            return deepCopy(AnimalDefinitions.animals[name])
        end
    end

    for _, definition in pairs(AnimalDefinitions.animals) do
        return deepCopy(definition)
    end
    return nil
end

--- Turn a farm animal into something that just exists and walks.
---
--- Husbandry, breeding and fleeing are all switched off. Attacking is off too:
--- the Leader's behaviour will be written deliberately rather than inherited
--- from a startled deer.
local function stripAnimalBehaviour(definition)
    definition.wild = true
    definition.alwaysFleeHumans = false
    definition.fleeZombies = false
    definition.sitRandomly = false
    definition.eatGrass = false

    definition.canBePet = false
    definition.canBePicked = false
    definition.canBeDomesticated = false
    definition.canBeAttached = false
    definition.canBeAlerted = false

    definition.attackBack = false
    definition.attackIfStressed = false
    definition.knockdownAttack = false
    definition.attackDist = 0
    definition.attackTimer = 999999999
    definition.baseDmg = 0

    definition.mate = nil
    definition.babyType = nil
    definition.pregnantPeriod = nil
    definition.timeBeforeNextPregnancy = nil
    definition.minAgeForBaby = nil
    definition.minAge = nil
    definition.maxAgeGeriatric = nil
    definition.milkType = nil
    definition.eggType = nil
end

-- --------------------------------------------------------------- register --

--- Give the species an avatar entry, cloned from the source.
---
--- AnimalAvatarDefinition drives the portrait in the animal UI. A species
--- missing from it throws when anything tries to show it, far from here.
local function cloneAvatar(type)
    if AnimalAvatarDefinition == nil then return end
    if AnimalAvatarDefinition[type] ~= nil then return end

    for _, name in ipairs({ "buck", "doe", "deer" }) do
        if AnimalAvatarDefinition[name] then
            AnimalAvatarDefinition[type] = deepCopy(AnimalAvatarDefinition[name])
            return
        end
    end
end

local function registerSpecies(spec)
    local definition = findSourceDefinition()
    if definition == nil then
        SZedPlus.logError("no animal definition to clone - is the animal system loaded?")
        return false
    end

    stripAnimalBehaviour(definition)

    -- Every model variant has to point somewhere. The game asks for the
    -- headless and skeleton forms when butchering, and a nil there throws well
    -- away from here, so they all get the one mesh we have.
    definition.bodyModel = spec.model
    definition.bodyModelSkel = spec.model
    definition.bodyModelHeadless = spec.model
    definition.bodyModelSkelNoHead = spec.model
    definition.modelscript = spec.model

    definition.textureSkeleton = spec.texture
    definition.textureSkeletonBloody = spec.texture

    definition.animset = spec.animset
    definition.group = spec.type

    definition.minSize = spec.minSize
    definition.maxSize = spec.maxSize
    definition.animalSize = spec.animalSize
    definition.collisionSize = spec.collisionSize
    definition.minWeight = spec.minWeight
    definition.maxWeight = spec.maxWeight

    -- One stage that never grows into anything else.
    definition.stages = { [spec.type] = { ageToGrow = 999999999 } }

    -- A single breed, so the game has something to pick.
    local breed = {}
    if definition.breeds then
        for _, existing in pairs(definition.breeds) do
            breed = deepCopy(existing)
            break
        end
    end
    breed.name = spec.breed
    breed.texture = spec.texture
    breed.textureMale = spec.texture
    breed.rottenTexture = spec.texture
    definition.breeds = { [spec.breed] = breed }

    cloneAvatar(spec.type)

    AnimalDefinitions.animals[spec.type] = definition
    SZedPlus.Creatures.registered[spec.type] = true

    SZedPlus.log("registered creature '%s' using model '%s'", spec.type, spec.model)
    return true
end

local function registerAll()
    local done = 0
    for _, spec in ipairs(SZedPlus.Creatures.SPECIES) do
        if registerSpecies(spec) then done = done + 1 end
    end
    -- Always printed: if this says 0, nothing else about creatures will work,
    -- and the reason will be on the line above.
    SZedPlus.logAlways("creatures registered: %d/%d", done, #SZedPlus.Creatures.SPECIES)
end

-- PARKED (2026-08-29). Registration is disabled: the species spawns and the
-- model loads, but the engine throws ArrayIndexOutOfBoundsException in
-- AnimationTrack every frame and the mesh renders as stretched geometry. See
-- CLAUDE.md, "Custom creatures: where it stalled".
--
-- Everything below is kept and working - only the hook is off. Re-enable this
-- one line to resume.
-- Events.OnGameBoot.Add(registerAll)

--- Whether a species was registered, for the debug tools.
function SZedPlus.Creatures.isRegistered(type)
    return SZedPlus.Creatures.registered[type] == true
end
