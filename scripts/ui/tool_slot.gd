class_name ToolSlot
extends Control
## One MMO-style hotbar slot: hotkey number, procedural glyph, name, AP cost. Draws itself so
## the look stays under our control; emits `pressed` on left click.

signal pressed

const SLOT_SIZE := Vector2(80.0, 84.0)

var index := 0
var entry: ToolEntry
var active := false:
	set(value):
		active = value
		queue_redraw()
var affordable := true:
	set(value):
		affordable = value
		queue_redraw()

var cooldown := 0:                  ## turns until usable again (drone); shown over the slot
	set(value):
		if value != cooldown:
			cooldown = value
			queue_redraw()

var _hover := false


func _init() -> void:
	custom_minimum_size = SLOT_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(_set_hover.bind(true))
	mouse_exited.connect(_set_hover.bind(false))


func configure(p_index: int, p_entry: ToolEntry) -> void:
	index = p_index
	entry = p_entry
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	var click := event as InputEventMouseButton
	if click != null and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		pressed.emit()


func _set_hover(on: bool) -> void:
	_hover = on
	queue_redraw()


func _draw() -> void:
	if entry == null:
		return
	var font := UiTheme.font
	# Flat_Theme slot frames: dark slate normally, lighter on hover, the orange one when selected (dark ink on it)
	var frame := "FrameSlot03a" if active else "FrameSlot01a"
	var frame_tint := Color.WHITE if active else (Color(0.62, 0.66, 0.80) if _hover else Color(0.36, 0.39, 0.50))
	UiTheme.draw_box(self, frame, Rect2(Vector2.ZERO, size), 6, frame_tint)

	var ink := Color(0.10, 0.08, 0.04) if active else Color.WHITE
	var tint := ink if affordable else (Color(0.45, 0.2, 0.15) if active else Color(0.55, 0.45, 0.45))
	_draw_glyph(entry.glyph, Vector2(size.x / 2.0, 36.0), tint)

	draw_string(font, Vector2(7.0, 15.0), str(index + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(13), Color(0.35, 0.2, 0.0) if active else Color(1.0, 0.82, 0.25))
	draw_string(font, Vector2(0.0, size.y - 8.0), entry.label, HORIZONTAL_ALIGNMENT_CENTER, size.x, UiTheme.fs(12), tint)
	if entry.cost() > 0.0:
		var cost_color := Color(0.75, 0.9, 1.0) if affordable else Color(1.0, 0.4, 0.35)
		if active:
			cost_color = Color(0.1, 0.15, 0.35) if affordable else Color(0.6, 0.1, 0.05)
		draw_string(font, Vector2(0.0, 15.0), "%.1f AP" % entry.cost(), HORIZONTAL_ALIGNMENT_RIGHT, size.x - 7.0, UiTheme.fs(12), cost_color)
	if cooldown > 0:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.0, 0.0, 0.45))
		draw_string(font, Vector2(0.0, 40.0), "CD %d" % cooldown, HORIZONTAL_ALIGNMENT_CENTER, size.x, UiTheme.fs(18), Color(1.0, 0.75, 0.35))
		draw_string(font, Vector2(0.0, 54.0), "turn%s" % ("s" if cooldown > 1 else ""), HORIZONTAL_ALIGNMENT_CENTER, size.x, UiTheme.fs(10), Color(1.0, 0.75, 0.35))


