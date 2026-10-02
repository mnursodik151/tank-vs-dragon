class_name DashAction
extends Action
## Ram: a straight charge along one bearing. It is a movement action - AP is priced like a walk
## (terrain weight of every hex entered * move_ap_per_weight) and the unit runs as far as its AP
## allows, stopping early when it hits something.
##
## Impact: every participant takes damage equal to the OTHER one's armor value (the rammer's front
## plate against the plate of the struck side), and both plates wear down. A struck unit with weaker
## armor than the rammer is also knocked back by the difference. Props (trees, rocks) have a fixed armor and
## hit points: a rammed prop takes the rammer's armor as damage and is destroyed at 0 hp. Slopes cost extra AP
## like a walk; a cliff face (see GridBoard.is_cliff) simply stops the dash.

const STEP := 0.05               ## metres between collision samples along the line
const MAX_RUN := 60.0            ## hard cap on the run length
const DASH_SPEED_MULT := 2.0     ## the run animates faster than a walk
const ARMOR_WEAR := 0.5          ## plate strength lost per point of ram damage taken
const KNOCK_PER_ARMOR := 0.6     ## launch speed (m/s, for mass 1) per point of armor difference; ground friction eats most of it
const KNOCK_MASS_EXPONENT := 0.3 ## launch speed falls with mass^this: heavier units are shoved less
const OBSTACLE_ARMOR := 8.0      ## blocked cell that is not a catalogued prop

var dir: Vector3                 ## flat unit vector of the run

var hit_unit: Unit               ## unit the run ends against, if any
var hit_cell := GridBoard.NO_CELL ## obstacle cell the run ends against, if any
var end_point: Vector3           ## where the unit ends up (y = rest height)

var _planned := false
var _cost := 0.0
var _run := 0.0
var _hit_prop_armor := 0.0
var _hit_kind := -1


func _init(p_actor: Unit, p_dir: Vector3) -> void:
	super(p_actor)
	dir = Vector3(p_dir.x, 0.0, p_dir.z).normalized()


## Walks the line once per action instance and records where it ends, what it costs and what it hits.
func plan(ctx: BattleContext) -> void:
	if _planned:
		return
	_planned = true
	var board := ctx.board
	var per_weight := actor.stats.move_ap_per_weight
	var start := actor.global_position
	var rest := actor.rest_height()
	end_point = Vector3(start.x, rest + board.surface_y(start), start.z)
	if dir.length() < 0.5:
		return
	var side := Vector3(-dir.z, 0.0, dir.x) * actor.stats.radius
	var radius := actor.stats.radius
	var pos := end_point
	var cell := actor.cell
	var budget := actor.ap + AP_EPSILON
	while _run < MAX_RUN:
		var nxt := pos + dir * STEP
		# Someone in the way (only those ahead of us, so touching units can be rammed or left behind).
		for other in ctx.alive_units():
			if other == actor:
				continue
			var to := other.global_position - pos
			to.y = 0.0
			if to.dot(dir) > 0.0 and to.length() < radius + other.stats.radius:
				hit_unit = other
				break
		if hit_unit != null:
			break
		# Obstacles / board edge, tested at the leading edge and both flanks of the footprint.
		var blocked := false
		for offset in [dir * radius, dir * radius + side, dir * radius - side]:
			var c := board.world_to_cell(nxt + offset)
			if not board.in_bounds(c):
				blocked = true
				break
			if board.is_blocked(c):
				hit_cell = c
				blocked = true
				break
			if absi(board.level_of(c) - board.level_of(cell)) >= GridBoard.CLIFF_LEVELS:
				blocked = true   # a cliff face stops the run
				break
		if blocked:
			break
		# Terrain price, paid when the unit's centre enters a new hex.
		var nc := board.world_to_cell(nxt)
		if nc != cell:
			var add := board.step_cost(cell, nc) * per_weight
			if _cost + add > budget:
				break
			_cost += add
			cell = nc
		pos = nxt
		_run += STEP
	end_point = Vector3(pos.x, rest + board.surface_y(pos), pos.z)
	if hit_cell != GridBoard.NO_CELL:
		_hit_kind = board.prop_at(hit_cell)
		_hit_prop_armor = Props.armor(_hit_kind as Props.Kind) if _hit_kind >= 0 else OBSTACLE_ARMOR
	if has_impact():
		_cost = maxf(_cost, per_weight)   # a charge is never free, even against a neighbour


