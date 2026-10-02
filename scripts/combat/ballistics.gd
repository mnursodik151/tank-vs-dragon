class_name Ballistics
extends RefCounted
## Projectile maths + a raycast tracer. Shells follow the analytic curve
##   p(t) = origin + v0 * t + 0.5 * (gravity + wind_accel) * t^2
## (no drag). The solvers below work in still air; wind is only ever applied to shells in
## flight (and optionally by the AI to estimate its own drift).

const STEP := 0.04          ## trace sampling step, seconds
const MAX_TIME := 12.0      ## flight time cap, seconds
const MIN_Y := -4.0         ## shells below this are lost
const MASK := Unit.LAYER_TERRAIN | Unit.LAYER_UNITS
const CLEARANCE_RANGE := 3.0   ## ground this far ahead of the muzzle can stop the barrel from depressing
const CLEARANCE_STEP := 0.4

static func gravity() -> float:
	return float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))

static func position_at(origin: Vector3, velocity: Vector3, t: float, wind_accel: Vector3 = Vector3.ZERO) -> Vector3:
	return origin + velocity * t + (Vector3.DOWN * gravity() + wind_accel) * (0.5 * t * t)

## Launch velocity that lands a shell of the given muzzle speed on `target` (still air).
## Returns Vector3.ZERO when the target is out of reach (or directly above/below the muzzle).
static func solve_velocity(origin: Vector3, target: Vector3, speed: float, high_arc: bool) -> Vector3:
	var g := gravity()
	var flat := Vector3(target.x - origin.x, 0.0, target.z - origin.z)
	var d := flat.length()
	if d < 0.01:
		return Vector3.ZERO
	var h := target.y - origin.y
	var v2 := speed * speed
	var disc := v2 * v2 - g * (g * d * d + 2.0 * h * v2)
	if disc < 0.0:
		return Vector3.ZERO
	var root := sqrt(disc)
	var tan_theta := ((v2 + root) if high_arc else (v2 - root)) / (g * d)
	var theta := atan(tan_theta)
	return flat / d * speed * cos(theta) + Vector3.UP * speed * sin(theta)

## Muzzle speed needed to reach `target` at a fixed barrel pitch (still air).
## Returns -1.0 when that pitch can never reach it.
static func solve_speed(origin: Vector3, target: Vector3, pitch: float) -> float:
	var g := gravity()
	var d := Vector2(target.x - origin.x, target.z - origin.z).length()
	var h := target.y - origin.y
	var denom := 2.0 * pow(cos(pitch), 2.0) * (d * tan(pitch) - h)
	if d < 0.01 or denom <= 0.0:
		return -1.0
	return sqrt(g * d * d / denom)

## Lowest barrel pitch (radians) that does not point the muzzle into rising ground just ahead of it: standing at
## the foot of a hill or cliff, the gun has to be raised to clear it. Very negative on open ground.
static func terrain_pitch_floor(board: GridBoard, muzzle: Vector3, flat_dir: Vector3) -> float:
	var floor_angle := -PI / 2.0
	var d := CLEARANCE_STEP
	while d <= CLEARANCE_RANGE:
		var ground := board.surface_y(muzzle + flat_dir * d)
		floor_angle = maxf(floor_angle, atan2(ground - muzzle.y, d))
		d += CLEARANCE_STEP
	return floor_angle

## Level-ground range of a shell fired at `pitch` with `speed` (still air).
static func flat_range(speed: float, pitch: float) -> float:
	if pitch <= 0.0:
		return 0.0
	return speed * speed * sin(2.0 * pitch) / gravity()

## Walks the curve and stops at the first collider. Returns
## {"points": PackedVector3Array, "hit": bool, "collider": Object (or null)}.
static func trace(space: PhysicsDirectSpaceState3D, origin: Vector3, velocity: Vector3, exclude: Array[RID], wind_accel: Vector3 = Vector3.ZERO) -> Dictionary:
	var pts := PackedVector3Array([origin])
	var prev := origin
	var t := 0.0
	while t < MAX_TIME:
		t += STEP
		var p := position_at(origin, velocity, t, wind_accel)
		var query := PhysicsRayQueryParameters3D.create(prev, p, MASK, exclude)
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			pts.append(hit["position"])
			return {"points": pts, "hit": true, "collider": hit["collider"]}
		pts.append(p)
		prev = p
		if p.y < MIN_Y:
			break
	return {"points": pts, "hit": false, "collider": null}
