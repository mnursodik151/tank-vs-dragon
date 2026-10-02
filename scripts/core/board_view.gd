class_name BoardView
extends Node3D
## Builds the visuals + terrain colliders of a GridBoard: the hex floor from the Hexagon Pack tiles (one grass tile per cell, stacked
## into columns on high ground, a ring of water around the board), obstacle prisms, props (PropView), terrain-weight patches,
## an optional (toggleable) grid overlay and reachable-cell highlights.
## GridBoard and Actions never touch this class' internals.

signal grid_toggled(grid_on: bool)

const TILE_GRASS := "tiles/base/hex_grass"          ## 2.0 wide (flat to flat), 1.0 thick, top face at y = 0 (tile paths are relative to HexTiles.DIR)
const TILE_COLUMN := "tiles/base/hex_grass_bottom"  ## the same prism without the bevelled top: fills the column under a raised tile
const TILE_WATER := "tiles/base/hex_water"          ## 0.8 thick, top face at y = -0.2
const TILE_FLAT_TO_FLAT := 2.0           ## native tile width; the game's hex (circumradius 1) is sqrt(3) wide, so tiles are scaled by sqrt(3) / 2
const WATER_RING := 4                    ## rows / columns of water tiles around the board
const TILE_TONE := 0.84                  ## the pack's saturated pastels blow out under this sun: every tile is darkened a little
const SEA_TONE := 0.72                   ## the sea ring is darker still (it is a lot of bright cyan)
const WATER_TOP := -0.3                  ## metres: sea surface below the grass, so a shore shows a little tile side
const BRIDGE_WIDEN := 1.3                ## bridge models are drawn this much larger than a tile's scale so they read from the camera
const BRIDGE_HEIGHT := 0.6               ## ...and squashed to this share of the (widened) height: units drive over them
const OBSTACLE_COLOR := Color(0.35, 0.30, 0.28)
const GRID_COLOR := Color(1.0, 1.0, 1.0, 0.30)
const FLOOR_DEPTH := 0.5
const OBSTACLE_HEIGHT := 1.2

var grid_visible := false:
	set(value):
		grid_visible = value
		if _grid != null:
			_grid.visible = value
		grid_toggled.emit(value)

var _board: GridBoard
var _grid := MeshInstance3D.new()
var _highlights := Node3D.new()
var _patches: Dictionary = {}        # cell -> terrain patch node
var _terrain_mats: Dictionary = {}    # Terrain.Type -> material
var _patch_mesh: ArrayMesh
var _crater_mesh: ArrayMesh
var _fire_mat: StandardMaterial3D
var _time := 0.0


func build(board: GridBoard) -> void:
	_board = board
	_build_floor()
	_build_terrain_patches()
	_build_grid_lines()
	_build_obstacles()
	var props := PropView.new()
	props.name = "Props"
	add_child(props)
	props.build(board)
	add_child(_highlights)


func toggle_grid() -> void:
	grid_visible = not grid_visible


## Where the mouse ray meets the ground (`plane_y` above the terrain surface, hills included), or null.
func mouse_ground_point(plane_y: float = 0.0) -> Variant:
	var viewport := get_viewport()
	var cam := viewport.get_camera_3d()
	if cam == null:
		return null
	var mouse := viewport.get_mouse_position()
	var origin := cam.project_ray_origin(mouse)
	var normal := cam.project_ray_normal(mouse)
	var hit: Variant = Plane(Vector3.UP, plane_y).intersects_ray(origin, normal)
	# the ground is not flat: re-aim at the plane through the surface height found under the previous guess
	for i in 4:
		if hit == null:
			return null
		var next: Variant = Plane(Vector3.UP, plane_y + _board.surface_y(hit as Vector3)).intersects_ray(origin, normal)
		if next == null:
			break
		hit = next
	return hit


func show_highlight(cells: Array, color: Color) -> void:
	clear_highlight()
	if cells.is_empty():
		return
	var mesh := _flat_hex_mesh(_board.hex_size * 0.94)
	var mat := _unshaded(color)
	for c: Vector2i in cells:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		mi.position = _board.cell_to_world(c, 0.03)
		_highlights.add_child(mi)


