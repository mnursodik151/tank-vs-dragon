class_name PlayerController
extends UnitController
## Mouse/keyboard controller built around the toolbar. Number keys 1-9 (or clicking a slot)
## pick the active tool; left click uses it; Space/Enter ends the turn.
##   Move   - hover previews the path and its AP cost, click walks there.
##   Weapon - the turret follows the mouse (short dotted bearing line, nothing else is predicted).
##            GUNNERY weapons: click opens the GunneryPanel (elevation, traverse, power charge).
##            BURST weapons: click fires a spread burst along the bearing.
##   Drone  - (infantry / ranger) click a point within range: the area around it counts as line of sight for a while (the eagle stays and is moved once per turn).
##   Ram    - dash in a straight line toward the mouse as far as AP allows; hitting something rams it.

signal action_chosen(action: Action)

const OK_COLOR := Color(0.35, 0.75, 1.0)
const BAD_COLOR := Color(1.0, 0.4, 0.35)
const BEARING_LENGTH := 4.0

var tools: Array[ToolEntry] = []
var tool_index := 0

var _unit: Unit
var _ctx: BattleContext
var _active := false
var _busy := false          ## true while the gunnery panel owns the input
var _ui := CanvasLayer.new()
var _toolbar := Toolbar.new()
var _panel := GunneryPanel.new()
var _last_hover := Vector3.INF


func _ready() -> void:
	_ui.layer = 5   # above the HUD text, so the (enlarged) gunnery panel is not drawn over
	add_child(_ui)
	_ui.add_child(_toolbar)
	_ui.add_child(_panel)
	_toolbar.tool_selected.connect(_select_tool)
	_toolbar.visible = false


func decide(unit: Unit, ctx: BattleContext) -> Action:
	_unit = unit
	_ctx = ctx
	if not ctx.view.grid_toggled.is_connected(_on_grid_toggled):
		ctx.view.grid_toggled.connect(_on_grid_toggled)
	tools = ToolEntry.build_for(unit)
	_toolbar.setup(tools, unit)
	_toolbar.visible = true
	_busy = false
	_active = true
	_select_tool(0)
	var action: Action = await action_chosen
	_active = false
	_toolbar.visible = false
	_ctx.guide.clear()
	ctx.view.clear_highlight()
	unit.lower_barrel()
	return action


## True while the gunnery panel owns the input.
func is_busy() -> bool:
	return _busy


func current_tool() -> ToolEntry:
	return tools[tool_index] if tool_index < tools.size() else null


## Short name of the active tool, for the HUD.
func tool_label() -> String:
	var t := current_tool()
	return t.label if t != null else "-"


func _process(_delta: float) -> void:
	if not _active:
		return
	_toolbar.refresh(_unit)
	if _busy:
		return
	var t := current_tool()
	if t == null:
		return
	if t.kind == ToolEntry.Kind.MOVE:
		_update_move_preview()
	elif t.kind == ToolEntry.Kind.WEAPON:
		_update_bearing(t.weapon)
	elif t.kind == ToolEntry.Kind.DRONE:
		_update_drone_preview()
	elif t.kind == ToolEntry.Kind.RAM:
		_update_dash_preview()


func _unhandled_input(event: InputEvent) -> void:
	if not _active or _busy:
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		if key.keycode >= KEY_1 and key.keycode <= KEY_9:
			_select_tool(key.keycode - KEY_1)
		elif key.keycode == KEY_SPACE or key.keycode == KEY_ENTER:
			_finish(null)
		return
	var click := event as InputEventMouseButton
	if click != null and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
		_on_click()


# --- tools --------------------------------------------------------------------

func _select_tool(index: int) -> void:
	if not _active or _busy or index < 0 or index >= tools.size():
		return
	tool_index = index
	_toolbar.set_active(index)
	_refresh()
	var t := tools[index]
	if t.kind == ToolEntry.Kind.DRONE and _unit.drone_cooldown > 0:
		_toolbar.flash(_spotter_wait())
	elif t.kind != ToolEntry.Kind.MOVE and _unit.ap + Action.AP_EPSILON < t.cost():
		_toolbar.flash("Not enough AP for %s (%.1f needed)" % [t.label, t.cost()])


func _on_grid_toggled(_grid_on: bool) -> void:
	if _active and not _busy:
		_refresh()


