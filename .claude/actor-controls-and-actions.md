# Actor controls & actions

Snapshot as of Rev 7. How a unit is represented, who decides what it does (controllers), and what it can do (actions). Related:
[gamestate-and-scene-manager.md](gamestate-and-scene-manager.md) (turn loop that drives all this), [ui-ux.md](ui-ux.md) (toolbar/panel the player controller uses), [implementation-notes.md](implementation-notes.md).

## The pattern
**Strategy + Command.** `TurnManager` asks the team's `UnitController.decide(unit, ctx)` (awaitable) for an `Action`; it validates with `can_execute`, then
`await action.execute(ctx)`, then waits for physics to settle. `null` from `decide` = end the unit's turn. Actions never touch the scene tree except through
`ctx` and `actor.get_tree()` (timers / physics frames). A unit may act repeatedly in one turn while `ap > Action.AP_EPSILON (0.001)`.

```
UnitController (Node)  decide(unit, ctx) -> Action | null
 |- PlayerController    toolbar + mouse/keyboard, team 0
 '- AIController        scripted, team 1 (and team 0 with --ai-vs-ai)
Action (RefCounted)     actor, cost(ctx), can_execute(ctx), execute(ctx), describe()
 |- MoveAction  |- ShootAction  |- DashAction (Ram)  '- DroneAction
```

## Unit (`scripts/units/unit.gd`)
`RigidBody3D` (cylinder collider, angular axes locked, `continuous_cd`, layer UNITS, mask TERRAIN|UNITS). **Frozen (kinematic) while game logic owns it**;
physics takes over only for knockback/ramming (`launch`) and returns control via `TurnManager._settle` + `GridBoard.resync`. Units stand where they were walked/knocked,
not on cell centres; `cell` is derived.
- Data: `UnitStats` (`data/*.tres`): `display_name, kind (INFANTRY/TANK), max_hp, max_ap, move_ap_per_weight, move_speed, initiative, mass, radius, height,
  armor_front/side/rear, sight_range, drone_range, weapons[]` (main gun first).

  | | HP | AP | AP/weight | speed | initiative | armor F/S/R | sight | weapons |
  |---|---|---|---|---|---|---|---|---|
  | Tank | 20 | 8 | 1.0 | 4 | 8 | 12/7/3 | 12 | Cannon (4 AP, 3 charges, 4 rounds), Machine Gun (2 AP, burst 6) |
  | Howitzer | 14 | 8 | 2.0 | 2.5 | 4 | 4/3/2 | 9 | Howitzer (5 AP, 3 charges, pitch 35-80, 4 rounds) |
  | Infantry | 8 | 6 | 0.5 | 3 | 12 | 0/0/0 | 16 | RPG (3 AP, 2 charges, normal round), Rifle (1.5 AP, burst 3); drone range 22 |
- Runtime state: `hp` (float), `ap`, `armor[3]` (wears down), `burning` (turns left), `drone_cooldown`, `cell`, `team`.
- Lifecycle: `begin_turn()` (AP = max, drone cooldown--, burn: -1 HP bypassing armor + "BURNING" popup), `spend_ap`, `take_damage` (direct), `take_hit(dmg, pen, to_hit) -> HitResult`
  (armor sectors by hull heading: <=50 deg front, >=130 rear, else side; pen >= plate -> PENETRATED, else partial absorb up to 85% and plate wear; burning halves plate),
  `ignite(turns)`, `die()` (hidden, collision off, emits `died`).
- Visuals: `_build_visuals` mounts the glTF model named by `UnitStats.model` through `UnitModel.assemble` (see implementation-notes Rev 10), else falls back to placeholder boxes/capsule. Only `face`, `aim`, `equip`, `lower_barrel`, `muzzle_position` touch the nodes, Soldiers carry an animated `SoldierRig` (Rev 13, implementation-notes): `Unit._rig`, driven by `walk` (MOVE/IDLE), `play_fire()` (called from `ShootAction._launch`), `_flinch` (HIT, from `take_hit`/`take_ram`) and `die()` (DEATH, hidden after 2.5 s).
  so swapping in models only touches those. `Label3D` over the unit shows `HP / AP`, `ARM f/s/r`, `BURNING`.
- Movement/physics: `walk(waypoints)` (tween, kinematic, faces each leg), `launch(impulse)` (unfreeze, velocity = impulse/mass), `is_settled()`, `freeze_in_place()`, `snap_to(pos)`.
- Aiming: `face(dir)` turns hull + turret, `aim(dir, pitch)` turns the turret and pitches the barrel, `muzzle_position(dir)` = shell spawn point.

## Actions

