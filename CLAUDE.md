# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

ZED+ is a **published Project Zomboid mod** — Steam Workshop id `3792733238`, first released 30 Aug 2026, second
release 3 Sep 2026 (T5 forms, per-form weights, Bandits guard, Simplified Chinese).

The design bible is the **spec of record**, written in French. Read it before any implementation work: it defines
every tier, path, and creature with concrete numbers (spawn rates, tile radii, day thresholds). Its "Points ouverts"
section lists deliberately-unresolved decisions — do not silently invent values for them; either ask, or implement
behind a clearly-marked configurable constant. When a design decision changes, update the bible in the same change
as the code.

## Environment (verified on this machine)

| Thing | Path |
|---|---|
| Game install | `D:\SteamLibrary\steamapps\common\ProjectZomboid` |
| Game build | **42.20.4** |
| Vanilla Lua source (best API reference) | `<game>\media\lua\{shared,client,server}` |
| Java API (decompile for signatures) | `<game>\projectzomboid.jar` |
| Local mod install dir | `C:\Users\tsuyu\Zomboid\mods\` |
| Runtime log / Lua errors | `C:\Users\tsuyu\Zomboid\console.txt`, `C:\Users\tsuyu\Zomboid\Logs\` |

## Build, test, run

There is no build system, linter, or test runner — Project Zomboid mods are interpreted Lua loaded directly from
disk. The full loop is:

1. Place (or symlink) the mod folder into `C:\Users\tsuyu\Zomboid\mods\SZedPlus\`.
2. Launch `ProjectZomboid64ShowConsole.bat` from the game install so Lua errors surface in a console window.
3. Enable the mod in-game (Mods menu), start/load a save.
4. Read `~\Zomboid\console.txt` for `LOG : Lua` lines and stack traces — this is the only real test feedback loop.

Iterating on Lua does **not** require a game restart in every case: the in-game debug menu can reload Lua, but any
change to `Events.*` registrations or `mod.info` does need a restart. When verifying behaviour, prefer the debug
spawn tools (`<game>\media\lua\client\DebugUIs\`) over waiting for natural zombie spawns.

## Mod folder layout (Build 42)

The layout sketched in the design bible is the **Build 41** flat layout and is out of date for B42.20. B42 mods use
per-build subfolders under the mod id:

```
zed_plus/                 <- repo root maps to the mod folder
  mod.info                <- top-level, legacy/B41 discovery
  poster.png
  common/                 <- assets shared across builds
    mod.info
    media/...
  42/                     <- Build 42 content; what actually loads in 42.x
    mod.info
    media/
      lua/
        shared/           <- constants, tier tables, pure logic (loads on both sides)
        client/           <- UI, sound, visual effects
        server/           <- spawn hooks, world state, calamity registry
      scripts/            <- .txt outfit/item definitions
      sound/              <- .ogg
```

`mod.info` is flat `key=value` (`name`, `id`, `poster`, `description`) — the `id` is what the mods menu and save
files key on, so it must never change once a save exists.

## Architecture the design implies

These are the cross-cutting decisions that are not obvious from any single part of the bible:

**Spawn-time determination, not runtime scanning.** A zombie's tier and path are rolled **once**, when it first
spawns, from `GameTime.getInstance():getNightsSurvived()`. `data.SZedPlus_initialized` is the idempotency guard —
every hook must check it first, because zombie objects are re-instantiated whenever a chunk reloads. Only T4+
carries ongoing evaluation logic; T1–T3 are set-and-forget stat tweaks.

**Two persistence tiers with different lifetimes.** Per-zombie state lives in `zombie:getModData()`. It survives a
save and reload, because the chunk writes it — but **not** the player walking away. A zombie handed to the population
manager is reduced to `ZombiePopulationManager$ZombieSaveData`, whose entire contents are `descriptorID, dir, state,
x, y, z`; modData is not among them, so everything the mod wrote is discarded and what comes back is an ordinary
zombie. `SZedPlus_Persistence` exists for that: a T5 is recorded by form and position in world ModData, and the first
unclassified zombie to appear near the record claims it. Not the same object — that is impossible — but the form
returns where it was left. Note the asymmetry it creates: after a *reload* modData is intact while the engine has
rebuilt the model from the descriptor, so flags like `outfitApplied` come back set describing clothes that no longer
exist. Ask the zombie what it is wearing rather than trusting the flag. Cross-zombie state (the calamity registry,
used for the "one Calamity per 150-tile radius" exclusion) cannot live there; it lives in
`ModData.getOrCreate("SZedPlus")`, held in memory and flushed on `Events.EveryTenMinutes`. Anything that must answer
a *global* question ("is there already a Calamity near here?") belongs in the registry, not in per-zombie data.

**Refusals are permanent.** `data.SZedPlus_calamityRefused` exists so a T4 that loses the regional-exclusion roll
never retries. This keeps the T6 check O(1) amortized instead of running a radius scan on every eligible zombie
forever. Preserve that property when touching promotion logic.

**Visual identity starts at T5.** T1–T4 must remain visually identical to ordinary zombies (Volatile excepted).
Any outfit/model change below T5 is a design regression, not a feature.

**Client/server split matters even in single-player.** Sounds, UI and particle effects go in `media/lua/client`;
spawn decisions, promotion checks and the registry go in `media/lua/server`. Tier tables and shared constants go in
`shared` so both sides agree. Getting this wrong works in single-player and breaks in multiplayer.

**Several behaviours need Java-side APIs reached from Lua** and are the risky parts of the project: simulated
flight via `IsoFlagType.fence` path checks (Volatile), forced destruction of `IsoThumpable` objects along a charge
path (Centaur), `IsoSmokeEmitter` spawning (Mist), and zombie-as-projectile movement via per-tick
`setX()/setY()` (Leader). Each has a stated fallback in the bible — verify the Java signature against
`projectzomboid.jar` before building on it, since these are the calls most likely to have changed in B42.

## Naming and language conventions

**The mod id and every prefix is `SZedPlus`** — decided, not a placeholder. It is the `id=` in `mod.info`, the
modData key prefix (`SZedPlus_initialized`, `SZedPlus_stage`, `SZedPlus_path`, `SZedPlus_calamityRefused`, …), the
global store key `ModData.getOrCreate("SZedPlus")`, the Lua table/namespace prefix, the filename prefix, and the
translation-key prefix. The design documents still show `MonMod_*` — that placeholder is dead; use `SZedPlus`.
Never introduce a second prefix, and never rename these keys once a save exists: modData is a save-file schema.

**All code is English-only** — variable, function, table and file names, plus comments. The design documents are in
French and the user works in French, but nothing French belongs in the Lua source.

**No player-facing string is hardcoded.** Every displayed text goes through a translation file.

## Translations (i18n)

Minimum shipped locales: **EN, FR, ES, DE, CN**. English is the reference and the fallback. Add every new string to
all five in the same change — never English-only. Simplified Chinese was contributed by **zyyxxxxx** and is credited
in the README and the Workshop description; strings added since are mine, not theirs, and are worth having reviewed.

**Translations are JSON, one file per language folder, with no language suffix in the filename.** B42.20 dropped
the `.txt` format completely - vanilla `Translate/<LANG>/` contains only `.json`. Some installed B42 mods still ship
`IG_UI_EN.txt`; that is dead weight, the loader ignores it. Verified the hard way: sandbox options shipped as
`Sandbox_FR.txt` rendered as raw keys in game, and switching to `Sandbox.json` was the fix.

```
42/media/lua/shared/Translate/
  EN/Sandbox.json     ->  { "Sandbox_SZedPlus_Foo": "Bar" }
  EN/IG_UI.json
  FR/Sandbox.json     <- same filename; the folder carries the language
  ES/... DE/...
```

Flat `"KEY": "value"` objects, UTF-8, no BOM. The path the engine builds is
`<mod>/media/lua/shared/Translate/<LANG>/<Name>.json` - the name has no `_EN` suffix.

Key naming follows the vanilla category prefix plus the mod prefix, e.g. `IGUI_SZedPlus_WitchScream`,
`Sandbox_SZedPlus_SpawnRate`. Look up the right category prefix in the vanilla files rather than inventing one -
the game resolves keys by category, so a wrong prefix silently renders the raw key.

The four locale files are the *only* place French appears in the mod's shipped content.

## Deploying locally

`deploy.ps1` (gitignored, local only) copies `SZedPlus\` into `%USERPROFILE%\Zomboid\mods\SZedPlus\`, wiping the
destination first so renamed and deleted files do not linger. `.\deploy.ps1 -DryRun` shows what it would do. It
refuses to touch anything outside `Zomboid\mods`.

## Multiplayer (hard requirement)

The mod must work in single player, on a dedicated server, and on a co-op host. This constrains the layout:

- **Files under `server/` are loaded on multiplayer clients too.** Every file that decides world state opens with
  `if isClient() then return end` — the same guard the vanilla Lua uses. Without it, each client rolls its own
  answer and diverges from the server.
- **Zombie modData is not replicated.** `zombie:getModData()` is empty on a multiplayer client. Anything the client
  needs to render (T5 appearance, effects) must be pushed explicitly via `sendServerCommand` / `OnServerCommand`.
  The debug helpers say so and warn when called on a remote client.
- **Sandbox options are replicated**, so both sides read the same config.
- `getPlayer()` does not exist on a dedicated server — iterate over connected players.

Context helpers live in `SZedPlus_Core.lua`: `isAuthoritative()`, `isSinglePlayer()`, `isDedicatedServer()`.

## Sandbox options

All tunables come from `42/media/sandbox-options.txt`, exposed as `SandboxVars.SZedPlus.<Name>`. **Never read
`SandboxVars` directly** — go through `SZedPlus.Config.get("Name")`, which falls back to a default when an option
is missing (older save, partial server override). The `DEFAULTS` table in `SZedPlus_Config.lua` must stay in sync
with the `default =` lines in the options file.

Adding an option means touching four places: the options file, the `DEFAULTS` table, and the label plus tooltip in
all four `Translate/<LANG>/Sandbox.json` files.

`tools/i18ncheck.py` verifies that the four locales define identical keys and that every option and page has a
translation; `tools/luacheck.py` does a rough balance check on the Lua files.

## Engine gotchas (learned by breaking things)

**The engine finishes building a zombie after `OnZombieCreate` returns, and overwrites its health.** Setting stats
from that hook silently loses them - the value reads back as the engine's, not yours, with no error. Classification
still happens in the hook (writing modData is fine), but stat changes go through `SZedPlus.Behaviour.queue()`, which
applies them a couple of ticks later from `OnTick`. A queue, not a check inside `OnZombieUpdate`: that hook runs for
every zombie every tick, while the queue is empty almost always.

**Do not trust a name found by grepping strings in a `.class` file.** `setHearing` appears in `IsoZombie` and is not
a method - `hearing` is an `int` field with no setter, so per-zombie hearing cannot be changed from Lua. Calling it
threw at runtime. Verify a signature before building on it: `scratchpad/methodsig.py <file.class> <name>` parses the
constant pool and prints real method descriptors.

**A method on the base class is not necessarily callable on the instance.** Kahlua resolves against the concrete
class, so a method declared on a parent and not present on the subclass throws at the call site even though it is
plainly there in the hierarchy. `getEmitter()` on a character returns a `CharacterSoundEmitter`, which has
`playSound` but no `playSoundLooped` - that one lives on `BaseSoundEmitter` - and the looping call threw. Check the
class the object actually is, not the class that documents the method: `tools/methodsig.py` takes a `.class` file,
and the debugger's object stack names the runtime type. This is the third shape of the same trap, after `setHearing`
(a field, not a method) and `forceModelScript` (a real setter nothing reads); the common lesson is that "the name
exists somewhere" is never the question worth asking.

**Lua cannot read or write Java fields.** Only methods are exposed. `IsoZombie.hearing` and `IsoZombie.sight` are
`public int` with no setter - they are what the Hearing and Sight sandbox options drive, and they are unreachable
from Lua in both directions (verified in game: the write threw, the read returned nil). A public field is NOT a
usable API here; if there is no method, there is no access. Where perception matters, drive the outcome instead -
`setTarget()`, `addAggro()` and `clearAggroList()` are public and give exact distances rather than three levels.

**Sandbox options cannot change during a game.** There is no engine event for "the sandbox options changed", and in
single player there is no in-game editor writing back to `SandboxVars` either - so re-reading them is not enough, the
values genuinely do not move until a restart. `SZedPlus.Config.reread(name)` re-reads one option now (useful on a
server, where an admin can change them), and a periodic `refresh()` on `EveryTenMinutes` catches that case. But
anything a player expects to toggle and see immediately needs a runtime override that takes precedence over the
sandbox value - `SZedPlus.AcidRender.isOn()/toggle()` is the pattern, driven from the debug menu's Display submenu.

**Anything that must HOLD has to be re-asserted every tick, not every sweep.** The behaviour sweep runs every six
ticks, and that is far too coarse to hold a state against the AI: a sprinter crosses real ground in six frames and
the engine re-acquires its target long before the next pass clears it. This cost several rounds across three
different forms — the Stalker's freeze, the dormant Mimic's inertness, the Witch's endless pursuit — each rewritten
repeatedly when the logic was never the problem, only its cadence. The Colossus worked from the first attempt purely
because it was held from `OnTick`. `holdSteadfast()` is that per-tick pass; `holdStill` and `holdTarget` opt a form
into it. And re-assert unconditionally: "only when the target is nil" left a Witch standing still with a stale
target set.

Even per-tick, `setCanWalk(false)` plus a cleared target is not a freeze — the AI keeps its own state and walks
anyway. `changeState(ZombieIdleState.instance())` with `setStateMachineLocked(true)` is the one the AI cannot step
around; every branch that is not the freeze must unlock, or a zombie frozen as the player turns away stays locked.

**A zombie does not wear its clothes.** `getWornItems()` on an `IsoZombie` is empty - `IsoZombie` has
`isUsingWornItems()` precisely because the normal answer is no. It carries `ItemVisual`s, and real `InventoryItem`s
only materialise when the corpse is built. Every loop written against `getWornItems()` therefore ran zero times and
reported success: the Boomer's two variants looked identical, and its blast logged "0 destroyed, 0 ruined" while
leaving the suit pristine. Iterate `zombie:getItemVisuals()` instead (`setTint`, `setDirt`, `getItemType`), or use the
character-level calls below.

**Holes and blood go on the character, not on the visual.** `HumanVisual` has `getHole` but *no* `setHole` - the
setter is on `ItemVisual`, one per garment - so `zombie:getHumanVisual():setHole(part)` is a silent no-op, and
`HumanVisual:setBlood()` paints the skin, which is invisible under a hazmat suit. The working calls are
`IsoGameCharacter:addHole(BloodBodyPartType)` and `addBlood(part, true, true, false)`; they find the covering garment
themselves, carry over to the looted item, and are what vanilla's own `DamageModelDefinitions.OnHitZombie` uses.
Call them ~3x per part, as vanilla does - one call barely shows. A hole asked for outside the garment's declared
`BloodLocation` regions is dropped silently, so check the item script before picking parts.

**`OnHitZombie` passes the zombie first, not the attacker.** The signature is `(zombie, wielder, bodyPart, weapon)`.
Getting the first two the wrong way round means the guard asks `isZedPlus()` about the player, returns false, and
every hit is dropped on the first line - with no error, and no log line to show the handler ever ran. Vanilla's
handler in `media/lua/shared/Definitions/DamageModelDefinitions.lua` is the reference.

**Do not project world coordinates by hand.** Drawing a ground effect with `isoToScreenX/Y` + `getRenderer():render()`
means reproducing the engine's zoom *and* ground-depth handling; getting either slightly wrong shows up as the
texture drifting across the ground as the camera zooms, and no amount of tweaking a Z or pixel offset fixes it.
`getWorldMarkers():addGridSquareMarker(square, r, g, b, useGroundDepth, size)` is the engine doing it - placed once,
correct at every zoom.

The textured overload takes a **bare name**, and the file has to be in one exact folder.
`WorldMarkers$GridSquareMarker.init` builds its path from a string-concat recipe sitting in the class constant pool
in full - `'media/textures/highlights/.png'` - so it does
`getSharedTexture("media/textures/highlights/" .. name .. ".png")`, defaulting to `"circle_center"`. No directory and
no extension in the name, and the PNG must be in `media/textures/highlights/` (a mod's copy of that folder merges
with the game's). Both the base and the overlay name are looked up, so passing `nil` for the overlay throws too.

**Draw a ground area as one marker per tile, not one big marker.** A single large marker has to be sized in tiles from
a radius (getting the diameter conversion below right), needs artwork authored for the whole footprint, and at more
than a few tiles across is clipped at chunk boundaries - which looks like the texture cropping as the camera moves.
Per tile, all three vanish: `size = 1.0` is one tile by definition, the drawn shape *is* the damage footprint because
the same test computes both, and a one-tile quad cannot straddle a chunk. Draw each tile slightly over 1.0 (~1.4) so
neighbours overlap into one shape instead of a grid of blobs.

**A custom texture cannot be used with a grid-square marker.** Settled, do not retry without new evidence. The
textured overload of `addGridSquareMarker` resolves its name through `IsoSpriteManager.getSprite()`, which calls
`AddSprite()` on a miss - and a sprite built that way ignores its texture's alpha, so the marker draws as a solid
diamond. This was chased through the artwork first (2:1 geometry, white RGB under the transparent pixels, no
premultiplication - all matched against vanilla's own files) before the test that decided it: passing vanilla's own
`circle_orb` produced the same solid diamond. The fault was never in the file. The lesson is cheaper than the
investigation was: when something that ships with the engine works and your copy does not, run *their* asset through
*your* code path before touching yours again.

**A marker's `size` is a diameter in tiles, not a radius.** `GridSquareMarker` sets
`scaleRatio = 64 * Core.tileScale / texture.getWidth()` and draws the sprite at `width * scaleRatio * size`, which
comes to `64 * tileScale * size` - and `64 * tileScale` is exactly one tile. So `size = 1.0` spans one tile, and a
circle of radius r needs `2r`. Passing a radius straight through draws every zone at half the width it covers.

**Sandbox options cannot change during a game.** There is no engine event for "the sandbox options changed", and in
single player there is no in-game editor writing back to `SandboxVars` either - so re-reading them is not enough, the
values genuinely do not move until a restart. `SZedPlus.Config.reread(name)` re-reads one option now (useful on a
server, where an admin can change them), and a periodic `refresh()` on `EveryTenMinutes` catches that case. But
anything a player expects to toggle and see immediately needs a runtime override that takes precedence over the
sandbox value - `SZedPlus.AcidRender.isOn()/toggle()` is the pattern, driven from the debug menu's Display submenu.

**A zombie does not wear its clothes.** `getWornItems()` on an `IsoZombie` is empty - `IsoZombie` has
`isUsingWornItems()` precisely because the normal answer is no. It carries `ItemVisual`s, and real `InventoryItem`s
only materialise when the corpse is built. Every loop written against `getWornItems()` therefore ran zero times and
reported success: the Boomer's two variants looked identical, and its blast logged "0 destroyed, 0 ruined" while
leaving the suit pristine. Iterate `zombie:getItemVisuals()` instead (`setTint`, `setDirt`, `getItemType`), or use the
character-level calls below.

**Holes and blood go on the character, not on the visual.** `HumanVisual` has `getHole` but *no* `setHole` - the
setter is on `ItemVisual`, one per garment - so `zombie:getHumanVisual():setHole(part)` is a silent no-op, and
`HumanVisual:setBlood()` paints the skin, which is invisible under a hazmat suit. The working calls are
`IsoGameCharacter:addHole(BloodBodyPartType)` and `addBlood(part, true, true, false)`; they find the covering garment
themselves, carry over to the looted item, and are what vanilla's own `DamageModelDefinitions.OnHitZombie` uses.
Call them ~3x per part, as vanilla does - one call barely shows. A hole asked for outside the garment's declared
`BloodLocation` regions is dropped silently, so check the item script before picking parts.

**`OnHitZombie` passes the zombie first, not the attacker.** The signature is `(zombie, wielder, bodyPart, weapon)`.
Getting the first two the wrong way round means the guard asks `isZedPlus()` about the player, returns false, and
every hit is dropped on the first line - with no error, and no log line to show the handler ever ran. Vanilla's
handler in `media/lua/shared/Definitions/DamageModelDefinitions.lua` is the reference.

**Do not project world coordinates by hand.** Drawing a ground effect with `isoToScreenX/Y` + `getRenderer():render()`
means reproducing the engine's zoom *and* ground-depth handling; getting either slightly wrong shows up as the
texture drifting across the ground as the camera zooms, and no amount of tweaking a Z or pixel offset fixes it.
`getWorldMarkers():addGridSquareMarker(square, r, g, b, useGroundDepth, size)` is the engine doing it - placed once,
correct at every zoom.

The textured overload takes a **bare name**, and the file has to be in one exact folder.
`WorldMarkers$GridSquareMarker.init` builds its path from a string-concat recipe sitting in the class constant pool
in full - `'media/textures/highlights/.png'` - so it does
`getSharedTexture("media/textures/highlights/" .. name .. ".png")`, defaulting to `"circle_center"`. No directory and
no extension in the name, and the PNG must be in `media/textures/highlights/` (a mod's copy of that folder merges
with the game's). Both the base and the overlay name are looked up, so passing `nil` for the overlay throws too.

**Draw a ground area as one marker per tile, not one big marker.** A single large marker has to be sized in tiles from
a radius (getting the diameter conversion below right), needs artwork authored for the whole footprint, and at more
than a few tiles across is clipped at chunk boundaries - which looks like the texture cropping as the camera moves.
Per tile, all three vanish: `size = 1.0` is one tile by definition, the drawn shape *is* the damage footprint because
the same test computes both, and a one-tile quad cannot straddle a chunk. Draw each tile slightly over 1.0 (~1.4) so
neighbours overlap into one shape instead of a grid of blobs.

**A custom texture cannot be used with a grid-square marker.** Settled, do not retry without new evidence. The
textured overload of `addGridSquareMarker` resolves its name through `IsoSpriteManager.getSprite()`, which calls
`AddSprite()` on a miss - and a sprite built that way ignores its texture's alpha, so the marker draws as a solid
diamond. This was chased through the artwork first (2:1 geometry, white RGB under the transparent pixels, no
premultiplication - all matched against vanilla's own files) before the test that decided it: passing vanilla's own
`circle_orb` produced the same solid diamond. The fault was never in the file. The lesson is cheaper than the
investigation was: when something that ships with the engine works and your copy does not, run *their* asset through
*your* code path before touching yours again.

**A marker's `size` is a diameter in tiles, not a radius.** `GridSquareMarker` sets
`scaleRatio = 64 * Core.tileScale / texture.getWidth()` and draws the sprite at `width * scaleRatio * size`, which
comes to `64 * tileScale * size` - and `64 * tileScale` is exactly one tile. So `size = 1.0` spans one tile, and a
circle of radius r needs `2r`. Passing a radius straight through draws every zone at half the width it covers.

**Marker artwork is 512x256, not square.** That 2:1 ratio is the isometric footprint of a ground tile - a top-down
circle reads as an ellipse twice as wide as tall - and every vanilla marker texture has it. A square 256x256 texture
drew a square, *and* drew it at double size, because `init` derives its scale from `texture.getWidth()`. Producing one
from a top-down image is a horizontal stretch to 512x256, which is that projection.

**And it carries no colour: white RGB everywhere, shape in the alpha.** `circle_center.png` is white in 100% of its
transparent pixels, and the marker's `r,g,b` supplies the colour. Ours had black RGB under its transparent areas -
the renderer does not fully respect alpha there, so that black filled the whole quad and the pool drew as a solid
dark diamond. Beware the resize: `Image.resize()` on an RGBA image puts the black back, because Pillow premultiplies
by alpha to resample and un-premultiplies afterwards, and that division yields 0 wherever alpha lands on 0. Resize
the alpha channel alone as an `L` image and merge it onto a fresh white RGB.

Two guesses were burned here before reading that recipe, and both failed the same way: **the check did not match what
the engine does**. Handed an absolute disk path, `getSharedTexture()` returns a texture quite happily, so the name
looked valid - and the marker still threw `NullPointerException: Cannot invoke "Texture.getWidth()"` from inside
`addGridSquareMarker`, because that is not the string `init` looks up. Verify a name by performing the engine's own
lookup, not one that merely resembles it; `nameWorks()` in `SZedPlus_AcidRender` builds the same path `init` does.
Names are a flat global namespace shared with every mod, so prefix the file (`SZedPlus_AcidPool.png`).

`tools/constval.py` prints the `ConstantValue` of static final fields, which is how the perception and speed
constants were read rather than guessed (`HEARING_PINPOINT=1 NORMAL=2 POOR=3`, `SPEED_SPRINTER=1 FAST_SHAMBLER=2
SHAMBLER=3`).

**`getWalkType()` can return a bare variant number.** It comes back as `"1"`..`"5"` rather than the
family-prefixed name (`slow2`, `sprint5`) that `getSpeedTypeFromWalkType` accepts and that `WALK_SCALE` is built
from. No zombie could be placed on the scale, so **every T1-T4 speed rule silently took the "unknown walk type"
exit** - 144 times in one session. That had disabled the tier speed modifier entirely while the health modifier
beside it worked, so the tiers still felt like tiers. `IsoZombie` stores `"slow"`, `"walk"` and `"sprint"` as three
separate strings and appends the variant, so the number is a name missing its family and `getSpeedType()` is the
family. `normaliseWalkType()` rebuilds the name from those two engine-supplied values and then **checks it** against
`getSpeedTypeFromWalkType` before use; `walk4` and `walk5` do not exist and are still skipped, warned once per walk
type rather than once per zombie. Those 144 identical lines are the real lesson: a warning that repeats per-entity
turns a genuine signal into noise, and this one sat in the log unread across several playtests.

**Confirmed signatures** (B42.20): `getHealth()F` and `setHealth(F)V` on `IsoGameCharacter`; `getWalkType()` returns
a `String` and `setWalkType(String)`, `setSpeedTypeFromWalkType()`, `getSpeedType()I` on `IsoZombie`. Walk type
values, from the engine's own doc: "slow1-3 if it's a shambler, or sprint1-5 if it's a sprinter" - the ordering
within a family is inferred, not documented.

## Zombie outfits, and why a T5 renders naked (open, 3 Sep 2026)

Shipped as a known issue. Five attempts, each wrong in a new way, so this is what is **established** and what is
**ruled out** - read it before writing code, and add to it rather than re-deriving it.

**Outfit lookup is gender-split, and this part is fixed.** `HumanVisual.dressInNamedOutfit` resolves the name
through `OutfitManager.FindMaleOutfit` or `FindFemaleOutfit` according to `isFemale`, and most outfits exist in only
one of the two lists - `WeddingDress` is female-only, `ConstructionWorker` male-only, checked against
`media/clothing/clothing.xml`. Ask the wrong list and the lookup returns null, the zombie is dressed in nothing, and
**no error is raised**. `setFemaleEtc()` from `OnZombieCreate` does not survive (the engine settles gender itself
afterwards, the same reason stats are queued), so gender is re-asserted in `Appearance.apply()` immediately before
the lookup and before any clothing - `setFemaleEtc` rebuilds the model and drops what the zombie wears.

**Every check made inside `apply()` is too early, by construction.** The engine finishes building a naturally
spawned zombie after the mod has had its turn. Three proxies were fooled in a row and each looked reasonable:

- the `outfitApplied` flag, set unconditionally - nothing ever retried;
- `getItemVisuals():size() > 0` - satisfied by the Witch's *veil* alone, an item worn through the inventory and
  gender-agnostic, while the dress was missing;
- **`getOutfitName()` - returns the requested outfit on a completely naked zombie.** The name outlives the
  garments. This is the trap most likely to catch the next attempt.

**The garments are correct. This is measured, not assumed.** A verification pass 120 ticks after dressing logs
`getItemVisuals()` item types and they are complete: `Vest_HighViz` + `Hat_HardHat` + `Trousers_Denim` for the
Colossus, `Apron_Spiffos` for the Spitter, `Base.WeddingDress` with veil and jewellery for the Witch - on zombies
rendering as bare bodies. Nothing strips them either: zero "was stripped" in a full session. **Do not spend another
round on the clothing data.**

**`resetModel()` is callable and does not fix it.** It is declared in `ILuaGameCharacter` alongside
`resetModelNextFrame()`, so the call is not being swallowed by a `pcall`. Called immediately after the late
dressing, the zombie still renders naked.

**A reload fixes it, and that asymmetry is the shape of the bug.** The model is built once and the mod's clothes
arrive afterwards. Reloading rebuilds it from data that is already correct.

**The unexplored lead: the persistent outfit id.** B42 zombies carry one, and it is how an outfit persists
compactly - `ZombiePopulationManager`, `SharedDescriptors`, `VirtualZombieManager` and `IsoWorld` all go through
`zombie/PersistentOutfits`. `IsoZombie` has `getPersistentOutfitID()`, `dressInPersistentOutfit()` and
`dressInPersistentOutfitID(int)`. If the model is built from that id then writing `ItemVisuals` is writing to the
wrong place, and every correct garment list has been beside the point. It would also explain what a stale render
does not: that reloading gives a T5 **an** outfit rather than **its own**.

Measured so far: the id is present and varied on dressed T5s - `4325475`, `-2143157897`, `4390984`. Large and
signed, so packed values rather than small indices into a list.

The obstacle: **`PersistentOutfits` is not exposed to Lua.** No exposer class references it, so
`pickOutfitMale/Female(name) -> int` cannot be called and there is no documented way to get the id for a named
outfit. `getPersistentOutfitID()` and `dressInPersistentOutfitID(int)` *are* on `IsoZombie` and reachable. Two
routes worth trying, in order:

1. Learn the mapping at runtime. Ordinary zombies the engine dressed expose both `getOutfitName()` and
   `getPersistentOutfitID()`, so a name-to-id table can be built by observation and then applied with
   `dressInPersistentOutfitID`. Self-validating: check `getOutfitName()` afterwards.
2. `PersistentOutfits.ApplyOutfit(int, String, IsoGameCharacter)` is **static** - if the class turns out to be
   reachable after all, that is the direct route.

**The experiment that has not been run.** `Debug > Zed+ > Redress nearby T5 forms` redresses and rebuilds on
demand, logging `before` and `after` with the id. Clicking it next to a naked T5 separates the two remaining
possibilities in one action: if it dresses, the data was always fine and only the rebuild timing is wrong; if it
does not, `ItemVisuals` are not what the zombie is drawn from and the id is the thing to chase. **Ask for this
before writing anything.**

## Zombie scaling: investigated, not possible (B42.20)

Making a zombie physically bigger or smaller cannot be done from Lua. This was chased down properly; the notes are
here so it is not re-investigated from scratch.

**What was tried and what happened**

- `media/scripts/models.txt` declaring bodies with `scale = 3.5`. The file **loads** - `getScriptManager():
  getModelScript("Base.SZedPlusBody_F_350")` returns non-nil in game - so the format and naming are right.
- `HumanVisual.setForceModelScript(name)` + `resetModelNextFrame()`. No visible effect. Not even
  `Base.Female_Skeleton`, a vanilla model, changes the zombie.
- Searching all 23,740 classes in the jar: `forceModelScript` is referenced by **exactly one** class, `HumanVisual`
  itself, for its own setter. No rendering code reads it. It is a dead field.

**Why it cannot work**

`ModelScript.scale` is real (public float, and the parser accepts it on a model block), but the code that applies it
is `ModelInstance.applyModelScriptScale()`. A character's body `ModelInstance` is only reachable through public
fields (`hair`, `beard`, `primaryHandModel`, …), and Lua cannot read Java fields - the same wall as
`IsoZombie.hearing`. `IsoAnimal` does use per-model scale, so scaling exists in the engine, but only where the
engine itself sets it up: an animal's size comes from its species' model, not from a per-instance setter.

**A rescaled mesh would not help either.** The meshes are `media/models_X/Skinned/MaleBody.x`, DirectX `.x` in text
mode - editable, and Blender can handle them with a third-party importer. But producing the mesh is only half the
job: there is no API to assign a model to one zombie, which is precisely what the point above establishes. A custom
mesh could only be swapped in globally, resizing every zombie in the game.

**If this is revisited**, `SZedPlus.Debug.tryModel("Base.Female_Skeleton")` re-runs the decisive test in one line:
if a zombie turns into a skeleton, the engine has started honouring model overrides and the door is open again.

## Custom creatures: decided direction

**T5 forms and T6 Calamities will be custom creatures built on B42's animal system, inside this mod** - not a
separate one. Reimplementing the behaviour is accepted, and wanted: it buys full control over how a Calamity acts,
which a zombie's fixed AI would never allow. Ordinary Zed+ (T1-T4) stay real zombies.

This is what puts a T-Rex in the game in the Workshop dinosaur mod (id 3784875732, mod id `VRaptor`, installed
locally and read for reference). Its own FAQ: "this uses animals so is completely separate".

**The shape of it:**

```
// media/scripts/<Name>_Models.txt
module SZedPlus
{
    animationsMesh Leader { meshFile = SZedPlus/Leader, keepMeshAnimations = true, }
    model Leader { mesh = SZedPlus/Leader, animationsMesh = SZedPlus.Leader,
                   shader = animalEffect, static = false, scale = 1.0, }
}
```

A species is a Lua table on `AnimalDefinitions`: `model`, `minSize`/`maxSize`, `animalSize` (gameplay footprint,
0.55 raptor vs 1.8 T-Rex), `collisionSize`, `spottingDist`, plus `attackBack` / `knockdownAttack` /
`canDoLaceration` for aggression. `scale` on the model script IS honoured for animals - that mod uses values from
0.001875 to 12.5 to normalise imported meshes. `keepMeshAnimations = true` keeps animations inside the mesh, so no
PZ animset needs authoring.

Meshes will come from free 3D assets (itch.io and similar) matching the game's style. Not AI-generated: the licence
forbids it, and it is an asset either way.

**Multiplayer: learn from their mistake.** That mod warns it desyncs, and the reason is in its code -
`Dino_MP_Server.lua` broadcasts every creature's position to every player **every 50 ms**, with a sequence number
and timestamp to patch over reordering:

```lua
local DINO_ACTIVE_INTERVAL_MS = 50
args = { id, seq, stamp, x, y, z, dirX, dirY, moving, running, speed }
sendServerCommand(player, MODULE, MOVE_COMMAND, args)
```

Hand-streaming position from Lua cannot be made reliable. The rule for this mod: **never send positions**. Move
creatures with `pathToLocation()` and let the engine replicate them - animals have a `getOnlineID()`, so the network
already knows about them - and send only *decisions* (state changes, target acquired, attack started), rarely, and
idempotently. If a behaviour cannot be expressed that way, prefer a weaker behaviour to a desynced one.

Single player is the priority (multiplayer is a small share of players) but it must not be knowingly broken.

## Custom creatures: where it stalled (2026-08-29)

The plumbing works. `IsoAnimal.new()` spawns a registered species, the model
loads, the species is accepted. What does not work is the animation: the engine
throws, every frame,

```
java.lang.ArrayIndexOutOfBoundsException: Index 60 out of bounds for length 60
   at AnimationTrack.get(AnimationTrack.java:143)
   at AnimationPlayer.updateBoneAnimationTransform_Internal