func _draw_glyph(glyph: String, c: Vector2, col: Color) -> void:
	match glyph:
		"move":
			draw_line(c + Vector2(-18, 0), c + Vector2(14, 0), col, 4.0)
			draw_colored_polygon(PackedVector2Array([c + Vector2(20, 0), c + Vector2(8, -10), c + Vector2(8, 10)]), col)
		"cannon":
			draw_line(c + Vector2(-12, 5), c + Vector2(20, -5), col, 9.0)
			draw_circle(c + Vector2(-12, 10), 9.0, col)
		"howitzer":
			draw_line(c + Vector2(-8, 10), c + Vector2(14, -16), col, 8.0)
			draw_rect(Rect2(c + Vector2(-20, 8), Vector2(34, 10)), col)
		"rocket":
			draw_line(c + Vector2(-16, 12), c + Vector2(8, -10), col, 7.0)
			draw_colored_polygon(PackedVector2Array([c + Vector2(18, -18), c + Vector2(4, -14), c + Vector2(14, -4)]), col)
			draw_circle(c + Vector2(-18, 14), 4.0, Color(1.0, 0.6, 0.2))
		"mg":
			for dy in [-9.0, 0.0, 9.0]:
				draw_line(c + Vector2(-18, dy), c + Vector2(8, dy), col, 3.0)
				draw_circle(c + Vector2(14, dy), 2.5, col)
		"rifle":
			draw_line(c + Vector2(-8, 4), c + Vector2(20, -4), col, 3.0)
			draw_line(c + Vector2(-20, 8), c + Vector2(-6, 3), col, 7.0)
		"drone":
			for s in [-1.0, 1.0]:
				draw_line(c + Vector2(-4.0 * s, 0), c + Vector2(-17.0 * s, -9), col, 3.0)
				draw_line(c + Vector2(4.0 * s, 0), c + Vector2(17.0 * s, 9), col, 3.0)
				draw_arc(c + Vector2(-17.0 * s, -9), 6.0, 0.0, TAU, 12, col, 2.0)
				draw_arc(c + Vector2(17.0 * s, 9), 6.0, 0.0, TAU, 12, col, 2.0)
			draw_rect(Rect2(c + Vector2(-6, -5), Vector2(12, 10)), col)
		"staff":
			draw_line(c + Vector2(-14, 18), c + Vector2(8, -10), col, 4.0)
			draw_arc(c + Vector2(12, -15), 8.0, 0.0, TAU, 14, col, 3.0)
			draw_circle(c + Vector2(12, -15), 3.5, Color(1.0, 0.6, 0.2))
		"octo":
			draw_line(c + Vector2(-6, 8), c + Vector2(18, -8), col, 9.0)
			draw_circle(c + Vector2(-10, 12), 8.0, col)
			draw_arc(c + Vector2(-14, -6), 8.0, PI * 0.5, PI * 1.9, 12, col, 3.0)
			draw_arc(c + Vector2(-2, -12), 6.0, PI * 0.9, PI * 2.2, 12, col, 3.0)
		"bow":
			draw_arc(c + Vector2(-10, 0), 22.0, -1.1, 1.1, 14, col, 4.0)
			draw_line(c + Vector2(-10 + 22.0 * cos(1.1), 22.0 * sin(1.1)), c + Vector2(-10 + 22.0 * cos(1.1), -22.0 * sin(1.1)), col, 2.0)
			draw_line(c + Vector2(-16, 0), c + Vector2(20, 0), col, 2.0)
			draw_colored_polygon(PackedVector2Array([c + Vector2(22, 0), c + Vector2(14, -4), c + Vector2(14, 4)]), col)
		"bolts":
			for p in [Vector2(-10, -8), Vector2(6, 2), Vector2(-4, 12)]:
				draw_line(c + p + Vector2(-7, 0), c + p + Vector2(7, 0), col, 3.0)
				draw_line(c + p + Vector2(0, -7), c + p + Vector2(0, 7), col, 3.0)
				draw_circle(c + p, 3.0, Color(0.85, 0.6, 1.0))
		"eagle":
			draw_colored_polygon(PackedVector2Array([c + Vector2(-2, -4), c + Vector2(-22, -10), c + Vector2(-14, 2), c + Vector2(-2, 7)]), col)
			draw_colored_polygon(PackedVector2Array([c + Vector2(2, -4), c + Vector2(22, -10), c + Vector2(14, 2), c + Vector2(2, 7)]), col)
			draw_circle(c + Vector2(0, 0), 5.0, col)
		"ram":
			draw_rect(Rect2(c + Vector2(-16, -10), Vector2(18, 20)), col)
			draw_line(c + Vector2(4, 0), c + Vector2(20, 0), col, 4.0)
			draw_line(c + Vector2(14, -6), c + Vector2(20, 0), col, 3.0)
			draw_line(c + Vector2(14, 6), c + Vector2(20, 0), col, 3.0)
		_:
			draw_circle(c, 12.0, col)
