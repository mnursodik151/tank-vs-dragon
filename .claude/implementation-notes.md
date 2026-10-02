# Tactics Proto – Implementation Notes

Godot 4.7.2, GDScript, Jolt physics, GL Compatibility. Git repo (origin https://github.com/mnursodik151/tank-vs-dragon.git). Window 1280x720.
Godot binary (console build): `D:\Projects\godot-windows-64-stable\Godot_v4.7.2-stable_win64_console.exe`
(run `--headless --path . --import --quit` once after adding a `class_name` script so the class cache updates).
Shell note: Git-bash here has Python 2 (`python`) and no `python3` - use the Edit tool / sed / awk for edits.
Avoid `%g` in GDScript format strings (unsupported). Avoid naming variables `round` (shadows the built-in).
**Assets**: every third-party asset lives under `res://assets/` (Animations, FBX, "FBX (Unity)", "Hexagon Pack", OBJ, Players, Textures, UI, glTF, previews)
and the whole folder is gitignored (`/assets/`); `CREDITS.md` has sources and licences. Keep new assets there. After moving assets, fix the `source_file`
paths inside the `.import` files and re-run `--import` (the editor must be closed). Unused FBX/OBJ exports log harmless `C:/` texture warnings on import.

## Detail docs (code-level snapshots, Rev 7; Rev 9 pack passes noted in gamestate-and-scene-manager.md)
- [gamestate-and-scene-manager.md](gamestate-and-scene-manager.md) - Game bootstrap, BattleContext, TurnManager loop, GameState/ShotRecord, SceneComposer, Atmosphere.
- [actor-controls-and-actions.md](actor-controls-and-actions.md) - Unit, Action classes, PlayerController, AIController, FireParams.
- [ui-ux.md](ui-ux.md) - HUD, toolbar, gunnery panel, shot review, world overlays, camera, controls, UX gaps.
Keep these in sync when the matching code changes; this file stays the history + design-intent log.

## Goal / direction (from the user)
Physics-based tactical RPG that emulates **artillery warfare** ("a 2.5D Worms"): tanks and other artillery machines,
occasionally infantry. The main-gun shot is the core turn mechanic and where physics comes in.
- Rev 2: hex grid; grid invisible (toggle); AP from weighted traversed cells; main-gun action.
- Rev 3: weapon toolbar (Ram stays), aux weapon (MG), different AP per weapon, no explicit trajectory guidance (angle+power
  panel with depth/traverse), wind, AI must not be perfect (wind outside its calculations).
- Rev 4: round types (normal/AP/incendiary/cluster) changeable in the gunnery screen with weights affecting gunnery physics;
  incendiary spreads and changes terrain; shot camera + parabolic trail recorded in a game-state manager (for a future end
  screen); armor by hull side that depletes/is bypassed (AP penetrates, incendiary softens); bigger map; charges (1-3, +AP
  each, weaker base power); reduced knockback, craters raise AP cost. Follow-up: the panel's shot ESTIMATION must be more
  noticeable, wind inside the panel, radar shows line of sight + estimated trajectory updating with charges/angle.

## History
- Rev 1: square grid, capsule units. Rev 2: hex, gridless movement, FireSolution preview. Rev 3: toolbar, gunnery panel,
  burst weapons, wind, AI noise. FireSolution/FireMinigame removed.
- Rev 4 (this): everything in the Rev 4 list above. The panel now has estimates (arc + radar path); the world still shows
  no trajectory (only a short bearing line).

- Rev 5: gunnery UI pass. Panel scaled up to fit the viewport; estimates are STILL AIR ONLY (no wind anywhere in them, wind box
  is raw info); radar back to basics (rings, fan, C1/C2/C3 reach ticks, line of sight, blips) - no flight path/landing mark/
  aim ring/power band, to keep the guesswork. Enemy distances are MEASURED with a standard deviation (see Spotting). Added a
  shot-review overlay (H) and an infantry drone action.

- Rev 6: environment props from the glTF asset pack (trees, large rocks, small rocks, bushes), map grown to 22x18, and REAL
  line-of-sight occlusion (trees + large rocks hide things from ground units' sight). See "Props and line of sight".

- Rev 7: lighting/sky pass + SceneComposer (random foliage per game). See the next two sections.

## Lighting (Rev 7, `scripts/core/atmosphere.gd`)
`Atmosphere.build(host)` (called by `Game._build_environment`) adds the WorldEnvironment (ProceduralSky, ambient + reflections from the
sky, filmic tonemap) and the warm sun. Camera is ortho at 45 deg, so the sky is mostly a hazy backdrop beyond the board edge.
Shadow fix: the sun uses `SHADOW_ORTHOGONAL` (one split, `directional_shadow_max_distance` 90) - the default 4-split PSSM put almost
the whole ortho view in a coarse far split, so foliage shadows were faint/blobby at normal zoom. Plus bias/blur tuning and project
settings (`[rendering]`: shadow atlas 4096, soft shadow filter quality 3, MSAA 4x). Leaf materials are glTF alpha-MASK (scissor), which
shadows honour. **Foliage shading**: `PropView._apply_foliage_shading` swaps every leaf/flower surface material (names Leaves*/Leaf*/Flowers)
for `shaders/foliage.gdshader` - sun-lit with a custom `light()` that ignores ATTENUATION, so leaves NEVER receive shadows (leaf cards
shadowing each other gave random dark patches on bushes and red TwistedTree canopies), normals pulled 55% towards up, wrap lighting.
Leaves still cast ground shadows. Compat note: `LIGHT_COLOR` already carries the light energy, do not divide by PI. Trade-off accepted
by the user: foliage ignores shadows (less dynamic lighting) for a uniform look. Don't put `normal_bias` below ~1 (striped acne). Time-of-day/weather variants would be extra parameters of `build` (composer could choose them).

## Scene composer (Rev 7, `scene_composer.gd` + `scene_layout.gd`)
`SceneComposer.compose(seed) -> SceneLayout` (plain data: `seed`, `props` = `[Props.Kind, Vector2i offset cell, model]`, `rough` cells).
`Game._compose_scene` runs it at every start (so `R` restart = a new map) with the spawn cells as `reserved` (radius 2 kept clear) and
prints `Scene seed N: ...` in --ai-vs-ai. HUD shows the seed; `--seed=N` (or `Game.forced_seed`) replays a map.
Passes (each a `_place_*` method over shared `_taken` cells): rough patches, tree copses (one species family each, 15% strangers),
loner trees, large rocks, small rock clusters, bushes (60% hug a tree/rock). Margin 1 from the board edge. Afterwards `_is_connected`
(GridBoard.find_path between all reserved cells); failing seeds are retried with derived seeds. Density knobs are vars on the composer.
To add spawn points/objectives: new pass + new SceneLayout field + Game consumes it (the spawn table in game.gd is still hard-coded).
`Game.extra_keep_clear` lets a test keep cells prop-free; the smoke test pins seed 7, keeps its firing lane / (21,7) / the scout->tank
sight line clear. The old hand-placed `Game.PROPS` / `ROUGH_CELLS` tables are gone.

## Props and line of sight (Rev 6)
- Assets: `glTF/*.gltf` (also FBX/OBJ copies; only glTF is used). Model names are the file stems; `Props` (`scripts/core/props.gd`) is
  the catalogue: `Kind {TREE, ROCK_LARGE, ROCK_SMALL, BUSH}` -> model list, `los_radius` (0 = see-through), fit box (height/width the
  model is scaled into, hex circumradius is 1 m), shot-review colour. Trees: CommonTree/Pine/TwistedTree/DeadTree 1-5, large rocks:
  Rock_Medium_1-3, small rocks: Pebble_Round_1-5 / Pebble_Square_1-6 (cluster of 3 per cell), bushes: Bush_Common(_Flowers).
  Note `Bush_Common` uses the red TwistedTree leaf texture (autumn look); `Bush_Common_Flowers` is green.
- Map data = `SceneLayout.props` (was `Game.PROPS`, now composed per game): `[Props.Kind.X, Vector2i(col,row), "ModelStem"]` (offset coords). `GridBoard.add_prop` makes the cell
  blocked (movement) and registers it; `prop_at/prop_model/prop_cells`. ALL four kinds block movement; only TREE (r 0.7) and
  ROCK_LARGE (r 0.9) block sight. To make bushes/small rocks passable instead, use terrain weights rather than `add_prop`.
- `PropView` (child "Props" of `BoardView`): one StaticBody3D per prop named `<Kind>_<Model>_c<col>r<row>` (e.g. `Tree_Pine_2_c3r6`),
  layer TERRAIN (so shells, explosions and knocked units all collide with it). Trees = trunk cylinder, bushes = cylinder, rocks =
  convex hull of the mesh. Yaw/size jitter seeded by the cell (stable between runs). Models are auto-scaled from their AABB.
- Line of sight: `GridBoard.los_occluders()` = (x, z, radius) discs; `los_blocked(a, b)` = segment-vs-disc (an occluder holding either end
  is ignored: you can see the tree you look at); `los_shadows(from, reach)` = quads behind each occluder (used by the radar).
  `Intel.board` (set via `BattleContext.board` setter): for a GROUND source (`s["unit"] != null`) a point inside the radius but behind
  an occluder gets `EDGE_FIDELITY` (not LoS). Drones / spotted areas look from above and are never blocked, so a shell landing behind
  a tree opens a spotted area. `Intel.reading` follows automatically (estimate + sigma instead of a tight reading).
- Views: `SightView` shader gets `occ[64]` (+`occ_count`) and src.w = 1 for ground units: fragments inside the radius but behind an
  occluder are hazy (shadow wedges). `MAX_OCCLUDERS` 64 (warns beyond). Gunnery radar: sight circles minus `los_shadows` (Geometry2D
  clip), props drawn as small grey discs. Shot review colours prop cells by kind.
- Map 22x18 (`Game.BOARD_SIZE`), spawns T0 (6,3) H0 (11,1) I0 (14,4) / T1 (15,14) H1 (10,16) I1 (6,14); camera `start_size` 32 / `max_size` 60.
  The smoke test keeps rows 1-3, cols 0-8 and (21,7) free via `Game.extra_keep_clear` (the composer is random).
- The AI ignores LoS and props except physically (its shells can hit them).
- Gotcha: assets import with "Case mismatch ... res://textures vs Textures" warnings (Windows only; would break on case-sensitive export).

## Camera: turn-start pan (Rev 6)
`TacticsCamera.focus_on(point)` glides to a point keeping the zoom (it reuses Mode.RETURN with the saved view = target; during a shot
sequence only the view it returns to changes; wheel zoom mid-glide changes the saved zoom). `Game._on_turn_started` (TurnManager.turn_started):
the player's team (0, unless `--ai-vs-ai`) ALWAYS pans; enemy turns pan only while `Game.enemy_turn_pan` (key `P`, HUD line shows it, default on).
HUD also shows `Shot cam: on/OFF` (`V`). The shot follow cam itself was re-verified (14/14 shots followed in an AI-vs-AI window run).
Test gotcha: changing `cam.size` while a glide is running gets overridden (the real game starts one on turn 1) - wait for `Mode.IDLE` first.

## Spotting (Rev 5, `scripts/combat/intel.gd`, `ctx.intel`)
Rev 5 text: "fog of war in spirit only" - since Rev 14 enemies outside sight ARE hidden and since Rev 17 sight has an inner (measured) and an outer (estimated) ring (see Rev 17); fidelity sets how well a SEEN target's distance is measured.
**A literal fog of war is planned for when the map gets bigger: `Intel.fidelity_at(team, units, point)` is the query to reuse.**
- Sources: every living unit's `UnitStats.sight_range` (Rev 17b: tank 9.6, howitzer 7.2, infantry 12.8 m; was 12 / 9 / 16) + temporary spotted areas.
- Inside any source = LoS fidelity 0.92. Outside = 0.50 at the edge, fading linearly to 0.10 over 1x the source radius.
- Reading = true + z*sigma, sigma = dist * lerp(0.30, 0.02, fidelity). z is gaussian, cached per target until the next
  `begin_turn` (no re-opening the panel to average the noise; shrinks smoothly as fidelity improves).
- Expansion: shell hitting outside LoS -> 6 m area for 2 rounds (`ShootAction._on_impact`, "SPOTTED"); `DroneAction` (infantry,
  `drone_range` 22 m, 2 AP, 7 m radius; stays on station 2 turns (launch turn + next), then flies off; the launcher gets
  `Unit.drone_cooldown` = 3 and can relaunch on its 3rd turn after (toolbar shows "CD n"). Physical marker = `Drone` node
  (quadcopter hovering 3.2 m up, beam + ring on the ground), stored in the area record and told to `depart()` by `Intel.tick`);
  friendly units' own sight. `TurnManager` calls `intel.tick` per round and
  `intel.begin_turn` per turn. **Rev 14: enemies outside sight are now hidden for real (screen and AI), see the Rev 14 section.**
- World overlay (`SightView`, `L` toggles, default on): hex-shaped ground overlay + shader; inside any friendly source clear with a
  mint edge, outside greyed (hazier further out). Fed by `ctx.intel.sources(0, units)` every frame (max 24 sources).
- Panel: foes drawn at the measured distance along the true bearing; outside LoS label "~18m (40%)" + fuzz ring; shaded discs
  show sight sources. C1-C3 reach ticks are exact still-air numbers (they follow elevation/round, not the target).

## Shot review (Rev 5, `scripts/ui/shot_review.gd`)
`H` toggles a full-screen top-down map (fixed orientation) listing every `GameState.shots` record: marker, trajectory (trail), list
with filter (F: all/allies/enemies), click/Up/Down select. Allied shots show full metadata + per-unit results + side profile;
enemy shots show only marker + trajectory. Swallows all input while open; `can_open` blocks it during the gunnery panel.

## Layout
```
project.godot            main scene res://scenes/start_menu.tscn
scenes/start_menu.tscn   project main scene: Control + start_menu.gd (Rev 16), loads main.tscn
scenes/main.tscn         single Node3D "Main" + game.gd. EVERYTHING else is built in code.
shaders/                 foliage.gdshader (leaf shading, see Lighting)
data/                    tank.tres, howitzer.tres, infantry.tres (UnitStats incl. armor + weapons array)
data/weapons/            tank_cannon, howitzer, rpg (GUNNERY) ; machine_gun, rifle (BURST)
data/rounds/             normal, ap, incendiary, cluster (RoundStats)
data/fantasy/            mage, octo_cannon, ranger (UnitStats); weapons/ staff, arcane_bolts, octo_cannon, longbow, quick_shot; rounds/ fireball, meteor, ballista, hail, arrow
scripts/core/            game, battle_config, factions, atmosphere, scene_composer, scene_layout, sight_view, battle_context, grid_board, terrain, props, prop_view, board_view, guide_view, turn_manager, tactics_camera,
                         game_state, shot_record, shot_trail, floating_text
scripts/units/           unit, unit_stats, weapon_stats, round_stats, hit_result, unit_model, soldier_rig, hero_rig
scripts/combat/          ballistics, wind, fire_params, shell, explosion, intel, drone, eagle, meteor
scripts/actions/         action, move_action, push_action, shoot_action, drone_action
scripts/controllers/     unit_controller, player_controller, ai_controller, hot_seat_controller
scripts/ui/              tool_entry, tool_slot, toolbar, gunnery_panel, wind_indicator, shot_review, start_menu, handoff_screen, victory_screen
tests/smoke_test.gd      headless checks (see Verification)
tests/fantasy_test.gd    headless checks of the fantasy faction (Rev 18)
```
GDScript uses tabs. `.uid` files are generated by the editor/import.

## Core concepts
- **Hex grid**: axial `Vector2i(q, r)`, pointy-top, hex_size 1.0 m, odd-r rectangle (now **22x18**). game.gd uses offset
  coords via `GridBoard.offset_to_axial`. Grid = pricing layer only; units stand where their body is.
- **Terrain** (`Terrain.Type`: GRASS 1, ROUGH 2, CRATER 2.5, FIRE 2, SCORCH 1.5): `GridBoard.set_terrain` (obstacles are
  never changed, emits `terrain_changed`), `crater_area`, `ignite_area`, `tick_fires(wind_push, rng)` (burn 3 rounds ->
  SCORCH, spread chance 0.10 + 0.55 * downwind alignment, only while >= 2 rounds left). `BoardView` keeps live patches
  (crater has an inner pit, fire flickers).
- **AP**: float. Move = sum(weights entered) * move_ap_per_weight; weapon = `total_cost(charge)` = ap_cost +
  charge_ap_extra*(charge-1); ram = dash, priced like a walk (see DashAction).
- **Shots**: `FireParams(weapon, ammo, charge, yaw, pitch, power)`; speed = muzzle_velocity * charge_scale(charge) *
  ammo.velocity_mult() (=1/sqrt(weight)) * power; wind accel * ammo.wind_mult() (=1/weight). `ShootAction` rolls gaussian
  aim error (GUNNERY) / burst spread, launches `Shell`s (raycast per physics step), `Explosion` resolves them.
- **Armor** (`Unit.take_hit(damage, pen, to_hit) -> HitResult`): sector from the angle between hull heading and the
  vector to the impact (<=50 front, >=130 rear, else side). Plate = armor[sector] * (0.5 if burning). pen >= plate ->
  PENETRATED full damage, plate -12%. Else stopped = (plate-pen)/plate * 0.85 -> damage*(1-stopped), plate wears
  damage*stopped*0.5. Burning (turns left): 1 dmg/turn bypassing armor. HP is float.
- **Rounds** (RoundStats): Normal (w1.0), AP (w1.35, dmg x0.55, radius x0.55, pen x2.2, direct-hit x2.4, impulse x0.6),
  Incendiary (w0.85, dmg x0.5, radius x1.2, pen x0.5, ignites ground + burning units), Cluster (w1.2, main blast small, 5
  bomblets radius 0.9 dmg 2 spread 2.8 m, 0.09 s apart, no craters).
- **Explosion**: blasts radius >= 0.8 flash, >= 1.0 scorch decal + (craters = cells within radius*0.75, or fire = cells within
  radius*1.3 for incendiary) if impact y < 1.6. Direct hit = shell collider is a Unit (falloff 1 and round bonus).
  Knockback speed = impulse*falloff/mass^0.5 (impulses roughly halved in rev 4: cannon 10, howitzer 18, RPG 6).
- **Shot camera**: `TacticsCamera.follow(shell)` (zoom `shot_zoom` 12, tracks) -> `release(hold)` lingers 1.1 s -> eases back;
  modes IDLE/FOLLOW/HOLD/RETURN; `shot_cam_enabled` (V key). `ShotTrail` = camera-facing ribbon fading behind the shell.
- **GameState** (`ctx.state`): `begin_shot/finish_shot/note_hit/note_terrain/battle_finished`, `shots: Array[ShotRecord]`
  (setup, wind, origin/impact, flight time, decimated trail, per-unit results with armor outcomes, blasts/craters/fires),
  `totals` (shots, landed, damage per team, friendly, kills, penetrations, absorbed, craters, fires, longest shot, rounds by
  type, charge AP), `summary()` and `summary_lines()` (printed in --ai-vs-ai).
- **Wind**: speed 0..10 m/s, `accel()` = dir*speed*0.1, drifts per round (`TurnManager.round_started`).

## Components (changes in rev 4)
- `WeaponStats`: + `charge_levels` (PackedFloat32Array of velocity fractions), `charge_ap_extra`, `rounds: Array[RoundStats]`,
  `penetration`, `burst_rounds` (was `rounds`), float `blast_damage`. Cannon v26 levels (0.6,0.8,1) range 24 AI; howitzer v18
  (0.55,0.8,1) 55 deg default; RPG levels (0.7,1), normal round only; MG pen 1.5, rifle pen 1.0.
- `UnitStats`: + `armor_front/side/rear` (tank 12/7/3, howitzer 4/3/2, infantry 0). `Unit`: hp float, `armor`, `burning`,
  `armor_sector`, `effective_armor`, `take_hit`, `ignite`, label shows `ARM f/s/r` and BURNING.
- `TurnManager`: standing in a burning cell ignites the unit at turn start; `begin_turn` ticks burn damage; dead -> turn skipped.
  `ctx.round_number` kept for logging. `Game._on_round_started`: wind drift + `board.tick_fires`.
- `PlayerController` unchanged API (panel returns FireParams incl. ammo/charge).
- `GunneryPanel` (REV 4 DESCRIPTION - superseded by Rev 5 above: no wind in estimates, plain radar, scaled to viewport, 780x404 design size): top strip = ammo buttons (T / click) + charge pips (C / click, unaffordable ones red) + COST text +
  weight note + description; left = side view (dial, ruler buckets 8..64 m, **estimated arc** in the barrel plane with head/tail
  wind, landing X + "EST x m"); centre-right = radar (rings, traverse fan, per-charge reach ticks "C1 8m", power band, line of
  sight, enemy blips with distances, **estimated flight path with wind drift**, still-air landing dashed link, aim-error ring);
  far right = WIND box (compass with barrel marker, big speed, TAIL/HEAD, CROSS L/R, drift); bottom = power bar.
  Remembers ammo/charge per weapon. Estimate uses `_estimate(speed)` (still-air flight + wind accel, ignores terrain).
- `AIController`: `_pick_round` (AP vs armored, cluster vs infantry, 20% incendiary), cheapest sufficient charge, `_solve(origin,
  aim, weapon, vmax)`, wind trace uses `wind * ammo.wind_mult()`.
- `TacticsCamera`: sizes start 26 / max 48; helpers `flat_forward/right`, `to_screen_dir`, `from_screen_dir`.

## Controls
`1`-`9` / click toolbar; weapon tool: click opens panel (gunnery) or fires (burst); panel: Up/Down elevation, Left/Right
traverse, T ammo, C charge, hold Space power / release fire, Esc or right click cancel; `Space` end turn, `G` grid, `V` shot cam,
`R` restart, `L` line-of-sight overlay, `P` enemy-turn camera pan on/off, `H` shot review, `WASD`/`Q E`/wheel camera. Headless AI battle: `--headless --path . -- --ai-vs-ai --fast --quit-on-end`.

## Verification (rev 4)
- `tests/smoke_test.gd` (headless, ~143 checks incl. composer, Intel, drone, review filters, props + LoS occlusion): hex/terrain (craters, fire burn-out and downwind spread), ballistics, wind, round
  weights, charges (cost + speed + reach), armor model (sectors, absorb/penetrate/wear/burn), live gunnery (front armor absorbs HE,
  AP penetrates, crater + incendiary fire + cluster blasts), shot-camera follow/return/disable, GameState log + summary, MG vs
  armor, AI wind drift vs awareness, fall-off-board.
- Windowed synthetic-input run (scratchpad) incl. `C` charge: 22 checks pass. Screenshots reviewed (panel w/ estimates + wind box,
  shot cam trail, craters/fire/armor aftermath).
- Rev 6 windowed screenshots (scratchpad scripts: `--path . --rendering-driver opengl3 --script x.gd`, save the viewport image) checked props, shadow wedges and the radar.
- Test gotchas: units parented to the SceneTree root during `_initialize` are not "inside tree" (guards added); obstacle hexes can sit
  on a test's line of fire (use the clear corridor at offset cells (1..7, 2)); the camera may still be returning from a previous shot.

## Known gaps / ideas
- Estimates ignore terrain and the gun's own error (drawn as a ring); no spotting-round memory/last-shot marker yet.
- AI never uses incendiary deliberately against clustered units, doesn't avoid fire, ranging by spotting not implemented.
- Fire does not damage units that merely walk through it (only at turn start); no burnable obstacles.
- Cluster is a ground burst (no airburst); bomblets skip off-map points.
- Balance untested by hand: battles last 3-5 rounds; tune charge levels, armor values, craters, fire spread.
- Panel layout is hard-coded for ~1280x720 viewports; the AI shows no panel (acts directly).
- GameState keeps decimated trails only; no replay playback yet.

## Rev 8: ram = dash, destroyable props + cover, ground elevation (cliffs)
- **Ram** is `DashAction` (was PushAction): straight run toward the mouse, priced like a walk, full extent of AP, stops before units / obstacle hexes / cliff faces. Impact: each side takes the
  other's armor value as damage (front plate vs struck plate / `Props.armor`), plates wear 0.5x damage taken, weaker target is knocked back by the armor difference. `exchange()` previews (dealt, taken).
- **Props have hit points** (`Props.INFO` hp/armor/cover; `GridBoard.damage_prop` -> `prop_damaged` / `prop_destroyed` signals; a destroyed prop unblocks its cell and drops its LoS occluder; `PropView` removes
  the collider at once and shrinks the model). Shells already stop on prop colliders (soak); `Explosion` now also (a) damages props in the blast with the same falloff (the struck prop takes the direct-hit
  amount), (b) applies **cover**: a ray from the unit toward the blast point; the first TERRAIN-layer blocker nearer than the point counts - a prop gives `Props.cover(kind)` (tree .35, large rock .6,
  small rocks .15, bush .1), bare ground (a hill) `TERRAIN_COVER` .5 - cutting both damage and push. Props are tagged with `meta "prop_cell"` (`Props.cell_of(collider)`).
- **Elevation**: `GridBoard` levels 0..5 (`ELEVATION_STEP` .5 m), `set_level / level_of / height_of / surface_y`. `cell_to_world(c, y)` now adds the cell height (y = offset above ground), so spawn /
  highlights / props follow automatically. `step_cost(from, to, allow_cliffs)` = terrain weight + climb (1/level up, .25/level down); a difference >= `CLIFF_LEVELS` (2) is a **cliff**: crossable but costs
  3/level up, 1.5/level down - AP only, height never costs HP. `find_path / reachable` take
  `allow_cliffs`; the AI passes false (`MoveAction.avoid_cliffs`) so it walks around. `DashAction` treats a cliff face as a wall. `smooth_route` only shortcuts across cells within the segment's level range.
- **LoS**: `GridBoard.los_blocked` = tree/rock discs OR `terrain_blocks` (ground higher than the eye-to-eye line, sampled every 0.3 hex). `SightView` bakes heights into a texture and marches it in the shader.
  Shots follow the physics floor (hill prisms), so shot angle / blocking / reach change with height; the AI aims at the target's ground height; the gunnery panel's reach estimate uses height above own ground.
- **Visuals**: `BoardView` floor = per-cell prism with top at the cell height (vertex-coloured: lighter higher; side faces earth for slopes, grey for cliffs); `mouse_ground_point` re-aims at the ground
  height under the guess (4 iterations); controller guides draw at `board.surface_y`.
- **SceneComposer** `_place_hills` (first pass): 3-5 mounds, peak 1..5 (skewed low), levels fall 1 per `hill_ring_width` (1-2) hexes, optional plateau, 45% get one side cut off sheer (-> cliff).
  Levels near spawn zones are capped by distance to them (flat spawns, gradual approach). Composer connectivity check ignores cliff crossings. `SceneLayout.levels` (offset cell -> level).
  Test hook `Game.flat_ground` (smoke test pins level ground for its legacy checks).
- Gaps: shot review map and radar shadows ignore elevation; props never burn; a destroyed prop leaves no rubble; AI does not seek cover or high ground; no per-unit climb limits (all units cross cliffs alike).
- Dev note: `py` (Python 3) exists in this shell besides Python 2 `python`; the Read tool shows one tab more than the file has (line-number separator) - matters for exact-string edits.
- **Gunnery over terrain** (Rev 8 follow-up): `GunneryPanel._estimate` marches the still-air arc against the height field (bisected landing; heights relative to the gun's ground; `blocked` = struck rising ground
  before the apex). The side view draws the ground silhouette along the aim line, the landing marker follows the ground, and "BLOCKED" / a hint is shown when terrain stops the arc. `Ballistics.terrain_pitch_floor`
  (ground within 3 m ahead of the muzzle) raises the minimum elevation (red dial segment, re-applied on traverse; capped at the weapon max); the AI honours it too (`_pitch_floor`, `_solve(board, ...)`). Weapon pitch
  limits are unchanged, so a gun high on a hill still cannot depress past its own minimum. Radar: `_draw_relief` tints cells higher (warm) / lower (cool) than the gun by level (faint, level ground clean) and
  outlines only cliff edges. Estimates still ignore wind and props.

## Rev 9: Hexagon Pack (KayKit Medieval Hexagon Pack) in the scene composer
- Pack lives in `Hexagon Pack/` (glTF used only; `.gdignore` in its `fbx`, `fbx(unity)`, `obj` folders keeps Godot from importing the copies). Tile = 2.0 m flat-to-flat / 2.31 point-to-point, the game hex is 1.73 / 2.0,
  and tanks are 1.2 m wide, so pack models are NOT used at native size: each kind has `scale` (native multiplier, houses 1.6, walls 1.0, supplies 3.0, ...) clamped by the height/width box (`Props.INFO`).
- `Props.Kind` gained BUILDING, WALL, FENCE, RUIN, SUPPLY, TENT, FOREST (appended: stored values stay valid). Pack models also joined existing kinds: `tree_single_A/B` (TREE, own copse family), `mountain_A/B/C` (ROCK_LARGE),
  `rock_single_A-E` (ROCK_SMALL). `Props.scene_path(stem)` resolves res://assets/glTF or the pack (folder table `PACK_FOLDERS`; buildings = `building_<type>_<colour>` in a folder per colour, 4 colours x 16 types in `BUILDING_MODELS`).
  Not used: castle (2+ hexes), watermill (needs a river), gates, corner walls, flags, hills/mountain-with-grass variants (the game has its own elevation), clouds, tiles (roads / rivers / coast).
- New INFO keys: `scale`, `center` (pack buildings keep their authored origin), `cluster` (N scattered items: pebbles, supplies), `line` + `yaw_offset` (walls/fences follow the composer's line yaw), `yaw_step` (buildings snap to 60 degrees), `jitter`.
  Stats: BUILDING hp 36 cover 0.7 LoS r 0.85, WALL hp 30, WOODS hp 24 LoS r 0.95, TENT (really an open canopy) LoS r 0.5, RUIN / SUPPLY / FENCE low and see-through. LoS occluders now ~40-50 on a map (shader cap 64: `wood_cells` kept at 2-3, smoke test checks it).
- `PropView._tone_pack_materials` multiplies pack albedo by 0.82 (pastel white blew out under the sun). Pack pines are saturated cyan-green next to the old trees - a deliberate trade-off, `Props.TREE_MODELS` is where to drop them.
- `GridBoard.add_prop(c, kind, model, yaw)`, `prop_yaw(c)`; layout prop = `[kind, cell, model]` or `[kind, cell, model, yaw]`. Composer passes: see gamestate-and-scene-manager.md "Hexagon Pack passes".
- Ideas next: roads as a cheap-AP terrain and rivers/water as obstacles (pack tiles), team banners at spawns (flags), a castle objective (multi-hex props), rubble left when a building is destroyed.

## Rev 10: glTF unit models (res://assets/Players) - `scripts/units/unit_model.gd`
- Mapping (user's choice): **Sherman = Tank, "Stylized tank" = Howitzer, Stylized Soldier2 = Infantry**; bazooka = RPG, M-16 = Rifle, tank shell = projectile of every GUNNERY weapon (burst bullets stay coloured dots). `UnitStats.model` / `WeaponStats.model` carry the ids ("sherman", "howitzer", "soldier"; "bazooka", "rifle"); empty = the old placeholder boxes.
- `UnitModel.MODELS` describes each model in its own space: scale, yaw (Sherman faces +Z already, the howitzer faces -X so yaw 90 deg), turret ring x/z, barrel trunnion, and how to split it. Rig space: +Z forward, body origin = turret ring axis, lowest hull point on the collider's floor.
  The Sherman is ONE mesh, so `_cut_mesh` splits its triangles by position (above y 180 = turret; thin and ahead of z 128 = barrel) into compact ArrayMeshes, cached per model (first unit pays ~0.1 s, restarts are free). The howitzer is split by mesh name (turret = casemate + sights, barrel = Final_013; its gun is modelled
  raised 16 deg, `rest_pitch_deg` levels it so pitch 0 stays level like the old barrel). Hull rotates to the heading (armor sectors read `_hull`), turret to the aim, barrel pitches; `muzzle_forward` is measured from the barrel vertices.
- Soldier: the model is a T-pose single body; the weapon is a separate model on the barrel node (`Unit.equip(weapon)`, called by `PlayerController._update_bearing` while a weapon tool is active and by `ShootAction`; the muzzle moves with it).
- Team identity: models keep their paint (tinted 35% towards the team colour via copies of the surface materials) and every unit gets a translucent team-coloured disc on the ground (`TeamRing`).
- Shell (`Shell.launch(..., with_trail)`): gunnery shells fly as the shell model (length = `weapon.shell_radius` x 6, nose along the velocity), the trail keeps the round colour.
- Scale choices: Sherman ~1.0 m wide / 1.5 m long, howitzer ~0.9 x 1.8 m, soldier 1.3 m tall; colliders (radius 0.6 / 0.3) unchanged, so a hull overhangs its collider a little. Muzzle height changed (tank ~1.06 m above ground, was 0.6) - one smoke-test hill was moved closer for that.
- Licences: CC-BY (credit) x5, the shell is **CC-BY-SA** - see CREDITS.md. Ideas: wrecks instead of vanishing on death, recoil/muzzle flash, walk wobble, soldier walk cycle (done in Rev 13), per-team skins, shell colour tint by round type.

## Rev 11: Hexagon Pack tiles, trees and rocks
- **Floor** (`BoardView._build_floor_tiles`): one `hex_grass` tile per cell at its elevation (scaled by sqrt(3)/2 so the 2.0 m tile fits the 1.73 m hex), `hex_grass_bottom` tiles stacked under raised cells down to the flat ground, and a WATER_RING (4) of `hex_water`
  tiles around the board (top at y -0.3, so a shore shows a bit of tile side). One MultiMesh per tile type (3 draw calls). Colliders are unchanged (the per-level convex prisms); only the old vertex-coloured prism mesh was dropped,
  so the hill tint, grey cliff faces and brown slope sides are gone (cliffs are now plain tile sides). Tiles are darkened (`TILE_TONE` 0.86, `WATER_TONE` 0.68) via a material copy. Terrain patches (rough / crater / fire), highlights and the grid still draw over the tops.
  Unused pack tiles: coast, rivers, roads, sloped grass (slopes are directional ramps, the game's elevation is stepped) - roads as cheap-AP terrain and rivers as obstacles are the obvious next uses.
- **Trees / rocks**: the old res://assets/glTF trees (CommonTree, Pine, TwistedTree, DeadTree) and rocks (Rock_Medium, Pebble_*) are no longer referenced: TREE = `tree_single_A/B` (scale 2.0, ~2.4 m), ROCK_LARGE = `mountain_A/B/C`,
  ROCK_SMALL = `rock_single_A-E` (cluster of 3, scale 2.0 capped at 0.8 m wide), copses use the single family "tree_single". **Bushes still use the old res://assets/glTF models** (the pack has none) - the red autumn ones in particular clash with the pack palette.
  (Rev 12 then removed the bushes and the foliage shader altogether.)

## Rev 12: bigger map, river + roads (pack tiles), bushes gone
- **Map 28x22** (`Game.BOARD_SIZE`, composer default; spawns T0 (9,5) H0 (14,3) I0 (17,6) / T1 (18,16) H1 (13,18) I1 (9,16) = the old table + (3,2)); camera `start_size` 38 / `max_size` 80; sight shader occluder cap 128 (maps now carry 60-90 sight blockers).
- **Terrain.Type.ROAD** (weight 0.5, not flammable, no coloured patch - the tile shows it). A crater/fire/scorch on a road overwrites the type (cost follows) but the tile stays.
- **Water**: `GridBoard.add_water(c)` (`is_water`, `water_cells`) = a walkable cell at `Terrain.WATER_WEIGHT` 4.0 (a tank pays 4 AP, infantry 2, a howitzer its whole 8): wading is possible but a bridge (ROAD cell, 0.5) is the cheap way across; pathing/AI choose accordingly.
  Water is immune to craters and fire (`set_terrain` / `ignite` / `cells_within` / `tick_fires` skip it), sight and shells cross it like open ground, the floor collider is the normal prism (river water is only 0.09 m below the banks), and `smooth_route` never cuts over it (weight > 1).
  `add_bridge(c)` = ROAD cell over the river (`is_bridge`). `add_water_exit(c)` marks the cell OUTSIDE the board a river flows to (tile selection only). Shot review paints water blue.
  (An earlier draft made water impassable with a separate physics layer so units drowned - dropped when the river became wadable.)
- **`SceneLayout`** gained `water`, `water_exits`, `roads`, `bridges` and **`apply(board)`** (levels, props, water, roads, bridges, rough) - used by `Game._build_board` and by the composer's connectivity check.
- **Composer order**: hills -> `_place_river` -> `_place_village` -> `_place_roads` -> rough -> copses -> loners -> large rocks -> small rocks -> groves -> stumps -> walls -> camps -> ruins -> woods -> fences.
  River: random walk west->east from just off the west edge, directions {SE, E, NE} with at most a 60 degree turn per step, kept within `river_wander` rows of the middle of the spawn rows, out of the RESERVED zones only (keep_clear lanes may be crossed: water does not block sight), hills under it levelled.
  Bridges (`bridges` 1-2): along straight river stretches, the two bank cells on a road axis (+-60/120 degrees off the river) level and every other neighbour dry. Roads: `AStar2D` over untaken cells (no cliff steps, hills cost more, bridge cells linked only to their two banks); main road = north edge -> north spawn centroid -> village lane (by row) ->
  bridge -> south spawn centroid -> south edge, plus a branch over the second bridge joining the main road on both banks. A seed whose map is not walk-connected is retried as before.
- **Bridges are models**: the pack's `hex_river_crossing_A/B` tiles only leave a road stopping at both banks, the span is `buildings/neutral/building_bridge_A/B` (A <-> crossing_A, B <-> crossing_B; same pivot and turn). `BoardView` draws one on every bridge cell,
  widened 1.3x and squashed to 60% height (`BRIDGE_WIDEN`, `BRIDGE_HEIGHT`) so it reads from the camera and vehicles do not sink into the crest. `HexTiles.crossing` returns {tile, yaw, bridge}.
- **`HexTiles`** (`hex_tiles.gd`): edge masks (bit k = neighbour `GridBoard.DIRS[k]`) of every pack road / river tile, measured by rendering them (dead end, straight, 2 bends, all junctions, star; rotation r moves bit k to k+r, yaw r*60 deg), crossing tiles carry river+road masks. `BoardView._tile_for` picks road / river / crossing / grass per cell
  from the neighbours at build time; lakes would work too (all-wet neighbours = star tile). A river cell with one open edge gets the straight tile. Coast tiles and sloped tiles are still unused.
- **Bushes removed** (`Props.Kind.BUSH` deleted; enum values shifted). Replaced by **GROVE** (`trees_A/B_small`, LoS radius 0.55, hug trees/rocks like bushes did) and **STUMPS** (`tree_single_A/B_cut`, cluster of 3, see-through); FOREST now only uses the medium/large clusters. `shaders/foliage.gdshader` and the foliage shading in PropView are gone;
  `res://assets/glTF` is no longer referenced by any script (only `Props.scene_path` still falls back to it for unknown stems) - the old glTF/FBX/OBJ/Textures folders can be deleted.
- Tests: spawn-dependent cells moved (scout sight line, fall-off cell (27,7), hilly reserved list), prop raycasts shoot straight down (neighbouring groves broke the sideways ray), new checks for road cost, wading cost, bridge preference, water immune to craters/fire, tile masks, bridge models, composer rivers (4 seeds) and a tank wading in the live scene.

## Rev 13: animated soldier (KayKit Rig_Medium clips on the unrigged Stylized Soldier2) - `scripts/units/soldier_rig.gd`
- The soldier mesh is ONE static T-pose mesh with no skeleton, so the user's humanoid animation pack (`res://assets/Animations`, KayKit Character Animations 1.1, CC0) is applied by rigging it at runtime (`SoldierRig`, nothing baked):
  1. the 23-bone Rig_Medium skeleton (names, parents, **rest rotations** - the clips are authored against them) is read from `Rig_Medium_General.glb`; only the rest POSITIONS are replaced by the soldier's chibi joints (`JOINTS`, model space: arm span 0.9, legs 0.4, head 0.34 for a 1.0 tall body);
  2. `_skin_mesh` auto-skins by distance to bone segments (`_segments`): nearest bone = 1, bones within `SKIN_BLEND` (0.04) fade in quadratically, 4 influences, left/right bones only move their own half. Overrides found by looking at renders: everything above y 0.13 inside x 0.25 = head (helmet flaps), vertices behind z -0.11 ignore the arm bones (the pack),
     a snout segment keeps the gas mask on the head. First rig of a run costs ~0.1 s (skinning + library), then cached and shared; each soldier owns only Skeleton3D + MeshInstance3D + AnimationPlayer;
  3. `_get_library` copies the clips in `CLIPS` (state -> pack/clip/loop) into one shared AnimationLibrary and refits their POSITION tracks (hips / upperleg / upperarm / handslot offsets were authored for a taller mannequin): `new = soldier_rest + (key - mannequin_rest) * (|soldier_rest| / |mannequin_rest|)` per bone. Rotation tracks are used as is.
  Node layout matches the clips' track paths (`SoldierRig/Rig_Medium/Skeleton3D:bone`, AnimationPlayer next to `Rig_Medium`), so no retargeting.
- **States** (`SoldierRig.State`, `set_state(state, speed)`): IDLE = `Ranged_2H_Aiming` (the unit always holds a weapon), MOVE = `Running_HoldingRifle` (rate = move speed / `MOVE_CLIP_SPEED` 2.2, clamped 0.7-1.8, a little foot slide on purpose), FIRE = `Ranged_2H_Shoot` (one-shot, back to IDLE), HIT = `Hit_A`, DEATH = `Death_A` (holds the last frame).
  Add clips by extending `CLIPS`/`State`; any KayKit Rig_Medium clip name works (Walking_A, Idle_A, Crouching, Ranged_2H_Reload, Cheering ... are in the packs under `Animations/Animations/gltf/Rig_Medium`).
- **Stance vs aim**: the ready/firing clips are a right-shoulder stance (rifle line = right hand at the shoulder -> left hand ahead, 36.5 deg off the body's forward). So the rig lives under the unit's TURRET node (the body follows the aim) and its `Rig_Medium` group is turned `STANCE_YAW` (-36.5 deg) in IDLE/FIRE/HIT/DEATH and 0 while running;
  the weapon mount (barrel node, `barrel_pivot` = `READY_MOUNT`, where the hands hold it) tweens to `CARRY_MOUNT` + yaw 90 deg (rifle across the chest, muzzle to the soldier's left, as the running clip holds it) during MOVE and back after. `UnitModel.assemble` branches on `"rig": true` in `MODELS`.
  `Unit.muzzle_position` now adds the barrel's sideways offset (the weapon is held at x -0.2 m, not on the turret axis).
- **Unit hooks**: `walk` -> MOVE then IDLE; `ShootAction._launch` -> `Unit.play_fire()` (each burst round restarts the clip); `take_hit`/`take_ram` that do damage and do not kill -> HIT; `die()` -> DEATH, the label hides at once, the body stays `SoldierRig.DEATH_LINGER` (2.5 s) and then `visible = false` like every other unit (`died` still fires immediately).
- Verification: smoke test 0 failures, headless `--ai-vs-ai` battle clean; windowed renders (scratchpad `unitview.gd`: assemble through `UnitModel`, `rig.set_state`, SubViewport save_png) for bind pose, ready stance with both weapons, running carry, firing, hit, death, front/back/top views.
- Gotchas: a new `class_name` needs `--headless --import --quit` once; reading bone poses in a headless script needs two `await process_frame` after `seek` (the pose is applied on process). The bazooka model is long (0.9 m) and sits on the shoulder - from the camera it reads fine, up close the rear end pokes behind the head.
- Not done / ideas: reload clip after a shot, crouch for cover, walk instead of run for short moves (`Walking_A`), wrecks for tanks, weapon on a `BoneAttachment3D` at `handslot.r` instead of the free mount (would lose the visible weapon pitch), baking the skin weights to a `.res` if the 0.1 s first-use cost ever matters, hit direction (Hit_A/B).

## Rev 14: information war - enemies outside line of sight are hidden (screen AND AI), gunnery "last shot" sidebar
- **Fog rule**: `Intel.sees(team, units, target)` = own team, or `in_los(fidelity_at(...))` (sight radius of any living unit / spotted area / drone, minus trees, rocks, hills). `BattleContext` got `viewer_team` (0; `-1` in `--ai-vs-ai` = see all),
  `visible_enemies_of(unit)` and `visible_to_viewer(unit)`. A shell landing outside sight still opens a 6 m spotted area, which now also *reveals* enemies inside it.
- **Screen**: `Game._update_fog()` (every frame) calls `Unit.set_concealed(bool)` - hides `_hull`, `_turret`, team ring and the HP/AP/armor label (physics untouched, corpses left alone). Also gated: the turn-start camera glide (`Game._on_turn_started` never pans to an unseen enemy),
  the shot-follow camera (`ShootAction`, only when the shooter is visible), the HUD active-unit line + ring ("Enemy turn - out of sight"), shot-review unit discs. Enemy *shots* in the review (marker + trajectory, incl. the muzzle dot) are still shown - deliberate counter-battery info.
  Gunnery radar: unseen foes get no blip and no reading at all (the old "~18m (40%)" fuzz ring is gone; `Intel.reading` noise still applies to seen foes).
- **AI** (`AIController`): `_nearest_enemy` only considers `ctx.visible_enemies_of(unit)` (team-wide sight, same as the player) and remembers `_last_known[team]`. Nothing in view -> `_search`: walk to the last known position (cleared on arrival, `search_arrival` 3.5 m), otherwise to a scouting point
  (farthest of 8 random open cells, kept per unit until reached). `_approach(unit, goal_point, ctx)` / `_move_toward(unit, goal, preferred, reserve, ctx)` are the shared movers. `_plan_shot` is unchanged (it is given a target). Full AI-vs-AI battles still end in 3-5 rounds.
- **Last shot sidebar** (`gunnery_panel.gd`, panel is now 1004 x 404: `MAIN_WIDTH` 780 for the old controls + `SIDEBAR_RECT` 212 wide; scales to ~1.26x at 1280x720): `GameState.last_gunnery_shot_of(unit)` (non-burst, same shooter) feeds
  - table LAST vs NOW (round, charge, yaw, elevation, power - NOW is green when equal, amber when different; power only while charging), range / flight time, wind then / now as TAIL|HEAD + CROSS L|R relative to each barrel, "same firing position" or "gun moved x m since";
  - RESULT: top-down target view in the gun's frame (**up = down-range**, right = right of the line of fire, 1 m grid + scale bar): target footprint at true radius, hull heading (gold front arc, grey rear arc, "F"), white X = where the shell fell, filled circle per blast that reached the target in the round colour
    (cluster bomblets small, incendiary adds the ground-fire ring = radius x 1.3), then text: unit + total damage (+ KILLED), `DIRECT` sector + outcome (+ blast count), armor before > after, "shell: x m short|long, y m left|right" of the target's centre. No enemy hit -> "No enemy hit. The shell fell x m out." (friendly damage shows as a red FRIENDLY FIRE tag).
  - The panel also prints `(yaw n)` next to TRAVERSE so the absolute yaw can be compared with the LAST column (the traverse number is relative to the mouse-chosen base bearing).
- **Data**: `ShotRecord` + `shooter_id`, `shooter_pos`, `round_short`, `round_color`, `round_special`; `GameState.note_hit(rec, victim, res, blast)` stores per hit `unit_id`, `unit_pos`, `unit_radius`, `hull_yaw` (new `Unit.hull_yaw()`) and the blast dict `{point, radius, fire_radius, direct, cover, bomblet}` (`Explosion._blast` got a `bomblet` flag).
  One entry per blast per unit, so a cluster shot lists the main blast and every bomblet that reached it.
- Tests: smoke test 252 checks, 0 failures (new: sees/visible_to_viewer, concealment, spotted area uncovers, AI target/scout/last-known, enemy-turn pan out of sight, blast data in results, last-shot lookup, hit grouping, frame rotation). The old "enemy turn pans to the enemy" check now places the foe in the far corner first.
  Windowed screenshots (scratchpad `shots.gd`: fire cluster / incendiary / AP / miss, open the panel, `get_texture().get_image().save_png`) checked the sidebar layout.
- Ideas not done: ghost ticks on the dial / power bar / radar for the last shot's elevation, power and yaw; last-known "ghost" markers for hidden enemies; AI reacting to incoming fire direction; sidebar for a different unit's / team's last shot.

## Rev 15: pixel UI - m6x11plus font + Flat_Theme sprites (`scripts/ui/ui_theme.gd`, `UiTheme`)
- **Font**: `res://assets/UI/Fonts/m6x11plus.ttf` (import: no antialiasing / hinting / subpixel). Its native grid is **16 px** (also 32, 48): 11 px, 12 px etc. smear (checked with a size ladder render). `UiTheme.SMALL` = 16, `LARGE` = 32;
  `UiTheme.fs(requested)` folds any requested size (the old 9-16 / 22 / 26 literals in the draw code) into SMALL, or LARGE from 22 up. Also set as the project default (`gui/theme/custom_font`), canvas default texture filter = nearest.
  Labels (HUD, toolbar AP/notice) use 16 with a 4 px outline; 3D labels via `UiTheme.style_label3d` (unit label 48, popups / guide label 32, nearest filtering). HUD is split into status lines + help lines (two Labels in a VBox, both 16).
- **Sprites**: `UiTheme.box(sprite, margin, tint)` = cached `StyleBoxTexture` from `res://assets/UI/Flat_Theme/Sprites/UI_Flat_<name>.png` (9-slice), `draw_box(canvas, ...)`, `draw_panel(canvas, rect, depth)` (Frame01a tinted slate; depth 1 = darker inset).
  Used for: gunnery panel window + wind box + sidebar + hit view (panels), round buttons (`Button01a_4` raised and tinted with the round colour when selected, `Button01a_1` flat dark otherwise), charge pips (`Button02a_*`, red tint when unaffordable), power bar (`Bar07a` track + own dark groove + fill),
  toolbar slots (`FrameSlot01a` tinted slate / lighter on hover, `FrameSlot03a` = the sheet's orange when selected, with dark ink), wind indicator, shot review (map frame, list, details). Not used yet: banners, selection corners (`Select*`), toggles, icons, `Bar*`/`BarFill*` other than Bar07a (HP bars would fit them).
  Sprite sheet knowledge: Frame01a/02a/03a = grey/blue/orange 96x64 windows, FrameSlot0Xa/b/c = normal / hover-ish / disabled 32x32, Button01a/02a_1..4 = cream keys with a bottom shade growing 1 -> 4, Bar05..13 = tracks with a groove, BarFill01a-g = 32x3 coloured lines.
- **Scale**: `GunneryPanel` now snaps its fit scale to whole numbers (`PIXEL_SNAP`, 1x at 1280x720; fractional scales blur pixel art + font) and the position to whole pixels. Panel design size grew to 1004 x 440 (sidebar is 428 tall) to fit 16 px text; the key legend moved to a footer line,
  weight/speed/wind and cost lines were shortened, radar captions merged ("TRAVERSE +0.0 (yaw 90.0)"). Sidebar wind rows read `wind TAIL 2.4  R 0.7` / `now ...`.
- Verification: smoke test 0 failures; windowed screenshots (scratchpad `shots.gd`, `crop.gd` to cut/zoom, `fonttest.gd` size ladder) of panel (cluster / incendiary / AP / miss / fog), toolbar and shot review.
- Gotcha: this machine's `sed -i` + Windows Python differ on `/tmp`; multi-line edits of CRLF files need `\r\n` care (the Edit tool and `io.open(newline='')` + normalising both worked).
- Rev 15 follow-up: `GunneryPanel.PIXEL_SNAP` is now `false` (readability beat crispness: whole-number scaling left the panel at 1x on 720p). It fits the viewport again (about 1.26x at 1280x720, margins 8 px, up to `MAX_SCALE` 3); set it to `true` for crisp pixels only.
- Rev 15 follow-up 2: font switched to **ThaleahFat** (`UI/Fonts/ThaleahFat.ttf`, same import settings, also native 16 / 32, all caps and ~35% wider than m6x11plus). Only `UiTheme.FONT_PATH` + `gui/theme/custom_font` changed; a few panel strings were shortened to fit (shell offset "SHORT 0.5  LEFT 0.1", radar caption). Switch back by editing those two paths (m6x11plus is still in `UI/Fonts`).

## Rev 16: start menu, 1P / hot seat, side + tint choice, victory screen
- **Flow**: `project.godot` main scene is now `scenes/start_menu.tscn` (`StartMenu`, code-built UI) -> START loads `scenes/main.tscn` (`Game`, unchanged entry point; the smoke test still instantiates it directly). `--ai-vs-ai` / `--skip-menu` user args skip the menu.
  `R` = `reload_current_scene` (rematch, new map, same setup). The victory screen's MAIN MENU button loads the menu again.
- **`BattleConfig`** (`scripts/core/battle_config.gd`, static vars so it survives scene changes): `two_player`, `p1_team` (side of Player 1 / "you": 0 = north spawns, 1 = south), `p1_color`, `p2_color` (`PALETTE` of 8). Colours belong to the ROLE (Player 1 / Player 2, or You / AI), not to the team number:
  `color_of(team)`, `name_of(team)` ("YOU"/"AI" or "PLAYER 1"/"PLAYER 2"), `human_teams()`, `is_human`. Defaults = the old game (team 0 blue vs red AI). `Game.TEAM_COLORS` and `Drone.TEAM_COLORS` are gone: `Unit.team_color` (set by `configure`) is what the drone lamp, the active-unit ring and the model tint use.
  Menu rules: the colour the other role wears is disabled (no two identical tints); Player 2 / the AI always takes the other side.
- **Controllers** (`Game._make_controllers`): 1P = `{p1_team: _player, other: _ai}`; hot seat = both teams -> `HotSeatController` (wraps `_player`); `--ai-vs-ai` = `_ai` twice. `Game._set_viewer(team)` sets `ctx.viewer_team`, `SightView.viewer_team`, `ShotReview.viewer_team` (-1 = see all, UI follows as team 0) and refreshes the fog.
- **Hot seat visibility**: the screen always looks through the CURRENT unit's team (`Game._on_turn_started` -> `_set_viewer(unit.team)` before the camera pan). `HotSeatController.decide` shows the `HandoffScreen` (opaque cover on CanvasLayer 20, `await run(team, unit)`, confirm = button / Enter / Space, swallows ALL input incl. camera keys, H, R) whenever the team differs from the previous turn's, so the previous player's view is never on screen when the next player looks. After the cover is confirmed a second step shows the **damage report** (`TurnReport.build(state, ctx, team, after_id)`, `ReportMap`): enemy shots since that team's last hand-off (`HotSeatController._reported`) that hit one of its units or landed inside its line of sight (current `Intel.fidelity_at` at the impact), as numbered entries `FIRE FROM THE <compass>` (north = -Z, from `origin` vs `impact`; same marker + trajectory info as the shot review shows for enemy shots, no weapon / round data) + one line per own unit hit (damage, armor sector, outcome, DESTROYED; cluster hits folded) and a north-up mini map (own units, trajectory polyline, X at the impact, ring on hit units, dot at the muzzle when the shooter was in sight). Skipped when there is nothing to report. Not covered: burn / fall deaths (not logged in GameState). Turn order is still the interleaved initiative order (infantry, tank, howitzer of BOTH teams), so the cover appears at almost every turn change - grouping a team's units together would be a turn-manager change (not done).
- **Victory screen** (`VictoryScreen`, CanvasLayer 12, `Game._on_battle_over` shows it `VICTORY_DELAY` 1.4 s after the last blast via a SceneTreeTimer connection): VICTORY / DEFEAT (1P), "PLAYER n WINS" (hot seat), DRAW; table SURVIVORS / DAMAGE DEALT / KILLS per side from `GameState.totals`, line ROUNDS / SHOTS / LONGEST (+ FRIENDLY FIRE when > 0); buttons REMATCH (NEW MAP), VIEW BATTLEFIELD (hides the panel; Enter re-opens it; H shot review works), MAIN MENU. `BattleContext.reveal_all` is set at battle end so every unit is shown (the AI's own sight rules are untouched). HUD result reads "<NAME> WINS" (`TEAM n` under --ai-vs-ai).
- **Shot review per viewer / history**: `ShotReview` reads `viewer_team` (set by `Game._set_viewer` each hot-seat turn), so each player sees full data for their own shots only and marker + trajectory for the other side's. Once the battle is over (`ctx.reveal_all`) it turns into the **SHOT HISTORY** (`_full()`): every shot with full data, units and shots in the sides' tints (`_team_col`), filter ALLIES / ENEMIES = Player 1 / Player 2 (or YOU / AI), details tagged with the owner. Opened by the victory screen's SHOT HISTORY button (`Game._open_history`: victory panel hides, `ShotReview.open_history()`, `closed` signal brings the results back) or by H afterwards.
- Radar distance noise (checked Rev 16): `Intel.reading` still scatters every VISIBLE foe's blip by sigma = distance x `sigma_fraction(fidelity)` (fidelity is always >= 0.92 for a visible foe, so about 4% of the range), but the radar only prints the measured distance (`%.0fm`); the old "(40%)" fidelity label and fuzz ring were dropped in Rev 14 with the unseen blips.
- `UiTheme` gained `button(text, tint, size)`, `panel_style(pad, depth)`, `label(text, color, size, align)` for Control-based screens (the in-battle UI is still `_draw`-based).
- Tests: smoke test 0 failures (new block "start menu choices": defaults, tints on units, hot-seat controllers + cover + viewer switch + concealment, sight/review follow the viewer, reveal at the end, headlines, 1P on the south side). Windowed screenshots (scratchpad `menu_shots.gd`) of menu, cover, victory.
- Not done / ideas: back to the menu mid-battle (only via the victory screen; `R` restarts), custom colour picker (8 presets now), map seed / board options in the menu, per-team unit lineups, a pause screen, camera yaw for the south side (the camera still starts north-up for both), a hot-seat turn order that groups a player's units.

## Rev 17: two sight rings (inner = measured, outer = estimated, beyond = hidden)
- **Rule** (`Intel`, replaces the Rev 14 "hidden outside the sight radius"): each living unit sees `sight_range` m (Rev 17b values: tank 9.6, howitzer 7.2, infantry 12.8) CLEARLY (inner ring, fidelity 0.92, deviation ~4% of the range) and `Intel.OUTER_BAND` (8 m, was 10) further as an
  ESTIMATE (outer ring: fidelity falls 0.5 -> 0.1 across the band, so sigma grows from ~16% to ~27% of the range); past radius + 8 m the target is fully concealed. Drone / impact areas keep a hard edge (no outer ring, `sources()` carries `"band"`).
  Trees, large rocks and higher ground hide a target from a ground unit in BOTH rings (fidelity 0, was "capped at 0.5").
- API: `fidelity_for(p, centre, radius, band = OUTER_BAND)` (0 beyond the band), `in_los(f)` = inner ring only, new `in_view(f)` = seen at all (`f > 0`); `sees()` = own team or `in_view` (so screen fog, AI targets, turn-start pan, radar blips, shot-review unit discs and the hot-seat `TurnReport` all use the two-ring rule);
  `reading()` also returns `"outer"`. `spot_impact` still tests the INNER ring (a shell landing in the outer ring still opens a 6 m spotted area). `FADE_FACTOR` is gone.
- **Overlay** (`SightView` shader, uniform `band`): clear inside + mint edge; outer ring light grey haze + amber edge line; beyond a dense dark shroud (also the shadow behind trees / rocks / hills). `GunneryPanel` radar: amber outline of each unit's outer ring, outer-ring foes are labelled `~21m` with a ring of one sigma, inner-ring foes `21m` as before.
- **AI** (`AIController._perceived_position`): a target seen only in the outer ring is aimed at its ESTIMATED range (the same cached noisy reading the player gets, along the true bearing) - the AI's shells scatter there like the player's; inner-ring targets are aimed at exactly.
- **Rev 17b**: both rings cut by 20% (`data/*.tres` sight_range x0.8, `OUTER_BAND` 10 -> 8). Total reach: infantry 20.8 m, tank 17.6 m, howitzer 15.2 m. Tests that needed an enemy out of sight park it in the far corner (27, 21); tests that needed one in the scout's inner ring (12.8 m) bring the tank to 60% of the way along the cleared sight line (the units start ~15 m apart, i.e. in the scout's outer ring).
- Smoke test 0 failures (new "two sight rings" block: ring fidelities, deviation growing, drones without an outer ring, live rings via a scratch context, AI estimated aim; tree test now expects fidelity 0).
- Ideas: per-unit outer band, an "estimate" tint on the foe's model / label in the outer ring, shell-landing observation in the outer ring improving the estimate.

## Rev 18: factions - modern vs fantasy (start menu), fantasy units, new rounds, eagle
User brief: faction choice in the menu; existing tank / infantry = MODERN; FANTASY = octo cannon (pushed by a knight) instead of the howitzer, mage with a staff instead of the tank,
ranger with a bow instead of the infantry; same trajectory system, different ammo; the drone becomes an eagle (smaller sight, movable once per turn).
- **Factions** (`scripts/core/factions.gd`, `Factions.Id {MODERN, FANTASY}`): a roster of three UnitStats in fixed slots (main unit, artillery, scout). `BattleConfig.p1_faction / p2_faction` (per ROLE, like the tints;
  `faction_of(team)`; `reset()` restores modern), so factions can be mixed. `Game._make_spawns` builds the spawn table from `SPAWN_CELLS` + the roster of each team (`Game.TANK/HOWITZER/INFANTRY` consts stay for tests).
  Headless: `--p1-faction=fantasy --p2-faction=modern` user args (p1 = the role on `p1_team`, team 0 by default). Start menu: per player a MODERN / FANTASY toggle + roster note above the tint swatches (swatches 36 px, VBox separation 6 to fit 720 p).
- **Fantasy numbers** equal their modern counterparts (hp / ap / armor / sight / weapon ballistics / drone range 22), so mixed battles are fair; only radius / height / mass fit the models (mage r .5 h 1.5, octo r .7 h 1.2, ranger r .3 h 1.5).
  Weapons are clones of the modern ones: Staff = cannon, Arcane Bolts = MG (tracer colour: new `WeaponStats.tracer_color`), Octo Cannon = howitzer, Longbow = RPG (round "Arrow"), Quick Shot = rifle (3-arrow burst). Toolbar glyphs staff / octo / bow / bolts / eagle drawn in `tool_slot.gd`.
- **Rounds** (`RoundStats` grew `projectile`, `fire_factor`, `bounces`, `restitution`, `fuse_distance`; `Special` + METEOR, AIRBURST; `fire_radius_factor()` keeps the old incendiary at 1.3):
  Fireball = HE numbers + `fire_factor` 0.9 (ground within 0.9 x blast radius burns instead of cratering, units in the blast ignite, small patch); Ballista = AP numbers with weight 1.1 (AP 1.35), projectile = bolt model;
  Meteor (weight 1.3, METEOR) = impact blast then `Explosion.meteor`: a `Meteor` RigidBody3D (Jolt, on no layer, mask terrain+units) leaves the impact reflected (sideways x `METEOR_SLIDE` .4, normal x restitution, min lift 4.5, max 9 m/s), `bounces` (3) landings,
  each = small burning blast (`sub_damage/sub_radius`, `_blast` with fire) + its cell set on fire (burning-tile trail), camera follows the rock; Jolt takes the rock's own `bounce` as the effective restitution (floor has 0). Hail (AIRBURST) = proximity-fused: `Shell.fuse_distance` ray ahead along the flight path hits terrain/unit -> `airburst` (burst ~3-4 m up on a steep descent,
  lower on a flat one), `Shell.burst_landing` = where it would have come down; `Explosion.airburst` rains `submunitions` ice stones (visual falling stones, tiny blasts, no craters) around that landing point. A hail shell that hits something first just detonates small (+ the same stones).
  Projectile looks: `UnitModel.make_projectile(id, length)` (fireball / meteor / hail = glowing spheres, bolt = arrow_B, arrow = arrow_A from the Fantasy Weapons Bits, "shell" = tank shell); `Shell.launch(..., projectile)`.
  AI `_pick_round`: AIRBURST counts as cluster (vs infantry), METEOR as the incendiary (20 %), best penetration = ballista as before.
- **Models**: `HeroRig` (extends `SoldierRig`, so `Unit._rig` / `set_state` / death linger work unchanged; `SoldierRig._ready` now calls `_start()`, `State` gained AIM): KayKit Adventurers `Mage/Ranger/Knight.glb` are already on the Rig_Medium skeleton - instanced as they are, the clips of
  `res://assets/Animations` (same packs as the soldier) in one library per profile (`HeroRig.PROFILES`), item on a `BoneAttachment3D` (staff_B at `handslot.r`, bow_A_withString at `handslot.l` yawed -90, Weapon Bits pack). States: IDLE / MOVE / AIM (draw / raise, held) / FIRE (release / shoot) / HIT / DEATH;
  `Unit.begin_aim()` is called by `ShootAction` before the aim settle, `play_fire` at launch, `lower_barrel` drops AIM back to IDLE. Weapon pitch is NOT visible on heroes (weapon is on the hand). Model entries "mage"/"ranger" have `"hero"` (muzzle = `barrel_pivot` in character units; scale .55).
  **Octo cannon** ("octo", model faces +X -> yaw -90 deg, scale .0062): base = TURRET (so cannon + knight turn with the aim; the empty HULL keeps the heading for armor sectors), cannon + octopus = BARREL (barrel axis is 27.45 deg raised in the file -> `rest_pitch_deg`, trunnion (8, 53)).
  The **knight** is the unit's `_rig` ("crew" in the model entry, offset 1.4 m behind, scale .5): walks (Walking_B) while the cannon moves, staggers (Hit_B) on each shot, dies with it; `HeroRig.PushPose` (SkeletonModifier3D) holds both arms forward while IDLE/MOVE (checked on renders only: `get_bone_global_pose` does not show modifier output).
  `UnitModel._load_parts` falls back to the lowest point of ALL parts when nothing is HULL. Team tint applies to every mesh under the rig.
- **Eagle** (`UnitStats.spotter_kind` "drone"/"eagle", `spotter_radius` 7 / 4.5): `Eagle extends Drone` (procedural bald eagle, flapping wings, circles over its point at 4.2 m; `Drone` was split into `_build_body`, `_animate`, `hover_height`, `relocate`, `_face_travel`).
  `DroneAction` for an eagle: first use flies it out from the ranger (`Intel.add_area(..., Intel.PERSISTENT, "eagle", node, owner)`); later uses MOVE the same bird / area (`Unit.spotter`, `Unit.spotter_area`), cost 2 AP, `EAGLE_COOLDOWN` 1 = once per turn (toolbar shows CD 1). Intel areas got an `owner`:
  areas of a dead owner stop counting at once and are dropped (bird flies off) at the next `tick`. Range 22 m from the ranger, as the drone. The AI still never uses spotters.
- Tests: `tests/fantasy_test.gd` (~85 checks: rosters / parity of numbers, round numbers, projectile models, rigs + clips + AIM / FIRE states, push pose, shots with Fireball / Ballista / Hail (octo, steep) / Meteor / bolts, eagle launch / move / persistence / owner death, menu faction buttons, mixed battle),
  smoke_test unchanged (283 checks, 0 failures). Headless AI battles fantasy vs fantasy and modern vs fantasy run clean. Windowed renders (scratchpad `viewlib.gd`, `unit1.gd`, `ingame2.gd`) checked the units, menu, meteor trail, hail burst and eagle.
- Gotchas: scratch harnesses must keep `ShootAction.new(...)` in a variable before `execute` (a temporary RefCounted is freed at the first await and the shot silently never happens); Python 2 `python` + Windows `/tmp` differ from git-bash `/tmp` (use `py`); `Read` output shows one extra tab of indent.
- Ideas not done: AI use of the eagle, a visible weapon pitch on the mage / ranger, ranger nocking an arrow model, hail / meteor panel estimates (the panel still shows the plain arc), per-faction map colours / UI skin, a faction-specific victory screen.
