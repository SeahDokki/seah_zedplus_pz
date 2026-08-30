# Third-party assets

Every 3D model, texture and sound in ZED+ that was not made for this project is listed here, with its author, its
source and its licence. Several of these licences require attribution; this file is how that obligation is met, and
the credits section of the README points at it.

**No asset in this mod is AI-generated.** See [LICENSE](LICENSE) §4.

---

## 3D models

### Bellwretch — Retro PSX Monster

Used for **The Leader** (T6 Calamity).

| | |
|---|---|
| **Author** | imaginais |
| **Source** | https://imaginais.itch.io/bellwretch-retro-psx-monster |
| **Licence** | *to be confirmed from the itch.io page* |
| **File** | `SZedPlus/42/media/models_X/SZedPlus/Bellwretch.fbx` |
| **Format** | FBX, 2.54 MB, rigged (61 joints) |
| **Animations** | idle, walk, run, crying attack, roar, hit reaction, death |

Used as supplied, with no modification to the mesh or its textures. Only the model script scale is set on the ZED+
side, which does not alter the file.

### Acid pool texture

Used for **the acid pools** left by the Spitter and the Boomer.

| | |
|---|---|
| **Author** | Seah (SeahDokki), recoloured from a Project Zomboid texture |
| **Source** | derived from `media/textures/BloodTextures/BloodOverlay.png` |
| **Licence** | derivative of a The Indie Stone asset - ships only inside this mod |
| **File** | `SZedPlus/42/media/textures/SZedPlus/AcidPool.png` |

The engine's own blood decals are hardcoded to `BloodOverlay.png` and cannot be
pointed at another texture, so the pools are drawn by the mod
(`SZedPlus_AcidRender.lua`) rather than handed to the renderer as decals.

### Burn overlay

Used for the **Boomer**'s scorched skin.

| | |
|---|---|
| **Author** | Seah (SeahDokki), recoloured from a Project Zomboid texture |
| **Source** | derived from `media/textures/BloodTextures/BloodOverlay.png` |
| **Licence** | derivative of a The Indie Stone asset - ships only inside this mod |
| **Files** | `SZedPlus/42/media/textures/BodyDmg/SZedPlus_Burn.png`, plus the clothing item that carries it |

Applied through the body-visual system - an invisible clothing item on the
`zeddmg` body location, the same mechanism behind the game's own `ZedDmg_*`
wounds and hair stubble. `HumanVisual.setSkinTextureName` would have been the
obvious route but no rendering code reads it.

---

## Reference files, not shipped

These live in `Assets/` for authoring and are **not** distributed with the mod:

| File | Purpose |
|---|---|
| `PZ_HumanRigV4.blend` | Project Zomboid human rig, reference for matching proportions |
| `BELLWRETCH.glb` | glTF version. Not shipped: the engine builds only 60 bones from its 61 joints and throws in AnimationTrack. The GLB declares no `skeleton` root, which is the likely cause. |

---

## Adding an asset

1. Put the source files in `Assets/` (gitignored - the repository ships only what the mod loads).
2. Copy what the game needs into `SZedPlus/42/media/`, with a filename free of spaces and non-ASCII characters.
3. Add a row here: author, URL, licence, and what it is used for.
4. If the licence requires attribution in-game as well as in the repository, say so in the row.

Prefer CC0 or CC-BY. Be careful with "free for personal use": this mod is distributed publicly, which that wording
usually excludes.

## Working files

`Assets/SZedPlus_AcidPool.png` is the authored acid splat, 512x512 top-down.
The copy shipped at `42/media/textures/highlights/SZedPlus_AcidPool.png` is that
image resized to 512x256 - the isometric footprint of a ground tile, which every
WorldMarkers texture uses. Re-edit the source, then re-project; editing the
shipped file directly means working on an already-squashed image.

Two conventions the shipped file has to keep, both matching vanilla's own marker
artwork in `media/textures/highlights/`:

- **White RGB under the transparent pixels**, not black. Black there renders as
  a solid dark quad.
- **Not premultiplied.** RGB may exceed alpha, as vanilla's does.

Resize each channel separately. Resizing an RGBA image whole makes Pillow
premultiply to resample and un-premultiply afterwards, which puts black back
wherever alpha lands on 0.
