class_name StartMenu
extends Control
## Start screen (the project's main scene): pick 1 player (vs the AI) or 2 players (hot seat), which side Player 1 takes,
## and the faction (modern / fantasy) and tint of each side. Writes the choices into `BattleConfig` and loads the battle scene.
## `--ai-vs-ai` / `--skip-menu` (user args) go straight to the battle with the current config.

const BATTLE_SCENE := "res://scenes/main.tscn"
const SLATE := Color(0.62, 0.66, 0.78)
const SELECTED := Color(1.0, 0.78, 0.30)
const SWATCH := Vector2(36.0, 36.0)

var _mode_buttons: Array[Button] = []
var _side_buttons: Array[Button] = []
var _swatches := {1: [], 2: []}      # player (1 / 2) -> Array[Button], one per palette colour
var _faction_buttons := {1: [], 2: []}   # player (1 / 2) -> Array[Button], one per Factions.Id
var _faction_notes := {1: UiTheme.label("", Color(0.75, 0.80, 0.90)), 2: UiTheme.label("", Color(0.75, 0.80, 0.90))}
var _mode_note := UiTheme.label("", Color(0.75, 0.80, 0.90))
var _side_title := UiTheme.label("", Color(0.75, 0.80, 0.90))
var _side_note := UiTheme.label("", Color(0.75, 0.80, 0.90))
var _p1_title := UiTheme.label("")
var _p2_title := UiTheme.label("")


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--ai-vs-ai") or args.has("--skip-menu"):
		_start.call_deferred()
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and (key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER):
		_start()


func _build() -> void:
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.09, 0.11, 0.15)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel_style(22))
	centre.add_child(panel)
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(560.0, 0.0)
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)

	col.add_child(UiTheme.label("TACTICS PROTO", Color(1.0, 0.85, 0.40), UiTheme.LARGE, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UiTheme.label("ARTILLERY SKIRMISH", Color(0.70, 0.75, 0.88), UiTheme.SMALL, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(_gap(6.0))

	col.add_child(UiTheme.label("MODE"))
	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", 8)
	col.add_child(modes)
	for i in 2:
		var b := UiTheme.button("1 PLAYER" if i == 0 else "2 PLAYERS", SLATE, UiTheme.SMALL)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_set_mode.bind(i == 1))
		modes.add_child(b)
		_mode_buttons.append(b)
	col.add_child(_mode_note)
	col.add_child(_gap(4.0))

	col.add_child(_side_title)
	var sides := HBoxContainer.new()
	sides.add_theme_constant_override("separation", 8)
	col.add_child(sides)
	for team in 2:
		var b := UiTheme.button("%s (spawns %s)" % [BattleConfig.side_name(team), "top" if team == 0 else "bottom"], SLATE, UiTheme.SMALL)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_set_side.bind(team))
		sides.add_child(b)
		_side_buttons.append(b)
	col.add_child(_side_note)
	col.add_child(_gap(4.0))

	col.add_child(UiTheme.label("FACTION AND TINT"))
	for player in [1, 2]:
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 8)
		col.add_child(head)
		var title: Label = _p1_title if player == 1 else _p2_title
		title.custom_minimum_size = Vector2(110.0, 0.0)
		title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		head.add_child(title)
		for f: int in Factions.Id.values():
			var fb := UiTheme.button(Factions.faction_name(f), SLATE, UiTheme.SMALL)
			fb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			fb.pressed.connect(_pick_faction.bind(player, f))
			head.add_child(fb)
			_faction_buttons[player].append(fb)
		col.add_child(_faction_notes[player])
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		col.add_child(row)
		for i in BattleConfig.PALETTE.size():
			var s := Button.new()
			s.focus_mode = Control.FOCUS_NONE
			s.custom_minimum_size = SWATCH
			s.pressed.connect(_pick_color.bind(player, i))
			row.add_child(s)
			_swatches[player].append(s)
	col.add_child(_gap(8.0))

	var start := UiTheme.button("START BATTLE", Color(0.55, 0.85, 0.55))
	start.pressed.connect(_start)
	col.add_child(start)
	var extras := HBoxContainer.new()
	extras.add_theme_constant_override("separation", 8)
	col.add_child(extras)
	var credits := UiTheme.button("CREDITS", SLATE, UiTheme.SMALL)
	credits.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	credits.pressed.connect(_show_credits)
	extras.add_child(credits)
	if not OS.has_feature("web"):    # a browser tab cannot be quit from the game
		var quit := UiTheme.button("QUIT", SLATE, UiTheme.SMALL)
		quit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		quit.pressed.connect(func() -> void: get_tree().quit())
		extras.add_child(quit)
	col.add_child(UiTheme.label("[Enter] start", Color(0.6, 0.65, 0.75), UiTheme.SMALL, HORIZONTAL_ALIGNMENT_CENTER))


