# Tactics Proto

2.5D physics-driven, turn-based **artillery tactics** prototype (Godot 4, GDScript, Jolt physics, Compatibility renderer).
Tanks, self-propelled guns and the occasional infantry squad fight on a hex board. You pick ammunition and charges,
aim with an estimating gunnery screen, wind and weight push the shell, and the blast armors-up, craters, burns and
launches things. 3D scene + orthographic camera; units are stylised glTF models (Sherman tank, self-propelled howitzer, soldier with bazooka / rifle; credits in CREDITS.md), the map uses the glTF environment packs.

## Run
Godot Project Manager -> Import -> select `project.godot` -> F5. The game opens on a **start menu**: 1 player (vs the AI) or
2 players (hot seat, a cover screen hides the board between turns), which side you take (north / south) and the tint of each side.
A victory screen (stats, rematch, main menu) closes every battle.

Controls: `1`-`9` (or click a toolbar slot) pick a tool, left click uses it, `Space` ends the turn, `Z` / `Backspace` undoes your last move (free, no limits), `X` rewinds the whole turn (free if you only moved; a shot, ram or spotter in it costs a rewind charge), `F1` opens the how-to-play pages (also on the start menu), `G` toggles the
hex grid, `V` toggles the shot camera, `P` toggles the camera pan to enemy turns (your own turn always pans), `R` restarts (same setup, new map), `WASD` pan, `Q/E` rotate camera, mouse wheel zoom.

## How a turn plays
- **Toolbar (bottom):** MMO-style hotbar: `Move`, each weapon (main gun first), `Ram`. Active slot highlighted, each
  slot shows hotkey + AP cost, unaffordable slots are red. Tank = Cannon (4 AP) + Machine Gun (2 AP); Howitzer =
  Howitzer (5 AP); Infantry = RPG (3 AP) + Rifle (1.5 AP); Ram = a straight dash priced like walking.
