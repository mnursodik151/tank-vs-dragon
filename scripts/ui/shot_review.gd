class_name ShotReview
extends Control
## Analysis overlay (H): a fixed top-down map of the battlefield with every recorded shot (muzzle,
## trajectory, impact) taken from GameState. Allied shots come with their full metadata (setup, wind,
## range, flight time, per-unit results, and a side profile of the flight); enemy shots are only a
## marker and a trajectory. While open it swallows all input so nothing leaks into the battle.
## Keys: H / Esc close, Up / Down or click a row to select, F cycles ALL / ALLIES / ENEMIES.
## Once the battle is over (`ctx.reveal_all`) it becomes the full SHOT HISTORY: every side's shots with their complete
## data, units in team colours, and the filter splits by player instead of ally / enemy.

signal closed

enum Filter { ALL, ALLIES, ENEMIES }

const ALLY_COLOR := Color(0.40, 0.68, 1.0)
const ENEMY_COLOR := Color(1.0, 0.40, 0.35)
const SIDE_WIDTH := 380.0
const MARGIN := 28.0
const ROW_HEIGHT := 22.0
const LIST_TOP := 78.0
const LIST_HEIGHT := 250.0

var viewer_team := 0
var can_open: Callable = Callable()   ## returns false while something else (the gunnery panel) owns the input

var _state: GameState
var _ctx: BattleContext
var _filter := Filter.ALL
var _selected := -1          # index into GameState.shots
var _scroll := 0
var _bounds := Rect2()


func setup(state: GameState, ctx: BattleContext) -> void:
	_state = state
	_ctx = ctx
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if not visible:
		if key != null and key.pressed and not key.echo and key.keycode == KEY_H \
				and (not can_open.is_valid() or can_open.call()):
			_open()
			get_viewport().set_input_as_handled()
		return
	if key == null:
		return
	get_viewport().set_input_as_handled()
	if not key.pressed:
		return
	match key.keycode:
		KEY_H, KEY_ESCAPE:
			_close()
		KEY_UP:
			_step(-1)
		KEY_DOWN:
			_step(1)
		KEY_F:
			_filter = ((_filter + 1) % Filter.size()) as Filter
			_scroll = 0
			if _selected >= 0 and not _passes(_state.shots[_selected]):
				_selected = -1
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button == null or not button.pressed:
		return
	accept_event()
	match button.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			_scroll = maxi(_scroll - 1, 0)
		MOUSE_BUTTON_WHEEL_DOWN:
			_scroll = mini(_scroll + 1, maxi(_visible_indices().size() - _rows_visible(), 0))
		MOUSE_BUTTON_LEFT:
			_click(button.position)
		MOUSE_BUTTON_RIGHT:
			_close()
	queue_redraw()


## Opens the review from outside (the victory screen's SHOT HISTORY button).
func open_history() -> void:
	_filter = Filter.ALL
	_selected = -1
	_open()


func _close() -> void:
	visible = false
	closed.emit()


## After the battle every shot is shown with its full data.
func _full() -> bool:
	return _ctx != null and _ctx.reveal_all


## Whether `rec`'s details may be shown: our own shots always, everyone's in the history.
func _info(rec: ShotRecord) -> bool:
	return _full() or rec.shooter_team == viewer_team


## The side the ALLIES filter means: the viewer's, or Player 1 / you in the history.
func _ref_team() -> int:
	return BattleConfig.p1_team if _full() else viewer_team


func _team_col(team: int) -> Color:
	if _full():
		return BattleConfig.color_of(team)
	return ALLY_COLOR if team == viewer_team else ENEMY_COLOR


func _filter_name() -> String:
	if _full() and _filter != Filter.ALL:
		return BattleConfig.name_of(_ref_team() if _filter == Filter.ALLIES else BattleConfig.other(_ref_team()))
	return Filter.keys()[_filter]


func _open() -> void:
	_compute_bounds()
	_scroll = 0
	var idx := _visible_indices()
	if _selected < 0 or not idx.has(_selected):
		_selected = idx[0] if not idx.is_empty() else -1
	visible = true
	queue_redraw()


# --- selection ----------------------------------------------------------------

func _passes(rec: ShotRecord) -> bool:
	match _filter:
		Filter.ALLIES:
			return rec.shooter_team == _ref_team()
		Filter.ENEMIES:
			return rec.shooter_team != _ref_team()
	return true


## Indices into GameState.shots, newest first, after the filter.
func _visible_indices() -> Array[int]:
	var out: Array[int] = []
	for i in range(_state.shots.size() - 1, -1, -1):
		if _passes(_state.shots[i]):
			out.append(i)
	return out


