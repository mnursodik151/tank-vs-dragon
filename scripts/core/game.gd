class_name Game
extends Node3D
## Prototype bootstrap: builds the hex board, spawns units, wires controllers, starts the battle.
## Headless smoke test (user args after "--"):
##   godot --headless --path . -- --ai-vs-ai --fast --quit-on-end

const TANK: UnitStats = preload("res://data/tank.tres")
const HOWITZER: UnitStats = preload("res://data/howitzer.tres")
const INFANTRY: UnitStats = preload("res://data/infantry.tres")

const BOARD_SIZE := Vector2i(28, 22)   # columns x rows (offset layout)
const HEX_SIZE := 1.0                  # hex circumradius, metres
const MENU_SCENE := "res://scenes/start_menu.tscn"
const VICTORY_DELAY := 1.4             # seconds between the last blast and the results screen

## Test / replay hooks: a seed >= 0 fixes the composed map (also `--seed=N`); these cells never get props.
static var forced_seed := -1
static var extra_keep_clear: Array[Vector2i] = []
static var flat_ground := false   ## test hook: compose the map without hills

## Pan the camera to the enemy's units when their turn starts (toggle: P). Your own turns always pan.
var enemy_turn_pan := true
var _args := OS.get_cmdline_user_args()
var _board: GridBoard
var _layout: SceneLayout
var _ctx := BattleContext.new()
var _turns := TurnManager.new()
var _view := BoardView.new()
var _guide := GuideView.new()
var _sight := SightView.new()
var _camera := TacticsCamera.new()
var _state := GameState.new()
var _player := PlayerController.new()
var _ai := AIController.new()
var _hot_seat := HotSeatController.new()   # wraps _player when two people share the screen
var _handoff := HandoffScreen.new()        # hot seat: cover between the players' turns
var _victory := VictoryScreen.new()
var _review := ShotReview.new()
var _history_from_results := false          # the review was opened from the victory screen and should return to it
var _hud := Label.new()      # status lines
var _hud_help := Label.new()   # settings + key cheat-sheet
var _result := ""
var _fire_rng := RandomNumberGenerator.new()
## Where each side's three units start (offset cells), in roster order: main unit, artillery piece, scout (see Factions).
const SPAWN_CELLS := {
	0: [Vector2i(9, 5), Vector2i(14, 3), Vector2i(17, 6)],
	1: [Vector2i(18, 16), Vector2i(13, 18), Vector2i(9, 16)],
}
var _spawns := {}   # team -> [[UnitStats, cell], ...], filled from the factions picked in the menu (`_make_spawns`)


func _ready() -> void:
	if _args.has("--fast"):
		Engine.time_scale = 3.0
	_read_faction_args()
	_make_spawns()
	_fire_rng.randomize()
	_build_environment()
	_layout = _compose_scene()
	_build_board()
	_spawn_units()
	_build_camera()
	_build_hud()
	add_child(_guide)
	add_child(_state)
	_sight.setup(_ctx, BattleConfig.p1_team)
	add_child(_sight)
	_ctx.guide = _guide
	_ctx.root = self
	_ctx.camera = _camera
	_ctx.state = _state

	for node: Node in [_turns, _player, _ai, _hot_seat]:
		add_child(node)

	var ai_vs_ai := _args.has("--ai-vs-ai")
	_set_viewer(-1 if ai_vs_ai else BattleConfig.p1_team)   # nobody is watching in AI vs AI; hot seat switches per turn
	_turns.verbose = ai_vs_ai
	_turns.battle_over.connect(_on_battle_over)
	_turns.round_started.connect(_on_round_started)
	_turns.turn_started.connect(_on_turn_started)
	_victory.rematch_pressed.connect(func() -> void: get_tree().reload_current_scene())
	_victory.menu_pressed.connect(func() -> void: get_tree().change_scene_to_file(MENU_SCENE))
	_victory.history_pressed.connect(_open_history)
	_review.closed.connect(_on_review_closed)
	_turns.start(_ctx, _make_controllers(ai_vs_ai))


## `--p1-faction=fantasy` / `--p2-faction=modern` (user args) set the factions without the menu (headless AI battles, tests).
func _read_faction_args() -> void:
	for arg: String in _args:
		var faction := Factions.parse(arg.get_slice("=", 1))
		if faction < 0:
			continue
		if arg.begins_with("--p1-faction="):
			BattleConfig.p1_faction = faction
		elif arg.begins_with("--p2-faction="):
			BattleConfig.p2_faction = faction


