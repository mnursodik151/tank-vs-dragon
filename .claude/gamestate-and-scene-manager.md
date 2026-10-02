# Game state manager & scene manager

Snapshot of the code as of Rev 7. Everything is built in code from one scene (`scenes/main.tscn` = a bare `Node3D "Main"` + `game.gd`).
Since Rev 16 there is a start menu scene (`scenes/start_menu.tscn`, the project's main scene) that fills the static `BattleConfig` (mode 1P / hot seat, side, tints) and loads `main.tscn`; still no autoloads. `Game` is the composition root, controllers come from `Game._make_controllers`, and
"restart" is `get_tree().reload_current_scene()`. Battle end shows `VictoryScreen` (rematch / main menu). Related: [implementation-notes.md](implementation-notes.md), [actor-controls-and-actions.md](actor-controls-and-actions.md), [ui-ux.md](ui-ux.md).

## Who owns what

| Piece | File | Kind | Owns |
|---|---|---|---|
| `Game` | `scripts/core/game.gd` | `Node3D` (root) | Bootstrap, spawn table, HUD text, global hotkeys, battle-over handling |
| `BattleContext` (`_ctx`) | `battle_context.gd` | `RefCounted` | The shared handle every Action/Controller receives (see below) |
| `TurnManager` | `turn_manager.gd` | `Node` | Round/turn loop, PLAN -> EXECUTE -> SETTLE state machine, winner check |
| `GameState` (`ctx.state`) | `game_state.gd` | `Node` | Battle record: shot log + running totals + result (nothing drives gameplay) |
| `SceneComposer` / `SceneLayout` | `scene_composer.gd`, `scene_layout.gd` | `RefCounted` | Seeded random map (props + rough ground) as plain data |
| `Atmosphere` | `atmosphere.gd` | static helper | WorldEnvironment (procedural sky) + sun |
| `GridBoard` (`ctx.board`) | `grid_board.gd` | `RefCounted` | Logical hex board: terrain weights, props, fire, pathfinding, unit placement, LoS occluders |
| `BoardView`, `PropView`, `SightView`, `GuideView`, `TacticsCamera` | `scripts/core/` | `Node3D`/`Camera3D` | Presentation of the above (see ui-ux.md) |

## Boot sequence (`Game._ready`)
1. `--fast` -> `Engine.time_scale = 3`. `_fire_rng.randomize()`.
2. `_build_environment()` -> `Atmosphere.build(self)`.
3. `_compose_scene()` -> `SceneLayout` (seed: `Game.forced_seed` / `--seed=N` / random 24-bit). `reserved` = the 6 spawn cells (radius 2 kept clear),
   `keep_clear` = `Game.extra_keep_clear` (test hook). Prints `Scene seed N: ...` under `--ai-vs-ai`.
4. `_build_board()`: `GridBoard.new(BOARD_SIZE 22x18, HEX 1.0)`, `add_prop` for each layout prop, `set_terrain(ROUGH)` for `layout.rough`,
   `BoardView.build`. Sets `ctx.board` (the setter also hands the board to `ctx.intel` for LoS) and `ctx.view`.
5. `_spawn_units()` from the hard-coded `_spawns` table: team 0 = Tank (6,3), Howitzer (11,1), Infantry (14,4); team 1 = Tank (15,14), Howitzer (10,16), Infantry (6,14)
   (offset coords). Teams face each other (+Z / -Z). Units go into `ctx.units`.
6. `_build_camera()`, `_build_hud()` (HUD label, `WindIndicator`, `ShotReview` on its own CanvasLayer 10), `_guide`, `_state`, `_sight` added as children.
7. Fill the rest of `ctx`: `guide`, `root` (= Game, parent for shells/flashes), `camera`, `state`.
8. Add `_turns`, `_player`, `_ai` as children, connect `battle_over` / `round_started` / `turn_started`, then
   `_turns.start(_ctx, {0: player-or-ai, 1: _ai})`. With `--ai-vs-ai` both teams use the same `AIController`.

Gotcha: node order matters only for the `ctx` wiring above (`ctx.board` must be set before `_sight.setup`, which iterates board cells).

## BattleContext (`_ctx`)
Fields: `board`, `view`, `guide`, `wind` (`Wind`), `intel` (`Intel`), `camera`, `state` (`GameState`), `round_number`, `root`, `units: Array[Unit]`, `verbose`, `viewer_team` (Rev 14: whose eyes the screen uses, -1 = all visible; with `visible_enemies_of(unit)` / `visible_to_viewer(unit)`). `GameState.note_hit` takes an optional blast dict and `last_gunnery_shot_of(unit)` feeds the gunnery sidebar.
Helpers: `alive_units()`, `enemies_of(unit)`. Actions and controllers must only reach the world through this - they never use the scene tree directly
(except `unit.get_tree()` for timers/physics frames).

## TurnManager: the loop
```
start(ctx, controllers{team->UnitController}) -> board.resync(units) -> _run_battle()
_run_battle: while round < max_rounds(100):
    winner? -> _finish          # checked before each round and after each turn
    round++ ; ctx.round_number ; intel.tick(round) ; emit round_started
    for unit in _turn_order():  # alive units sorted by stats.initiative DESC, both teams interleaved
        await _run_turn(unit)
_run_turn(unit):
    burning cell -> unit.ignite(BURN_TURNS) ; intel.begin_turn(unit) ; unit.begin_turn() (AP refill, drone CD--, burn tick) ; emit turn_started
    dead? return
    while unit alive and ap > epsilon:
        PLAN     action = await controller.decide(unit, ctx)       # null = end turn
        validate action.can_execute(ctx)  (illegal -> warning + end turn)
        EXECUTE  await action.execute(ctx) ; emit action_executed
        SETTLE   await _settle()                                   # wait until all bodies rest
        winner? -> break
    END_TURN: view.clear_highlight(), guide.clear(), emit turn_ended, await one process_frame
```
- `State { IDLE, PLAN, EXECUTE, SETTLE, END_TURN, FINISHED }`, `state_changed` fires on each. `NO_WINNER = -1`, `DRAW = -2`.
- `_settle()`: polls physics frames until every living unit `is_settled()` for `calm_frames_required` (10) frames, hard cap `settle_timeout` 4 s.
  Units below `kill_plane_y` (-3) die ("fell off the board"). Ends with `board.resync(units)` - **physics never drives logic; logical cells are re-derived from body positions**.
- Turn order is re-sorted every round with `sort_custom` (not stable): equal initiative (i.e. the two same-type units) has no guaranteed order.
  Initiatives: infantry 12, tank 8, howitzer 4.
- Winner = only one team has living units (`DRAW` if none). `max_rounds` hit -> `DRAW`.
- Signals nobody listens to yet: `state_changed`, `turn_ended`, `action_executed`, `Unit.died`, `GameState.shot_recorded`. These are the natural hooks for UI/audio/replay.

## Game-level state & hotkeys (in `game.gd`)
- `enemy_turn_pan` (P): camera glides to enemy units at their turn start; own turns (team 0, not `--ai-vs-ai`) always pan (`_on_turn_started` -> `camera.focus_on`).
- `_on_round_started`: `wind.drift()` and `board.tick_fires(wind direction * speed fraction, rng)`.
- Keys in `_unhandled_input`: `R` reload scene (new random map; `forced_seed` static survives a reload), `G` grid, `V` shot cam, `L` LoS overlay, `P` pan.
  (`H` is handled by `ShotReview` itself; `Space`/`1-9` by `PlayerController`; WASD/QE/wheel by `TacticsCamera`.)
- `_on_battle_over(team)`: sets `_result` text ("TEAM n WINS" / "DRAW") for the HUD, `GameState.battle_finished`, prints `summary_lines()` under `--ai-vs-ai`,
  `get_tree().quit()` under `--quit-on-end`. Nothing else happens: no end screen, no prompt - the player presses `R`.
- Command line (user args after `--`): `--ai-vs-ai`, `--fast`, `--quit-on-end`, `--seed=N`.
  Headless run: `Godot_..._console.exe --headless --path . -- --ai-vs-ai --fast --quit-on-end`.
- Test hooks: `Game.forced_seed`, `Game.extra_keep_clear` (static vars).

## GameState (battle record)
Purely a recorder; `ShootAction`/`Explosion` feed it, `ShotReview` and the console summary read it.
- API: `reset()`, `begin_shot(ctx, actor, params, ap_cost) -> ShotRecord` (called when a shot is fired), `finish_shot(rec, impact, landed, flight_time, flight_path)`
  (decimates the path with `TRAIL_STRIDE` 3 and emits `shot_recorded`), `note_hit(rec, victim, HitResult)` (per unit struck, updates damage/kill/armor totals),
  `note_terrain(rec, craters, fires)`, `battle_finished(winner, rounds)`, `summary()` (dict), `summary_lines()` (console text).
- Fields: `shots: Array[ShotRecord]`, `winner`, `rounds_played`, `finished`, `totals` =
  `shots, landed, damage_dealt{team}, friendly_damage, kills{team}, penetrations, armor_absorbed, craters, fires, ap_on_charges, longest_shot, rounds_by_type{}, weapons{}`.
- `ShotRecord` (`shot_record.gd`): id, round, shooter name/team, weapon, round type, charges, AP cost, yaw/pitch/power/speed, wind speed+angle, burst/rounds,
  origin/impact/distance/flight_time/landed, decimated `trail`, `results[]` (per-unit: unit, team, sector, outcome, damage, raw, armor before/after, killed),
  `blasts`, `craters`, `fires`; `to_dict()` for export.
- Burst weapons: the record's `impact` is overwritten per bullet and `finish_shot` is called once after the burst with `flight_time` 0 and no trail.
- Gaps: not persisted to disk, no replay playback, trails are decimated, `GameState` is a `Node` although it uses no node features (could be a `RefCounted` like `BattleContext`). Movement / non-shot events (moves, rams, drones, burn damage, falls) are **not** logged.

## Scene composition (SceneComposer / SceneLayout)
- `compose(seed) -> SceneLayout{seed, props: [[Props.Kind, Vector2i offset cell, model stem, (optional) yaw]], rough: [Vector2i], water / roads / bridges: [Vector2i], water_exits: [Vector2i outside the board], levels: {offset cell: elevation level}}`; retries with `hash([seed, i+1])` up to 24x until every
  reserved cell is walk-connected (`_is_connected` via `GridBoard.find_path`), else warns and returns an empty map.
- First pass `_place_hills` (elevation, see implementation-notes Rev 8; cliffs never needed for connectivity). Then (shared `_taken` set, `_blocked_zone` = edge margin 1 + reserved radius 2 + keep_clear): rough patches (5-7 blobs of 3-5), tree copses (2-4 centres >= 6 apart,
  3-5 trees each, one family + 15% strangers), loner trees (3-5), large rocks (5-8, spaced 3), small rocks (9-13), groves (6-9, 60% hug a tree/rock), stumps (4-6, beside the copses).
  Density knobs are plain vars on the composer.
- **Hexagon Pack passes** (appended after the foliage ones, so a seed keeps its foliage): `_place_village` (85%: a civic building + 3-6 homes/workshops in ONE colour, no two adjacent, flat ground only, 1-3 supply piles in the lanes),
  `_place_fortifications` (0-1 wall lines of 3-5 `wall_straight` along a hex direction, 60% with a gate gap, plus a tower at one end), `_place_camps` (0-2: 2-3 canopy "tents" + supply piles), `_place_ruins` (2-4),
  `_place_woods` (2-3 patches of 2-3 touching FOREST cells of one tree family), `_place_fences` (1-2 fence lines near the village). `_find_line` returns `{cells, dir, yaw}` (yaw lays a model's local x along the line;
  `PropView` adds the kind's `yaw_offset`); the yaw travels as the 4th entry of a layout prop into `GridBoard.add_prop(..., yaw)` / `prop_yaw(c)`.
- Extending: add a `_place_*` pass + a field on `SceneLayout` + have `Game` consume it. The spawn table in `game.gd` is still hard-coded (the obvious next move into the composer).
- `Game._build_board` is the only consumer today (`GridBoard.add_prop` blocks movement for all prop kinds; only props with `los_radius` > 0 (trees, large rocks, buildings, walls, woods, canopies) block sight - see implementation-notes "Props and line of sight").

## Atmosphere
`Atmosphere.build(host)` adds `WorldEnvironment` (ProceduralSky, sky ambient + reflections, filmic tonemap) and `Sun` (orthogonal single-split shadow, max distance 90).
Constants at the top of the file; time-of-day/weather would be extra parameters of `build`.

## Where the architecture is thin / ideas
- No main menu, pause, settings, mission/map selection or end screen: `Game` is hard-wired to one skirmish. A scene manager would add a menu scene,
  a `Battle` scene (what `Game` is now), a results scene fed by `GameState.summary()` + `shots`, and pass a `BattleConfig` (seed, spawns, teams, controllers) instead of static vars.
- `Game` mixes bootstrap, HUD text, hotkeys and battle-over handling; the HUD builder and key handling are the easy parts to split out.
- `Game._process` rebuilds the HUD string every frame.
- Team count is effectively 2 (`TEAM_COLORS`, `_spawns`, `GameState` totals keyed 0/1); the TurnManager itself supports any number.
- `Intel` and the wind live on the context (not on `GameState`); a save/load would have to serialize board (terrain, fires, props), units (hp/ap/armor/burning/cooldown),
  wind, intel areas, round number.
