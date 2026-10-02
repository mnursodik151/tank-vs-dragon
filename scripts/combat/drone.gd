class_name Drone
extends Node3D
## Physical marker for a spotting drone on station (see DroneAction / Intel): a small quadcopter
## hovering over the spotted point, a beam down to the ground and a ring showing the area it
## covers. The node sits on the ground at the target; only the body bobs. `depart()` flies it away.

const HOVER_HEIGHT := 3.2
const RING_COLOR := Color(0.5, 0.95, 0.65)

var _body := Node3D.new()
var _rotors: Array[MeshInstance3D] = []
var _ring := MeshInstance3D.new()
var _ring_mat: StandardMaterial3D
var _beam := MeshInstance3D.new()
var _time := 0.0
var _departing := false
var _on_station := false
var _flying := false


## Height the body hovers at above the ground point.
func hover_height() -> float:
	return HOVER_HEIGHT


## Builds the visuals for a drone covering `radius` metres, its lamp in `team_color`.
func build(team_color: Color, radius: float) -> void:
	_build_body(team_color)
	_body.visible = false
	add_child(_body)

	var torus := TorusMesh.new()
	torus.inner_radius = maxf(radius - 0.07, 0.1)
	torus.outer_radius = radius + 0.07
	_ring.mesh = torus
	_ring_mat = _glow(Color(RING_COLOR, 0.9))
	_ring.material_override = _ring_mat
	_ring.position.y = 0.05
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.visible = false
	add_child(_ring)

	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.025
	cyl.bottom_radius = 0.025
	cyl.height = hover_height()
	_beam.mesh = cyl
	_beam.material_override = _glow(Color(RING_COLOR, 0.4))
	_beam.position.y = hover_height() / 2.0
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beam.visible = false
	add_child(_beam)


## The flying thing itself (a subclass makes its own): fills `_body`, which `build` then hides until it flies in.
func _build_body(team_color: Color) -> void:
	var dark := _mat(Color(0.18, 0.19, 0.22))
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 0.16, 0.5)
	body.mesh = box
	body.material_override = dark
	_body.add_child(body)
	var light := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.1
	sphere.height = 0.2
	light.mesh = sphere
	light.position.y = -0.12
	var lamp := _mat(team_color)
	lamp.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	light.material_override = lamp
	_body.add_child(light)
	for i in 4:
		var a := PI / 4.0 + PI * 0.5 * i
		var tip := Vector3(cos(a), 0.0, sin(a)) * 0.5
		var arm := MeshInstance3D.new()
		var arm_mesh := BoxMesh.new()
		arm_mesh.size = Vector3(0.5, 0.05, 0.05)
		arm.mesh = arm_mesh
		arm.material_override = dark
		arm.position = tip * 0.5
		arm.rotation.y = -a
		_body.add_child(arm)
		var rotor := MeshInstance3D.new()
		var disc := CylinderMesh.new()
		disc.top_radius = 0.22
		disc.bottom_radius = 0.22
		disc.height = 0.012
		rotor.mesh = disc
		var rm := _mat(Color(0.85, 0.9, 1.0, 0.45))
		rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		rotor.material_override = rm
		rotor.position = tip + Vector3(0.0, 0.07, 0.0)
		_body.add_child(rotor)
		_rotors.append(rotor)


## Flies the drone from `from` (world) to hover over this node's position. Awaitable.
func fly_in(from: Vector3) -> void:
	_body.global_position = from
	_body.visible = true
	await _glide_to_station()


## Moves this node (and the area it covers) to `ground` and flies the body over from where it hovers now. Awaitable.
func relocate(ground: Vector3) -> void:
	var from := _body.global_position
	_on_station = false
	_ring.visible = false
	_beam.visible = false
	global_position = ground
	_body.global_position = from
	await _glide_to_station()


func _glide_to_station() -> void:
	_flying = true
	var hover := global_position + Vector3(0.0, hover_height(), 0.0)
	var dist := _body.global_position.distance_to(hover)
	var tw := create_tween()
	tw.tween_property(_body, "global_position", hover, clampf(dist / 14.0, 0.5, 1.4)) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_face_travel(hover)
	await tw.finished
	_flying = false
	_on_station = true
	_ring.visible = true
	_beam.visible = true
	_ring.scale = Vector3(0.2, 1.0, 0.2)
	create_tween().tween_property(_ring, "scale", Vector3.ONE, 0.35)


## Turns the body toward where it is flying (a quadcopter does not care; the eagle does).
func _face_travel(_to: Vector3) -> void:
	pass


func depart() -> void:
	if _departing:
		return
	_departing = true
	_on_station = false
	_ring.visible = false
	_beam.visible = false
	var tw := create_tween()
	tw.tween_property(_body, "position:y", hover_height() + 9.0, 0.9).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(queue_free)


func _process(delta: float) -> void:
	_time += delta
	_animate(delta)
	if _on_station and not _departing:
		_ring_mat.albedo_color.a = 0.65 + 0.25 * sin(_time * 3.0)


## Per-frame motion of the body: rotors spinning, and the little hover wobble while on station.
func _animate(delta: float) -> void:
	for r in _rotors:
		r.rotation.y += delta * 55.0
	if _on_station and not _departing:
		_body.position = Vector3(sin(_time * 0.9) * 0.12, hover_height() + sin(_time * 1.7) * 0.1, cos(_time * 0.7) * 0.12)
		_body.rotation = Vector3(sin(_time * 1.3) * 0.05, 0.0, cos(_time * 1.1) * 0.05)


static func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.8
	return m


static func _glow(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = color
	return m
