class_name WindIndicator
extends Control
## Small compass in the corner showing wind direction (rotated with the camera) and speed.

const COMPASS_RADIUS := 30.0

var wind: Wind


func _init() -> void:
	custom_minimum_size = Vector2(150.0, 100.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if wind == null:
		return
	var font := UiTheme.font
	UiTheme.draw_panel(self, Rect2(0.0, 2.0, size.x, 92.0), 1)
	var c := Vector2(size.x - 52.0, 48.0)
	draw_circle(c, COMPASS_RADIUS + 6.0, Color(0.06, 0.07, 0.09, 0.8))
	draw_arc(c, COMPASS_RADIUS + 6.0, 0.0, TAU, 40, Color(0.4, 0.43, 0.5), 2.0)

	var cam := get_viewport().get_camera_3d() as TacticsCamera
	var dir := Vector2.UP
	if cam != null:
		dir = cam.to_screen_dir(wind.direction())
	var t := wind.speed / Wind.MAX_SPEED
	var col := Color(0.4, 0.9, 0.5).lerp(Color(1.0, 0.45, 0.25), clampf(t * 1.4, 0.0, 1.0))
	var half := 6.0 + 20.0 * t
	var tail := c - dir * half
	var tip := c + dir * half
	draw_line(tail, tip, col, 4.0)
	var side := Vector2(-dir.y, dir.x)
	draw_colored_polygon(PackedVector2Array([tip + dir * 8.0, tip + side * 6.0, tip - side * 6.0]), col)

	draw_string(font, Vector2(0.0, 40.0), "WIND", HORIZONTAL_ALIGNMENT_RIGHT, size.x - 108.0, UiTheme.fs(13), Color(0.7, 0.73, 0.8))
	draw_string(font, Vector2(0.0, 60.0), "%.1f m/s" % wind.speed, HORIZONTAL_ALIGNMENT_RIGHT, size.x - 108.0, UiTheme.fs(16), col)
