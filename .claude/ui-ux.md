# UI / UX

Snapshot as of Rev 7. All UI is code-built (no `.tscn` UI, no `Theme`): custom `_draw()` Controls for the toolbar, gunnery panel, wind compass and shot review; world-space
overlays (`GuideView`, `SightView`, `BoardView` highlights, `Label3D` popups) for in-world feedback. Related: [actor-controls-and-actions.md](actor-controls-and-actions.md)
(what the player controller does with these), [gamestate-and-scene-manager.md](gamestate-and-scene-manager.md), [implementation-notes.md](implementation-notes.md).

> **Rev 15 look**: all text is the m6x11plus pixel font at 16 / 32 px and panels, buttons, slots and bars are Flat_Theme 9-slice sprites via `UiTheme` (see implementation-notes Rev 15). Font sizes quoted below are the old pre-Rev-15 numbers; the gunnery panel is now 1004x440 and scales in whole steps only.

## Design principles in play
- **Guesswork on purpose.** The world shows only a coarse bearing; the gunnery panel gives still-air estimates only (no wind, no terrain, no gun error), distances to enemies are *measured with noise*
  (`Intel`), and enemy shots in the review show only marker + trajectory. UI must never reveal the true landing point before the shot.
- **Everything is drawn, not themed** - fixed colour language: gold/yellow = selected / active / your bearing, mint/green = friendly, sight, OK, blue = ally, red = enemy / unaffordable / error,
  light blue = AP cost, ammo colours come from `RoundStats.color`.
- **Input ownership**: world input goes through `_unhandled_input`; the toolbar slots and the panel consume their own clicks, so nothing leaks. The gunnery panel and shot review each swallow input while open.

## Screen layout (1280x720 design size)
```
+--------------------------------------------------------------+
| HUD text (top-left, Game._hud)                 WIND compass  |  CanvasLayer default
|                                                (top-right)   |
|                                                              |
|          3D board (orthographic 45 deg camera)               |
|                                                              |
|        [ GUNNERY PANEL: ammo+charges / side view / radar /   |  CanvasLayer 5 (PlayerController._ui)
|          wind box / power bar ]  - opens above the toolbar    |
|   notice ("Not enough AP...")                                |
|   AP 6.0 / 8.0                                               |
|   [1 Move][2 Cannon][3 MG][4 Ram]   <- Toolbar (bottom centre)|
+--------------------------------------------------------------+
  SHOT REVIEW (H): full-screen overlay on CanvasLayer 10
```

### HUD text (`Game._process`, top-left label with black outline)
Lines: `Round n | STATE`, active unit `name (team) HP x/y AP z`, `Tool / Grid / Shot cam`, `Enemy-turn pan / Map seed`, the hotkey cheat-sheet, `WASD pan  Q/E rotate  Wheel zoom`, and the result
("TEAM n WINS" / "DRAW"). The active unit also gets a team-coloured ground ring (`GuideView` disc "active").

### Toolbar (`toolbar.gd`, `tool_slot.gd`, `tool_entry.gd`)
MMO-style hotbar, bottom-centre. One `ToolSlot` (80x84) per `ToolEntry`: Move, each weapon (main first), Drone (spotters), Ram. A slot draws its hotkey number (gold, top-left), AP cost (top-right, light blue,
red when unaffordable), a procedural glyph (`move, cannon, howitzer, rocket, mg, rifle, drone, ram`), and its name. States: normal / hover / selected (gold 3 px border); unaffordable = dimmed tint; drone
cooldown = dark overlay with "CD n turns". Above the bar: `AP x / max` (offset -102) and a fading notice label (`flash(text)`, red, 0.9 s + 0.5 s fade, offset -128). `Toolbar.refresh(unit)` runs every frame while it is the player's turn.
The cost shown is the weapon's *base* AP (charges are only priced in the panel). Only slots 1-9 get hotkeys.

### Wind compass (`wind_indicator.gd`)
Top-right corner; arrow rotated with the camera (`to_screen_dir`), length and colour (green -> orange) scale with speed, "WIND" and "x.x m/s" text. Redraws every frame.

### Gunnery panel (`gunnery_panel.gd`, 1004x404 design size = 780 controls + 212 "last shot" sidebar, scaled up to fit, max 1.5x)
Opened by clicking a GUNNERY weapon (terrain-aware: arc ends on hills, ground silhouette, min elevation from ground ahead, radar relief tint - see implementation-notes Rev 8); returns `FireParams` or null. Regions (unscaled px):
- **Top strip**: title, key legend, AP, round buttons (T / Shift+T / click; short names, ammo colours), charge pips (C / click; red when unaffordable), `COST x AP (base + n charges)`, weight -> speed -> wind multipliers, round description.
- **Elevation (left, side view)**: dial with 5/10 degree ticks within the weapon's pitch limits, drag / mouse wheel (1 deg) / Up-Down (18 deg/s). Ruler picks a bucket (8..64 m) from the full-power range.
  Estimated still-air arc in the barrel plane with landing cross and `EST x m`, text `ELEVATION x deg` and the estimate hint ("full power" until the player starts charging).
- **Traverse (right, radar)**: top-down disc that follows the camera orientation; range rings (5 or 10 m), the allowed traverse fan around the world bearing, C1/C2/C3 reach ticks with a `C1 8m` readout under the disc,
  yellow line of sight, sight shading (own sight discs minus tree/rock shadows, drone/impact areas) and prop discs, friendly blips (blue, true place), foe blips (red, *measured* distance on the true bearing, dimmed when clipped to the rim) - ONLY for enemies inside the team's line of sight, unseen ones are not drawn at all (Rev 14). Drag inside or Left/Right (8 deg/s) to traverse; `TRAVERSE +x.x deg` readout.
