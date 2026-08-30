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
