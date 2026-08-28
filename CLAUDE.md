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
used for the "one Calamité per 150-tile radius" exclusion) cannot live there; it lives in
`ModData.getOrCreate("SZedPlus")`, held in memory and flushed on `Events.EveryTenMinutes`. Anything that must answer
a *global* question ("is there already a Calamité near here?") belongs in the registry, not in per-zombie data.

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
path (Centaure), `IsoSmokeEmitter` spawning (Brume), and zombie-as-projectile movement via per-tick
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

Build 42.20 stores translations as **JSON**, one flat `"KEY": "value"` object per file (verified against
`<game>\media\lua\shared\Translate\<LANG>\*.json`; the old B41 `.txt` + `Charset` format is gone). Mirror that
layout:

```
42/media/lua/shared/Translate/
  EN/  IG_UI_EN.json      <- UI strings
       ItemName_EN.json   <- item display names
  FR/  ...                <- same filenames, FR suffix
  ES/  ...
  DE/  ...
```

Key naming follows the vanilla category prefix plus the mod prefix, e.g. `IGUI_SZedPlus_WitchScream`,
`ItemName_SZedPlus_AcidPool`. Look up the right category prefix in the vanilla files rather than inventing one —
the game resolves keys by category, so a wrong prefix silently renders the raw key.

The four locale files are the *only* place French appears in the mod's shipped content.
