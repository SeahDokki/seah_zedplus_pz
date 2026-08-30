--- ZED+ : T5 outfits.
---
--- Data only - SZedPlus_Appearance applies it.
---
--- Two ways to dress a zombie, in order of preference:
---
--- `outfit` names one of the game's own outfits, applied with
--- dressInNamedOutfit(). This is the engine's own path - the same one it uses
--- for every zombie it spawns - so the clothing sticks and renders.
---
--- `items` lists individual clothing items, worn one by one. Used only where no
--- vanilla outfit fits. Less reliable: worn items alone did not show on the
--- model in testing, so treat this as the fallback it is.
---
--- Declaring outfits in clothing.xml is not an option: it is a single shared
--- list keyed by GUID, and a mod shipping its own would replace the game's.
---
--- One fixed outfit per form for now, no variants - a Witch always looks like
--- a Witch. Variants can be added later by turning `items` into a list of
--- lists.
---
--- Loaded after SZedPlus_Core (alphabetical), before anything in server/.

SZedPlus = SZedPlus or {}
SZedPlus.Outfits = {}

--- Body parts used when soaking a whole torso and arms.
--- Names must match the BloodBodyPartType enum.
SZedPlus.Outfits.UPPER_BODY = {
    "Torso_Upper", "Torso_Lower", "ForeArm_L", "ForeArm_R",
    "UpperArm_L", "UpperArm_R",
}

SZedPlus.Outfits.WHOLE_BODY = {
    "Head", "Neck", "Torso_Upper", "Torso_Lower", "Back", "Groin",
    "ForeArm_L", "ForeArm_R", "UpperArm_L", "UpperArm_R",
    "Hand_L", "Hand_R",
    "UpperLeg_L", "UpperLeg_R", "LowerLeg_L", "LowerLeg_R",
}

