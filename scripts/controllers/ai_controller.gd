class_name AIController
extends UnitController
## Minimal AI. Per turn: fire the first affordable weapon with a usable shot (main gun first,
## auxiliary weapons as fallback), ram when a dash reaches an enemy and hurts it more than the rammer,
## otherwise reposition toward a good range (walking around cliffs rather than over them).
##
## Fairness: the AI solves its shots in STILL AIR with the same ballistics maths and then adds
## human-like gunnery error (aim_noise_deg / power_noise). Wind is applied to its shells by the
## physics just like the player's, so it drifts off target unless `wind_awareness` > 0, in which
## case it compensates that fraction of its own predicted drift.
##
## Information: like the player it only knows about enemies inside its team's line of sight (Intel.sees).
## With none in view it heads for where an enemy was last seen, otherwise it scouts across the map.

@export var think_delay: float = 0.4
@export var aim_noise_deg: float = 1.2        ## gaussian error on yaw / pitch
@export var power_noise: float = 0.04         ## gaussian fractional error on charge
@export var wind_awareness: float = 0.0       ## 0 = ignores wind, 1 = perfectly corrects for it
@export var preferred_range_ratio: float = 0.7
@export var search_arrival: float = 3.5       ## a search goal counts as reached this close (metres)

var _rng := RandomNumberGenerator.new()
var _last_known: Dictionary = {}    # team -> Vector3 where one of its enemies was last seen
var _search_goal: Dictionary = {}   # Unit instance id -> Vector3 scouting goal


func _init() -> void:
	_rng.randomize()


func decide(unit: Unit, ctx: BattleContext) -> Action:
	await unit.get_tree().create_timer(think_delay).timeout

	var target := _nearest_enemy(unit, ctx)
	if target == null:
		return _search(unit, ctx)
	if unit.can_do(ActionSpec.Kind.SHOOT):   # the AI only uses what the unit's blueprint says it can do
		for weapon in unit.stats.weapons:
			if unit.ap + Action.AP_EPSILON < weapon.ap_cost:
				continue
			var shot := _plan_shot(unit, target, weapon, ctx)
			if shot != null and shot.can_execute(ctx):
				return shot
	var ram := _plan_ram(unit, target, ctx)
	if ram != null:
		return ram
	return _approach(unit, target.global_position, ctx)


# --- ramming ------------------------------------------------------------------

## A dash straight at `target` that ends against an enemy and costs the target more than the rammer.
func _plan_ram(unit: Unit, target: Unit, ctx: BattleContext) -> DashAction:
	var dash := DashAction.new(unit, target.global_position - unit.global_position)
	if not dash.can_execute(ctx) or dash.hit_unit == null or dash.hit_unit.team == unit.team:
		return null
	var ex := dash.exchange()
	if ex.x <= ex.y:
		return null
	return dash


# --- shooting -----------------------------------------------------------------

## Where `unit` believes `target` is: the true place inside the inner sight ring, but only the estimated range (same
## noisy reading the player gets, along the true bearing) when it is seen in the outer ring.
func _perceived_position(unit: Unit, target: Unit, ctx: BattleContext) -> Vector3:
	var reading := ctx.intel.reading(unit, target, ctx.units)
	var rel := target.global_position - unit.global_position
	rel.y = 0.0
	if not reading["outer"] or rel.length() < 0.01:
		return target.global_position
	var at := unit.global_position + rel.normalized() * float(reading["est"])
	at.y = target.global_position.y
	return at