| Action | AP cost | `can_execute` extra conditions | `execute` |
|---|---|---|---|
| `MoveAction(actor, point)` | path weight x `move_ap_per_weight` (INF if no path) | destination cell != current, path non-empty | spends AP, **places the unit logically at once** (`board.place`), then `await actor.walk(smoothed route)` |
| `ShootAction(actor, FireParams)` | `params.total_cost()` = `ap_cost + charge_ap_extra*(charge-1)` | `actor.stats.weapons` contains the weapon | spend AP, `GameState.begin_shot`, aim, 0.3 s (gunnery) / 0.15 s (burst) settle, launch `Shell`(s), camera follow, await all impacts, lower barrel |
| `DashAction(actor, dir)` (Ram) | like a walk: terrain weight of each hex entered x `move_ap_per_weight`, as far as AP allows (floor: one hex if it hits something) | AP covers the planned run; run > 0 or an impact | `plan` marches a 0.05 m step line (stops *before* touching a unit, an obstacle hex or the board edge; leading edge + flanks tested), spend AP, `board.place` at once, `await actor.walk([end], 2x speed)`, then impact. **Impact**: each side takes damage = the other's armor value (rammer's front plate vs the struck plate / prop `Props.armor`), ignoring armor mitigation (`Unit.take_ram`); each plate wears `ARMOR_WEAR` (0.5) x damage taken; if rammer armor > struck armor the unit is launched away at `(diff * KNOCK_PER_ARMOR) / mass^KNOCK_MASS_EXPONENT`. Props never wear or move. `exchange()` previews (dealt, taken). |
| `DroneAction(actor, point)` | 2.0 | `drone_range > 0`, cooldown 0, within range, point in bounds | spend AP, cooldown = 3, spawn `Drone`, `intel.add_area(...)`, `await drone.fly_in(...)`, "DRONE ON STATION" popup |

