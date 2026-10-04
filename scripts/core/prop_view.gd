class_name PropView
extends Node3D
## Builds the environment props of a GridBoard from the glTF models (see Props): one StaticBody3D per
## prop cell, named "<Kind>_<Model>_<q>_<r>", with the model scaled to fit its hex and a collider shells
## and knocked-around units can hit. Trees get a cylinder, everything else a convex hull of its mesh;
## small rocks and supplies are clusters of three items. Yaw and size are varied per cell (deterministically); walls and fences
## follow the yaw the composer gave their line. Pack models (buildings, walls, supplies, woods...) are sized by the kind's "scale".
## Props are destroyable (GridBoard.damage_prop): a destroyed prop loses its collider at once and its model
## shrinks away; a damaged one flinches.

const FRICTION := 0.8
const TRUNK_RADIUS := 0.35

const PACK_TONE := Color(0.82, 0.82, 0.82)   ## Hexagon Pack colours are bright pastels; against this sun and sky they blow out to white

static var _toned_mats: Dictionary = {}     # pack material -> darkened copy (shared by every prop)
static var _bounds: Dictionary = {}   # model stem -> AABB in the model's own space
static var _hulls: Dictionary = {}    # model stem -> convex-hull points in the model's own space (building one is the slow part of a prop)

var _bodies: Dictionary = {}   # cell -> StaticBody3D


func build(board: GridBoard) -> void:
	for c: Vector2i in board.prop_cells():
		_build_prop(board, c, board.prop_at(c) as Props.Kind, board.prop_model(c))
	board.prop_destroyed.connect(_on_prop_destroyed)
	board.prop_damaged.connect(_on_prop_damaged)
	board.prop_restored.connect(func(c: Vector2i, kind: int) -> void: _build_prop(board, c, kind as Props.Kind, board.prop_model(c)))


func _on_prop_destroyed(c: Vector2i, _kind: int) -> void:
	var body: StaticBody3D = _bodies.get(c)
	_bodies.erase(c)
	if body == null or not is_instance_valid(body):
		return
	body.collision_layer = 0   # shells and bodies pass straight away
	var tween := body.create_tween()
	tween.set_parallel(true)
	for child in body.get_children():
		if child is Node3D and not child is CollisionShape3D:
			tween.tween_property(child, "scale", Vector3.ONE * 0.01, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(body.queue_free)


func _on_prop_damaged(c: Vector2i, _hp: float) -> void:
	var body: StaticBody3D = _bodies.get(c)
	if body == null or not is_instance_valid(body):
		return
	for child in body.get_children():
		if child is Node3D and not child is CollisionShape3D:
			var node := child as Node3D
			var rest := node.rotation
			var tween := node.create_tween()
			tween.tween_property(node, "rotation:z", rest.z + 0.08, 0.05)
			tween.tween_property(node, "rotation:z", rest.z - 0.06, 0.08)
			tween.tween_property(node, "rotation:z", rest.z, 0.08)


func _build_prop(board: GridBoard, c: Vector2i, kind: Props.Kind, model: String) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(c)
	var body := StaticBody3D.new()
	var offset_cell := GridBoard.axial_to_offset(c)   # same (column, row) the map data uses
	body.name = "%s_%s_c%dr%d" % [Props.kind_name(kind).capitalize().replace(" ", ""), model, offset_cell.x, offset_cell.y]
	body.collision_layer = Unit.LAYER_TERRAIN
	body.collision_mask = 0
	var phys := PhysicsMaterial.new()
	phys.friction = FRICTION
	body.physics_material_override = phys
	body.position = board.cell_to_world(c)
	body.set_meta(Props.META_CELL, c)
	_bodies[c] = body
	add_child(body)

	var info := Props.info(kind)
	var size_mult := 1.0 + rng.randf_range(-1.0, 1.0) * float(info.get("jitter", 0.1))
	if info.has("cluster"):
		var pool := Props.models(kind)
		var count := int(info["cluster"])
		var angle := rng.randf_range(0.0, TAU)
		for i in count:
			var stem := model if i == 0 else pool[rng.randi() % pool.size()]
			var a := angle + TAU * float(i) / float(count) + rng.randf_range(-0.4, 0.4)
			var offset := Vector3(cos(a), 0.0, sin(a)) * rng.randf_range(0.35, 0.55)
			_add_model(body, kind, stem, offset, rng.randf_range(0.0, TAU), rng.randf_range(0.75, 1.15))
	else:
		_add_model(body, kind, model, Vector3.ZERO, _pick_yaw(info, board.prop_yaw(c), rng), size_mult)


## Facing of a prop: the layout's line yaw for walls and fences, else random (snapped to `yaw_step` when the kind has one).
func _pick_yaw(info: Dictionary, layout_yaw: float, rng: RandomNumberGenerator) -> float:
	var roll := rng.randf_range(0.0, TAU)   # always drawn: same sequence for every kind
	if info.has("line") and not is_nan(layout_yaw):
		return layout_yaw + float(info.get("yaw_offset", 0.0))
	if info.has("yaw_step"):
		return roundf(roll / float(info["yaw_step"])) * float(info["yaw_step"])
	return roll


## Adds one model (and its collider) to `body`, scaled to the kind's fit box and sitting on the floor.
func _add_model(body: StaticBody3D, kind: Props.Kind, model: String, offset: Vector3, yaw: float, size_mult: float) -> void:
	var scene := load(Props.scene_path(model)) as PackedScene
	if scene == null:
		push_warning("PropView: missing model %s" % model)
		return
	var inst := scene.instantiate() as Node3D
	var box := _model_bounds(model, inst)
	var info := Props.info(kind)
	var fits := minf(float(info["height"]) / box.size.y, float(info["width"]) / maxf(box.size.x, box.size.z))
	var fit := minf(float(info.get("scale", INF)), fits) * size_mult   # "scale": native size unless it would not fit the box
	var basis := Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3.ONE * fit)
	var origin := offset
	if info.get("center", kind != Props.Kind.TREE):
		# rocks, groves, walls...: centre the model on its spot (trees and pack buildings keep the origin they were authored around)
		var centre := box.get_center()
		origin -= basis * Vector3(centre.x, 0.0, centre.z)
	inst.transform = Transform3D(basis, origin)
	if Props.scene_path(model).begins_with(Props.PACK_DIR):
		_tone_pack_materials(inst)
	body.add_child(inst)

	var col := CollisionShape3D.new()
	var height := box.size.y * fit
	match kind:
		Props.Kind.TREE:
			var cyl := CylinderShape3D.new()
			cyl.radius = TRUNK_RADIUS
			cyl.height = height
			col.shape = cyl
			col.position = offset + Vector3(0.0, height * 0.5, 0.0)
		_:
			var hull := ConvexPolygonShape3D.new()
			var pts := PackedVector3Array()
			for p in _model_hull(model, inst):
				pts.append(inst.transform * p)
			hull.points = pts
			col.shape = hull
	col.name = "Collider_" + model
	body.add_child(col)