func _refresh() -> void:
	_last_hover = Vector3.INF
	_ctx.guide.clear()
	_ctx.view.clear_highlight()
	_unit.lower_barrel()
	var t := current_tool()
	if t == null:
		return
	match t.kind:
		ToolEntry.Kind.MOVE:
			if _ctx.view.grid_visible:
				var budget := _unit.ap / _unit.stats.move_ap_per_weight
				var reach := _ctx.board.reachable(_unit.cell, budget)
				reach.erase(_unit.cell)
				_ctx.view.show_highlight(reach.keys(), Color(0.2, 0.5, 1.0, 0.30))
		ToolEntry.Kind.DRONE:
			_ctx.guide.show_disc("drone_range", Vector3(_unit.global_position.x, _ground(_unit.global_position) + 0.02, _unit.global_position.z),
				_unit.stats.drone_range, Color(0.4, 0.9, 0.6, 0.10))


func _on_click() -> void:
	var t := current_tool()
	if t == null:
		return
	match t.kind:
		ToolEntry.Kind.MOVE:
			var p: Variant = _ctx.view.mouse_ground_point()
			if p != null:
				var move := MoveAction.new(_unit, p as Vector3)
				if move.can_execute(_ctx):
					_finish(move)
				elif move.cost(_ctx) < INF:
					_toolbar.flash("Not enough AP (%.1f needed)" % move.cost(_ctx))
		ToolEntry.Kind.DRONE:
			var p: Variant = _ctx.view.mouse_ground_point()
			if p != null:
				var drone := DroneAction.new(_unit, p as Vector3)
				if drone.can_execute(_ctx):
					_finish(drone)
				elif _unit.drone_cooldown > 0:
					_toolbar.flash(_spotter_wait())
				elif not drone.in_range():
					_toolbar.flash("Out of %s range (%.0f m)" % [_unit.stats.spotter_kind, _unit.stats.drone_range])
				else:
					_toolbar.flash("Not enough AP (%.1f needed)" % drone.cost(_ctx))
		ToolEntry.Kind.RAM:
			var dir: Variant = _dash_dir()
			if dir != null:
				var dash := DashAction.new(_unit, dir as Vector3)
				if dash.can_execute(_ctx):
					_finish(dash)
				elif dash.cost(_ctx) > _unit.ap:
					_toolbar.flash("Not enough AP (%.1f needed)" % dash.cost(_ctx))
				else:
					_toolbar.flash("No room to dash")
		ToolEntry.Kind.WEAPON:
			_use_weapon(t.weapon)


func _use_weapon(weapon: WeaponStats) -> void:
	if _unit.ap + Action.AP_EPSILON < weapon.ap_cost:
		_toolbar.flash("Not enough AP for %s (%.1f needed)" % [weapon.display_name, weapon.ap_cost])
		return
	var yaw: Variant = _bearing_yaw()
	if yaw == null:
		return
	if weapon.aiming == WeaponStats.Aiming.BURST:
		_finish(ShootAction.new(_unit, FireParams.make(weapon, yaw as float, 0.0, 1.0)))
		return
	_open_gunnery(weapon, yaw as float)


func _open_gunnery(weapon: WeaponStats, yaw: float) -> void:
	_busy = true
	_ctx.guide.clear()
	var params: FireParams = await _panel.run(_unit, weapon, _ctx, yaw)
	_busy = false
	if params == null:
		_refresh()
		return
	var shot := ShootAction.new(_unit, params)
	if shot.can_execute(_ctx):
		_finish(shot)
	else:
		_toolbar.flash("Cannot fire")
		_refresh()


func _finish(action: Action) -> void:
	if not _active:
		return
	_active = false
	action_chosen.emit(action)


# --- guidance -----------------------------------------------------------------

## Yaw (radians) from the unit toward the mouse on the ground, or null when too close / off-map.
func _bearing_yaw() -> Variant:
	var p: Variant = _ctx.view.mouse_ground_point()
	if p == null:
		return null
	var flat: Vector3 = (p as Vector3) - _unit.global_position
	flat.y = 0.0
	if flat.length() < 0.3:
		return null
	return atan2(flat.x, flat.z)


## Weapon tool: swing the turret toward the mouse and mark only the bearing.
func _update_bearing(weapon: WeaponStats) -> void:
	var yaw: Variant = _bearing_yaw()
	if yaw == null:
		_ctx.guide.clear()
		return
	var dir := Vector3(sin(yaw as float), 0.0, cos(yaw as float))
	var pitch := 0.0 if weapon.aiming == WeaponStats.Aiming.BURST else deg_to_rad(weapon.default_pitch_deg)
	_unit.equip(weapon)
	_unit.aim(dir, pitch)
	var start := Vector3(_unit.global_position.x, _ground(_unit.global_position) + 0.05, _unit.global_position.z) + dir * (_unit.stats.radius + 0.5)
	var pts := PackedVector3Array([start, start + dir * BEARING_LENGTH])
	_ctx.guide.show_dots("bearing", pts, Color(1.0, 0.85, 0.3, 0.9), 0.4)
	_ctx.guide.show_disc("crosshair", start + dir * (BEARING_LENGTH + 0.3), 0.28, Color(1.0, 0.85, 0.3, 0.55))


