# Persistence v2 — integration trace and test plan

**Temporary working document.** Delete it together with the engine probe, before the release build.

## Trace

Integrated 6 Sep 2026 from `Assets/ZedPlus_persistence.patch`, with the untouched original beside it in
`Assets/SZedPlusPersistence/`. **Both are local only — `Assets/` is gitignored**, so this commit is the only copy of
the change that leaves this machine. Contributed by a third party through Sparty, on 6 Sep 2026 — **credit line
still owed in README.md, name unknown at integration time.**

Five files, and nothing else in the mod was touched:

| File | Change |
|---|---|
| `server/SZedPlus_Persistence.lua` | rewritten, 219 → 811 lines |
| `server/SZedPlus_Spawn.lua` | reclaim path, spec carries `formBottle`/`persistId`/`t4SpawnDay`, one probe call |
| `server/SZedPlus_Appearance.lua` | Boomer bottle no longer re-rolled on every `apply` |
| `server/SZedPlus_EngineIdentityProbe.lua` | **new, temporary** |
| `client/SZedPlus_EngineIdentityProbeMenu.lua` | **new, temporary** |

What it changes, in one line each:

- the identity ledger covers **T1-T5**, not T5 alone;
- matching uses `getSharedDescriptorID()` (64 tiles, indexed) before the 6-tile spatial fallback, which is now
  scored on persistent outfit id and sex, with a descriptor mismatch as a hard veto;
- `attachClaim` binds a record to the rebuilt zombie instead of consuming and recreating it;
- runtime descriptor/spatial indexes and an O(1) cleanup rotation replace the full-table walks;
- save schema v3, with the v0.1.0 `forms` registry migrated then deleted.

Checked at integration: `tools/luacheck.py` passes on all 22 files; every `Keys.*` the new code reads is already
defined in `SZedPlus_Core.lua`; no caller of the removed `Persistence.consume()` remains; no `os.*`, `io.*`,
`loadstring`, network call or path traversal anywhere in the five files; the probe's `OnClientCommand` handler is
gated on `Capability.UseDebugContextMenu`.

**The load-bearing assumption:** that `getSharedDescriptorID()` is stable across population-manager virtualisation.
It is not documented, the author does not claim it, and the 64-tile descriptor radius rests entirely on it. Test D
below is what decides it. Until D passes, treat the wide radius as unproven.

## Mid-save upgrade

Safe, and written for it. No modData key is renamed or introduced — `formBottle`, `persistId` and `t4SpawnDay` are
already in `SZedPlus_Core.lua` and already written by the shipped build, so the save-file schema rule in CLAUDE.md
holds. `copyLegacyEntry` maps the v0.1.0 `forms` records into the new ledger with `stage = 5` and a fresh
`lastSeenDay`, so an old T5 is not culled on the first upgrade tick. A zombie still carrying an orphaned `persistId`
has that key reused rather than duplicated, and `nextId` is pushed past it (`remember`, lines 491-501). T1-T4
already in the save enrol lazily through the `remember()` call on the already-initialized branch of
`SZedPlus_Spawn.lua`, the first time the player is near them. `Events.OnSave` now flushes the ledger, which the
shipped build did not do — a quit inside the ten-minute window used to lose records.

Two things it does **not** do:

- **It is not retroactive.** A T1-T4 that was already virtualised when the update landed lost its modData before the
  update existed; nothing can bring it back. The protection starts the next time a Zed+ is seen loaded.
- **The migration is one-way.** `store.forms` and `store.nextFormId` are deleted once copied. Rolling back to the
  Workshop build finds no legacy registry and starts empty: no crash and no corruption, but every remembered T5 is
  gone, and re-upgrading afterwards discards whatever the downgraded session recorded (`identities` wins, legacy is
  dropped again). Say so in the patch notes rather than letting a player discover it.

Watch the ledger size in the first sessions after an upgrade on a long-running save: going from T5-only to T1-T5
means it fills far faster than it ever has. That is test I.

## Setup

```powershell
.\deploy.ps1 -DryRun     # check what it would wipe
.\deploy.ps1
```

