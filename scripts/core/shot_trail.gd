class_name ShotTrail
extends Node3D
## Camera-facing ribbon drawn behind a shell in flight: the parabola reads as a glowing line
## that is brightest at the shell and fades toward the muzzle. After impact it lingers a moment
## and then fades out and frees itself.

const WIDTH := 0.09
const FADE_TIME := 2.2

var color := Color(1.0, 0.85, 0.3)

var _points := PackedVector3Array()
var _mesh := ImmediateMesh.new()
var _mat := StandardMaterial3D.new()
var _dirty := false
var _fading := false
var _alpha := 1.0


func _ready() -> void:
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.vertex_color_use_as_albedo = true
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh
	mi.material_override = _mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.top_level = true   # points are in world space
	add_child(mi)


func add_point(p: Vector3) -> void:
	_points.append(p)
	_dirty = true


## Starts the fade-out (call when the projectile has landed).
func finish() -> void:
	_fading = true


func _process(delta: float) -> void:
	if _fading:
		_alpha -= delta / FADE_TIME
		if _alpha <= 0.0:
			queue_free()
			return
		_dirty = true
	if _dirty:
		_rebuild()
		_dirty = false


func _rebuild() -> void:
	_mesh.clear_surfaces()
	var n := _points.size()
	if n < 2:
		return
	var cam := get_viewport().get_camera_3d()
	var view := cam.global_transform.basis.z if cam != null else Vector3.BACK
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in n:
		var a := _points[maxi(i - 1, 0)]
		var b := _points[mini(i + 1, n - 1)]
		var dir := (b - a).normalized()
		var side := dir.cross(view).normalized()
		var t := float(i) / float(n - 1)
		var half := WIDTH * (0.25 + 0.75 * t)
		var c := Color(color, (0.05 + 0.95 * t) * _alpha)
		_mesh.surface_set_color(c)
		_mesh.surface_add_vertex(_points[i] + side * half)
		_mesh.surface_set_color(c)
		_mesh.surface_add_vertex(_points[i] - side * half)
	_mesh.surface_end()