func _gap(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0.0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# --- choices ------------------------------------------------------------------

func _set_mode(two_player: bool) -> void:
	BattleConfig.two_player = two_player
	_refresh()


func _set_side(team: int) -> void:
	BattleConfig.p1_team = team
	_refresh()


func _pick_faction(player: int, faction: int) -> void:
	if player == 1:
		BattleConfig.p1_faction = faction
	else:
		BattleConfig.p2_faction = faction
	_refresh()


func _pick_color(player: int, index: int) -> void:
	var c := BattleConfig.PALETTE[index]
	if player == 1:
		BattleConfig.p1_color = c
	else:
		BattleConfig.p2_color = c
	_refresh()


func _refresh() -> void:
	var two := BattleConfig.two_player
	_mode_note.text = "Hot seat: take turns on this screen - a cover hides the board between turns." if two \
		else "You against the AI."
	_side_title.text = "PLAYER 1 SIDE" if two else "YOUR SIDE"
	_side_note.text = "%s takes the %s side." % ["Player 2" if two else "The AI", BattleConfig.side_name(BattleConfig.other(BattleConfig.p1_team)).to_lower()]
	_p1_title.text = BattleConfig.name_of(BattleConfig.p1_team)
	_p2_title.text = BattleConfig.name_of(BattleConfig.other(BattleConfig.p1_team))
	_p1_title.add_theme_color_override("font_color", BattleConfig.p1_color)
	_p2_title.add_theme_color_override("font_color", BattleConfig.p2_color)
	for i in _mode_buttons.size():
		_style_toggle(_mode_buttons[i], (i == 1) == two)
	for i in _side_buttons.size():
		_style_toggle(_side_buttons[i], i == BattleConfig.p1_team)
	for player in [1, 2]:
		var faction := BattleConfig.p1_faction if player == 1 else BattleConfig.p2_faction
		for f in _faction_buttons[player].size():
			_style_toggle(_faction_buttons[player][f], f == faction)
		(_faction_notes[player] as Label).text = Factions.BLURBS[faction]
		var mine := BattleConfig.p1_color if player == 1 else BattleConfig.p2_color
		var theirs := BattleConfig.p2_color if player == 1 else BattleConfig.p1_color
		for i in BattleConfig.PALETTE.size():
			var c := BattleConfig.PALETTE[i]
			var s: Button = _swatches[player][i]
			var taken := c.is_equal_approx(theirs)    # the other side wears it: two identical tints are indistinguishable
			s.disabled = taken
			s.tooltip_text = "Used by the other side" if taken else ""
			_style_swatch(s, c, c.is_equal_approx(mine), taken)


func _style_toggle(b: Button, on: bool) -> void:
	var tint := SELECTED if on else SLATE
	b.add_theme_stylebox_override("normal", UiTheme.box("Button01a_1" if on else "Button01a_4", 5, tint))
	b.add_theme_stylebox_override("hover", UiTheme.box("Button01a_1" if on else "Button01a_4", 5, tint.lightened(0.25)))


func _style_swatch(s: Button, c: Color, selected: bool, taken: bool) -> void:
	for state in ["normal", "hover", "pressed", "disabled"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = c.darkened(0.55) if taken else (c.lightened(0.15) if state == "hover" else c)
		sb.set_border_width_all(4 if selected else 2)
		sb.border_color = Color.WHITE if selected else Color(0.10, 0.11, 0.15)
		s.add_theme_stylebox_override(state, sb)


func _show_credits() -> void:
	add_child(CreditsScreen.new())


func _start() -> void:
	get_tree().change_scene_to_file(BATTLE_SCENE)