func _plan_shot(unit: Unit, target: Unit, weapon: WeaponStats, ctx: BattleContext) -> ShootAction:
	var seen_at := _perceived_position(unit, target, ctx)
	var flat := seen_at - unit.global_position
	flat.y = 0.0
	var dist := flat.length()
	if dist < weapon.min_range or dist > weapon.max_range or dist < 0.01:
		return null
	var dir := flat / dist
	var origin := unit.muzzle_position(dir)
	var space := unit.get_world_3d().direct_space_state
	var exclude: Array[RID] = [unit.get_rid()]

	if weapon.aiming == WeaponStats.Aiming.BURST:
		# Direct fire: needs a clear line to the target's centre.
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(origin, target.global_position, Ballistics.MASK, exclude))
		if hit.is_empty() or hit["collider"] != target:
			return null
		var to := target.global_position - origin
		var pitch := atan2(to.y, Vector2(to.x, to.z).length())
		return ShootAction.new(unit, FireParams.make(weapon, atan2(dir.x, dir.z), pitch, 1.0))

	var aim := Vector3(seen_at.x, ctx.board.surface_y(seen_at), seen_at.z)
	var ammo := _pick_round(target, weapon)
	var mult := ammo.velocity_mult() if ammo != null else 1.0
	var wind_accel := ctx.wind.accel() * (ammo.wind_mult() if ammo != null else 1.0)

	# Cheapest charge level that can reach the target (every extra charge costs AP).
	var charge := 0
	var velocity := Vector3.ZERO
	for c in range(1, weapon.max_charges() + 1):
		if unit.ap + Action.AP_EPSILON < weapon.total_cost(c):
			break
		velocity = _solve(ctx.board, origin, aim, weapon, weapon.muzzle_velocity * weapon.charge_scale(c) * mult)
		if velocity != Vector3.ZERO:
			charge = c
			break
	if charge == 0:
		return null
	var vmax := weapon.muzzle_velocity * weapon.charge_scale(charge) * mult

	# Is the line of fire clear (still air)? Otherwise something would eat the shell.
	var still := Ballistics.trace(space, origin, velocity, exclude)
	var landing: Vector3 = still["points"][still["points"].size() - 1]
	if not still["hit"] or Vector2(landing.x - aim.x, landing.z - aim.z).length() > weapon.blast_radius + target.stats.radius:
		return null

	if wind_awareness > 0.0 and ctx.wind.speed > 0.0:
		var windy := Ballistics.trace(space, origin, velocity, exclude, wind_accel)
		var impact: Vector3 = windy["points"][windy["points"].size() - 1]
		var drift := Vector3(impact.x - aim.x, 0.0, impact.z - aim.z)
		var corrected := _solve(ctx.board, origin, aim - drift * wind_awareness, weapon, vmax)
		if corrected != Vector3.ZERO:
			velocity = corrected

	var horizontal := Vector2(velocity.x, velocity.z).length()
	var yaw := atan2(velocity.x, velocity.z) + _rng.randfn(0.0, deg_to_rad(aim_noise_deg))
	var pitch_angle := atan2(velocity.y, horizontal) + _rng.randfn(0.0, deg_to_rad(aim_noise_deg) * 0.5)
	pitch_angle = clampf(pitch_angle, _pitch_floor(ctx.board, origin, dir, weapon), deg_to_rad(weapon.pitch_max_deg))
	var power := velocity.length() / vmax * (1.0 + _rng.randfn(0.0, power_noise))
	return ShootAction.new(unit, FireParams.make(weapon, yaw, pitch_angle, power, charge, ammo))


## AP / ballista rounds against armor, cluster / hail against infantry, now and then incendiary / meteor, otherwise the first (HE / fireball).
func _pick_round(target: Unit, weapon: WeaponStats) -> RoundStats:
	if weapon.rounds.is_empty():
		return null
	var best_pen: RoundStats = weapon.rounds[0]
	var cluster: RoundStats = null
	var incendiary: RoundStats = null
	for r in weapon.rounds:
		if r.penetration_mult > best_pen.penetration_mult:
			best_pen = r
		if r.special == RoundStats.Special.CLUSTER or r.special == RoundStats.Special.AIRBURST:
			cluster = r      # a shower of small blasts (cluster / hail)
		elif r.special == RoundStats.Special.INCENDIARY or r.special == RoundStats.Special.METEOR:
			incendiary = r   # sets the ground ablaze (incendiary / meteor)
	if target.stats.armor_front + target.stats.armor_side > 8.0 and best_pen != weapon.rounds[0]:
		return best_pen
	if target.stats.kind == UnitStats.Kind.INFANTRY and cluster != null:
		return cluster
	if incendiary != null and _rng.randf() < 0.2:
		return incendiary
	return weapon.rounds[0]


## Lowest elevation the weapon can use here: its own limit, raised when ground just ahead of the muzzle rises
## above the barrel (capped at the weapon's maximum).
func _pitch_floor(board: GridBoard, muzzle: Vector3, flat_dir: Vector3, weapon: WeaponStats) -> float:
	return clampf(Ballistics.terrain_pitch_floor(board, muzzle, flat_dir),
		deg_to_rad(weapon.pitch_min_deg), deg_to_rad(weapon.pitch_max_deg))