Launch `D:\SteamLibrary\steamapps\common\ProjectZomboid\ProjectZomboid64ShowConsole.bat` (build 42.20.4) so Lua
errors surface. All evidence is in `C:\Users\tsuyu\Zomboid\console.txt`.

Useful greps while testing:

```bash
grep -aE "identity persistence loaded|identity #.* restored|dropping stale Zed\+" ~/Zomboid/console.txt
grep -a "ERROR" ~/Zomboid/console.txt | grep -a SZedPlus
```

Spawn through `right-click > Debug > Zed+` rather than waiting on natural spawns. "Go away and come back" below
means far enough that the area unloads and the population manager takes the zombies — a drive, not a few tiles.

## Blocking — all of these must pass before the commit

**A. It loads at all.** Start a new save. `identity persistence loaded, 0 remembered Zed+(s)` appears once, and no
SZedPlus stack trace anywhere in the session.

**B. The old capability still works.** Spawn a T5 Witch. Note where. Go away, come back. She is still a Witch, in
roughly that place. Log shows `identity #N restored as ... via <descriptor|spatial> match`. This is the behaviour
that already shipped — a regression here is a hard stop.

**C. The new capability works.** Same, with a T2 and a T4. Before this patch they came back as ordinary zombies.
Check with `Debug > Zed+ > inspect` that stage and path are the ones you spawned, and that the T4's spawn day did
not reset.

**D. The decisive experiment.** Run the probe's own **P5 — descriptor tracking** on a group, then **P3 — fresh vs
rebuilt** and **P6 — ZED+ continuity**. What is being read out of the log: does the same zombie keep its shared
descriptor across an unload/reload cycle, and do rebuilt zombies re-enter the natural roll (**P4 — negative
reroll** answers that one). If descriptors turn out not to be stable, `DESCRIPTOR_CLAIM_RADIUS` must come down to
`CLAIM_RADIUS` before any release, and the match reason in the logs should read `spatial` almost always.

**E. Nothing is stolen.** Stand a T5 next to ordinary zombies, in a crowd. Nobody else turns into her, and she does
not lose herself, while everyone stays loaded. This is what the `active` table and the descriptor veto are for.

**F. Migration off the shipped save.** Load a save made on the current Workshop build, one that has T5 records under
the old `forms` key. Count in the log matches what was remembered. Then confirm in a fresh session that the ledger
survived and no ghost T5 reappeared at an old position — the mixed-schema case the migration is written to prevent.

**G. The Boomer bottle holds.** Spawn a Boomer, note whether it carries the bottle, reload, and check again. Repeat
across an unload/reload. Before this patch it was re-rolled on every `apply`.

## Should pass, not blocking

**H. Multiplayer.** Hard requirement per CLAUDE.md, but nothing here should be MP-specific: the ledger is
server-side and the probe menu is debug-gated. Worth one dedicated-server smoke test — join, spawn a T5, walk away,
come back — before the Workshop release rather than before the commit.

**I. Ledger growth.** T1-T5 means far more records than T5 alone. After a long session, check that the count in
`identity persistence loaded` is proportionate and that `dropping stale Zed+ identity` fires. Nothing to fix unless
it looks unbounded.

## Session log

**Session 1 — 6 Sep 2026, `Logs/2026-09-06_13-14_DebugLog.txt`. Failed, one bug, fixed.**

Settings: `SpawnRate=2`, `DayTier1/3/5/6=0`, `TierRampDays=30`, `Debug=true`. Driving. 378 Zed+ classified, well
spread (T1 63, T2 77, T3 85, T4 75, T5 78), so the spawn side of the setup was right — `TierRampDays` at its default
did not starve T5 the way it was expected to.

`next()` is **not callable in PZ's Kahlua**: `Object tried to call nil in removeBucket`, 738 failures and 3340 stack
frames, from the single occurrence at `removeBucket`. Fixed by asking `pairs` instead. It was the only distinct
error in the whole session.

The interesting part is the blast radius. `refreshActive()` is the first call in both the `EveryTenMinutes` and
`OnSave` handlers, so its throw took `dropStaleBatch`, `census` and — the one that matters — `flush()` with it.
**Nothing was ever written to the save.** 0 claims, 0 census lines, 0 identities restored: the session produced no
evidence about descriptors at all, which is why test D is still open.

