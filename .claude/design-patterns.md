# Design patterns

Why the code is shaped the way it is, and how to extend it without breaking the shape. Written in Rev 20 (command history + undo, the
modular parameter system); older patterns (Strategy controllers, the composition root) are included so the whole picture is in one place.
Code-level snapshots live in [gamestate-and-scene-manager.md](gamestate-and-scene-manager.md), [actor-controls-and-actions.md](actor-controls-and-actions.md),
[ui-ux.md](ui-ux.md); history and design intent in [implementation-notes.md](implementation-notes.md).

## Map of the patterns

| Concern | Pattern | Where |
|---|---|---|
| Things a unit does | **Command** (+ meta-command for undo) | `scripts/actions/` |
| Taking things back | **Memento** per subsystem, aggregated by a snapshot; **history** as the invoker's log | `battle_snapshot.gd`, `command_history.gd`, `capture()/restore()` on `Unit`, `GridBoard`, `Intel`, `GameState` |
| Who decides an action | **Strategy** | `scripts/controllers/` |
| Unit definition | **Blueprint / Prototype**: immutable authored data, cloned per unit | `UnitBlueprint`, `Tunable.clone()` |
| One unit's live numbers | **Facade / orchestrator** over the clones | `UnitProfile` |
| Upgrades | **Modifier stack** (layered, source-tagged, re-derived from base) | `StatModifier`, `Upgrade`, `RunState` |
| "Every number is a stat" | **Reflection-built registry** | `StatCatalog` |
| Wiring | **Composition root** + shared **context object** | `Game`, `BattleContext` |
| Views follow the model | **Observer** (signals) | `GridBoard.terrain_changed / prop_*`, `TurnManager` signals |

## 1. Commands, history and undo

**The command.** `Action` (`RefCounted`) = `actor`, `cost()`, `can_execute()`, `execute()` (awaitable), `describe()`. A controller *decides* one,
`TurnManager` validates it, records it, runs it, waits for physics to settle. Two additions in Rev 20:

* `reversibility()` -> `Action.Reversibility`: `FREE` (a move: can be undone at any time, no rules), `COSTLY` (shot, ram, spotter: only by a rewind, which
  needs a charge), `NONE` (never). The default is COSTLY; `MoveAction` says FREE.
* `records_history()`: false for meta-commands. **Taking back is itself a command**, and there are two separate ones (`TakeBackAction` is their base):
  `UndoMoveAction` (the free move undo) and `RewindAction` (the limited whole-turn rewind). A controller returns one like any other action, so
  `UnitController.decide()` needed no extra channel, and the turn loop treats it uniformly (validate, execute, settle).

**The memento.** Physics-driven side effects (a blast that craters the ground, destroys a tree, kills a unit, opens a spotted area) cannot be
inverted action by action, so undo restores a **snapshot** taken just before the action:

```
Unit.capture/restore       position, hp, ap, armor, burning, cooldown, spotter refs, hull/turret/barrel yaw, dead flag (a killed unit stands up again)
GridBoard.capture/restore  props (hp / destroyed), blocked cells, terrain, weights, fires; emits terrain_changed / prop_restored so views follow
Intel.capture/restore      spotted-area records (kept BY IDENTITY: Unit.spotter_area points at one), marker positions; markers opened since are freed
GameState.capture/restore  shot list length, next id, totals (the undo counters themselves survive)
BattleSnapshot             strings those together + removes scorch decals added since; then board.resync(units)
```

Not restored on purpose: wind and round counter (they change between rounds, never inside a turn), `Intel`'s per-target reading noise (re-aiming after a
rewind sees the same readings), floating text / flashes / trails. **A rewound shot rolls its aim error again** - a rewind is a re-roll, which is why the
costly ones are limited.

**The invoker.** `CommandHistory` (`ctx.history`) holds `Entry{action, snapshot, time_ms}` for the *current unit's turn only* (emptied on `begin_turn`
and `end_turn`). `TurnManager._run_turn` calls `history.begin_turn(unit)`, then for every action `history.record(action, ctx)` *before* `execute`.
**Two functions, two rule sets** (Rev 21 split them):

