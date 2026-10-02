class_name VictoryScreen
extends Control
## End-of-battle overlay: VICTORY / DEFEAT (1 player) or the winning player (hot seat) / DRAW, a per-side stats table
## from GameState.totals, and REMATCH (new map, same setup) / SHOT HISTORY (the shot review with every side's data) /
## VIEW BATTLEFIELD / MAIN MENU. "View battlefield" hides the
## panel so the player can look at the final position and open the shot review (H); Enter brings the results back.

signal rematch_pressed
signal menu_pressed
signal history_pressed

const GOLD := Color(1.0, 0.85, 0.40)

var _panel := PanelContainer.new()
var _shown := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false


## Builds the panel for the finished battle and shows it.
func present(winner: int, state: GameState, ctx: BattleContext) -> void:
	for child in get_children():
		child.queue_free()
	var shade := ColorRect.new()
	shade.color = Color(0.03, 0.04, 0.07, 0.62)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UiTheme.panel_style(24))
	centre.add_child(_panel)
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(520.0, 0.0)
	col.add_theme_constant_override("separation", 10)
	_panel.add_child(col)

	var headline := _headline(winner)
	col.add_child(UiTheme.label(headline[0], headline[1], UiTheme.LARGE, HORIZONTAL_ALIGNMENT_CENTER))
	if headline[2] != "":
		col.add_child(UiTheme.label(headline[2], headline[1], UiTheme.SMALL, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(_table(state, ctx))
	col.add_child(UiTheme.label(_summary_line(state), Color(0.80, 0.85, 0.95), UiTheme.SMALL, HORIZONTAL_ALIGNMENT_CENTER))

	var rematch := UiTheme.button("REMATCH (NEW MAP)", Color(0.55, 0.85, 0.55))
	rematch.pressed.connect(rematch_pressed.emit)
	col.add_child(rematch)
	var history := UiTheme.button("SHOT HISTORY", Color(0.62, 0.66, 0.78), UiTheme.SMALL)
	history.pressed.connect(history_pressed.emit)
	col.add_child(history)
	var look := UiTheme.button("VIEW BATTLEFIELD", Color(0.62, 0.66, 0.78), UiTheme.SMALL)
	look.pressed.connect(hide_results)
	col.add_child(look)
	var menu := UiTheme.button("MAIN MENU", Color(0.62, 0.66, 0.78), UiTheme.SMALL)
	menu.pressed.connect(menu_pressed.emit)
	col.add_child(menu)
	_shown = true
	visible = true


func is_open() -> bool:
	return visible


func hide_results() -> void:
	visible = false


## Brings the panel back after something else (the shot history) covered it.
func show_results() -> void:
	visible = _shown


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if _shown and not visible and key != null and key.pressed and not key.echo \
			and (key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER):
		visible = true
		get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if visible and event is InputEventKey:
		get_viewport().set_input_as_handled()   # keep the battle's hotkeys quiet behind the results


## [title, colour, subtitle]
func _headline(winner: int) -> Array:
	if winner == TurnManager.DRAW:
		return ["DRAW", Color(0.80, 0.82, 0.88), "NOBODY IS LEFT STANDING"]
	var tint := BattleConfig.color_of(winner)
	if BattleConfig.two_player:
		return ["VICTORY", tint, "%s WINS" % BattleConfig.name_of(winner)]
	if winner == BattleConfig.p1_team:
		return ["VICTORY", tint.lightened(0.2), "ALL ENEMY UNITS DESTROYED"]
	return ["DEFEAT", tint, "THE AI HOLDS THE FIELD"]


func _table(state: GameState, ctx: BattleContext) -> Control:
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 28)
	grid.add_theme_constant_override("v_separation", 4)
	var teams: Array[int] = [BattleConfig.p1_team, BattleConfig.other(BattleConfig.p1_team)]
	grid.add_child(UiTheme.label(""))
	for t in teams:
		grid.add_child(_cell(BattleConfig.name_of(t), BattleConfig.color_of(t), HORIZONTAL_ALIGNMENT_RIGHT))
	var rows := [
		["SURVIVORS", func(t: int) -> String: return "%d / %d" % [_count(ctx, t, true), _count(ctx, t, false)]],
		["DAMAGE DEALT", func(t: int) -> String: return "%d" % roundi(state.totals["damage_dealt"][t])],
		["KILLS", func(t: int) -> String: return "%d" % state.totals["kills"][t]],
	]
	for row: Array in rows:
		grid.add_child(_cell(row[0], Color(0.75, 0.80, 0.90), HORIZONTAL_ALIGNMENT_LEFT))
		for t in teams:
			grid.add_child(_cell((row[1] as Callable).call(t), Color.WHITE, HORIZONTAL_ALIGNMENT_RIGHT))
	var holder := CenterContainer.new()
	holder.add_child(grid)
	return holder


func _cell(text: String, color: Color, align: HorizontalAlignment) -> Label:
	var l := UiTheme.label(text, color, UiTheme.SMALL, align)
	l.custom_minimum_size = Vector2(150.0 if align == HORIZONTAL_ALIGNMENT_LEFT else 110.0, 0.0)
	return l


## Units of `team` still alive (`alive_only`) or fielded in total.
func _count(ctx: BattleContext, team: int, alive_only: bool) -> int:
	var n := 0
	for u in ctx.units:
		if u.team == team and (u.is_alive() or not alive_only):
			n += 1
	return n


func _summary_line(state: GameState) -> String:
	var t := state.totals
	var s := "ROUNDS %d   SHOTS %d   LONGEST %.0f M" % [state.rounds_played, t["shots"], t["longest_shot"]]
	if t["friendly_damage"] > 0.5:
		s += "   FRIENDLY FIRE %d" % roundi(t["friendly_damage"])
	return s