--- Per-form appearance.
---
--- `female`    true or false forces the gender, nil leaves it random.
--- `items`     worn on top of whatever the game already dressed the zombie in;
---             shoes and underwear are left alone on purpose, so they stay
---             consistent with the body the game generated.
--- `condition` 0-10 durability of the items placed above; low means visibly
---             worn and torn.
--- `blood`     { parts = {...}, amount = 0..1 }
--- `dirt`      same shape. Used on the Boomer to darken the skin, standing in
---             for the burn texture the game does not have.
--- `holes`     body parts to punch through, for genuinely ruined clothing.
SZedPlus.Outfits.BY_FORM = {

    -- Ruined white wedding dress and veil. Bloodied, not merely dirty: she is
    -- the one who screams and never lets go.
    witch = {
        female = true,
        outfit = "WeddingDress",
        items = { "Hat_WeddingVeil" },
        condition = 2,
        blood = { parts = SZedPlus.Outfits.UPPER_BODY, amount = 1.0 },
        holes = { "Torso_Lower", "UpperLeg_L" },
    },

    -- Heavy work gear. Cannot be made physically larger, so bulk is suggested
    -- by silhouette: boilersuit plus padded jacket plus hard hat.
    colossus = {
        female = false,
        outfit = "ConstructionWorker",
        items = { "Hat_HardHat_Miner" },
        condition = 6,
        dirt = { parts = SZedPlus.Outfits.UPPER_BODY, amount = 0.7 },
    },

    -- Damaged hazmat suit: whoever was handling this is who blew up.
    --
    -- The burn is a real texture now, not dirt standing in for one. It rides on
    -- the body-visual system the game uses for its own zombie wounds.
    --
    -- Damaged hazmat suit: whoever was handling this is who blew up.
    --
    -- The suit tells you which one you are facing, before you commit:
    --
    --   intact (1 in 4)  - the oxygen bottle is still on it. This one goes up
    --                      in fire as well as acid.
    --   ruined (3 in 4)  - the bottle already went off. It did not kill the
    --                      Boomer, but it holed the suit and burned the skin
    --                      underneath. Acid only.
    --
    -- No modelled bottle: a back-mounted item was tried and the hazmat suit
    -- refuses it outright ("cannot be worn with a backpack"), and the game has
    -- no oxygen tank item anyway. The suit carries the information instead,
    -- which reads at a distance and cannot conflict with anything.
    -- The oxygen bottle is not a separate item, and cannot be one: HazmatSuit
    -- is tagged base:scba and carries Tooltip_item_SCBA_NoBackpack, so the tank
    -- is already part of its model and the engine refuses anything else on the
    -- back. The bottle's presence is told by the state of the suit instead -
    -- intact and bright, or holed, darkened and bloodied.
    boomer = {
        outfit = "HazardSuit",
        items = {},
        bottleChance = 25,

        -- Intact: the bottle is still there. Clean, bright, undamaged - the
        -- hazmat yellow left alone.
        withBottle = {
            condition = 10,
            dirt = { parts = SZedPlus.Outfits.UPPER_BODY, amount = 0.1 },
        },

        -- Already blown: the bottle went off, holed the suit and burned the
        -- skin underneath.
        --
        -- Condition and holes alone were not readable at a glance - a worn suit
        -- looks much like a new one from three tiles away. The suit is darkened
        -- as well, which is visible immediately and is the actual tell.
        --
        -- The holes are spread across every region the suit can actually show
        -- one on. HazmatSuit declares
        --   BloodLocation = Trousers;Jumper;Head;Neck;Hands;Shoes
        -- and a hole asked for outside those regions is silently dropped, so
        -- the list below covers torso (Jumper), legs (Trousers), hands and
        -- head rather than picking parts at random.
        withoutBottle = {
            condition = 1,
            bodyVisual = "Base.SZedPlus_Burn",
            tintWorn = { match = "Hazmat", r = 0.42, g = 0.36, b = 0.16 },
            dirt = { parts = SZedPlus.Outfits.WHOLE_BODY, amount = 1.0 },
            blood = { parts = SZedPlus.Outfits.UPPER_BODY, amount = 0.7 },
            holes = {
                "Torso_Upper", "Torso_Lower",
                "UpperArm_L", "UpperArm_R", "ForeArm_L", "ForeArm_R",
                "UpperLeg_L", "UpperLeg_R", "LowerLeg_R",
                "Hand_R", "Neck",
            },
        },
    },

    -- Grey hoodie and denim shorts. No vanilla outfit is exactly that, but
    -- Hobbo draws from a pool containing both, so it is used as the base and
    -- the result is then forced grey.
    --
    -- `tintWorn` re-colours whatever the outfit actually put on, rather than an
    -- item we placed ourselves: the hoodie's TINT suffix means it accepts a
    -- colour, and the outfit would otherwise randomise it.
    stalker = {
        outfit = "Hobbo",
        items = {},
        tintWorn = { match = "Hoodie", r = 0.25, g = 0.25, b = 0.27 },
        condition = 3,
        dirt = { parts = SZedPlus.Outfits.UPPER_BODY, amount = 0.5 },
    },

    -- Spiffo mascot suit, wrecked.
    spitter = {
        outfit = "Cook_Spiffos",
        items = { "Hat_Spiffo" },
        condition = 2,
        dirt = { parts = SZedPlus.Outfits.UPPER_BODY, amount = 0.6 },
        holes = { "ForeArm_L", "LowerLeg_R" },
    },

    -- Park ranger.
    scout = {
        outfit = "Ranger",
        items = {},
        condition = 5,
        dirt = { parts = SZedPlus.Outfits.UPPER_BODY, amount = 0.4 },
    },

    -- mimic: deliberately absent. It has to pass for an ordinary corpse, so
    -- the game dresses it as it would any other zombie.
    -- volatile: not designed yet.
}

--- The outfit for a T5 form, or nil when that form keeps the game's clothing.
function SZedPlus.Outfits.get(form)
    if form == nil then return nil end
    return SZedPlus.Outfits.BY_FORM[form]
end
