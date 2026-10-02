class_name GuideView
extends Node3D
## Transient world-space guidance: dotted paths / trajectories, flat discs (blast zone,
## scatter, active-unit ring) and a floating text label. Slots are addressed by name and
## created on demand, so callers just say show_dots("trajectory", ...) / clear().

const DISC_HEIGHT := 0.02

var _dots: Dictionary = {}   # slot -> MultiMeshInstance3D
var _discs: Dictionary = {}  # slot -> MeshInstance3D
var _dot_mesh := SphereMesh.new()
var _disc_mesh := CylinderMesh.new()
var _label := Label3D.new()


func _ready() -> void:
	_dot_mesh.radius = 0.07
	_dot_mesh.height = 0.14
	_dot_mesh.radial_segments = 8
	_dot_mesh.rings = 4
	_disc_mesh.top_radius = 1.0
	_disc_mesh.bottom_radius = 1.0
	_disc_mesh.height = DISC_HEIGHT
	_disc_mesh.radial_segments = 40
	_disc_mesh.rings = 1
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.pixel_size = 0.01
	UiTheme.style_label3d(_label, UiTheme.LARGE)
	_label.outline_size = 10
	_label.visible = false
	add_child(_label)


## Dotted polyline, re-sampled every `spacing` metres.
func show_dots(slot: String, points: PackedVector3Array, color: Color, spacing: float = 0.35) -> void:
	var mmi := _dot_slot(slot)
	var samples := _resample(points, spacing)
	mmi.multimesh.instance_count = samples.size()
	for i in samples.size():
		mmi.multimesh.set_instance_transform(i, Transform3D(Basis(), samples[i]))
	(mmi.material_override as StandardMaterial3D).albedo_color = color
	mmi.visible = samples.size() > 0


func hide_dots(slot: String) -> void:
	if _dots.has(slot):
		(_dots[slot] as MultiMeshInstance3D).visible = false


## Flat translucent disc lying on the ground at `centre` (its y is used as the height).
func show_disc(slot: String, centre: Vector3, radius: float, color: Color) -> void:
	var mi := _disc_slot(slot)
	mi.position = centre
	mi.scale = Vector3(radius, 1.0, radius)
	(mi.material_override as StandardMaterial3D).albedo_color = color
	mi.visible = true


func hide_disc(slot: String) -> void:
	if _discs.has(slot):
		(_discs[slot] as MeshInstance3D).visible = false


func show_label(pos: Vector3, text: String, color: Color) -> void:
	_label.position = pos
	_label.text = text
	_label.modulate = color
	_label.visible = true


func hide_label() -> void:
	_label.visible = false


## Hides everything except the slots named in `keep`.
func clear(keep: Array = []) -> void:
	for slot: String in _dots:
		if not keep.has(slot):
			hide_dots(slot)
	for slot: String in _discs:
		if not keep.has(slot):
			hide_disc(slot)
	hide_label()


func _dot_slot(slot: String) -> MultiMeshInstance3D:
	if not _dots.has(slot):
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _dot_mesh
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = _unshaded()
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
		_dots[slot] = mmi
	return _dots[slot]


func _disc_slot(slot: String) -> MeshInstance3D:
	if not _discs.has(slot):
		var mi := MeshInstance3D.new()
		mi.mesh = _disc_mesh
		mi.material_override = _unshaded()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_discs[slot] = mi
	return _discs[slot]


func _unshaded() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat


static func _resample(points: PackedVector3Array, spacing: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	if points.is_empty():
		return out
	out.append(points[0])
	var carry := 0.0  # distance travelled since the last emitted sample
	for i in range(1, points.size()):
		var a := points[i - 1]
		var b := points[i]
		var seg := a.distance_to(b)
		if seg < 0.0001:
			continue
		var d := spacing - carry
		while d <= seg:
			out.append(a.lerp(b, d / seg))
			d += spacing
		carry = seg - (d - spacing)
	return out