## The spawn table: every team's roster (its faction's unit types) on that team's start cells.
func _make_spawns() -> void:
	_spawns.clear()
	for team: int in SPAWN_CELLS:
		var roster := Factions.roster(BattleConfig.faction_of(team))
		var entries := []
		for i in roster.size():
			entries.append([roster[i], SPAWN_CELLS[team][i]])
		_spawns[team] = entries


## Who decides for each team: the player against the AI (on the side picked in the menu), two people behind the
## hand-off cover, or the AI for both (--ai-vs-ai).
func _make_controllers(ai_vs_ai: bool) -> Dictionary:
	if ai_vs_ai:
		return {0: _ai, 1: _ai}
	if BattleConfig.two_player:
		_hot_seat.inner = _player
		_hot_seat.handoff = _handoff
		return {0: _hot_seat, 1: _hot_seat}
	return {BattleConfig.p1_team: _player, BattleConfig.other(BattleConfig.p1_team): _ai}


## Whose eyes the screen uses (-1 = everyone's): fog, the line-of-sight overlay and the shot review all follow.
func _set_viewer(team: int) -> void:
	_ctx.viewer_team = team
	_sight.viewer_team = maxi(team, 0)
	_review.viewer_team = maxi(team, 0)
	_update_fog()


## The victory screen's SHOT HISTORY: the shot review (full data for every side after the battle) over the board; closing it
## brings the results back.
func _open_history() -> void:
	_history_from_results = true
	_victory.hide_results()
	_review.open_history()


func _on_review_closed() -> void:
	if _history_from_results:
		_history_from_results = false
		_victory.show_results()


func _team_name(team: int) -> String:
	return "TEAM %d" % team if _args.has("--ai-vs-ai") else BattleConfig.name_of(team)


## The camera glides to whoever's turn it starts (zoom is kept). Your own turns always pan, so you never
## start off-screen; panning to the enemy's turns can be switched off with P. In hot seat the screen switches to the
## new player's eyes first (the hand-off cover is already up by the time the board can be seen).
func _on_turn_started(unit: Unit) -> void:
	if not unit.is_alive():
		return
	if BattleConfig.two_player and not _args.has("--ai-vs-ai"):
		_set_viewer(unit.team)
	var own_turn := _ctx.viewer_team == unit.team
	# never glide to an enemy the player cannot see: that would give its position away
	if own_turn or (enemy_turn_pan and _ctx.visible_to_viewer(unit)):
		_camera.focus_on(unit.global_position)


## Each round the wind shifts a little and fires burn down / spread (downwind more likely).
func _on_round_started(_n: int) -> void:
	_ctx.wind.drift()
	_board.tick_fires(_ctx.wind.direction() * (_ctx.wind.speed / Wind.MAX_SPEED), _fire_rng)


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_R:
			get_tree().reload_current_scene()
		KEY_G:
			_view.toggle_grid()
		KEY_V:
			_camera.shot_cam_enabled = not _camera.shot_cam_enabled
		KEY_L:
			_sight.visible = not _sight.visible
		KEY_P:
			enemy_turn_pan = not enemy_turn_pan



## Enemy units outside the viewer's line of sight vanish from the screen (model, label, ring).
func _update_fog() -> void:
	for u in _ctx.units:
		u.set_concealed(u.is_alive() and not _ctx.visible_to_viewer(u))


func _process(_delta: float) -> void:
	_update_fog()
	var unit := _turns.current_unit
	var lines := PackedStringArray()
	var help := PackedStringArray()
	lines.append("Round %d  |  %s" % [_turns.round_number, TurnManager.State.keys()[_turns.state]])
	if unit != null and unit.is_alive() and not unit.is_concealed():
		lines.append("%s (%s)  HP %d/%d  AP %.1f" % [
			unit.stats.display_name, _team_name(unit.team), ceili(unit.hp), unit.stats.max_hp, unit.ap])
		_guide.show_disc("active", Vector3(unit.global_position.x, _board.surface_y(unit.global_position) + 0.03, unit.global_position.z),
			unit.stats.radius + 0.25, Color(unit.team_color, 0.6))
	else:
		_guide.hide_disc("active")
		if unit != null and unit.is_alive():
			lines.append("Enemy turn - out of sight")
	help.append("Tool: %s   Grid: %s   Shot cam: %s" % [_player.tool_label(), "on" if _view.grid_visible else "off",
		"on" if _camera.shot_cam_enabled else "OFF"])
	help.append("Enemy-turn pan: %s [P]   Map seed: %d (--seed=N replays it)" % ["on" if enemy_turn_pan else "off", _layout.seed])
	help.append("[1-9] Toolbar  [G] Grid  [V] Shot cam  [L] Line of sight  [H] Shot review  [Space] End turn  [R] Restart")
	help.append("WASD pan   Q/E rotate   Wheel zoom")
	if _result != "":
		lines.append(_result + ("" if _victory.is_open() else "   [Enter] results"))
	_hud.text = "\n".join(lines)
	_hud_help.text = "\n".join(help)


