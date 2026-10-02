class_name Shell
extends Node3D
## A projectile in flight (cannon shell, rocket, bullet). Follows the analytic parabola
## (gravity + wind) and raycasts along each physics step, so it never tunnels. Optionally draws a
## ShotTrail behind it. The *consequences* (Explosion) are what hand bodies to the physics engine.

signal impacted(point: Vector3, hit: bool, collider: Object)

var flight_time := 0.0
var path := PackedVector3Array()    ## every flight sample (for GameState)
var trail: ShotTrail
var impact_normal := Vector3.UP     ## surface normal where it struck (set before `impacted` fires)
var impact_velocity := Vector3.ZERO ## velocity at the moment of impact
var airburst := false               ## it burst in the air (fuse_distance) instead of striking something
var fuse_distance := 0.0            ## > 0: proximity fuse - bursts when terrain or a unit lies this far ahead along its flight path
var burst_landing := Vector3.ZERO   ## where it was heading when the fuse fired (the surface it would have struck)

var _origin := Vector3.ZERO
var _velocity := Vector3.ZERO
var _wind_accel := Vector3.ZERO
var _exclude: Array[RID] = []
var _done := false
var _mi := MeshInstance3D.new()
var _mat := StandardMaterial3D.new()
var _model: Node3D   ## the projectile model (gunnery rounds); bullets stay tinted dots

const MODEL_LENGTH_PER_RADIUS := 6.0   ## shell model length = weapon.shell_radius * this


func _ready() -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	mesh.radial_segments = 8
	mesh.rings = 4
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mi.mesh = mesh
	_mi.material_override = _mat
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mi)


## Call after the shell has been added to the tree.
func launch(origin: Vector3, velocity: Vector3, exclude: Array[RID], wind_accel: Vector3 = Vector3.ZERO,
		radius: float = 0.12, color: Color = Color(1.0, 0.85, 0.3), with_trail: bool = false, projectile: String = "shell") -> void:
	_origin = origin
	_velocity = velocity
	_wind_accel = wind_accel
	_exclude = exclude
	_mat.albedo_color = color
	_mi.scale = Vector3.ONE * radius * 2.0
	if with_trail:   # gunnery shells fly as the shell model, pointed along the flight path; the trail keeps the round's colour
		_model = UnitModel.make_projectile(projectile, radius * MODEL_LENGTH_PER_RADIUS)
		if _model != null:
			_mi.visible = false
			add_child(_model)
	global_position = origin
	path.append(origin)
	if with_trail:
		trail = ShotTrail.new()
		trail.color = color
		get_parent().add_child(trail)
		trail.add_point(origin)


func _physics_process(delta: float) -> void:
	if _done:
		return
	var prev := global_position
	flight_time += delta
	var next := Ballistics.position_at(_origin, _velocity, flight_time, _wind_accel)
	var query := PhysicsRayQueryParameters3D.create(prev, next, Ballistics.MASK, _exclude)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		impact_normal = hit["normal"]
		impact_velocity = _velocity_at(flight_time)
		_finish(hit["position"], true, hit["collider"])
		return
	if fuse_distance > 0.0 and next.distance_to(prev) > 0.0001:
		var ahead := PhysicsRayQueryParameters3D.create(next, next + (next - prev).normalized() * fuse_distance, Ballistics.MASK, _exclude)
		var near := get_world_3d().direct_space_state.intersect_ray(ahead)
		if not near.is_empty():
			airburst = true
			burst_landing = near["position"]
			impact_velocity = _velocity_at(flight_time)
			global_position = next
			_finish(next, true, null)
			return
	global_position = next
	if _model != null and next.distance_to(prev) > 0.0001:
		var dir := (next - prev).normalized()
		look_at(next + dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT)
	path.append(next)
	if trail != null:
		trail.add_point(next)
	if next.y < Ballistics.MIN_Y or flight_time > Ballistics.MAX_TIME:
		_finish(next, false, null)


func _velocity_at(t: float) -> Vector3:
	return _velocity + (Vector3.DOWN * Ballistics.gravity() + _wind_accel) * t


func _finish(point: Vector3, hit: bool, collider: Object) -> void:
	_done = true
	visible = false
	path.append(point)
	if trail != null:
		trail.add_point(point)
		trail.finish()
	impacted.emit(point, hit, collider)
	queue_free()
