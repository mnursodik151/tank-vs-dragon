class_name FloatingText
extends RefCounted
## Combat popups ("PEN Front -7.9", "BURNING") that rise from a world position and fade.


static func spawn(parent: Node, world_pos: Vector3, text: String, color: Color = Color.WHITE, rise: float = 1.3) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var label := Label3D.new()
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.pixel_size = 0.01
	UiTheme.style_label3d(label, UiTheme.LARGE)
	label.outline_size = 10
	label.modulate = color
	parent.add_child(label)
	label.global_position = world_pos
	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "global_position:y", world_pos.y + rise, 1.4)
	tween.tween_property(label, "modulate:a", 0.0, 1.4).set_delay(0.5)
	tween.chain().tween_callback(label.queue_free)
