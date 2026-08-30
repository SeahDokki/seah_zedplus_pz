# ZED+ — Design Bible
**Mod Project Zomboid** · Phase de conception

---

## Concept général

Des zombies ordinaires sont secrètement "infectés" dès leur apparition. Leur stade d'évolution est déterminé une fois à spawn en fonction du nombre de jours écoulés depuis le début de l'apocalypse. À partir du T4, une évolution dynamique devient possible.

---

## Règles globales

| Paramètre | Valeur |
|---|---|
| Taux d'apparition | ~1 Zed+ sur 400 zombies |
| Stades à spawn | T1–T2 : Jour 0+ · T3–T4 : Jour 7+ |
| T4 → T5 | Survit 4 jours sans devenir Calamité |
| T4 → T6 | Aucune Calamité dans 150 tiles **ET** ≥ 25 zombies dans la zone (configurable) |
| Exclusion régionale | 1 seule Calamité par rayon de 150 tiles. Refus définitif — le T4 ne réessaie jamais. |
| Calamités pré-placées | Certaines fixées en début de partie près de bâtiments importants de la carte |
| Apparences distinctives | Uniquement T5 et T6. T1→T4 : zombie visuellement normal (sauf Volatile) |

---

## T1 – T2 · Zombie Renforcé *(Jour 0+)*

Indiscernable d'un zombie ordinaire — même apparence, mêmes sons, même comportement apparent. Stats légèrement supérieures. Le joueur ne sait pas qu'il a affaire à un Zed+.

---

## T3 – T4 · Spécialisations *(Jour 7+)*

Différenciation uniquement comportementale. Apparence identique à un zombie normal. La voie est tirée aléatoirement à spawn et détermine les formes T5 accessibles.

| Voie | Comportement T3–T4 |
|---|---|
| **Fast** | Plus rapide que la normale, moins résistant |
| **Tank** | Nettement plus lent, bien plus résistant |
| **Stealth** | Sens émoussés : n'aggro que de très près, et oublie une cible qui s'éloigne |
| **Ranged** | Sens aiguisés : repère le joueur bien au-delà de la portée normale |

---

## T5 · Formes finales *(via T4 + 4 jours survie)*

Tenue et comportement distincts. 2 options par voie, choisies aléatoirement.

### Voie Fast

**Witch**
- Vitesse ×1.5 · Résistance normale · Aggro conditionnelle
- Reste immobile jusqu'à trop de bruit, éclairage direct ou proximité excessive. Hurlement unique puis charge permanente — même en voiture, elle ne décroche jamais.

**Volatile** *(vol simulé)*
- Rapide · Résistance faible · Vol oui
- Se déplace en vol simulé, franchit clôtures et palissades (ignore `IsoFlagType.fence`). Repère le joueur → 2–3 cris d'alerte pour attirer la zone → meurt. N'attaque pas.
- ⚑ Durée de vie après alerte à définir

### Voie Tank

**Colosse**
- Très lente · Résistance très haute · Stagger quasi nul
- Avance inexorablement. Le stagger ne l'affecte presque pas.
- Faiblesse : armes tranchantes ×2 · Résistance : blunt ×0.5

**Boomer**
- Extrêmement lente · Résistance haute · Explosion
- À 4–5 tiles du joueur : s'immobilise, pousse un cri, explose 4 secondes plus tard.
- Explosion : lourds dégâts directs + projection d'acide (même effet que le Spitter).
- ⚑ Uniformiser l'effet acide avec le Spitter

### Voie Stealth

**Le Traqueur** *(remplace le Sneaker)*
- Vitesse très rapide · Résistance normale · Se fige sous le regard
- Reste parfaitement immobile tant que le joueur le regarde, et fonce dès qu'il se détourne. On ne le voit jamais bouger, seulement plus près qu'avant. Acculé à courte distance, il abandonne la ruse et charge.
- Le Sneaker d'origine devait contourner le joueur : impossible, un zombie PZ avec une cible marche droit dessus et écrase tout chemin imposé, et sans cible il se désintéresse. Immobiliser fonctionne, d'où cette forme qui interrompt l'IA au lieu de la combattre.

**Mimique**
- Vitesse rampant · Résistance normale · Réveil : fouille ou contact
- Allongé au sol, indiscernable d'un cadavre. Se réveille si le joueur passe dessus ou tente de le fouiller. Renverse le joueur (résistance selon fitness) et s'attaque aux pieds. Peut retourner à l'état dormant si le joueur s'éloigne.
- ⚑ Conditions de réendormissement à définir

### Voie Ranged

**Spitter**
- Vitesse modérée · Résistance normale · Portée distance
- Lance des flaques d'acide au sol. Délai de 0,5 seconde dans la flaque avant application des effets (corrosion équipement, brûlures sur parties non couvertes). Les flaques ont une durée de vie limitée.

**Scout**
- Rapide · Résistance faible · Alerte très large
- Dès qu'il repère un joueur, fonce vers lui en hurlant. Cri de portée comparable à un tir de feu d'arme. Danger = la horde qu'il convoque, pas lui-même.

---

## T6 · Calamités *(via T4 + conditions de zone)*

Voie spéciale directe depuis T4 — court-circuite le T5. Chaque Calamité hérite de deux classes. Chaque classe apparaît dans exactement 2 Calamités.

| Calamité | Classes | Compatible via |
|---|---|---|
| L'Hôte | Stealth + Ranged | T4 Stealth ou T4 Ranged |
| La Brume | Fast + Stealth | T4 Fast ou T4 Stealth |
| Le Leader | Tank + Ranged | T4 Tank ou T4 Ranged |
| Le Centaure | Fast + Tank | T4 Fast ou T4 Tank |

