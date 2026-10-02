class_name TacticsCamera
extends Camera3D
## Fixed-pitch orthographic camera: WASD pan, Q/E rotate in 90-degree steps, wheel zoom.
## Shot camera: follow(shell) zooms in and tracks a projectile, release() lingers on the impact
## and then eases back to where the player was looking (toggle with TacticsCamera.shot_cam_enabled).

enum Mode { IDLE, FOLLOW, HOLD, RETURN }

@export var pitch_deg: float = 45.0
@export var distance: float = 30.0
@export var pan_speed: float = 8.0
@export var min_size: float = 6.0
@export var max_size: float = 80.0
@export var start_size: float = 38.0
@export var shot_cam_enabled: bool = true
@export var shot_zoom: float = 12.0       ## orthographic size while following a shell
@export var follow_speed: float = 7.0     ## higher = tighter tracking

var focus: Vector3 = Vector3.ZERO
var yaw_deg: float = 45.0
var mode: Mode = Mode.IDLE

var _follow_node: Node3D
var _follow_pos := Vector3.ZERO
var _saved_focus := Vector3.ZERO
var _saved_size := 0.0
var _hold_left := 0.0


func _ready() -> void:
	projection = Camera3D.PROJECTION_ORTHOGONAL
	size = start_size
	near = 0.1
	far = 200.0
	_apply()


## Starts tracking `target` (a shell). Remembers the current view so release() can restore it.
func follow(target: Node3D) -> void:
	if not shot_cam_enabled:
		return
	if mode == Mode.IDLE:
		_saved_focus = focus
		_saved_size = size
	_follow_node = target
	_follow_pos = target.global_position
	mode = Mode.FOLLOW


## Glides to `point` keeping the current zoom (turn start: the acting unit must be on screen however the
## player panned). During a shot-camera sequence only the view it will return to is changed.
func focus_on(point: Vector3) -> void:
	_saved_focus = Vector3(point.x, 0.0, point.z)
	if mode == Mode.IDLE:
		_saved_size = size
		mode = Mode.RETURN


## The shell has landed: linger `hold` seconds on the impact, then return to the saved view.
func release(hold: float = 1.0) -> void:
	if mode == Mode.FOLLOW:
		if is_instance_valid(_follow_node):
			_follow_pos = _follow_node.global_position
		_hold_left = hold
		mode = Mode.HOLD


func _process(delta: float) -> void:
	match mode:
		Mode.FOLLOW:
			if is_instance_valid(_follow_node):
				_follow_pos = _follow_node.global_position
			_ease_to(_follow_pos, shot_zoom, delta, follow_speed)
		Mode.HOLD:
			_ease_to(_follow_pos, shot_zoom, delta, follow_speed)
			_hold_left -= delta
			if _hold_left <= 0.0:
				mode = Mode.RETURN
		Mode.RETURN:
			_ease_to(_saved_focus, _saved_size, delta, 4.0)
			if focus.distance_to(_saved_focus) < 0.05 and absf(size - _saved_size) < 0.1:
				focus = _saved_focus
				size = _saved_size
				mode = Mode.IDLE
		_:
			_pan(delta)
	_apply()


func _ease_to(target_focus: Vector3, target_size: float, delta: float, speed: float) -> void:
	var t := 1.0 - exp(-speed * delta)
	focus = focus.lerp(target_focus, t)
	size = lerpf(size, target_size, t)


func _pan(delta: float) -> void:
	var yaw := deg_to_rad(yaw_deg)
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := fwd.cross(Vector3.UP)
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		dir += fwd
	if Input.is_key_pressed(KEY_S):
		dir -= fwd
	if Input.is_key_pressed(KEY_D):
		dir += right
	if Input.is_key_pressed(KEY_A):
		dir -= right
	focus += dir.normalized() * pan_speed * (size / 14.0) * delta



func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		if key.keycode == KEY_Q:
			yaw_deg -= 90.0
		elif key.keycode == KEY_E:
			yaw_deg += 90.0
		return
	var wheel := event as InputEventMouseButton
	if wheel != null and wheel.pressed:
		var step := 0.0
		if wheel.button_index == MOUSE_BUTTON_WHEEL_UP:
			step = -1.0
		elif wheel.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			step = 1.0
		if step != 0.0:
			if mode == Mode.IDLE:
				size = clampf(size + step, min_size, max_size)
			else:   # mid shot / glide: change the zoom the camera settles on
				_saved_size = clampf(_saved_size + step, min_size, max_size)


## Horizontal view direction ("up" on screen) and screen-right, flattened onto the ground.
func flat_forward() -> Vector3:
	var f := -global_transform.basis.z
	f.y = 0.0
	return f.normalized()


func flat_right() -> Vector3:
	var r := global_transform.basis.x
	r.y = 0.0
	return r.normalized()


## Ground vector -> screen direction (x right, y down), for top-down widgets that follow the camera.
func to_screen_dir(world_flat: Vector3) -> Vector2:
	return Vector2(world_flat.dot(flat_right()), -world_flat.dot(flat_forward()))


## Inverse of to_screen_dir: screen offset -> ground vector.
func from_screen_dir(screen: Vector2) -> Vector3:
	return flat_right() * screen.x - flat_forward() * screen.y


func _apply() -> void:
	var yaw := deg_to_rad(yaw_deg)
	var pitch := deg_to_rad(pitch_deg)
	var offset := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
	look_at_from_position(focus + offset, focus, Vector3.UP)