- **Wind box (far right)**: compass with barrel marker + wind arrow, speed, TAIL/HEAD and CROSS L/R components, "not in estimate".
- **Power bar (bottom)**: hold Space (or press and hold on the bar) to charge (`charge_time` seconds to full), release to fire; auto-fires at 100%; minimum-power marker; Esc / right click cancels.
- **Last-shot sidebar (right, Rev 14)**: this unit's previous gunnery shot - LAST vs NOW table (round / charge / yaw / elevation / power), range + flight time, wind then vs now (TAIL|HEAD, CROSS L|R), "same firing position" / "gun moved x m", and a top-down RESULT view of the hit in the gun's frame (up = down-range): target footprint + hull heading, white X for the shell, one circle per blast that reached the target (bomblets, incendiary fire ring), then damage / armor / "x m short|long, y m left|right". Details in implementation-notes Rev 14.
- Remembers round + charge per weapon (`_memory`); starts with the highest affordable charge <= remembered. Layout constants are hard-coded; `_fit_to_viewport` only scales uniformly and centres.

### Shot review (`shot_review.gd`) - H
Full-screen dark overlay: fixed-orientation top-down map (hex cells coloured by terrain/props, unit discs), every `GameState.shots` trajectory + impact cross (older shots fade), list (newest first, 22 px rows),
details box. Allied shots show setup, wind, range, flight time, per-unit results (sector/outcome/damage/armor before > after) and a side profile; enemy shots only a marker and path ("No data on enemy weapons").
Keys: Up/Down or click to select, F filter (ALL/ALLIES/ENEMIES), wheel scroll, H/Esc/right click close; clicking the map picks the nearest impact. `can_open` is set by `Game` to `not _player.is_busy()` so it cannot open over the gunnery panel.
It handles `_input` (not unhandled), so it also eats Space/WASD while open.

## World-space feedback
- `GuideView` (named slots, created on demand): `show_dots(slot, points, color)` (re-sampled dotted line, MultiMesh), `show_disc`, `show_label`, `clear(keep)`. Used for move paths, bearing + crosshair, drone range/area, active-unit ring.
- `BoardView`: hex floor, terrain patches (craters with pit, flickering fire), toggleable grid (G), `show_highlight(cells, color)` for reach / ram targets, `mouse_ground_point(plane_y)`.
- `SightView` (L toggles, default on): shader overlay of the viewing team's line of sight - mint edge, haze outside, shadow wedges behind trees/large rocks; up to 24 sources and 64 occluders.
- `FloatingText.spawn`: billboard `Label3D` popups that rise and fade ("BURNING -1", "SPOTTED", "DRONE ON STATION", armor results from `Explosion`).
- Unit `Label3D` (HP/AP/armor/BURNING, billboard, no depth test) above each unit.
- Shell visuals: `Shell`, `ShotTrail` (camera-facing fading ribbon), explosion flashes/decals, `Drone` model with beam + ring.

## Camera (`tactics_camera.gd`)
Orthographic, fixed 45 deg pitch, yaw 45 deg stepped by 90 deg with Q/E, WASD pan (speed scales with zoom), wheel zoom (size 6..60, start 32). Modes: IDLE / FOLLOW (shot cam, zoom 12, tracks the shell) / HOLD (1.1 s on impact) /
RETURN (eases back; also used for the turn-start `focus_on` glide). `V` disables the shot cam, `P` the enemy-turn pan. Helpers `to_screen_dir` / `from_screen_dir` keep the radar, compass and
shot review traverse in the camera's orientation. Q/E and WASD still move the camera while the gunnery panel is open (the radar follows).

## Controls cheat-sheet
| Context | Keys |
|---|---|
| Always | `R` restart (new map), `G` grid, `V` shot cam, `L` line of sight, `P` enemy-turn pan, `H` shot review, `WASD` pan, `Q/E` rotate, wheel zoom |
| Player turn | `1-9` / click tool, left click use, `Space`/`Enter` end turn |
| Gunnery panel | Up/Down elevation, Left/Right traverse, `T` / `Shift+T` round, `C` charge, hold `Space` power, release fire, `Esc` / right click cancel, drag dial / radar, wheel elevation |
| Shot review | Up/Down / click select, `F` filter, wheel scroll, `H` / `Esc` close |

## UX gaps / ideas
- Start menu, hot-seat cover and victory screen exist since Rev 16 (see implementation-notes Rev 16; `Control`-based, styled through `UiTheme.button/panel_style/label`). Still missing: pause, settings, tutorial, back-to-menu mid-battle (`R` restarts), no turn-order or unit-info panel, no tooltips beyond the toolbar flash messages.
- Layouts are hard-coded for ~1280x720 (the gunnery panel scales uniformly, the toolbar and HUD do not); no `Theme`, no localisation, fonts are the engine fallback font.
- No controller / touch support; hotkeys 1-9 only; no key rebinding.
- The player gets no feedback about enemy turns beyond the camera pan and the world (no "enemy is firing" banner, enemy shots only visible via the shot review / shot camera).
- The toolbar shows base AP, not the charge-adjusted cost; Move shows no cost until hover.
- Estimates deliberately omit wind/terrain; a possible UX layer is a "last shot" marker / spotting-round memory (listed in implementation-notes known gaps).
- Accessibility: colour is the main signal (red vs green), no colour-blind palette, small fonts (9-14 px) in the panel.