func _rows_visible() -> int:
	return int(LIST_HEIGHT / ROW_HEIGHT)


func _step(dir: int) -> void:
	var idx := _visible_indices()
	if idx.is_empty():
		return
	var at := idx.find(_selected)
	at = clampi((0 if at < 0 else at) + dir, 0, idx.size() - 1)
	_selected = idx[at]
	_scroll = clampi(_scroll, maxi(at - _rows_visible() + 1, 0), at)


func _click(p: Vector2) -> void:
	var idx := _visible_indices()
	var list := _list_rect()
	if list.has_point(p):
		var row := int((p.y - list.position.y) / ROW_HEIGHT) + _scroll
		if row >= 0 and row < idx.size():
			_selected = idx[row]
		return
	# a click on the map picks the shot whose impact is nearest
	var map := _map_rect()
	if map.has_point(p):
		var best := -1
		var best_d := 18.0
		for i in idx:
			var d := _to_screen(_state.shots[i].impact).distance_to(p)
			if d < best_d:
				best_d = d
				best = i
		if best >= 0:
			_selected = best
			_scroll = clampi(idx.find(best), 0, maxi(idx.size() - _rows_visible(), 0))


# --- layout -------------------------------------------------------------------

func _map_rect() -> Rect2:
	return Rect2(MARGIN, MARGIN + 34.0, size.x - SIDE_WIDTH - MARGIN * 3.0, size.y - MARGIN * 2.0 - 34.0)


func _side_x() -> float:
	return size.x - SIDE_WIDTH - MARGIN


func _list_rect() -> Rect2:
	return Rect2(_side_x(), MARGIN + LIST_TOP - 28.0, SIDE_WIDTH, LIST_HEIGHT)


func _compute_bounds() -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in _ctx.board.all_cells():
		var p := _ctx.board.cell_to_world(c)
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.z))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.z))
	var pad := _ctx.board.hex_size
	_bounds = Rect2(lo - Vector2(pad, pad), hi - lo + Vector2(pad, pad) * 2.0)


func _scale() -> float:
	var map := _map_rect()
	return minf(map.size.x / _bounds.size.x, map.size.y / _bounds.size.y)


func _to_screen(p: Vector3) -> Vector2:
	var map := _map_rect()
	var s := _scale()
	var origin := map.position + (map.size - _bounds.size * s) / 2.0
	return origin + (Vector2(p.x, p.z) - _bounds.position) * s


# --- drawing ------------------------------------------------------------------

func _draw() -> void:
	if not visible or _state == null:
		return
	var font := UiTheme.font
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.04, 0.06, 0.94))
	draw_string(font, Vector2(MARGIN, MARGIN + 14.0), "SHOT HISTORY" if _full() else "SHOT REVIEW", HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(22), Color(1.0, 0.82, 0.25))
	var note := "top-down, fixed orientation  -  battle over: full data for every side" if _full() \
		else "top-down, fixed orientation  -  allies: full data  -  enemies: marker and trajectory only"
	draw_string(font, Vector2(MARGIN + 230.0 if _full() else MARGIN + 170.0, MARGIN + 14.0), note, HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(12), Color(0.6, 0.63, 0.7))
	draw_string(font, Vector2(0.0, size.y - 10.0), "Up/Down or click: select   F: filter   Wheel: scroll list   H / Esc: close",
		HORIZONTAL_ALIGNMENT_CENTER, size.x, UiTheme.fs(12), Color(0.6, 0.63, 0.7))
	_draw_map()
	_draw_list(font)
	_draw_details(font)


func _draw_map() -> void:
	var board := _ctx.board
	var s := _scale()
	UiTheme.draw_panel(self, _map_rect().grow(5.0), 0)
	draw_rect(_map_rect(), Color(0.07, 0.08, 0.10))
	for c in board.all_cells():
		var centre := board.cell_to_world(c)
		var col := Color(0.22, 0.24, 0.27) if board.is_blocked(c) else Terrain.color(board.terrain_at(c)).darkened(0.35)
		if board.is_water(c):
			col = Color(0.16, 0.34, 0.55)
		if board.prop_at(c) >= 0:
			col = Props.map_color(board.prop_at(c) as Props.Kind)
		var poly := PackedVector2Array()
		for i in 6:
			poly.append(_to_screen(board.corner(centre, i, board.hex_size * 0.96)))
		draw_colored_polygon(poly, col)
		if board.is_blocked(c) and board.prop_at(c) < 0 and not board.is_water(c):
			draw_line(poly[0], poly[3], Color(0.4, 0.42, 0.46), 1.5)
	# units (where they stand now)
	for u in _ctx.alive_units():
		if u.team != viewer_team and not _ctx.visible_to_viewer(u):
			continue   # an enemy outside our line of sight is not on our map (visible_to_viewer is true for all once the battle is over)
		var p := _to_screen(u.global_position)
		var col := _team_col(u.team)
		draw_circle(p, maxf(u.stats.radius * s, 5.0), Color(col, 0.35))
		draw_arc(p, maxf(u.stats.radius * s, 5.0), 0.0, TAU, 16, col, 1.5)
		draw_string(UiTheme.font, p + Vector2(-5.0, 4.0), u.stats.display_name.left(1), HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(11), col.lightened(0.4))
	# shots: oldest first so the newest and the selected one end up on top
	var idx := _visible_indices()
	idx.reverse()
	for i in idx:
		if i != _selected:
			_draw_shot(_state.shots[i], false)
	if _selected >= 0 and idx.has(_selected):
		_draw_shot(_state.shots[_selected], true)