func clear_highlight() -> void:
	for child in _highlights.get_children():
		child.queue_free()


# --- construction -----------------------------------------------------------

func _build_floor() -> void:
	var body := StaticBody3D.new()
	body.collision_layer = Unit.LAYER_TERRAIN
	body.collision_mask = 0
	var phys := PhysicsMaterial.new()
	phys.friction = 0.8
	body.physics_material_override = phys
	add_child(body)

	# Colliders: one slightly oversized hex prism per cell (reaching down past the lowest ground), so neighbours overlap and
	# leave no seams. A prism's top sits at its cell's elevation: slopes and cliffs are just neighbouring steps.
	var shapes: Dictionary = {}   # level -> shape
	for c in _board.all_cells():
		var level := _board.level_of(c)
		if not shapes.has(level):
			var shape := ConvexPolygonShape3D.new()
			shape.points = _prism_points(_board.hex_size * 1.003, 0.0, -(_board.height_of(c) + FLOOR_DEPTH))
			shapes[level] = shape
		var col := CollisionShape3D.new()
		col.shape = shapes[level]
		col.position = _board.cell_to_world(c)
		body.add_child(col)
	_build_floor_tiles()


## The visible floor: a tile on every cell at its elevation - grass, a road tile (picked from the road neighbours), a river tile
## (from the wet neighbours) or a crossing for a bridge - with `hex_grass_bottom` columns stacked under raised ones (down to the
## level of the flat ground), and sea tiles around the board. One MultiMesh per tile type.
func _build_floor_tiles() -> void:
	var scale_xz := _board.hex_size * sqrt(3.0) / TILE_FLAT_TO_FLAT   # exact fit: neighbouring tiles touch
	var tile_scale := Basis.from_scale(Vector3.ONE * scale_xz)
	var thickness := 1.0 * scale_xz
	var groups: Dictionary = {}   # tile path -> Array[Transform3D]
	for c in _board.all_cells():
		var top := _board.height_of(c)
		var origin := _board.cell_to_world(c)
		var pick := _tile_for(c)
		var basis := Basis(Vector3.UP, float(pick["yaw"])) * tile_scale
		_group(groups, String(pick["tile"])).append(Transform3D(basis, Vector3(origin.x, top, origin.z)))
		if pick.has("bridge"):   # the arched stone deck over the river, flattened a little so vehicles do not sink into its crest
			var deck := basis * Basis.from_scale(Vector3(BRIDGE_WIDEN, BRIDGE_HEIGHT * BRIDGE_WIDEN, BRIDGE_WIDEN))
			_group(groups, String(pick["bridge"])).append(Transform3D(deck, Vector3(origin.x, top, origin.z)))
		if _board.is_water(c):
			continue
		var y := top - thickness
		while y > -thickness + 0.001:   # stack until the bottom reaches the underside of a flat-ground tile
			_group(groups, TILE_COLUMN).append(Transform3D(tile_scale, Vector3(origin.x, y, origin.z)))
			y -= thickness
	for row in range(-WATER_RING, _board.size.y + WATER_RING):
		for col in range(-WATER_RING, _board.size.x + WATER_RING):
			var cell := GridBoard.offset_to_axial(Vector2i(col, row))
			if _board.in_bounds(cell):
				continue
			var origin := _board.cell_to_world(cell)
			_group(groups, TILE_WATER).append(Transform3D(tile_scale, Vector3(origin.x, WATER_TOP + 0.2 * scale_xz, origin.z)))
	for tile: String in groups:
		_add_tiles(tile, groups[tile])


func _group(groups: Dictionary, tile: String) -> Array:
	if not groups.has(tile):
		groups[tile] = []
	return groups[tile]