### L'Hôte *(Stealth + Ranged)*
- Immobile · Résistance extrême · Aucune attaque
- Couché au sol, indiscernable d'un cadavre. Génère continuellement des Zed+ T1–T2 lorsqu'un joueur approche ou qu'un bruit fort est perçu (tir, hélicoptère…). Il faut l'éliminer pour stopper le flux — très difficile sans se faire déborder.

### La Brume *(Fast + Stealth)*
- Vitesse rapide · Résistance faible · Fumée dense
- Se déplace rapidement et imprévisiblement en émettant en continu un nuage de fumée dense — même effet qu'un fumigène vanilla (`IsoSmokeEmitter`). Visibilité quasi nulle dans son sillage. Ne combat pas : son rôle est de créer une zone aveugle pour la horde qui suit. Résistance faible — priorité à l'élimination à distance avant qu'elle s'approche.

### Le Leader *(Tank + Ranged)*
- Très lente · Résistance haute · Taille exceptionnelle
- Masse imposante autour de laquelle les zombies s'agglutinent. Dès qu'il repère un joueur, attrape un zombie parmi ceux qui l'entourent et le projette à toute vitesse. Zombie impacté = rampant au sol. Sans zombies à portée, il avance et frappe au corps-à-corps pour des dégâts lourds.
- Implémentation : déplacement rapide du zombie via `setX()/setY()` par ticks. Piste : `ThrowableProjectile` Java pour arc visuel réel.
- Contre-jeu : éliminer la horde d'abord, Le Leader seul est beaucoup moins dangereux.

### Le Centaure *(Fast + Tank)*
- Vitesse extrême · Résistance haute · Stagger nul en charge
- Sprint à vitesse extrême en cycles de charge. Pendant la charge : inarrêtable, traverse la horde, **détruit tout obstacle cassable sur sa trajectoire** (fenêtres, portes, clôtures via `IsoThumpable`). Seuls les murs solides le stoppent net. Impact : dégâts lourds + forte projection du joueur. Pause courte entre chaque charge.
- Contre-jeu : frapper pendant les pauses. Esquiver sur le côté au dernier moment. Les murs solides peuvent couper une charge.

---

## Easter Egg · Thriller *(Ultra-rare)*

Sur certaines routes, une chance infime (≈ 1/5000 par chunk chargé) de tomber sur un groupe de zombies qui danse. Inspiré de Michael Jackson's Thriller et d'Armageddon Riders.

- 5 à 8 zombies ordinaires en cercle autour d'un zombie central en tenue orange
- Boucle audio "Thriller" modifiée jouée en son monde (rayon ~15 tiles)
- Rotation lente simulée via `setFacing()` cyclique
- Ils aggrèrent normalement si le joueur s'approche — la danse cesse
- Implémentation son : fichier `.ogg` dans `media/sound/` · `getSoundManager():PlayWorldSound()`

---

## Notes techniques clés

### Structure mod
```
SZedPlus/
  mod.info
  preview.png
  media/
    lua/
      shared/   ← logique commune client+serveur
      client/   ← UI, sons côté client
      server/   ← logique monde, spawns
    scripts/    ← définitions outfits (.txt)
    sound/      ← fichiers audio (.ogg)
```

### Persistance des données
- **Par zombie** : `zombie:getModData()` — table Lua sauvegardée avec le chunk
- **Monde** : `ModData.getOrCreate("SZedPlus")` — survit aux sauvegardes
- **Registre Calamités** : table Lua en mémoire + flush dans ModData toutes les 10 min (`Events.EveryTenMinutes`)

### Données clés par zombie T4
```lua
data.SZedPlus_initialized    -- bool : déjà traité
data.SZedPlus_isSpecial      -- bool : c'est un Zed+
data.SZedPlus_stage          -- numéro de stade
data.SZedPlus_path           -- "fast" | "tank" | "stealth" | "ranged"
data.SZedPlus_t4SpawnDay     -- jour où il a atteint T4 (pour calcul 4 jours → T5)
data.SZedPlus_calamityRefused -- bool : a déjà échoué la tentative T6
data.SZedPlus_calamityId     -- clé dans le registre si Calamité active
```

### Temps de jeu
```lua
GameTime.getInstance():getNightsSurvived()  -- jours depuis début apocalypse
```

### Vol simulé (Volatile)
Détecter `IsoFlagType.fence` sur les tiles du chemin et permettre le passage. Bloquer uniquement sur `IsoFlagType.solidfloor` / murs pleins.

### Projectile zombie (Le Leader)
Déplacement rapide tile-par-tile via `setX()/setY()` sur plusieurs ticks. À ~1 tile du joueur : dégâts + `zombie:setCrawling(true)`. Piste à explorer : `ThrowableProjectile` pour arc balistique visuel.

### Destruction en charge (Le Centaure)
Vérifier tiles sur la trajectoire via `IsoThumpable` → destruction forcée des objets cassables. Les murs non-thumpables stoppent la charge.

### Fumée (La Brume)
Spawn continu de `IsoSmokeEmitter` sur la position. Fallback : spawner des fumigènes vanilla (`SmokeGrenade`) autour d'elle si l'API Java est inaccessible depuis Lua.

---

## Points ouverts (À définir)

1. **Volatile** — durée de vie exacte après alerte avant mort naturelle
2. **Boomer / Spitter** — uniformiser l'effet acide (même implémentation)
3. **Mimique** — conditions exactes de réendormissement (distance ? timer ?)
4. **Scout** — comportement exact au contact (attaque au corps-à-corps ? ou fuit ?)