func _draw_shot(rec: ShotRecord, selected: bool) -> void:
	var ally := _info(rec)
	var col := _team_col(rec.shooter_team)
	var age := _ctx.round_number - rec.round_number
	var alpha := 1.0 if selected else clampf(0.75 - 0.12 * age, 0.3, 0.75)
	var width := 3.0 if selected else 1.6
	var map := _map_rect().grow(-2.0)
	var pts := PackedVector2Array()
	if rec.trail.size() >= 2:
		for p in rec.trail:
			var sp := _to_screen(p)
			if not map.has_point(sp):
				pts.append(sp.clamp(map.position, map.end))   # shells that fly off the map stop at its edge
				break
			pts.append(sp)
	else:
		pts.append(_to_screen(rec.origin).clamp(map.position, map.end))
		pts.append(_to_screen(rec.impact).clamp(map.position, map.end))
	if pts.size() < 2:
		pts.append(pts[0] + Vector2(0.1, 0.0))
	if selected:
		draw_polyline(pts, Color(col, 0.3), 8.0, true)
	if rec.trail.size() >= 2:
		draw_polyline(pts, Color(col, alpha), width, true)
	else:
		draw_dashed_line(pts[0], pts[1], Color(col, alpha), width, 6.0)
	draw_circle(_to_screen(rec.origin), 3.5 if selected else 2.5, Color(col, alpha))
	var m := _to_screen(rec.impact).clamp(map.position, map.end)
	var r := 7.0 if selected else 5.0
	draw_line(m + Vector2(-r, -r), m + Vector2(r, r), Color(col, alpha), width)
	draw_line(m + Vector2(-r, r), m + Vector2(r, -r), Color(col, alpha), width)
	if selected or ally:
		draw_string(UiTheme.font, m + Vector2(r + 2.0, -r), "#%d" % rec.id, HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(11), Color(col.lightened(0.3), alpha))


func _draw_list(font: Font) -> void:
	var x := _side_x()
	var idx := _visible_indices()
	draw_string(font, Vector2(x, MARGIN + 14.0), "SHOTS  (%d)   filter: %s" % [idx.size(), _filter_name()],
		HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(14), Color(0.85, 0.88, 0.95))
	var list := _list_rect()
	UiTheme.draw_panel(self, list, 1)
	if idx.is_empty():
		draw_string(font, list.position + Vector2(10.0, 24.0), "no shots recorded yet", HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(13), Color(0.55, 0.58, 0.65))
	for row in _rows_visible():
		var at := row + _scroll
		if at >= idx.size():
			break
		var rec := _state.shots[idx[at]]
		var ally := _info(rec)
		var r := Rect2(list.position + Vector2(0.0, row * ROW_HEIGHT), Vector2(list.size.x, ROW_HEIGHT))
		var col := _team_col(rec.shooter_team)
		if idx[at] == _selected:
			draw_rect(r, Color(col, 0.22))
		draw_circle(r.position + Vector2(10.0, ROW_HEIGHT / 2.0), 4.0, col)
		var text := "#%d   %s %s  -  %s, charge %d" % [rec.id, rec.shooter_name, rec.weapon_name, rec.round_name, rec.charges] if ally \
			else "#%d   enemy shot" % rec.id
		draw_string(font, r.position + Vector2(22.0, 16.0), text, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 28.0, UiTheme.fs(12), col.lightened(0.5) if ally else col)