func _on_battle_over(team: int) -> void:
	_result = "DRAW" if team == TurnManager.DRAW else "%s WINS" % _team_name(team)
	_state.battle_finished(team, _turns.round_number)
	_ctx.reveal_all = true   # the fog lifts: show where everybody ended up
	if _args.has("--ai-vs-ai"):
		for line in _state.summary_lines():
			print(line)
	if _args.has("--quit-on-end"):
		get_tree().quit()
		return
	# let the last blast play out before the results cover the board (a SceneTreeTimer connection dies with this node)
	get_tree().create_timer(VICTORY_DELAY).timeout.connect(_victory.present.bind(team, _state, _ctx))


# --- scene construction -----------------------------------------------------

func _build_environment() -> void:
	Atmosphere.build(self)


## Rolls a fresh map (hills, foliage + undergrowth) around the spawn points. Unit spawns are fixed for now; the
## composer is where spawn points and objectives will be chosen later.
func _compose_scene() -> SceneLayout:
	var composer := SceneComposer.new()
	composer.board_size = BOARD_SIZE
	composer.hex_size = HEX_SIZE
	for team: int in _spawns:
		for entry: Array in _spawns[team]:
			composer.reserved.append(entry[1])
	composer.keep_clear = extra_keep_clear
	if flat_ground:
		composer.hills = Vector2i.ZERO
	var seed := forced_seed
	for arg: String in _args:
		if arg.begins_with("--seed="):
			seed = int(arg.get_slice("=", 1))
	if seed < 0:
		seed = int(_fire_rng.randi() & 0xFFFFFF)
	var layout := composer.compose(seed)
	if _args.has("--ai-vs-ai"):
		print("Scene seed %d: %s" % [layout.seed, layout.summary()])
	return layout


func _build_board() -> void:
	_board = GridBoard.new(BOARD_SIZE, HEX_SIZE)
	_layout.apply(_board)
	_view.build(_board)
	add_child(_view)
	_ctx.board = _board
	_ctx.view = _view


func _spawn_units() -> void:
	for team: int in _spawns:
		for entry: Array in _spawns[team]:
			var c := GridBoard.offset_to_axial(entry[1])
			var unit := Unit.new()
			unit.configure(entry[0], team, BattleConfig.color_of(team))
			add_child(unit)
			_board.place(unit, c)
			unit.snap_to(_board.cell_to_world(c, unit.rest_height()))
			unit.face(Vector3(0.0, 0.0, 1.0 if team == 0 else -1.0))
			_ctx.units.append(unit)


func _build_camera() -> void:
	_camera.focus = _board.world_center()
	add_child(_camera)
	_camera.make_current()


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var box := VBoxContainer.new()
	box.position = Vector2(16.0, 10.0)
	box.add_theme_constant_override("separation", 4)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(box)
	for pair: Array in [[_hud, UiTheme.SMALL], [_hud_help, UiTheme.SMALL]]:
		var label: Label = pair[0]
		label.add_theme_font_override("font", UiTheme.font)
		label.add_theme_font_size_override("font_size", pair[1])
		label.add_theme_color_override("font_outline_color", Color.BLACK)
		label.add_theme_constant_override("outline_size", 4)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(label)

	var wind_ui := WindIndicator.new()
	wind_ui.wind = _ctx.wind
	wind_ui.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	wind_ui.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	wind_ui.offset_top = 10.0
	wind_ui.offset_right = -10.0
	layer.add_child(wind_ui)

	var review_layer := CanvasLayer.new()   # above the toolbar and the gunnery panel
	review_layer.layer = 10
	add_child(review_layer)
	review_layer.add_child(_review)
	_review.setup(_state, _ctx)
	_review.can_open = func() -> bool: return not _player.is_busy() and not _handoff.visible and not _victory.visible

	# the hot-seat cover and the results sit on top of everything, added last so they see input first
	for pair: Array in [[_victory, 12], [_handoff, 20]]:
		var top := CanvasLayer.new()
		top.layer = pair[1]
		add_child(top)
		top.add_child(pair[0])