| | `undo_move()` / `UndoMoveAction` | `rewind()` / `RewindAction` |
|---|---|---|
| Takes back | the most recent action, if it is a move (`FREE`); repeatable back to the turn start | the whole turn (restores the first entry's snapshot) |
| Rules | **none**: no charge, no window, no switch, every game mode | `rules.rewind_charges` per battle (one used when the turn holds a COSTLY action), `rules.rewind_window_sec` (0 = off; the oldest costly action must be younger), NONE actions block it |
| Free case | always | a turn of moves only rewinds for free and with no rules either |
| Refusal text | `refusal_move()`: "Nothing to undo" / "Only a move can be undone" | `refusal_rewind()`: "Nothing to rewind" / "No rewinds left" / "Too late to rewind (10 s window)" |

`BattleRules` (`rewind_charges`, `rewind_window_sec`; stats like any other, so upgrades raise them) per team via `ctx.rules_for(team)`; `Game._setup_rules()` gives the
player the run's rules (`RunState.rules()`), hot seat no rewinds (the other player is not looking: a rewind would be a free re-roll), the AI nothing. A shot is taken back
only by a rewind - so a shot followed by moves can still have those moves undone for free, but never the shot.

**Keeping the turn open.** The loop is `while alive and (ap > eps or controller.holds_turn(unit, ctx))`. `UnitController.holds_turn()` defaults to
false (scripted controllers end at 0 AP); `PlayerController` returns `history.can_undo_any()`, so a player with no AP left but something to take
back must press Space to end the turn (a popup says so, see below). Keys: **Z / Backspace** undo move, **X** rewind turn.

**Extending.**
* New action: subclass `Action`; decide its `reversibility()`; if it creates nodes or state outside what the four `capture()`s cover, extend the matching
  `capture/restore` (and add a test in `tests/undo_test.gd`). That is the only place an action can break undo.
* New persistent battle state (a new subsystem): give it `capture()/restore()` and add it to `BattleSnapshot.take/restore`.
* History across turns (undo an enemy phase, "rewind the round"): the snapshots already allow it; stop clearing in `begin_turn` and decide the rules.

## 2. Strategy: controllers

`UnitController.decide(unit, ctx) -> Action | null` (null = end turn), `holds_turn()`. Implementations: `PlayerController` (toolbar + mouse), `AIController`
(scripted; only does what the unit's blueprint says it can do: `unit.can_do(kind)`), `HotSeatController` (wraps the player controller, hand-off cover).
`Game._make_controllers` picks per team. A new controller only implements `decide`.

## 3. Blueprint -> clone -> profile: the unit template

```
data/blueprints/tank.tres      UnitBlueprint   id (file stem), stats, actions[], meta{}, tags
   |- stats: data/tank.tres    UnitStats       the unit's own numbers + weapons[] (-> WeaponStats -> rounds[] RoundStats)
   '- actions[]                ActionSpec      MOVE, SHOOT (uses the weapons), SPOTTER (SpotterSpec), RAM (RamSpec)
UnitProfile.create(blueprint, modifiers)       the orchestrator of ONE unit: private deep clones + modifiers
   |- profile.stats            effective UnitStats (what `unit.stats.*` reads everywhere in the game code)
   |- profile.actions          effective specs (`ram()`, `spotter()`, `can(kind)`)
   '- stat(id) / base_stat(id) / params() / describe_params() / meta()
Unit.configure(profile_or_blueprint, team, colour)
```

* **Authored data is immutable.** `Tunable.clone()` deep-copies (unit -> weapons -> rounds) and remembers `origin`; `reset_to_origin()` puts a clone back,
  *in place*, so references to a weapon / round clone (toolbar entries, the gunnery panel) survive upgrades. `UnitStats.owns_weapon()` matches clone or origin.
  Gotcha: **packed arrays are passed by reference** - always `.duplicate()` before editing one (`weapon.charge_levels`), or the authored resource is corrupted.
* **What a unit can do is data.** `ToolEntry.build_for`, `ShootAction/DashAction/DroneAction.can_execute` and the AI read the profile's actions; a blueprint
  without `RAM` gives a unit that cannot ram, without `SPOTTER` one without a drone.
* **Action parameters belong to the action.** `RamSpec` (speed_mult, max_run, damage_mult, ap_cost_mult, armor_wear, knock_per_armor, knock_mass_exponent)
  and `SpotterSpec` (spotter_kind, reach, radius, ap_cost, cooldown_turns, duration_rounds) replaced the constants in `DashAction` / `DroneAction` and the
  drone fields of `UnitStats`.
* **The six units** (`tank`, `howitzer`, `infantry`, `mage`, `octo_cannon`, `ranger`) are mapped: `Factions.ROSTERS` lists blueprints, `Game._spawn_units`
  builds a profile per unit. Numbers are identical to before (smoke test: 283 checks unchanged).

## 4. Stats, modifiers, upgrades

**Everything tunable is an `@export` number on a `Tunable` resource** (`UnitStats`, `WeaponStats`, `RoundStats`, `RamSpec`, `SpotterSpec`, `BattleRules`).
`StatCatalog` reads those scripts by reflection: stat id = `<scope>.<variable>` (`unit.max_hp`, `weapon.muzzle_velocity`, `round.weight`, `ram.armor_wear`,
`spotter.reach`, `rules.rewind_charges`), label = the variable name, group = its `@export_group`, limits from `@export_range` else "never below 0"
(`*_deg` may be negative). Enums, strings, colours and resource references are settings, not stats. **A new `@export var x: float` is a stat the moment it
exists**; `tests/params_test.gd` fails if any exported number is missing from the catalog.

Bullet physics lives on the round (`weight` -> speed / wind drift, `restitution`, `friction`, `body_mass`, `body_damp`, `sub_impulse`, `sub_penetration_mult`,
`bounces`), unit body physics on the unit (`mass`, `friction`, `bounce`, `linear_damp`, `knockback_taken`), AP on the unit (`max_ap` per turn, `ap_carry` /
`ap_carry_cap` for unspent AP, `move_ap_per_weight`), defence on the unit (armor, `max_absorb`, `wear_*`, arcs, `damage_taken_mult`, burn numbers).

**A `StatModifier`** = stat id + op + value + `source` (the upgrade id) + optional `target` (an instance id: a weapon / round file stem) and `tag` filters.
Fold order per stat: `SET` (last wins) -> `ADD` (summed) -> `PERCENT` (summed, applied once) -> `SCALE` (each multiplies) -> clamp to the stat's limits
(ints rounded; bools react to SET only; arrays per element). Tags: authored `tags` plus implicit ones (weapon: `gunnery` / `burst`; round: its special,
`burning`; unit: `tank` / `infantry`).

**Re-derivation, not mutation.** `UnitProfile.rebuild()` = reset every clone from its origin, fold all modifiers again. `remove_source(id)` therefore undoes
an upgrade exactly. `Unit` listens to `profile.changed` (mass, collider, friction follow).

**Upgrades.** `Upgrade` (a `Tunable`: title, description, `modifiers[]`, `unit_ids` / `unit_tags` filter) -> `RunState` (static, survives scene changes:
`start()`, `add(upgrade)`, `unit_modifiers(blueprint)`, `rules()`). While a run is active `Game` builds the *player's* units' profiles with those modifiers and the
side's `BattleRules`; the AI and hot seat get nothing. No run, no behaviour change.

**Metadata for tools / menus.** `profile.meta()` = id, name, tags, blueprint `meta`, actions, weapons, active modifiers and `params()`;
`describe_params()` = one row per number (key, label, group, base, value, modified, sources, min, max). Keys: `unit.max_hp`, `weapon:tank_cannon.muzzle_velocity`,
`round:tank_cannon/ap.weight`, `ram.armor_wear`, `spotter.reach`.

### Recipes
* **New stat**: add an `@export var` (with `@export_group` / `@export_range`) to the right resource, read it where it matters. Set the default to the old behaviour.
* **New unit**: a `UnitStats` .tres (+ weapons / rounds), a blueprint .tres in `data/blueprints/` (actions + `meta`), list it in `Factions.ROSTERS`.
* **New action kind**: add to `ActionSpec.Kind`, a spec subclass if it has numbers (+ add the script to `StatCatalog.scopes()`), an `Action` subclass, a `ToolEntry.build_for` case,
  `PlayerController` input, AI use if wanted; choose `reversibility()`.
* **New upgrade**: `Upgrade.make(&"id", "Title", [StatModifier.make(&"weapon.blast_damage", StatModifier.Op.PERCENT, 0.2, &"", &"", &"explosive")], [], ["tank"])`,
  `RunState.start(); RunState.add(u)`.

## 5. Composition root and context

`Game` builds everything in code and fills a `BattleContext` (`board`, `view`, `guide`, `wind`, `intel`, `camera`, `state`, `units`, `history`, `rules_for(team)`,
`viewer_team`...). Actions and controllers reach the world only through it. Views subscribe to the model's signals (`terrain_changed`, `prop_damaged`,
`prop_destroyed`, `prop_restored`); the model never knows the views.

## 6. UI conventions (Rev 21)

* **Gentle popup** (`Toolbar.show_popup(text, hold)`): a small slate panel above the bar that fades in, holds and fades out by itself, never takes mouse input. Use it for
  reminders, `Toolbar.flash` stays for refusals (red). `PlayerController._update_end_turn_hint()` shows it once when the unit can afford nothing but moving or ramming
  (`_only_move_or_ram_left()`: no weapon / spotter slot affordable, spotter cooldown counted; a unit whose toolbar is only Move / Ram never triggers it) and re-arms when
  options come back (an undo, a new unit).
* **How to play** (`HowToPlayScreen`, `scripts/ui/how_to_play_screen.gd`): modal overlay, three pages (BASICS, MOVEMENT, GUNNERY SCREEN) of BBCode text, the gunnery page with
  a numbered miniature of the real panel (`HowToPlayScreen.Diagram`, drawn from `GunneryPanel`'s own rectangles). Terrain costs in the text come from `Terrain`, so they cannot drift;
  the key lists are hand-written - **keep them in step with `PlayerController` / `GunneryPanel` / `Game` when keys change**. Opened by the start menu's HOW TO PLAY button / F1 and by
  F1 in a battle (`Game._open_how_to_play`, own CanvasLayer 30). Esc / Enter / F1 close, Left / Right / Tab / 1-3 switch pages.

## Known limits / ideas
* Weapon / action **grants** from upgrades (adding a weapon) are structural, not numeric: not modelled yet (the profile's `rebuild()` keeps structure fixed).
* AP gained from events (kills, overwatch) is not a stat yet; AP is per-turn grant + carry-over.
* World rules stay constants (explosion falloff / crater factor, fire spread, `Intel` ring widths, `OUTER_BAND`): they are not per-unit. Promote one to a stat by moving it onto a resource.
* No UI to start a run or pick upgrades; `RunState` is API only. No difficulty scaling for the AI side (it would reuse `UnitProfile.create(bp, modifiers)`).
* The gunnery panel draws a target's hull arcs with the default 50 / 130 degrees (it works from logged shots, not live units).
* Undo history is per turn; hot seat has the free move undo only.
* How to play is static text: no pictures of the world, no tutorial battle, no in-battle pause.

## Tests
`tests/smoke_test.gd` (world, 283 checks), `tests/fantasy_test.gd` (80), `tests/params_test.gd` (catalog, modifiers, blueprints, wiring, upgrades, rules; 59),
`tests/undo_test.gd` (history, both take-back functions, restore of moves / shots / spotters / props / fires, rules, window, the turn loop, live key input; 58),
`tests/ui_test.gd` (how-to-play pages and entry points, the end-turn popup; 31). Run each with
`godot --headless --path . --script res://tests/<name>_test.gd` (run `--headless --path . --import --quit` after adding a `class_name`).