func _draw_details(font: Font) -> void:
	var x := _side_x()
	var top := _list_rect().end.y + 18.0
	var box := Rect2(x, top, SIDE_WIDTH, size.y - top - MARGIN - 8.0)
	UiTheme.draw_panel(self, box, 1)
	if _selected < 0 or _selected >= _state.shots.size():
		draw_string(font, box.position + Vector2(12.0, 26.0), "select a shot", HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(13), Color(0.55, 0.58, 0.65))
		return
	var rec := _state.shots[_selected]
	var col := _team_col(rec.shooter_team)
	if not _info(rec):
		draw_string(font, box.position + Vector2(12.0, 26.0), "ENEMY SHOT  #%d" % rec.id, HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(15), ENEMY_COLOR)
		draw_string(font, box.position + Vector2(12.0, 48.0), "No data on enemy weapons or settings -", HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(12), Color(0.6, 0.63, 0.7))
		draw_string(font, box.position + Vector2(12.0, 64.0), "only where it fell and the path it flew.", HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(12), Color(0.6, 0.63, 0.7))
		return

	var lines := PackedStringArray()
	lines.append("%s  -  %s  -  %s" % [rec.shooter_name, rec.weapon_name, rec.round_name])
	lines.append("round %d, charge %d (%.1f AP)" % [rec.round_number, rec.charges, rec.ap_cost])
	if rec.burst:
		lines.append("burst of %d, bearing %.1f deg" % [rec.rounds, rad_to_deg(rec.yaw)])
	else:
		lines.append("yaw %.1f deg   pitch %.1f deg   power %d%%" % [rad_to_deg(rec.yaw), rad_to_deg(rec.pitch), roundi(rec.power * 100.0)])
		lines.append("muzzle speed %.1f m/s" % rec.speed)
	lines.append("wind %.1f m/s toward %.0f deg" % [rec.wind_speed, rad_to_deg(rec.wind_angle)])
	lines.append("range %.1f m   flight %.2f s   %s" % [rec.distance, rec.flight_time, "landed" if rec.landed else "LOST off map"])
	if rec.blasts > 0 or rec.craters > 0 or rec.fires > 0:
		lines.append("blasts %d   craters %d   fire cells %d" % [rec.blasts, rec.craters, rec.fires])
	var y := 24.0
	var owner_tag := "  (%s)" % BattleConfig.name_of(rec.shooter_team) if _full() else ""
	draw_string(font, box.position + Vector2(12.0, y), "SHOT #%d%s" % [rec.id, owner_tag], HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(15), col)
	for line in lines:
		y += 18.0
		draw_string(font, box.position + Vector2(12.0, y), line, HORIZONTAL_ALIGNMENT_LEFT, SIDE_WIDTH - 24.0, UiTheme.fs(12), Color(0.85, 0.88, 0.95))
	if rec.results.is_empty():
		y += 18.0
		draw_string(font, box.position + Vector2(12.0, y), "hit no unit", HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(12), Color(0.6, 0.63, 0.7))
	for res in rec.results:
		y += 18.0
		var friendly: bool = res["team"] == rec.shooter_team
		var text := "%s (%s)  %s  dmg %.1f  armor %.1f > %.1f%s" % [res["unit"], res["sector"], res["outcome"].capitalize(), res["damage"],
			res["armor_before"], res["armor_after"], "  KILLED" if res["killed"] else ""]
		draw_string(font, box.position + Vector2(12.0, y), text, HORIZONTAL_ALIGNMENT_LEFT, SIDE_WIDTH - 24.0, UiTheme.fs(11),
			Color(1.0, 0.7, 0.4) if friendly else Color(1.0, 0.85, 0.5))
	_draw_profile(font, rec, Rect2(box.position + Vector2(12.0, y + 14.0), Vector2(SIDE_WIDTH - 24.0, box.end.y - (box.position.y + y + 14.0) - 10.0)), col)


## Side profile of a gunnery flight: distance along the ground against height.
func _draw_profile(font: Font, rec: ShotRecord, area: Rect2, color: Color) -> void:
	if rec.burst or rec.trail.size() < 2 or area.size.y < 50.0:
		return
	var o := rec.origin
	var top := 0.5
	var far := 1.0
	for p in rec.trail:
		top = maxf(top, p.y)
		far = maxf(far, Vector2(p.x - o.x, p.z - o.z).length())
	var s := minf(area.size.x / far, (area.size.y - 14.0) / top)
	var ground := area.end.y - 12.0
	draw_line(Vector2(area.position.x, ground), Vector2(area.end.x, ground), Color(0.4, 0.43, 0.5), 1.0)
	var pts := PackedVector2Array()
	for p in rec.trail:
		pts.append(Vector2(area.position.x + Vector2(p.x - o.x, p.z - o.z).length() * s, ground - maxf(p.y, 0.0) * s))
	draw_polyline(pts, color, 2.0, true)
	draw_string(font, Vector2(area.position.x, area.end.y), "side profile: apex %.1f m, range %.1f m" % [top, far],
		HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(10), Color(0.6, 0.63, 0.7))