func has_impact() -> bool:
	return hit_unit != null or hit_cell != GridBoard.NO_CELL


func run_length(ctx: BattleContext) -> float:
	plan(ctx)
	return _run


func cost(ctx: BattleContext) -> float:
	plan(ctx)
	return _cost


func can_execute(ctx: BattleContext) -> bool:
	plan(ctx)
	return super(ctx) and (_run > STEP * 0.5 or has_impact())


## Armor values at the point of impact: x = the rammer's front plate, y = what it strikes
## (the facing plate of a unit, the fixed armor of a prop). Zero when nothing is hit.
func armor_pair() -> Vector2:
	var mine := actor.effective_armor(HitResult.Sector.FRONT)
	if hit_unit != null:
		var sector := hit_unit.armor_sector(end_point - hit_unit.global_position)
		return Vector2(mine, hit_unit.effective_armor(sector))
	if hit_cell != GridBoard.NO_CELL:
		return Vector2(mine, _hit_prop_armor)
	return Vector2.ZERO


## (damage dealt to the target, damage taken by the rammer) if the run were executed now.
func exchange() -> Vector2:
	var armors := armor_pair()
	return Vector2(armors.x, armors.y) if has_impact() else Vector2.ZERO


func execute(ctx: BattleContext) -> void:
	plan(ctx)
	actor.spend_ap(cost(ctx))
	actor.face(dir)
	ctx.board.place(actor, ctx.board.world_to_cell(end_point))   # logical position updates immediately
	if _run > STEP * 0.5:
		await actor.walk([end_point] as Array[Vector3], DASH_SPEED_MULT)
	if has_impact():
		_resolve_impact(ctx)
	# Let the physics server step once so any knock-back velocity is live before settle polling.
	await actor.get_tree().physics_frame


func _resolve_impact(ctx: BattleContext) -> void:
	var armors := armor_pair()
	var mine := armors.x
	var theirs := armors.y
	if hit_unit != null:
		var sector := hit_unit.armor_sector(actor.global_position - hit_unit.global_position)
		_popup(ctx, hit_unit, hit_unit.take_ram(mine, sector, ARMOR_WEAR))
		if hit_unit.is_alive() and mine > theirs:
			var away := hit_unit.global_position - actor.global_position
			var push_dir := Vector3(away.x, 0.0, away.z)
			push_dir = push_dir.normalized() if push_dir.length() > 0.001 else dir
			var speed := (mine - theirs) * KNOCK_PER_ARMOR
			# Unit.launch divides by mass, so pre-multiply to land on mass^KNOCK_MASS_EXPONENT overall.
			hit_unit.launch(push_dir * speed * pow(hit_unit.stats.mass, 1.0 - KNOCK_MASS_EXPONENT))
	if hit_cell != GridBoard.NO_CELL and _hit_kind >= 0:
		var name := Props.kind_name(_hit_kind as Props.Kind)
		var left := ctx.board.damage_prop(hit_cell, mine)
		FloatingText.spawn(ctx.root, ctx.board.cell_to_world(hit_cell, 1.2),
			"%s -%.0f" % [name, mine] if left > 0.0 else "%s destroyed" % name, Color(0.8, 0.75, 0.55))
	_popup(ctx, actor, actor.take_ram(theirs, HitResult.Sector.FRONT, ARMOR_WEAR))


func _popup(ctx: BattleContext, unit: Unit, res: HitResult) -> void:
	FloatingText.spawn(ctx.root, unit.global_position + Vector3(0.0, unit.stats.height / 2.0 + 0.9, 0.0),
		res.popup_text(), Color(1.0, 0.45, 0.25))


func describe() -> String:
	if hit_unit != null:
		return "%s rams %s" % [actor.stats.display_name, hit_unit.stats.display_name]
	if hit_cell != GridBoard.NO_CELL:
		return "%s rams into %s" % [actor.stats.display_name, hit_cell]
	return "%s dashes" % actor.stats.display_name