func _tone_pack_materials(n: Node) -> void:
	var mi := n as MeshInstance3D
	if mi != null and mi.mesh != null:
		for i in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(i) as BaseMaterial3D
			if mat != null and mi.get_surface_override_material(i) == null:
				if not _toned_mats.has(mat):
					var toned := mat.duplicate() as BaseMaterial3D
					toned.albedo_color = mat.albedo_color * PACK_TONE
					_toned_mats[mat] = toned
				mi.set_surface_override_material(i, _toned_mats[mat])
	for child in n.get_children():
		_tone_pack_materials(child)


func _model_bounds(model: String, inst: Node3D) -> AABB:
	if not _bounds.has(model):
		var boxes: Array[AABB] = []
		_gather_boxes(inst, Transform3D.IDENTITY, boxes)
		var merged := boxes[0]
		for b in boxes:
			merged = merged.merge(b)
		_bounds[model] = merged
	return _bounds[model]


func _gather_boxes(n: Node, parent_xf: Transform3D, out: Array[AABB]) -> void:
	var xf := parent_xf
	if n is Node3D:
		xf = parent_xf * (n as Node3D).transform
	if n is MeshInstance3D:
		out.append(xf * (n as MeshInstance3D).get_aabb())
	for child in n.get_children():
		_gather_boxes(child, xf, out)


## The model's hull points in its own space (before the instance's scale, yaw and offset), built once per model stem.
func _model_hull(model: String, inst: Node3D) -> PackedVector3Array:
	if not _hulls.has(model):
		var pts := PackedVector3Array()
		_collect_hull(inst, inst.transform.affine_inverse(), pts)   # cancels the instance's own transform
		_hulls[model] = pts
	return _hulls[model]


## Convex-hull points of every mesh below `n`, in the space the traversal started in (the body's, when
## it starts at a model whose transform is already set).
func _collect_hull(n: Node, parent_xf: Transform3D, out: PackedVector3Array) -> void:
	var xf := parent_xf
	if n is Node3D:
		xf = parent_xf * (n as Node3D).transform
	if n is MeshInstance3D:
		var shape := (n as MeshInstance3D).mesh.create_convex_shape(true, false)   # no simplify pass: it costs 30-130 ms per model
		if shape != null:
			for p in shape.points:
				out.append(xf * p)
	for child in n.get_children():
		_collect_hull(child, xf, out)