## {"tile", "yaw"} for a cell: river / crossing / road tile from its neighbours, else grass.
func _tile_for(c: Vector2i) -> Dictionary:
	var salt := absi(hash(c))
	var wet := 0
	var road := 0
	for k in 6:
		var n := c + GridBoard.DIRS[k]
		if _board.is_water(n) or _board.is_water_exit(n) or (_board.is_bridge(n) and not _board.is_bridge(c)):
			wet |= 1 << k
		if _board.terrain_at(n) == Terrain.Type.ROAD and not _board.is_water(n):
			road |= 1 << k
	var pick := {}
	if _board.is_water(c):
		# a bridge neighbour carries the river on underneath it
		pick = HexTiles.river(wet, salt)
		return pick if not pick.is_empty() else {"tile": TILE_WATER, "yaw": 0.0}
	if _board.is_bridge(c):
		wet = 0
		for k in 6:
			var n := c + GridBoard.DIRS[k]
			if _board.is_water(n) or _board.is_water_exit(n):
				wet |= 1 << k
		pick = HexTiles.crossing(wet, road)
		return pick if not pick.is_empty() else {"tile": TILE_GRASS, "yaw": 0.0}
	if _board.terrain_at(c) == Terrain.Type.ROAD:
		pick = HexTiles.road(road, salt)
	return pick if not pick.is_empty() else {"tile": TILE_GRASS, "yaw": 0.0}


func _add_tiles(tile: String, transforms: Array) -> void:
	if transforms.is_empty():
		return
	var scene := load(HexTiles.DIR + tile + ".gltf") as PackedScene
	var source := scene.instantiate()
	var found: Array = []
	_find_mesh(source, Transform3D.IDENTITY, found)   # the tile's mesh and where it sits in its file
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = (found[0] as MeshInstance3D).mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, (transforms[i] as Transform3D) * (found[1] as Transform3D))
	source.free()
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Tiles_" + tile.get_file()
	mmi.multimesh = mm
	var src_mat := mm.mesh.surface_get_material(0) as BaseMaterial3D
	if src_mat != null:
		var toned := src_mat.duplicate() as BaseMaterial3D
		var tone := SEA_TONE if tile == TILE_WATER else TILE_TONE
		toned.albedo_color = src_mat.albedo_color * Color(tone, tone, tone)
		mmi.material_override = toned
	add_child(mmi)


func _find_mesh(n: Node, xf: Transform3D, out: Array) -> void:
	if n is Node3D:
		xf = xf * (n as Node3D).transform
	if n is MeshInstance3D and out.is_empty():
		out.append(n)
		out.append(xf)
		return
	for child in n.get_children():
		_find_mesh(child, xf, out)


## Every non-grass cell gets a coloured patch so terrain cost stays readable even with the grid
## hidden. Patches follow the board live (craters, fires, scorched ground appear mid-battle).
func _build_terrain_patches() -> void:
	_patch_mesh = _flat_hex_mesh(_board.hex_size * 0.98)
	_crater_mesh = _flat_hex_mesh(_board.hex_size * 0.6)
	_fire_mat = _unshaded(Terrain.color(Terrain.Type.FIRE))
	for t in [Terrain.Type.ROUGH, Terrain.Type.CRATER, Terrain.Type.SCORCH]:
		_terrain_mats[t] = _flat(Terrain.color(t))
	for c: Vector2i in _board.terrain_cells():
		_on_terrain_changed(c, _board.terrain_at(c))
	_board.terrain_changed.connect(_on_terrain_changed)


func _on_terrain_changed(c: Vector2i, t: int) -> void:
	if _patches.has(c):
		(_patches[c] as Node).queue_free()
		_patches.erase(c)
	if t == Terrain.Type.GRASS or t == Terrain.Type.ROAD:
		return   # the tiles show grass and roads
	var holder := Node3D.new()
	holder.position = _board.cell_to_world(c, 0.012)
	var mi := MeshInstance3D.new()
	mi.mesh = _patch_mesh
	mi.material_override = _fire_mat if t == Terrain.Type.FIRE else _terrain_mats[t]
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(mi)
	if t == Terrain.Type.CRATER:
		var pit := MeshInstance3D.new()
		pit.mesh = _crater_mesh
		pit.material_override = _flat(Terrain.color(Terrain.Type.CRATER).darkened(0.45))
		pit.position.y = 0.004
		pit.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(pit)
	add_child(holder)
	_patches[c] = holder