```

and the mesh renders as geometry stretched to infinity.

**The key observation, and the one to start from if this is picked up again:**
the number 60 never changed. The Bellwretch skin was taken from 61 joints down
to 53, and the error still said "60 out of bounds for length 60". Whatever
sizes that track to 60, **it is not our model**. Chasing the model's structure
was therefore the wrong thread, in hindsight.

Ruled out along the way, each verified rather than assumed:

- The species definition. Cloning the deer is what the dinosaur mod does too.
- The mesh structure. Five differences against a model that imports cleanly
  (the dinosaur mod's Velociraptor) were found and fixed by `tools/fixglb.py`:
  no `skeleton` root, mesh node parented to the armature, skeleton root under an
  armature carrying a 0.2576 scale, two primitives instead of one, and eight
  trailing joints no vertex is weighted to.
- The file format. GLB and FBX fail identically.
- The deer's skeleton (29 bones) and the human body are not the source of 60.

**Where to look next**: what builds an AnimationTrack of exactly 60. Vanilla
animals declare `animationsMesh` as a *separate* file from `mesh`
(`model DeerDoe { mesh = Skinned/DeerDoe, animationsMesh = Deer_Doe }`) while
ours points `animationsMesh` at the same mesh, relying on
`keepMeshAnimations = true`. That asymmetry was not chased down and is the most
promising remaining lead.

The T5 forms are unaffected: they are zombies, and they work.

## Tier modifiers

`SZedPlus_Tiers.lua` holds the numbers, `SZedPlus_Behaviour.lua` applies them. Everything is **relative**: health
multiplies what the game rolled, and speed shifts the walk type along a scale, so the player's Toughness and Speed
sandbox settings are preserved. A T3 is a T4 with the path effect halved, via `PATH_SCALE`.

Idempotence matters because the modifiers are re-applied whenever a chunk reloads: the original health and walk type
are captured once into modData, and every modifier is computed from those, never from the current values.

## Current state

Implemented: sandbox options, config with fallbacks, the Calamity registry, the spawn roll, T1-T4 health and speed
modifiers, all seven T5 forms with their behaviours and outfits, per-form spawn weights, form persistence across
chunk unloads, the acid system, the Bandits guard, and the debug tooling (right-click > Debug > Zed+: spawn any
tier, GetStats panel, inspect, remove, redress nearby T5s).

Not implemented: the Stealth short-aggro behaviour (no way to set hearing - needs a different mechanism), the Ranged
putrefaction gas, the Volatile, every T6 Calamity, tier promotion (T4 to T5/T6), and the Thriller easter egg.

**Open bug, shipped as a known issue:** a T5 spawned naturally is drawn without its outfit until the area reloads.
See the section below before touching it - five attempts have been made and each was wrong in a new way.
