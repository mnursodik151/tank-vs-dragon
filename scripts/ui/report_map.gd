class_name ReportMap
extends Control
## Small north-up map for the hot-seat damage report: the board outline, the incoming player's units, and for each enemy
## shot its trajectory (marker at the impact, ring on a unit it hit). Fixed orientation, like the shot review.

const MAP_SIZE := Vector2(300.0, 260.0)
const PAD := 14.0
const ENEMY_TRAJECTORY := Color(1.0, 0.55, 0.40)

var _bounds := Rect2()
var _entries: Array[Dictionary] = []
var _own: Array[Dictionary] = []     # {"pos": Vector3, "color": Color}
var _enemy_color := ENEMY_TRAJECTORY


func _init() -> void:
	custom_minimum_size = MAP_SIZE
	clip_contents = true


func show_report(ctx: BattleContext, team: int, entries: Array[Dictionary]) -> void:
	_entries = entries
	_enemy_color = BattleConfig.color_of(BattleConfig.other(team)).lerp(ENEMY_TRAJECTORY, 0.4)
	_own.clear()
	for u in ctx.units:
		if u.is_alive() and u.team == team:
			_own.append({"pos": u.global_position, "color": u.team_color})
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in ctx.board.all_cells():
		var p := ctx.board.cell_to_world(c)
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.z))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.z))
	_bounds = Rect2(lo, hi - lo).grow(ctx.board.hex_size)
	queue_redraw()


func _to_map(p: Vector3) -> Vector2:
	var inner := MAP_SIZE - Vector2.ONE * PAD * 2.0
	var s := minf(inner.x / _bounds.size.x, inner.y / _bounds.size.y)
	var used := _bounds.size * s
	var origin := (MAP_SIZE - used) * 0.5
	return origin + (Vector2(p.x, p.z) - _bounds.position) * s


func _draw() -> void:
	if _bounds.size.x <= 0.0:
		return
	UiTheme.draw_panel(self, Rect2(Vector2.ZERO, MAP_SIZE), 1)
	var corner_a := _to_map(Vector3(_bounds.position.x, 0.0, _bounds.position.y))
	var corner_b := _to_map(Vector3(_bounds.end.x, 0.0, _bounds.end.y))
	draw_rect(Rect2(corner_a, corner_b - corner_a), Color(0.25, 0.3, 0.38, 0.5), false, 2.0)
	UiTheme.text(self, Vector2(MAP_SIZE.x * 0.5, 14.0), "N", Color(0.75, 0.8, 0.9), UiTheme.SMALL, HORIZONTAL_ALIGNMENT_CENTER, 20.0)
	for u in _own:
		draw_circle(_to_map(u["pos"]), 5.0, u["color"])
	var n := 0
	for e in _entries:
		n += 1
		var pts := PackedVector2Array()
		for p in (e["trail"] as PackedVector3Array):
			pts.append(_to_map(p))
		if pts.size() >= 2:
			draw_polyline(pts, Color(_enemy_color, 0.85), 2.0)
		if e["origin_seen"]:
			draw_circle(pts[0], 4.0, _enemy_color)   # the muzzle: the shooter was in sight
		var at := _to_map(e["impact"])
		draw_line(at + Vector2(-5, -5), at + Vector2(5, 5), Color.WHITE, 2.0)
		draw_line(at + Vector2(-5, 5), at + Vector2(5, -5), Color.WHITE, 2.0)
		UiTheme.text(self, at + Vector2(7.0, -4.0), str(n), Color.WHITE, UiTheme.SMALL)
		for h in (e["hits"] as Array):
			draw_arc(_to_map(h["pos"]), 9.0, 0.0, TAU, 20, Color(1.0, 0.35, 0.3), 2.0)
