class_name Wind
extends RefCounted
## Battlefield wind: a flat vector that accelerates every shell sideways. It drifts a little
## each round. Lobbed shells (long flight time) suffer most, bullets barely notice.

const MAX_SPEED := 10.0     ## m/s
const COUPLING := 0.1       ## shell acceleration (m/s^2) per m/s of wind

var speed := 0.0            ## m/s
var angle := 0.0            ## radians, direction the wind blows TOWARD (same convention as Unit.face: atan2(x, z))
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.randomize()
	randomize_all()


func randomize_all() -> void:
	speed = _rng.randf_range(0.0, MAX_SPEED * 0.8)
	angle = _rng.randf() * TAU


## Called once per round: small shifts in speed and heading.
func drift() -> void:
	speed = clampf(speed + _rng.randfn(0.0, 1.5), 0.0, MAX_SPEED)
	angle = wrapf(angle + _rng.randfn(0.0, 0.5), -PI, PI)


func set_fixed(p_speed: float, p_angle: float) -> void:
	speed = clampf(p_speed, 0.0, MAX_SPEED)
	angle = p_angle


## Flat direction the wind blows toward.
func direction() -> Vector3:
	return Vector3(sin(angle), 0.0, cos(angle))


## Horizontal acceleration applied to a shell in flight.
func accel() -> Vector3:
	return direction() * speed * COUPLING