- **Move:** the grid is hidden by default; hover for a dotted path and `cost / AP`. Units walk to the exact clicked point;
  the grid only prices the trip: AP = sum of the terrain weights entered * `move_ap_per_weight`.
  Terrain: **road 0.5**, grass 1, rough (brown) 2, **crater** 2.5, **fire** 2, scorched 1.5; a **river** cuts the map in two: wading a river cell costs **4** (eight road hexes' worth), the stone **bridges** are the cheap way across. `G` shows the grid and reachable hexes.
- **GUNNERY weapons (cannon, howitzer, RPG):** aim the turret at the mouse (dotted bearing only) and click to open the
  **gunnery panel**:
  - *Ammo* (`T` / click): **HE** (normal), **AP** (heavy, tiny blast, penetrates armor on a direct hit), **INC**
	(incendiary), **CLU** (cluster bomblets). Each round has a *weight*: heavier = slower muzzle speed (`1/sqrt(w)`)
	but less wind drift (`1/w`).
  - *Charges* (`C` / click, 1-3): each charge level raises the maximum muzzle speed (more reach) and costs +1 AP; the
	cost is shown live. One charge is deliberately weak.
  - *Elevation* side view (drag / wheel / Up-Down) with a live **still-air estimated arc** and a metre ruler.
  - *Traverse* radar (drag / Left-Right, +/- a few degrees around your bearing): line of sight, C1/C2/C3 reach ticks and
	enemy blips. No flight path or landing mark - the guesswork is yours. Enemy distances are **measured with a standard
	deviation**: tight inside line of sight (own sight radius, friends, drone / impact areas shown as shaded discs), starting
	at 50% fidelity outside it and fading with distance (shown as `~18m (40%)` + a fuzz ring). A shell landing outside line
	of sight reveals the area around it; infantry can launch a **Drone** (tool 4, 2 AP): a visible quadcopter hovers over the spot for 2 turns, then flies off; 3-turn cooldown.
  `L` toggles the ground overlay that shows your line of sight and greys out the hazy rest of the map.
  - *Wind* box: speed, direction relative to the barrel, head/tail and cross components. Wind is not part of any estimate.
  - *Power*: hold `Space` (or press and hold on the bar), release to fire. `Esc` / right click cancels.
  Estimates use still-air physics and ignore wind, terrain and the gun's own error. The panel scales up to fit the window.
- **Shot review (`H`):** top-down map of every recorded shot with its trajectory and impact; allied shots show full data
  (setup, wind, range, results, side profile), enemy shots only the marker and path. `F` filters, Up/Down or click selects.
- **BURST weapons (MG, rifle):** aim at the mouse, click: a spread burst along the bearing.
- **Shot camera:** gunnery shots zoom in, follow the shell with a glowing parabolic trail, linger on the impact, then
  ease back (`V` toggles). Every shot is recorded in `GameState` (setup, wind, trail, impact, per-unit results).
- **Armor:** tanks and guns have front/side/rear plates (tank 12/7/3, howitzer 4/3/2). The side hit is decided by where the
  blast/shell lands relative to the hull heading. A hit whose penetration reaches the plate bypasses it (plate wears 12%);
  weaker hits are partly stopped (up to 85%, more the weaker they are) and wear the plate until it is depleted. **Burning
  halves plate strength.** Floating text reports `PEN Front -7.9` / `Front armor -2.1 (72% stopped)`.
- **Terrain effects:** blasts of radius >= 1 leave a scorch mark and turn the cells around the impact into **craters**
  (higher AP cost). **Incendiary** rounds ignite the cells instead: fire burns 3 rounds, spreads (far more likely downwind),
  burns units that start their turn in it (1 dmg, armor halved), then leaves scorched ground.
- **Props & line of sight:** the 28x22 map is dotted with trees, large rocks, small rock clusters, groves and stumps (glTF models, auto-scaled
  to the hex) plus medieval set pieces from the KayKit Hexagon Pack (a village, wall lines with towers, canopy camps, ruins, dense woods,
  pasture fences). Every prop blocks movement, stops shells and can be shot to pieces; **trees, large rocks, buildings, walls, woods and canopies also block line of sight** from ground units:
  a target behind one is only an estimate (see Spotting), the `L` overlay and the gunnery radar show the sight shadows. Drones and
  spotted areas look from above. Map data: `Game.PROPS` (`[Props.Kind, (col, row), "ModelName"]`).
- **Knockback** is deliberately mild now; units shoved off the board still die.
- **AI fairness:** the AI solves still-air shots (picking round and the cheapest sufficient charge: AP vs armor, cluster vs
  infantry), adds gunnery error, and gets hit by wind (and round weight) like the player unless `wind_awareness` > 0.

## Architecture
```
scripts/
  core/         game.gd (bootstrap), GridBoard (hex maths, terrain, craters, fire, Dijkstra, resync), Terrain,
				Props / PropView (Hexagon Pack trees, rocks, buildings... + colliders), HexTiles (road / river tile masks), BoardView (floor/obstacles/grid + live terrain patches), GuideView, TurnManager, BattleContext,
				TacticsCamera (+ shot camera), GameState / ShotRecord, ShotTrail, FloatingText
  units/        Unit (RigidBody3D, armor + burning), UnitModel (glTF hull / turret / barrel rigs from assets/Players/), UnitStats, WeaponStats, RoundStats, HitResult (Resources / data)
  combat/       Ballistics (solvers + tracer), Wind, FireParams (weapon, ammo, charge, yaw/pitch/power),
				Shell (raycast-stepped, trail), Explosion (armor, damage, craters, fire, cluster)
  actions/      Action, MoveAction, DashAction (ram), ShootAction (gunnery + burst + camera + logging)
  controllers/  UnitController, PlayerController (toolbar-driven), AIController
  ui/           Toolbar/ToolSlot/ToolEntry, GunneryPanel, WindIndicator
data/           units (tank, howitzer, infantry); data/weapons/; data/rounds/ (normal, ap, incendiary, cluster)
tests/          smoke_test.gd (headless)
```

Turn loop (`TurnManager`): burn check -> `PLAN` -> `EXECUTE` -> `SETTLE` (await bodies at rest, kill plane, `resync`) ->
repeat until AP is spent -> `END_TURN`. `round_started` drives wind drift and fire ticking.

Key ideas:
- Logic owns positions on the grid; units are frozen kinematic bodies that physics only borrows briefly.
- A shot is `FireParams` (weapon, ammo, charge, yaw, pitch, power). Muzzle speed = `muzzle_velocity * charge_scale *
  round.velocity_mult * power`; flight `p(t) = o + v t + 0.5 (g + wind * round.wind_mult) t^2`, raycast per step.
- Terrain is a first-class grid property (`GridBoard.set_terrain`) so craters/fire change pathing costs live.
- `GameState` is only a recorder: `summary()` / `summary_lines()` are meant for an end screen.

## Tuning
- Rounds (`data/rounds/*.tres`): `weight`, `damage_mult`, `radius_mult`, `penetration_mult`, `impulse_mult`,
  `direct_hit_mult`, cluster `submunitions/spread/sub_damage/sub_radius`.
- Weapons: `muzzle_velocity`, `charge_levels` (velocity fraction per charge), `charge_ap_extra`, pitch limits,
  `penetration`, blast values, `aim_error_deg`, burst values; `min_range`/`max_range` feed the AI.
- Armor: `UnitStats.armor_*`; `Unit.MAX_ABSORB`, `WEAR_ON_PEN`, `WEAR_ON_ABSORB`, `BURN_ARMOR_MULT`, arcs `FRONT_ARC_DEG` / `REAR_ARC_DEG`.
- Terrain: `Terrain.WEIGHTS`; `Explosion.CRATER_FACTOR`, `FIRE_FACTOR`, `BURN_TURNS`; `GridBoard.FIRE_DURATION`, `FIRE_SPREAD_*`.
- Wind: `Wind.MAX_SPEED`, `COUPLING`, `drift()`. Knockback: weapon `blast_impulse`, `Explosion.MASS_EXPONENT`.
- Camera: `TacticsCamera.shot_zoom`, `follow_speed`, `ShootAction.CAMERA_HOLD`. Map: `BOARD_SIZE`, `PROPS`, rough cells in `game.gd`; prop fit sizes / sight radii in `Props.INFO`.
- AI: `aim_noise_deg`, `power_noise`, `wind_awareness`.

## Tests
```
godot --headless --path . --script res://tests/smoke_test.gd          # core mechanics, exits non-zero on failure
godot --headless --path . -- --ai-vs-ai --fast --quit-on-end         # full AI vs AI battle + GameState summary
```

## Next milestones
1. End screen / replay fed by `GameState` (shot log with trails already recorded).
2. More terrain types (mud, road, water) and cover/height; burnable obstacles.
3. More firing inputs and shell types (smoke, guided, airburst cluster); per-unit memory of the last shot.
4. Collision impact damage, physics props, wrecks.
5. Smarter AI (line-of-fire search, flanking, spotting-round ranging, fire avoidance).
6. Models/sprites; `Unit._build_visuals` is the single swap point.

## Editing in VS Code
Edit scripts in VS Code, run from the Godot editor. In Godot: Editor Settings -> Text Editor -> External,
enable "Use External Editor", Exec Path = path to `Code.exe`, Exec Flags = `{project} --goto {file}:{line}:{col}`.
Install the `geequlim.godot-tools` extension for completion (it talks to the editor's language server,
so keep the Godot editor open). GDScript requires tabs for indentation (configured in `.vscode/settings.json`).
Edit `.tscn`/`.tres`/`project.godot` inside Godot, not externally, while the editor is open.