func _process(delta: float) -> void:
	_time += delta
	if _fire_mat != null:
		var flicker := 0.5 + 0.5 * sin(_time * 8.0)
		_fire_mat.albedo_color = Color(1.0, 0.35 + 0.3 * flicker, 0.08, 0.85)


func _build_grid_lines() -> void:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for c in _board.all_cells():
		var centre := _board.cell_to_world(c, 0.02)
		for i in 6:
			var n := c + GridBoard.EDGE_NEIGHBORS[i]
			# Draw each shared edge once.
			if _board.in_bounds(n) and (n.y < c.y or (n.y == c.y and n.x < c.x)):
				continue
			im.surface_add_vertex(_board.corner(centre, i))
			im.surface_add_vertex(_board.corner(centre, (i + 1) % 6))
	im.surface_end()
	_grid.mesh = im
	_grid.material_override = _unshaded(GRID_COLOR)
	_grid.visible = grid_visible
	_grid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_grid)


func _build_obstacles() -> void:
	var radius := _board.hex_size * 0.96
	var shape := ConvexPolygonShape3D.new()
	shape.points = _prism_points(radius, OBSTACLE_HEIGHT, 0.0)
	var mat := _flat(OBSTACLE_COLOR)
	var phys := PhysicsMaterial.new()
	phys.friction = 0.8
	for c: Vector2i in _board.blocked_cells():
		if _board.prop_at(c) >= 0 or _board.is_water(c):
			continue   # props are built by PropView, water by the floor tiles
		var centre := _board.cell_to_world(c)
		var body := StaticBody3D.new()
		body.collision_layer = Unit.LAYER_TERRAIN
		body.collision_mask = 0
		body.physics_material_override = phys
		body.position = centre
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)

		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_add_top(st, Vector3.ZERO, radius, OBSTACLE_HEIGHT)
		for i in 6:
			_add_side(st, Vector3.ZERO, radius, i, OBSTACLE_HEIGHT, 0.0)
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.material_override = mat
		body.add_child(mi)
		add_child(body)


# --- hex geometry helpers ---------------------------------------------------

func _prism_points(radius: float, y_top: float, y_bottom: float) -> PackedVector3Array:
	var pts := PackedVector3Array()
	for i in 6:
		pts.append(_board.corner(Vector3(0.0, y_top, 0.0), i, radius))
		pts.append(_board.corner(Vector3(0.0, y_bottom, 0.0), i, radius))
	return pts


func _flat_hex_mesh(radius: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_top(st, Vector3.ZERO, radius, 0.0)
	return st.commit()


func _add_top(st: SurfaceTool, centre: Vector3, radius: float, y: float, color: Color = Color.WHITE) -> void:
	var c := Vector3(centre.x, y, centre.z)
	st.set_normal(Vector3.UP)
	st.set_color(color)
	for i in 6:
		st.add_vertex(c)
		st.add_vertex(_board.corner(c, i, radius))
		st.add_vertex(_board.corner(c, (i + 1) % 6, radius))


func _add_side(st: SurfaceTool, centre: Vector3, radius: float, edge: int, y_top: float, y_bottom: float, color: Color = Color.WHITE) -> void:
	var top := Vector3(centre.x, y_top, centre.z)
	var a := _board.corner(top, edge, radius)
	var b := _board.corner(top, (edge + 1) % 6, radius)
	var a2 := Vector3(a.x, y_bottom, a.z)
	var b2 := Vector3(b.x, y_bottom, b.z)
	var mid := deg_to_rad(60.0 + 60.0 * edge)
	st.set_normal(Vector3(cos(mid), 0.0, sin(mid)))
	st.set_color(color)
	for v in [a, b, b2, a, b2, a2]:
		st.add_vertex(v)


func _flat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _unshaded(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat
