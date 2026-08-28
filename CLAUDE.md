# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

ZED+ is a **Project Zomboid mod, currently in design phase**. The repository contains no code yet — only
[zedplus-design-bible.md](zedplus-design-bible.md), and the git repo has no commits.

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

**Two persistence tiers with different lifetimes.** Per-zombie state lives in `zombie:getModData()` and is saved
with the *chunk* — it survives unloading but is scoped to that zombie. Cross-zombie state (the calamity registry,
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

Minimum shipped locales: **EN, FR, ES, DE**. English is the reference and the fallback. Create all four folders at
once and add every new string to all four in the same change — never English-only.

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
all four `Sandbox_<LANG>.txt` files.

`scratchpad/i18ncheck.py` verifies that the four locales define identical keys and that every option and page has a
translation; `scratchpad/luacheck.py` does a rough balance check on the Lua files.

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

**Confirmed signatures** (B42.20): `getHealth()F` and `setHealth(F)V` on `IsoGameCharacter`; `getWalkType()` returns
a `String` and `setWalkType(String)`, `setSpeedTypeFromWalkType()`, `getSpeedType()I` on `IsoZombie`. Walk type
values, from the engine's own doc: "slow1-3 if it's a shambler, or sprint1-5 if it's a sprinter" - the ordering
within a family is inferred, not documented.

## Tier modifiers

`SZedPlus_Tiers.lua` holds the numbers, `SZedPlus_Behaviour.lua` applies them. Everything is **relative**: health
multiplies what the game rolled, and speed shifts the walk type along a scale, so the player's Toughness and Speed
sandbox settings are preserved. A T3 is a T4 with the path effect halved, via `PATH_SCALE`.

Idempotence matters because the modifiers are re-applied whenever a chunk reloads: the original health and walk type
are captured once into modData, and every modifier is computed from those, never from the current values.

## Current state

Implemented: sandbox options, config with fallbacks, the Calamity registry, the spawn roll, T1-T4 health and speed
modifiers, and the debug tooling (right-click > Debug > Zed+: spawn any tier, GetStats panel, inspect, remove).

Not implemented: the Stealth short-aggro behaviour (no way to set hearing - needs a different mechanism), the Ranged
putrefaction gas, every T5 form, every T6 Calamity, tier promotion (T4 to T5/T6), and the Thriller easter egg.
