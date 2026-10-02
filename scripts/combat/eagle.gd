class_name Eagle
extends Drone
## The ranger's spotter: a bald eagle that circles over its point (a smaller area than a drone covers) and stays there until the ranger
## sends it somewhere else (once per turn, see DroneAction) or dies. Same node as Drone - ring on the ground, beam, body overhead -
## only the body is a bird: flapping wings, a little banking, facing where it flies.

const EAGLE_HOVER := 4.2
const ORBIT_RADIUS := 1.3
const ORBIT_SPEED := 0.9        ## radians per second
const FLAP_FLYING := 9.0        ## wing beats (radians of phase) per second while it travels
const FLAP_SOARING := 2.6       ## ... and while it circles on station

var _wings: Array[Node3D] = []
var _flap := 0.0
var _station_time := 0.0


func hover_height() -> float:
	return EAGLE_HOVER


func _build_body(team_color: Color) -> void:
	var feathers := _mat(Color(0.30, 0.19, 0.10))
	var dark := _mat(Color(0.20, 0.12, 0.07))
	var white := _mat(Color(0.95, 0.95, 0.92))
	var gold := _mat(Color(0.95, 0.72, 0.15))
	_add(_ellipsoid(Vector3(0.17, 0.15, 0.40)), feathers, Vector3.ZERO)
	_add(_ellipsoid(Vector3(0.115, 0.115, 0.125)), white, Vector3(0.0, 0.06, 0.25))               # head
	var beak := CylinderMesh.new()
	beak.top_radius = 0.0
	beak.bottom_radius = 0.045
	beak.height = 0.14
	var beak_mi := _add(beak, gold, Vector3(0.0, 0.035, 0.40))
	beak_mi.rotation.x = PI / 2.0                                                                    # cone axis Y -> +Z
	var tail := BoxMesh.new()
	tail.size = Vector3(0.20, 0.025, 0.24)
	_add(tail, white, Vector3(0.0, 0.0, -0.40))
	var lamp := _mat(team_color)
	lamp.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_add(_ellipsoid(Vector3(0.07, 0.05, 0.07)), lamp, Vector3(0.0, -0.10, -0.12))                    # team band under the belly
	for side in [-1.0, 1.0]:
		var wing := Node3D.new()                 # pivots at the shoulder; the planks stick out sideways
		wing.position = Vector3(0.10 * side, 0.03, 0.04)
		var inner := BoxMesh.new()
		inner.size = Vector3(0.42, 0.03, 0.34)
		var inner_mi := MeshInstance3D.new()
		inner_mi.mesh = inner
		inner_mi.material_override = feathers
		inner_mi.position = Vector3(0.21 * side, 0.0, 0.0)
		wing.add_child(inner_mi)
		var outer := BoxMesh.new()
		outer.size = Vector3(0.34, 0.022, 0.26)
		var outer_mi := MeshInstance3D.new()
		outer_mi.mesh = outer
		outer_mi.material_override = dark
		outer_mi.position = Vector3(0.59 * side, 0.0, -0.04)
		wing.add_child(outer_mi)
		_body.add_child(wing)
		_wings.append(wing)


func _face_travel(to: Vector3) -> void:
	var d := to - _body.global_position
	if Vector2(d.x, d.z).length() > 0.05:
		_body.rotation = Vector3(0.0, atan2(d.x, d.z), 0.0)


func _animate(delta: float) -> void:
	_flap += delta * (FLAP_FLYING if _flying else FLAP_SOARING)
	var beat := sin(_flap)
	var amplitude := 0.55 if _flying else 0.22
	for i in _wings.size():
		_wings[i].rotation.z = beat * amplitude * (1.0 if i == 1 else -1.0)   # wing 0 is the right one (-X): mirrored
	if _on_station and not _departing:
		_station_time += delta
		var radius := ORBIT_RADIUS * smoothstep(0.0, 1.2, _station_time)
		var a := _time * ORBIT_SPEED
		_body.position = Vector3(cos(a) * radius, EAGLE_HOVER + sin(_time * 1.9) * 0.12, sin(a) * radius)
		_body.rotation = Vector3(0.0, -a, 0.22)   # tangent heading, banking into the circle
	elif not _on_station:
		_station_time = 0.0


func _ellipsoid(radii: Vector3) -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 12
	sphere.rings = 6
	var mi := MeshInstance3D.new()
	mi.mesh = sphere
	mi.scale = radii
	return mi


## Adds a mesh (or an already built instance) to the body with `mat` at `pos`.
func _add(mesh_or_instance: Variant, mat: Material, pos: Vector3) -> MeshInstance3D:
	var mi: MeshInstance3D
	if mesh_or_instance is MeshInstance3D:
		mi = mesh_or_instance
	else:
		mi = MeshInstance3D.new()
		mi.mesh = mesh_or_instance
	mi.material_override = mat
	mi.position = pos
	_body.add_child(mi)
	return mi