Worth remembering when reading the next session: a throw in the first statement of an event handler silently
disables everything after it, and the only symptom was a log full of a message that named none of the things that
had stopped working. Resist wrapping these handlers in `pcall` — that would have hidden this instead of surfacing it.

**Session 2 — 6 Sep 2026, `Logs/2026-09-06_13-31_DebugLog.txt`. Clean run, test D answered: no.**

Teleport far, wait, teleport back to spawn. Zero Lua errors. 159 identities remembered, **599 claims**, 599
restorations, 4 censuses — the reclaim path works, which is tests B and C provisionally green.

Test D fails, and the first reading of it was wrong. The claim log initially showed 14 `STABLE` against 0 `CHANGED`,
which looks like a stable descriptor. It is an artifact of `safeSharedDescriptorId` rejecting `value <= 0`: 61% of
the ids are negative, so the filter kept ~39% of samples, and a `STABLE` verdict additionally required *both* sides
to survive that filter — self-selecting exactly the cases where the value had not changed. The filter was
manufacturing its own evidence.

Measuring the same value through the outfit accessor, which accepts negatives, gives 536 paired samples:

| | |
|---|---|
| id identical across a reconstruction | 29 (**5.4%**) |
| id different | 507 (**94.6%**) |
| `descriptorId` == `persistentOutfitId`, both present | 463 / 463 (**always**) |
| distinct id values seen | 659, for 174 identities |
| id values shared by two different identities | 43 |
| claims beyond the 6-tile spatial radius | 15 / 961 |

Identity #465 in one session: `-2143223372` → `4260018` → `-2143158018` → `-2143092281`.

So `getSharedDescriptorID()` is not an engine UUID. It returns the same number as `getPersistentOutfitID()` — the
current outfit's packed id, re-derived whenever the engine redresses the zombie — and it collides between zombies
that happen to wear the same thing. CLAUDE.md already recorded these ids as "large and signed" (`-2143157897`); the
`<= 0` guard was throwing away valid values and hiding the instability behind a plausible-looking statistic.

Acted on: `DESCRIPTOR_CLAIM_RADIUS` 64 → 6, and the descriptor-mismatch veto removed. The veto was the dangerous
half — on a 94.6% mismatch rate it would have rejected almost every legitimate reclaim, and invisibly, because a
vetoed candidate never reaches the log. The match *bonus* is kept: it is meaningless 94.6% of the time and correct
the rest. The `+8` mismatch penalty on outfit id is gone for the same reason, and because it was scoring one signal
twice.

Ledger growth over ~20 minutes at `SpawnRate=2`: 384 → 599 records, descriptor coverage 35% → 42%. Fast, but that is
the most hostile setting the option allows; test I still wants a normal-rate observation.

## Release, 6 Sep 2026

Probe removed — both files and the `noteNaturalRoll` call — before publishing. It was never used: the six P1-P6
experiments needed a zone armed by hand, while the `PROBE2` lines added straight into `SZedPlus_Persistence` measured
the same thing passively and produced all 599 samples during an ordinary drive. Those lines stay, gated on `Debug`.

Shipped with tests A-D done and **E, F, G not run**. That is a deliberate call, not an oversight: the criterion is
that a save must not be bricked, and the ledger only ever writes into the mod's own `ModData.getOrCreate("SZedPlus")`
store — the worst it can do is forget things. Test I, ledger growth, is the one that still matters under that
criterion, and default `SpawnRate=400` makes it roughly 200x slower than the session that produced 599 records in
twenty minutes.

Also shipped: the multiplayer acid fix, with no multiplayer test. It cannot be tested alone and the private server
is on default settings at day 7, so acid barely occurs there. The patch notes say so plainly and ask for reports.

## Then

Green on A-G: commit and push. Anything red: report the log lines, do not commit around it.

Still owed regardless of the result:

- the contributor's name in the README credits table;
- deletion of the two probe files and the `noteNaturalRoll` call in `SZedPlus_Spawn.lua` before the release build
  (also noted in CLAUDE.md, "Current state");
- `DESCRIPTOR_CLAIM_RADIUS` revisited if D says descriptors do not survive.
