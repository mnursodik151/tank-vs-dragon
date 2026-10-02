class_name HandoffScreen
extends Control
## Hot-seat cover: a fully opaque screen shown whenever the turn passes to the other player, so nobody reads the
## previous player's view of the board. `await run(team, unit, ctx, report)` returns once the next player has confirmed
## the cover (button / Enter / Space) and, when enemy fire since their last turn hit them or landed in sight,
## the damage report that follows it (see TurnReport). While shown it swallows all input, so nothing (camera keys,
## restart, shot review) reaches the battle.

signal confirmed

const HIT_COLOR := Color(1.0, 0.45, 0.40)

var _title := UiTheme.label("", Color.WHITE, UiTheme.LARGE, HORIZONTAL_ALIGNMENT_CENTER)
var _line := UiTheme.label("", Color(0.80, 0.85, 0.95), UiTheme.SMALL, HORIZONTAL_ALIGNMENT_CENTER)
var _cover := PanelContainer.new()
var _report := PanelContainer.new()
var _report_body := VBoxContainer.new()   # rebuilt for every report
var _map := ReportMap.new()
var _button := UiTheme.button("READY")
var _continue := UiTheme.button("CONTINUE")


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.07, 0.08, 0.11, 1.0)   # opaque on purpose
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)

	_cover.add_theme_stylebox_override("panel", UiTheme.panel_style(24))
	centre.add_child(_cover)
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(440.0, 0.0)
	col.add_theme_constant_override("separation", 12)
	_cover.add_child(col)
	col.add_child(_title)
	col.add_child(UiTheme.label("PASS THE SCREEN", Color(1.0, 0.85, 0.40), UiTheme.SMALL, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(_line)
	col.add_child(_button)
	col.add_child(UiTheme.label("[Enter] ready", Color(0.6, 0.65, 0.75), UiTheme.SMALL, HORIZONTAL_ALIGNMENT_CENTER))
	_button.pressed.connect(_confirm)

	_report.add_theme_stylebox_override("panel", UiTheme.panel_style(20))
	centre.add_child(_report)
	var rcol := VBoxContainer.new()
	rcol.add_theme_constant_override("separation", 10)
	_report.add_child(rcol)
	rcol.add_child(UiTheme.label("WHILE YOU WAITED", Color(1.0, 0.85, 0.40), UiTheme.LARGE, HORIZONTAL_ALIGNMENT_CENTER))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	rcol.add_child(row)
	_report_body.custom_minimum_size = Vector2(380.0, 0.0)
	_report_body.add_theme_constant_override("separation", 6)
	row.add_child(_report_body)
	row.add_child(_map)
	rcol.add_child(_continue)
	rcol.add_child(UiTheme.label("[Enter] continue   -   map: north is up, X = where a shell landed, ring = your unit hit",
		Color(0.6, 0.65, 0.75), UiTheme.SMALL, HORIZONTAL_ALIGNMENT_CENTER))
	_continue.pressed.connect(_confirm)


## Shows the cover for `team`'s turn, then (if `report` has entries) the damage report, waiting for a confirmation each time.
func run(team: int, unit: Unit, ctx: BattleContext, report: Array[Dictionary]) -> void:
	_title.text = "%s'S TURN" % BattleConfig.name_of(team)
	_title.add_theme_color_override("font_color", BattleConfig.color_of(team))
	_line.text = "Next up: %s. The other player should look away." % unit.stats.display_name
	_cover.visible = true
	_report.visible = false
	visible = true
	await confirmed
	if not report.is_empty():
		_fill_report(ctx, team, report)
		_cover.visible = false
		_report.visible = true
		await confirmed
	visible = false


func _fill_report(ctx: BattleContext, team: int, report: Array[Dictionary]) -> void:
	for child in _report_body.get_children():
		child.queue_free()
	var n := 0
	for e in report:
		n += 1
		_report_body.add_child(UiTheme.label("%d. FIRE FROM THE %s" % [n, e["from"]], Color(1.0, 0.85, 0.40)))
		var hits: Array = e["hits"]
		if hits.is_empty():
			_report_body.add_child(UiTheme.label("   landed in sight, no hits", Color(0.75, 0.80, 0.90)))
		for h: Dictionary in hits:
			var text := "   YOUR %s  -%d HP  (%s, %s)" % [String(h["unit"]).to_upper(), roundi(h["damage"]), h["sector"], h["outcome"]]
			if h["killed"]:
				text += "  DESTROYED"
			_report_body.add_child(UiTheme.label(text, HIT_COLOR))
	_map.show_report(ctx, team, report)


func _input(event: InputEvent) -> void:
	if not visible:
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and (key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER or key.keycode == KEY_SPACE):
		_confirm()
	if key != null:
		get_viewport().set_input_as_handled()


func _confirm() -> void:
	if visible:
		confirmed.emit()
