class_name Toolbar
extends Control
## MMO-style hotbar along the bottom of the screen: Move, weapons, Ram. The active slot is
## highlighted, slots the unit cannot afford are tinted red. Number keys / clicks select.

signal tool_selected(index: int)

var _row := HBoxContainer.new()
var _slots: Array[ToolSlot] = []
var _ap := Label.new()
var _notice := Label.new()
var _undo := Label.new()
var _popup := PanelContainer.new()
var _popup_label := Label.new()
var _popup_tween: Tween
var _notice_tween: Tween


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)  # (plain set_anchors_preset would keep the 0x0 rect)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_row.add_theme_constant_override("separation", 6)
	_row.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_row.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_row.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_row.offset_bottom = -12.0
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_row)

	_ap.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_ap.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_ap.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_ap.offset_bottom = -102.0
	_style_label(_ap, UiTheme.SMALL)
	add_child(_ap)

	_notice.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_notice.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_notice.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_notice.offset_bottom = -128.0
	_style_label(_notice, UiTheme.SMALL)
	_notice.add_theme_color_override("font_color", Color(1.0, 0.5, 0.4))
	_notice.modulate.a = 0.0
	add_child(_notice)

	_undo.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_undo.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_undo.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_undo.offset_bottom = -154.0
	_style_label(_undo, UiTheme.SMALL)
	_undo.add_theme_color_override("font_color", Color(0.65, 0.85, 1.0))
	add_child(_undo)

	# the gentle popup (e.g. "press SPACE to end your turn"): a small slate panel above the bar that fades in and out by itself
	_popup.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_popup.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_popup.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_popup.offset_bottom = -184.0
	_popup.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_popup.add_theme_stylebox_override("panel", UiTheme.panel_style(10, 1))
	_popup.modulate.a = 0.0
	_popup_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_popup_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_popup_label.add_theme_font_override("font", UiTheme.font)
	_popup_label.add_theme_font_size_override("font_size", UiTheme.SMALL)
	_popup_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
	_popup.add_child(_popup_label)
	add_child(_popup)


## Rebuilds the slots for the unit about to act.
func setup(entries: Array[ToolEntry], unit: Unit) -> void:
	for s in _slots:
		s.queue_free()
	_slots.clear()
	for i in entries.size():
		var slot := ToolSlot.new()
		slot.configure(i, entries[i])
		slot.pressed.connect(func() -> void: tool_selected.emit(i))
		_row.add_child(slot)
		_slots.append(slot)
	refresh(unit)


func set_active(index: int) -> void:
	for i in _slots.size():
		_slots[i].active = (i == index)


## Updates affordability tinting and the AP readout.
func refresh(unit: Unit) -> void:
	for s in _slots:
		s.cooldown = unit.drone_cooldown if s.entry.kind == ToolEntry.Kind.DRONE else 0
		s.affordable = unit.ap + Action.AP_EPSILON >= s.entry.cost() and s.cooldown <= 0
	_ap.text = "AP %.1f / %.1f" % [unit.ap, unit.stats.max_ap]


## Standing line above the bar: what can be taken back right now ("[Z] Undo move   1 rewind left").
func set_undo_hint(text: String) -> void:
	_undo.text = text


## Gentle, self-dismissing message above the bar: fades in, stays `hold` seconds, fades out. Never blocks input.
func show_popup(text: String, hold: float = 4.5) -> void:
	_popup_label.text = text
	if _popup_tween != null:
		_popup_tween.kill()
	_popup.modulate.a = 0.0
	_popup_tween = create_tween()
	_popup_tween.tween_property(_popup, "modulate:a", 1.0, 0.4)
	_popup_tween.tween_interval(hold)
	_popup_tween.tween_property(_popup, "modulate:a", 0.0, 1.0)


func hide_popup() -> void:
	if _popup_tween != null:
		_popup_tween.kill()
	_popup.modulate.a = 0.0


## Brief warning above the bar ("Not enough AP").
func flash(text: String) -> void:
	_notice.text = text
	if _notice_tween != null:
		_notice_tween.kill()
	_notice.modulate.a = 1.0
	_notice_tween = create_tween()
	_notice_tween.tween_interval(0.9)
	_notice_tween.tween_property(_notice, "modulate:a", 0.0, 0.5)


func _style_label(label: Label, font_size: int) -> void:
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", UiTheme.font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
