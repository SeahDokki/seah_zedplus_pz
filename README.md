# ZED+

**A Project Zomboid mod — Build 42**

Design Bible — special enemy system, evolution tree and behaviours.

[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20the%20mod-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/seahworld)
[![License](https://img.shields.io/badge/License-Non--Commercial%20Source--Available-8A6C1A)](LICENSE)

**[Subscribe on the Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3792733238)**

> ⚑ 3 open points still to be decided — see [Open points](#open-points).

---

## Contents

- [Lore](LORE.md)
- [Spawn mechanics](#spawn-mechanics)
- [Evolution tree](#evolution-tree)
- [T1–T2 · Reinforced Zombie](#t1t2--reinforced-zombie)
- [T3–T4 · Paths](#t3t4--paths)
- [T5 · Final forms](#t5--final-forms)
- [T6 · Calamities](#t6--calamities)
- [Easter Egg · Thriller](#easter-egg--thriller)
- [Open points](#open-points)
- [Credits](#credits)
- [License](#license)
- [Support](#support)

---

## Concept

Ordinary zombies are secretly "infected" from the moment they spawn. A Zed+ looks exactly like any other zombie until
tier 5 — the danger is that you cannot tell which one it is until it acts.

---

## Spawn mechanics

Tier and path are decided at spawn time from the current apocalypse day, rolled once, and never revisited.

| Rule | Value |
|---|---|
| **Spawn rate** | ~1 Zed+ per 400 ordinary zombies |
| **Tier thresholds** | T1–T2: day 0+ · T3–T4: day 7+ · T5: day 21+ *(all configurable)* |
| **Path** | Rolled uniformly among the paths left enabled. All four off means nothing goes past T2 |
| **T5 form** | Rolled from the two forms its path can become, by **weight**. A form at 0 never appears; a path with both forms at 0 produces a T4 instead |

### Why T5 is rolled and not evolved

The design bible specifies a T4 evolving into a T5 after four days of survival, and that cannot be built as written.
A zombie's modData does not survive the player leaving the area — the population manager discards it — so a T4's
survival clock would reset every time you walked away. [SZedPlus_Persistence](SZedPlus/42/media/lua/server/SZedPlus_Persistence.lua)
exists purely to work around that for T5, and even it can only ever match *near enough*.

Rolling at spawn is indistinguishable to the player, because nobody meets the same zombie twice. What it costs is the
evolution narrative — which was never observable. `T4SurvivalDays` is consequently unused, and kept only so a future
promotion path has the field it would want.

**T6 remains unreachable.** The Calamities are not implemented, so the zone conditions, the regional exclusion and the
pre-placed Calamities described below are design, not behaviour.

---

## Evolution tree

```mermaid
graph TD
    ZED["<b>Zed+</b><br/>T1–T2"]

    ZED --> FAST["<b>Fast</b><br/>T3–T4"]
    ZED --> TANK["<b>Tank</b><br/>T3–T4"]
    ZED --> STEALTH["<b>Stealth</b><br/>T3–T4"]
    ZED --> RANGED["<b>Ranged</b><br/>T3–T4"]

    FAST --> WITCH["Witch<br/>T5"]
    FAST --> VOLATILE["Volatile<br/>T5"]
    TANK --> COLOSSUS["Colossus<br/>T5"]
    TANK --> BOOMER["Boomer<br/>T5"]
    STEALTH --> STALKER["Stalker<br/>T5"]
    STEALTH --> MIMIC["Mimic<br/>T5"]
    RANGED --> SPITTER["Spitter<br/>T5"]
    RANGED --> SCOUT["Scout<br/>T5"]

    STEALTH -.-> HOST["The Host<br/>T6 — Calamity"]
    RANGED -.-> HOST
    FAST -.-> MIST["The Mist<br/>T6 — Calamity"]
    STEALTH -.-> MIST
    TANK -.-> LEADER["The Leader<br/>T6 — Calamity"]
    RANGED -.-> LEADER
    FAST -.-> CENTAUR["The Centaur<br/>T6 — Calamity"]
    TANK -.-> CENTAUR
```

- **Solid line** — `T4 → T5`: after 4 days of survival
- **Dashed line** — `T4 → T6`: if the zone conditions are met (skips T5 entirely)

---

## T1–T2 · Reinforced Zombie

**Day 0+**

Indistinguishable from an ordinary zombie — same appearance, same sounds, same apparent behaviour. Slightly higher
stats. The player has no way of knowing they are facing a Zed+. Custom outfits and distinctive behaviour only appear
from T5 onward.

---

## T3–T4 · Paths

**Day 7+ · Specialisations**

Differentiation is **behavioural only** — the Zed+ still looks exactly like an ordinary zombie. The path is rolled
randomly at spawn and determines which T5 forms are reachable.

| Path | Behaviour |
|---|---|
| **Fast** | Faster than normal, less resistant. *Visually identical to a normal zombie.* Only its speed gives it away. |
| **Tank** | Considerably slower, but far more resistant. *Visually identical to a normal zombie.* Hard to tell apart without attacking it. |
| **Stealth** | Dulled senses — only notices the player from a few tiles away, and forgets a target that moves away. *Normal appearance and sounds.* |
| **Ranged** | Keen senses — spots the player from far outside normal detection range and starts closing in before they know it is there. *Normal appearance.* |

---

## T5 · Final forms

**Day 21+ · Mini-bosses**

The final form is rolled randomly between the two options of the path. Behaviour is entirely distinct.

### Fast path

#### Witch — *Passive and dangerous*

| Speed | Resistance | Aggro |
|---|---|---|
| ×1.5 | Normal | Conditional |

Stays motionless, sitting or standing, until a player makes too much noise nearby, shines a light directly on her, or
gets too close. She then lets out a single scream and charges without ever disengaging.

> **Key mechanic** — Once aggroed, the pursuit is permanent: even if the player gets into a car and drives away, the
> Witch holds the chase indefinitely.

#### Volatile — *Airborne biological drone* ⚑

| Speed | Resistance | Flight |
|---|---|---|
| Fast | Low | Yes |

Moves in simulated flight, crossing fences and palisades. As soon as it spots a player it emits 2–3 alert screams to
draw in the zombies of the area, then dies naturally.

> **Key mechanic** — Flight: crosses all fences and tall fences. Does not attack — its only role is to raise the
> alarm before expiring.

> ⚑ **To be decided** — lifespan after the alert.

### Tank path

#### Colossus — *A slow wall of flesh*

| Speed | Resistance | Stagger |
|---|---|---|
| Very slow | Very high | Almost none |

Moves slowly and inexorably toward the player. Stagger barely affects it — hitting it repeatedly will not push it
back.

> **Resistances** — `×2` damage from bladed weapons · `×0.5` from blunt weapons

`Weakness: bladed ×2` · `Resistance: blunt ×0.5`

#### Boomer — *Walking bomb*

| Speed | Resistance | Threat |
|---|---|---|
| Extremely slow | High | Explosion |

Wears a hazmat suit and heads slowly toward the player once it spots them. At **2 tiles** it stops and screams, and
the blast follows **4 seconds** later — close enough that it has to reach you, so backing off in time is the answer.

**Two variants**, told apart on sight by the suit and by the oxygen bottle on its back:

| | Oxygen bottle | Suit | On detonation |
|---|---|---|---|
| **1 in 4** | Yes, intact | Pristine | Fire explosion **plus** [acid](#acid) |
| **3 in 4** | None | Already torn and holed | [Acid](#acid) only |

The torn suit is the tell: its bottle has already gone off once without killing it, so there is nothing left to
ignite. A Boomer in a clean suit is the one that still has its bottle — and the one worth shooting from a distance.

> **Shot on sight** — A bullet primes it whatever its remaining health, on a shorter **2-second** fuse. There is no
> time to walk away from a bullet's worth of warning, so shooting one at close range is the mistake, not the safe
> answer.

> **No free hazmat suit** — The blast ruins its own gear: destroyed outright 1 time in 5, shredded but lootable the
> rest of the time. Killing one is never a clean way to get a suit.

### Stealth path

#### Stalker — *Never seen moving*

| Speed | Resistance | Behaviour |
|---|---|---|
| Very fast | Normal | Freezes when watched |

Stands perfectly still for as long as the player is looking at it, and closes the distance the moment they turn
away. It is never seen moving — only closer than it was.

> **Key mechanic** — Cornered at close range it drops the act and rushes, so backing into a wall does not make it
> safe.

> Replaces the earlier *Sneaker*, which was meant to circle around behind the player. A Project Zomboid zombie with
> a target walks straight at it and overwrites any path set for it, and without a target it loses interest entirely
> — there is no "approach from that side" behaviour to borrow. Freezing works reliably, so this form interrupts the
> AI rather than fighting it.

#### Mimic — *The corpse that waits* ⚑

| Speed | Resistance | Wake trigger |
|---|---|---|
| Crawling | Normal | Search / contact |

Lies prone on the ground, indistinguishable from an ordinary corpse. Wakes up if the player walks directly over it or
tries to loot it. It knocks the player down (resisted based on fitness) and attacks their feet.

> **After waking** — Becomes a permanent crawler until it goes dormant again. Can return to its dormant state if the
> player moves far enough away.

> ⚑ **To be decided** — exact conditions for going dormant again.

### Ranged path

#### Spitter — *Acid area control*

| Speed | Resistance | Range |
|---|---|---|
| Moderate | Normal | Ranged |

Throws a single [acid](#acid) pool straight under the player's feet, from up to 10 tiles away, then waits about
6 seconds before it can spit again.

> **It plants itself to spit** — Rooted for a second and a half each time, which is the window to close the distance
> on it. Leading the target was tried and dropped: the pool landed where the player was heading rather than where
> they stood, which read as missing rather than as area control.

#### Scout — *Living alarm*

| Speed | Resistance | Alert |
|---|---|---|
| Fast | Low | Very wide |

The moment it spots a player it sprints toward them while screaming continuously. Its scream draws zombies over a
range comparable to a gunshot.

> **Ranged role** — The danger is not the Scout itself, it is the horde it summons. Killing it quietly before it
> screams is the priority.

### Acid

One shared effect, thrown by the [Spitter](#spitter--acid-area-control) and left behind by the
[Boomer](#boomer--walking-bomb). A pool sits on the ground for about **25 seconds**, then fades out.

Standing in one is what hurts — crossing it is free. The pool only bites after **half a second** of contact, so the
penalty falls on players who fail to react rather than on anyone who touches it.

Once it does bite, it works on the legs and feet only:

- **Covered skin** — the clothing takes the corrosion instead, losing condition slowly.
- **Bare skin** — burns, accumulating while the player stands in it and capped well short of fatal.
- **Waterproof footwear** — wellies, waders, hazmat boots: acid stays out entirely. Read from the item's water
  resistance rather than from a list of names, so any modded footwear that is genuinely waterproof protects too.
  Ruined boots let it through, which keeps them a consumable rather than a permanent answer.

| | Pools | Radius | Placement |
|---|---|---|---|
| **Spitter** | 1 | 1 tile | Under the player's feet |
| **Boomer** | 5 | 2.2 tiles | Scattered all around the blast |

> **Drawn by the mod, not by the game** — There is no ground-effect system to hang this on, and the engine's blood
> decals are hardcoded to a single texture that cannot be pointed elsewhere. Pools are rendered by the mod itself.

---

## T6 · Calamities

**4 Calamities · Special T4 → T6 route**

One Calamity per region (~150-tile radius). The T4→T6 transition skips T5 entirely — it is the T4's first choice, but
the conditions must be met. **A refused T4 can never try again**: it stays T4 until it dies, or evolves into a T5
after four days. Some Calamities are pre-placed at world generation near landmark buildings.

Each Calamity inherits two classes; each class appears in exactly two Calamities.

| Calamity | Classes | Reachable from |
|---|---|---|
| **The Host** | Stealth + Ranged | T4 Stealth or T4 Ranged |
| **The Mist** | Fast + Stealth | T4 Fast or T4 Stealth |
| **The Leader** | Tank + Ranged | T4 Tank or T4 Ranged |
| **The Centaur** | Fast + Tank | T4 Fast or T4 Tank |

### The Host — *Zombie factory*

`Stealth · Ranged`

| Speed | Resistance | Attack |
|---|---|---|
| Immobile | Extreme | None |

Lies on the ground, indistinguishable from an ordinary corpse. Unable to move or attack. While alive it continuously
spawns T1–T2 Zed+ whenever a player approaches or a loud noise is heard (gunfire, helicopter…). Its Stealth nature
makes it hard to spot; its Ranged nature gives it a wide spawning radius.

> **Priority** — It has to be killed to stop the flow, and it is very hard to kill without being overrun by its own
> creations.

### The Mist — *Living smoke grenade*

`Fast · Stealth`

| Speed | Resistance | Area |
|---|---|---|
| Fast | Low | Dense smoke |

Moves fast and unpredictably while continuously emitting a dense smoke cloud — the same effect as a vanilla smoke
grenade. Visibility in its wake is close to zero. Its Stealth nature makes it extremely hard to locate inside its own
smoke. It does not fight: its role is to create a blind zone for the zombies following it.

> **Implementation** — Continuously spawn `IsoSmokeEmitter` (vanilla object) at the Mist's position every tick. The
> smoke dissipates naturally after a few seconds, but the Mist keeps moving and keeps producing more.

> **Counterplay** — Kill it at range before it closes in: once you are inside its cloud, aiming at it is very hard.
> Shoot toward the sound. Its resistance is low — it dies quickly once hit.

### The Leader — *Horde commander*

`Tank · Ranged`

| Speed | Resistance | Size |
|---|---|---|
| Very slow | High | Exceptional |

A massive, slow body that ordinary zombies naturally cluster around. Once it spots a player, it grabs one of the
surrounding zombies and hurls it at high speed toward the target. The impacted zombie becomes a crawler. With no
zombies in reach, the Leader closes in and hits in melee for heavy damage.

> **Projectile implementation** — Move the thrown zombie rapidly via `setX()`/`setY()` across ticks. On impact
> (~1 tile from the player): damage plus crawler state. Worth exploring: the Java `ThrowableProjectile` for a real
> ballistic arc.

`Vulnerable without escort` · `Clear the horde first`

### The Centaur — *The unstoppable sprinter*

`Fast · Tank`

| Speed | Resistance | Stagger |
|---|---|---|
| Extreme | High | None while charging |

Sprints at extreme speed toward the player in charge cycles. During a charge no stagger can stop it — it ploughs
through the surrounding horde and destroys every breakable obstacle in its path: windows, doors, fences. Only solid
walls stop it. On impact: heavy damage and strong player knockback. After each charge it pauses briefly before going
again.

> **Destruction while charging** — Check the trajectory tile by tile via `IsoThumpable` and force-destroy every
> breakable object in the way. Solid, non-thumpable walls block and break the charge. This lets it smash into a
> lightly fortified base if the player refuses to come out.

> **Counterplay** — The pauses between charges are the only safe window to attack. Dodging sideways at the last
> moment is the core technique: the Centaur does not brake and carries far past you in the charge direction.

`Post-charge pause` · `Solid walls = hard stop` · `Breakable obstacles ignored`

---

## Easter Egg · Thriller

**Ultra-rare event**

On certain roads, a vanishingly small chance to run into something unexpected — a group of dancing zombies. Inspired
by *Armageddon Riders* and *Michael Jackson's Thriller*.

| | |
|---|---|
| **Trigger** | Ultra-rare chance when crossing a road segment. Independent of the Zed+ system. |
| **Composition** | 5 to 8 ordinary zombies in a circle · 1 central zombie in an orange outfit (dedicated outfit) |
| **Sound** | Modified "Thriller" audio loop played as a world sound (low volume, ~15-tile radius). Stops if the zombies die. |
| **Behaviour** | Zombies slowly rotating in place (cyclic `setFacing()`). They aggro normally if the player approaches — the dance stops. |
| **Sound implementation** | Custom `.ogg` file in `media/sound/`, triggered via `getSoundManager():PlayWorldSound()` |
| **Known limits** | No native "dance" animation available from Lua — simulated with rotation plus sound. The effect relies on surprise more than on visuals. |

---

## Open points

1. **Volatile** — exact lifespan after the alert, before dying naturally
2. **Mimic** — exact conditions for going dormant again (distance? timer?)
3. **Scout** — exact behaviour on contact (melee attack? or flee?)

---

## Contributing

Contributions are welcome — bug fixes, behaviour tuning, compatibility patches and translations.

- **Code is English-only.** Names and comments in English, no exceptions.
- **No hardcoded player-facing strings.** Everything goes through the translation files: EN, FR, ES, DE and CN at
  minimum, all five updated in the same change. `python tools/i18ncheck.py` verifies they stay in step.
- **All identifiers are prefixed `SZedPlus`** — mod id, modData keys, Lua namespaces, translation keys.
- **No AI-generated assets.** AI assistance on code and translations is fine; images, textures, models, sounds and
  music must be human-authored. See [LICENSE](LICENSE) §4.

By contributing you agree to the terms in [LICENSE](LICENSE) §5.

---

## Credits

**ZED+ by Seah (SeahDokki).**

| | |
|---|---|
| Simplified Chinese (`CN`) | **zyyxxxxx** |
| Lore — origin, timeline, eleven chapters, one file per tier | **zyyxxxxx** |

The translation was contributed unprompted and done properly — consistent terminology, correct full-width
punctuation, and idiom where the English is idiomatic rather than dictionary matches.

Then they wrote the mod a **whole backstory**, in three languages, without being asked: where the Knox Virus came
from, what it wants (nothing), and why every tier above the last exists because humanity put it there. It is theirs,
not mine. Summarised in [LORE.md](LORE.md).

Thank you, twice.

Translations are welcome. English is the reference; see [Contributing](#contributing) above and the layout in
[CLAUDE.md](CLAUDE.md). Anyone who sends one gets a line here and on the Workshop page.

---

## License

ZED+ is **source-available, not open source** — see [LICENSE](LICENSE) for the terms that actually apply.

**You may**, free of charge and without asking:

- play the mod, on any private or public server
- study and modify it for your own use
- contribute changes back
- build and publish compatibility or add-on mods (`ZED+ x <other mod>`)
- include it in modpacks and collections, unmodified and credited

**You may not**:

- claim authorship of the mod or republish it under another name
- sell it, or put it behind a paywall, subscription or paid tier — commercial rights are reserved to the author
- relicense it under different terms
- contribute AI-generated assets (images, sounds, models); AI-assisted *code and translations* are allowed

Credit as **ZED+ by Seah (SeahDokki)** with a link back to this repository.

For anything outside these terms, ask.

---

## Support

If you enjoy ZED+, you can support its development on Ko-fi:

**☕ [ko-fi.com/seahworld](https://ko-fi.com/seahworld)**

---

## Project documentation

| File | Contents |
|---|---|
| `README.md` | This document — the reference design bible |
| [zedplus-design-bible.md](zedplus-design-bible.md) | Condensed version plus technical notes (mod structure, persistence, modData) |
| [pz-zedplus-design.html](pz-zedplus-design.html) | Styled HTML version (source of this README) |
| [CLAUDE.md](CLAUDE.md) | Implementation reference: environment, Build 42 layout, architecture |
| [LORE.md](LORE.md) | The setting, spoiler-light — the Knox Virus and why each tier exists |
