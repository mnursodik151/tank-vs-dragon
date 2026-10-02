class_name MoveAction
extends Action
## Walk to any point on the board. The grid only prices the trip: AP = sum of the terrain
## weights of the hexes entered along the cheapest path * the unit's move_ap_per_weight.
## The unit ends up exactly at the requested point (nudged clear of other units), not at a cell centre.
## Ground elevation counts: slopes cost extra AP uphill. Cliff faces can be crossed for a steep AP price or
## avoided - the AI walks around them (`avoid_cliffs`). Height never costs hit points.

var point: Vector3                 ## requested world position (y ignored)
var destination: Vector2i = GridBoard.NO_CELL
var avoid_cliffs := false          ## never route across a cliff face

var _planned := false
var _path: Array[Vector2i] = []
var _weight := 0.0


func _init(p_actor: Unit, p_point: Vector3, p_avoid_cliffs: bool = false) -> void:
	super(p_actor)
	point = p_point
	avoid_cliffs = p_avoid_cliffs


## Computes path + weight once per action instance.
func plan(ctx: BattleContext) -> void:
	if _planned:
		return
	_planned = true
	destination = ctx.board.world_to_cell(point)
	_path = ctx.board.find_path(actor.cell, destination, INF, not avoid_cliffs)
	_weight = ctx.board.path_cost(_path)


func path_cells(ctx: BattleContext) -> Array[Vector2i]:
	plan(ctx)
	return _path


func cost(ctx: BattleContext) -> float:
	plan(ctx)
	if _path.is_empty():
		return INF
	return _weight * actor.stats.move_ap_per_weight


func can_execute(ctx: BattleContext) -> bool:
	plan(ctx)
	return super(ctx) and destination != actor.cell and not _path.is_empty()


## World-space waypoints (smoothed) the unit will follow, excluding its current position.
func route(ctx: BattleContext) -> Array[Vector3]:
	plan(ctx)
	if _path.is_empty():
		return []
	var end := _resolve_end(ctx)
	return ctx.board.smooth_route(actor.global_position, _path, end, actor, actor.stats.radius)


## Final standing point: the click, pushed out of other units' footprints, kept inside the
## destination cell (falls back to the cell centre).
func _resolve_end(ctx: BattleContext) -> Vector3:
	var y := actor.rest_height()   # standing height above the ground
	var end := Vector3(point.x, y, point.z)
	for other in ctx.alive_units():
		if other == actor:
			continue
		var away := end - other.global_position
		away.y = 0.0
		var min_dist := actor.stats.radius + other.stats.radius + 0.05
		if away.length() < min_dist:
			if away.length() < 0.001:
				away = Vector3.RIGHT
			end = other.global_position + away.normalized() * min_dist
			end.y = y
	if ctx.board.world_to_cell(end) != destination:
		return ctx.board.cell_to_world(destination, y)
	end.y = y + ctx.board.surface_y(end)
	return end


func execute(ctx: BattleContext) -> void:
	plan(ctx)
	var waypoints := route(ctx)
	var end := waypoints[waypoints.size() - 1] if not waypoints.is_empty() else actor.global_position
	actor.spend_ap(cost(ctx))
	ctx.board.place(actor, ctx.board.world_to_cell(end))  # logical position updates immediately
	await actor.walk(waypoints)


func describe() -> String:
	return "%s moves to %s" % [actor.stats.display_name, destination]