Details worth knowing:
- **MoveAction**: plans once per instance (`plan`) so the controller can ask `path_cells`, `route`, `cost`, `can_execute` for the hover preview cheaply. The unit ends at the *clicked point*
  (nudged out of other units' footprints, clamped to the destination cell). The grid only prices the trip: terrain weights GRASS 1, ROUGH 2, CRATER 2.5, FIRE 2, SCORCH 1.5 plus slope climb (see `GridBoard.step_cost`); props block. Cliff crossings (`avoid_cliffs` false) just cost a lot of AP; the AI sets `avoid_cliffs`.
  Moving does not step through fire damage - burning is only applied at turn start (known gap).
- **ShootAction**: GUNNERY = one shell with gaussian aim error (`aim_error_deg`), shot camera, parabolic trail, impact -> `Explosion.detonate` (+ `Explosion.cluster` for cluster rounds).
  BURST = `burst_rounds` bullets with growing spread (`spread_deg + spread_growth_deg*i`), `round_interval` apart. Wind accel = `ctx.wind.accel() * ammo.wind_mult()`.
  A gunnery shell landing outside the team's sight opens an `Intel` "impact" area (6 m, 2 rounds) with a "SPOTTED" popup.
  Muzzle speed = `muzzle_velocity * charge_scale(charge) * ammo.velocity_mult() * power`, `velocity_mult = 1/sqrt(weight)`, `wind_mult = 1/weight`.
- **FireParams** (`combat/fire_params.gd`) = weapon, ammo (`RoundStats`, null for burst), charge, yaw, pitch, power (clamped to `min_power`..1 for gunnery). Built by `FireParams.make(...)`.
  It is the contract between the gunnery panel / burst click / AI and `ShootAction`; nothing about the predicted landing is carried.
- **DroneAction**: the drone stays 2 rounds (launch round + next), launcher can relaunch on its 3rd own turn after (`COOLDOWN_TURNS` 3). Spotted areas count as line of sight for fidelity of distance readings.
- Adding an action: subclass `Action`, override `cost/can_execute/execute/describe`; add a `ToolEntry.Kind` + `build_for` entry + `PlayerController._on_click/_refresh/_process` case, and teach the AI if it should use it.

## PlayerController (`scripts/controllers/player_controller.gd`)
Owns the UI layer (`CanvasLayer` 5: `Toolbar` + `GunneryPanel`). `decide()` builds the toolbar for the unit (`ToolEntry.build_for`: Move, each weapon, Drone (if `drone_range > 0`), Ram), selects tool 0,
then `await action_chosen`. `_finish(action)` emits it; `null` (Space/Enter) ends the turn.
State: `_active` (waiting for input), `_busy` (gunnery panel owns the input; `is_busy()` also blocks the shot review), `tools`, `tool_index`.

Input (all through `_unhandled_input`, so clicking toolbar slots / the panel never leaks into the world):
- `1`-`9` or click a slot: select a tool (flashes "Not enough AP..." / "Drone recharging..." if unusable). `Space`/`Enter`: end turn.
- Left click uses the tool:
  - **Move**: ground point -> `MoveAction`; if unaffordable flashes the needed AP. Hover shows dotted path, end marker disc and `cost / AP` label; with the grid on, reachable cells are highlighted blue.
  - **Weapon (BURST)**: fires immediately along the bearing to the mouse (`FireParams.make(weapon, yaw, 0, 1)`).
  - **Weapon (GUNNERY)**: opens the gunnery panel with the coarse bearing; `GunneryPanel.run` returns `FireParams` or null (cancel) -> `ShootAction`. Needs `weapon.ap_cost` AP just to open.
  - **Drone**: ground point within range -> `DroneAction`; hover shows a disc (green, red when out of range/cooling down) and the range circle.
  - **Ram**: hover previews the dash line toward the mouse, its end, `cost / AP` and (on impact) `RAM: deal x, take y`; click -> `DashAction` (full run: the dash always goes as far as AP/obstacles allow, direction only).
- Weapon tool hover: the turret swings to the mouse (`unit.aim`), a short dotted bearing line + crosshair disc are drawn. Nothing about the shot is predicted in the world.
- Every refresh (`_refresh`) clears guides/highlights and lowers the barrel; the grid toggle re-triggers it.

## AIController (`scripts/controllers/ai_controller.gd`)
Exports: `think_delay` 0.4 s, `aim_noise_deg` 1.2, `power_noise` 0.04, `wind_awareness` 0.0 (0 = ignores wind, 1 = perfect correction), `preferred_range_ratio` 0.7.
One action per `decide` call (the turn loop calls it again while AP remains):
1. Target = nearest living enemy (by 3D distance). No target -> end.
2. For each weapon in the unit's order (main first) that it can afford: `_plan_shot`; the first valid `ShootAction` wins.
3. `_plan_ram`: a `DashAction` straight at the target that ends against an enemy and deals more damage than it takes (`exchange()`).
4. Otherwise `_approach`: score every reachable cell by `| distance to target - preferred |` (preferred = max(min_range+1, max_range*0.7)); +2 penalty if the move leaves less AP than the main weapon costs;
   no better cell -> `null` (end turn).
`_plan_shot`: out of `[min_range, max_range]` -> none. BURST: needs a raycast with a clear line to the target. GUNNERY: `_pick_round` (AP if target front+side armor > 8; cluster vs infantry; 20% incendiary;
else the first/normal round), cheapest charge that can reach (`_solve` still-air, prefers the weapon's default pitch with just enough power, else full power on the low/high arc), still-air trace must land
within `blast_radius + target radius`, optional wind compensation (`wind_awareness`), then adds gaussian yaw/pitch/power noise. Since Rev 14 it only targets enemies its team can see (`Intel.sees`) and scouts / heads for the last seen position otherwise (see implementation-notes Rev 14); it still ignores drones and does not avoid fire.

## Cross-cutting rules
- Physics never decides logic: after any action `TurnManager._settle()` waits for rest and `GridBoard.resync` re-derives cells (units that ended inside terrain are snapped).
- Winner checks happen after every action, so a kill ends the battle mid-turn.
- Controllers are chosen per team in `Game._ready` (`{0: _player or _ai, 1: _ai}`); a new controller only has to implement `decide`.
- Unit-test-ish coverage is in `tests/smoke_test.gd` (armor model, charges, live gunnery, AI wind drift, fall-off-board, drone, ...).

## Gaps / ideas
- Movement is not interruptible and does not trigger anything en route (fire, mines, overwatch). Ending a move inside a fire cell only hurts at the next turn start.
- No undo / confirm step; right click does nothing outside the gunnery panel.
- AI: no focus on weak targets, no use of cover/line of sight, no drone use, single-turn thinking, `Ram` only when adjacent and nothing else is possible, ties in "nearest" are arbitrary.
- `ToolEntry.cost()` shows the base AP of a weapon; the true cost depends on the chosen charge (shown only in the gunnery panel).
- Only the active team-0 player controls units; hotseat / second human would need a controller per team with its own UI context.

## Rev 18 addendum (fantasy faction)
Units come from `Factions.roster` (see implementation-notes Rev 18). `DroneAction` also drives the ranger's **eagle** (`UnitStats.spotter_kind == "eagle"`): persistent, moved by the same action once per turn (`drone_cooldown` 1), 4.5 m area.
`ShootAction` calls `Unit.begin_aim()` first (hero wind-up animation), special rounds branch in `_on_impact`: AIRBURST -> `_hail` / `Explosion.airburst`, METEOR -> `Explosion.meteor` (physics bounces), CLUSTER as before.