## Still-air launch velocity for muzzle speed `vmax` within the weapon's limits (Vector3.ZERO if
## none exists): first at the weapon's default elevation with just enough power, otherwise at full power.
func _solve(board: GridBoard, origin: Vector3, aim: Vector3, weapon: WeaponStats, vmax: float) -> Vector3:
	var flat_dir := Vector3(aim.x - origin.x, 0.0, aim.z - origin.z).normalized()
	var pmin := _pitch_floor(board, origin, flat_dir, weapon)
	var pmax := deg_to_rad(weapon.pitch_max_deg)
	var flat := Vector3(aim.x - origin.x, 0.0, aim.z - origin.z).normalized()

	var pitch := clampf(deg_to_rad(weapon.default_pitch_deg), pmin, pmax)
	var speed := Ballistics.solve_speed(origin, aim, pitch)
	if speed > 0.0 and speed <= vmax and speed >= vmax * weapon.min_power:
		return _velocity(flat, pitch, speed)

	var full := Ballistics.solve_velocity(origin, aim, vmax, weapon.high_arc)
	if full == Vector3.ZERO:
		return Vector3.ZERO
	pitch = atan2(full.y, Vector2(full.x, full.z).length())
	if pitch >= pmin and pitch <= pmax:
		return full
	pitch = clampf(pitch, pmin, pmax)
	speed = Ballistics.solve_speed(origin, aim, pitch)
	if speed <= 0.0 or speed > vmax or speed < vmax * weapon.min_power:
		return Vector3.ZERO
	return _velocity(flat, pitch, speed)




func _velocity(flat: Vector3, pitch: float, speed: float) -> Vector3:
	return (flat * cos(pitch) + Vector3.UP * sin(pitch)) * speed


# --- positioning --------------------------------------------------------------

## Nothing in sight: walk to where an enemy was last seen, else scout toward a far-off point of the map.
func _search(unit: Unit, ctx: BattleContext) -> Action:
	var goal := Vector3.INF
	if _last_known.has(unit.team):
		goal = _last_known[unit.team]
		if _flat_distance(unit.global_position, goal) < search_arrival:
			_last_known.erase(unit.team)   # got there and nobody is around any more
			goal = Vector3.INF
	if goal == Vector3.INF:
		var id := unit.get_instance_id()
		if not _search_goal.has(id) or _flat_distance(unit.global_position, _search_goal[id]) < search_arrival:
			_search_goal[id] = _pick_scouting_point(unit, ctx)
		goal = _search_goal[id]
	return _move_toward(unit, goal, 0.0, 0.0, ctx)


## The farthest of a few random open cells: scouts spread out instead of dithering around their spawn.
func _pick_scouting_point(unit: Unit, ctx: BattleContext) -> Vector3:
	var cells := ctx.board.all_cells()
	var best := unit.global_position
	var best_d := -1.0
	for i in 8:
		var c: Vector2i = cells[_rng.randi() % cells.size()]
		if ctx.board.is_blocked(c):
			continue
		var p := ctx.board.cell_to_world(c)
		var d := _flat_distance(unit.global_position, p)
		if d > best_d:
			best_d = d
			best = p
	return best


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _approach(unit: Unit, goal_point: Vector3, ctx: BattleContext) -> Action:
	var weapon := unit.stats.main_weapon()
	var preferred := 1.5
	var reserve := 0.0
	if weapon != null:
		preferred = maxf(weapon.min_range + 1.0, weapon.max_range * preferred_range_ratio)
		reserve = weapon.ap_cost
	return _move_toward(unit, goal_point, preferred, reserve, ctx)


## Moves to the reachable cell whose distance to `goal_point` is closest to `preferred`, keeping `reserve` AP when possible.
func _move_toward(unit: Unit, goal_point: Vector3, preferred: float, reserve: float, ctx: BattleContext) -> Action:
	if not unit.can_do(ActionSpec.Kind.MOVE):
		return null
	var goal := Vector3(goal_point.x, 0.0, goal_point.z)
	var per_weight := unit.stats.move_ap_per_weight

	var best := unit.cell
	var best_score := _score(ctx.board.cell_to_world(unit.cell), goal, preferred)
	var reach := ctx.board.reachable(unit.cell, unit.ap / per_weight, false)
	for c: Vector2i in reach:
		if c == unit.cell:
			continue
		var score := _score(ctx.board.cell_to_world(c), goal, preferred)
		if unit.ap - reach[c] * per_weight < reserve:
			score += 2.0  # prefer moves that leave enough AP to fire afterwards
		if score < best_score - 0.01:
			best = c
			best_score = score
	if best == unit.cell:
		return null
	return MoveAction.new(unit, ctx.board.cell_to_world(best), true)


func _score(pos: Vector3, goal: Vector3, preferred: float) -> float:
	return absf(Vector2(pos.x - goal.x, pos.z - goal.z).length() - preferred)


## The nearest enemy this unit's team can see, or null. Remembers where it was for `_search`.
func _nearest_enemy(unit: Unit, ctx: BattleContext) -> Unit:
	var nearest: Unit = null
	var nearest_dist := INF
	for e in ctx.visible_enemies_of(unit):
		var d := unit.global_position.distance_to(e.global_position)
		if d < nearest_dist:
			nearest = e
			nearest_dist = d
	if nearest != null:
		_last_known[unit.team] = nearest.global_position
	return nearest