## Why the spotting tool cannot be used right now: "Drone recharging (2 more turns)" / "Eagle resting (once per turn)".
func _spotter_wait() -> String:
	var kind := _unit.stats.spotter_name()
	if _unit.stats.spotter_kind == "eagle":
		return "%s resting - it can be moved once per turn" % kind
	return "%s recharging (%d more turn%s)" % [kind, _unit.drone_cooldown, "s" if _unit.drone_cooldown > 1 else ""]


## Drone tool: a disc where the drone would put eyes on the ground (red when out of range).
func _update_drone_preview() -> void:
	var p: Variant = _ctx.view.mouse_ground_point()
	if p == null:
		_ctx.guide.hide_disc("drone_area")
		return
	var drone := DroneAction.new(_unit, p as Vector3)
	var col := Color(0.4, 0.9, 0.6) if drone.in_range() and _unit.drone_cooldown <= 0 else BAD_COLOR
	var at: Vector3 = p
	_ctx.guide.show_disc("drone_area", Vector3(at.x, _ground(at) + 0.03, at.z), _unit.stats.spotter_radius, Color(col, 0.30))


## Ground height under a world position (hills), for drawing guides on the surface.
func _ground(p: Vector3) -> float:
	return _ctx.board.surface_y(p)


## Unit vector from the unit toward the mouse on the ground, or null when too close / off-map.
func _dash_dir() -> Variant:
	var yaw: Variant = _bearing_yaw()
	if yaw == null:
		return null
	return Vector3(sin(yaw as float), 0.0, cos(yaw as float))


## Ram tool: the line the dash would run, where it ends, its AP price and what it would hit.
func _update_dash_preview() -> void:
	var dir: Variant = _dash_dir()
	if dir == null:
		_ctx.guide.clear()
		return
	var dash := DashAction.new(_unit, dir as Vector3)
	var from := Vector3(_unit.global_position.x, _ground(_unit.global_position) + 0.05, _unit.global_position.z)
	dash.plan(_ctx)
	var end := Vector3(dash.end_point.x, _ground(dash.end_point) + 0.05, dash.end_point.z)
	var ok := dash.can_execute(_ctx)
	var color := BAD_COLOR if not ok else (Color(1.0, 0.55, 0.2) if dash.has_impact() else OK_COLOR)
	_ctx.guide.show_dots("path", PackedVector3Array([from, end]), color)
	_ctx.guide.show_disc("marker", Vector3(end.x, end.y - 0.01, end.z), _unit.stats.radius, Color(color, 0.4))
	var text := "%.1f / %.1f AP" % [dash.cost(_ctx), _unit.ap]
	if dash.has_impact():
		var ex := dash.exchange()
		text += "
RAM: deal %.0f, take %.0f" % [ex.x, ex.y]
	_ctx.guide.show_label(end + Vector3(0.0, 1.4, 0.0), text, color)


func _update_move_preview() -> void:
	var p: Variant = _ctx.view.mouse_ground_point()
	if p == null:
		_ctx.guide.clear()
		return
	var point: Vector3 = p
	if point.is_equal_approx(_last_hover):
		return
	_last_hover = point

	var move := MoveAction.new(_unit, point)
	var cells := move.path_cells(_ctx)
	if cells.size() < 2:
		_ctx.guide.clear()
		return
	var ok := move.can_execute(_ctx)
	var color := OK_COLOR if ok else BAD_COLOR
	var pts := PackedVector3Array([Vector3(_unit.global_position.x, _ground(_unit.global_position) + 0.05, _unit.global_position.z)])
	for wp in move.route(_ctx):
		pts.append(Vector3(wp.x, _ground(wp) + 0.05, wp.z))
	_ctx.guide.show_dots("path", pts, color)
	var cost := move.cost(_ctx)
	var end := pts[pts.size() - 1]
	_ctx.guide.show_disc("marker", Vector3(end.x, end.y - 0.01, end.z), _unit.stats.radius, Color(color, 0.4))
	var text := "%.1f / %.1f AP" % [cost, _unit.ap]
	_ctx.guide.show_label(end + Vector3(0.0, 1.4, 0.0), text, color)
