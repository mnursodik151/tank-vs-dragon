class_name UnitModel
extends RefCounted
## Unit visuals from the glTF models in res://Players. A model is cut into the three moving parts a Unit has - the HULL (turns to
## the travel direction), the TURRET (turns to the aim) and the BARREL (pitches) - either by mesh part name or, for a model that is
## one single mesh (the Sherman), by cutting its triangles by position. Cut meshes are cached, so only the first unit of a model pays.
##
## Everything is described in the model's own space (the glTF root after its Sketchfab node chain) and turned into "rig space":
## +Z is forward, the body origin is the turret ring axis, the lowest hull point sits on `floor_y`. Per model:
##   scene, scale (model units -> metres), yaw (radians that turn the model's forward onto +Z),
##   turret_pivot (x, z of the turret ring), barrel_pivot (trunnion: where the gun pitches), rest_pitch_deg (how far the model's gun
##   is raised in its rest pose; undone so that pitch 0 is level), and the split: "turret_parts" / "barrel_parts" (mesh name prefixes)
##   or "cut" {turret_min_y, barrel_max_abs_x, barrel_min_z} for a single mesh.
## Weapons held by a soldier are separate models (WEAPONS) mounted on the barrel node: see `equip`. A model with "rig" (the soldier) is
## not cut: it is one skinned body (SoldierRig, animated) on the TURRET node, so it turns with the aim; its barrel_pivot is where the
## hands hold the weapon in the firing stance.
## Fantasy faction: a model with "hero" is one of the KayKit Adventurers characters (HeroRig: rigged already, item in the hand, animated)
## standing on the TURRET node; its muzzle is `barrel_pivot` (model units above the feet). A model may also carry a "crew" HeroRig (the
## knight pushing the octo cannon) that stands behind the machine on the turret node and plays the unit's walk / hit / death animations.
## Licences: the models are CC-BY 4.0 (CC0 for the KayKit packs), credited in CREDITS.md.

enum Group { HULL, TURRET, BARREL }

const MODELS := {
	"sherman": {
		"scene": "res://Players/Model/sherman_tank_-_stylised_blender_lowpoly_ww2/scene.gltf",
		"scale": 0.0037, "yaw": 0.0,
		"turret_pivot": Vector3(0.0, 0.0, -20.0), "barrel_pivot": Vector3(0.0, 226.0, 130.0),
		"cut": {"turret_min_y": 180.0, "barrel_max_abs_x": 14.0, "barrel_min_z": 128.0},
	},
	"howitzer": {
		"scene": "res://Players/Model/stylized_tank/scene.gltf",
		"scale": 0.00085, "yaw": PI / 2.0,
		"turret_pivot": Vector3(31.0, 0.0, 0.0), "barrel_pivot": Vector3(-400.0, 1257.0, 0.0), "rest_pitch_deg": 16.1,
		"turret_parts": ["Final_010_", "Final_011_", "Final_012_", "Final_014_", "Final_015_", "Final_016_"],
		"barrel_parts": ["Final_013_"],
	},
	"soldier": {
		"scene": "res://Players/Model/stylized_soldier2/scene.gltf",
		"scale": 1.3, "yaw": 0.0,
		"turret_pivot": Vector3(0.0, 0.0, 0.0), "barrel_pivot": SoldierRig.READY_MOUNT,
		"rig": true,
	},
	# --- fantasy faction -------------------------------------------------------------------------------------------------------------------
	# The octo cannon faces +X in its own space (yaw -90 deg puts that on +Z). The carriage turns with the aim (it is the TURRET, so the
	# hull stays an empty heading marker for the armor sectors), the barrel with the octopus clinging to it pitches around the trunnion.
	"octo": {
		"scene": "res://Players/Model/octo_cannon/scene.gltf",
		"scale": 0.0062, "yaw": -PI / 2.0,
		"turret_pivot": Vector3(22.0, 0.0, 0.0), "barrel_pivot": Vector3(8.0, 53.0, 0.0), "rest_pitch_deg": 27.45,
		"turret_parts": ["OctoCannon_TheBigCannonBase"],
		"barrel_parts": ["OctoCannon_TheBigCannon_", "OctoCannon_CannonOctopus"],
		"crew": {"profile": "knight", "scale": 0.5, "offset": Vector3(0.0, 0.0, -1.4)},
	},
	"mage": {
		"scene": "res://Players/Model/KayKit_Adventurers_2.0_FREE/Characters/gltf/Mage.glb",
		"scale": 0.55, "yaw": 0.0, "hero": "mage",
		"turret_pivot": Vector3.ZERO, "barrel_pivot": Vector3(0.0, 1.9, 1.0),
	},
	"ranger": {
		"scene": "res://Players/Model/KayKit_Adventurers_2.0_FREE/Characters/gltf/Ranger.glb",
		"scale": 0.55, "yaw": 0.0, "hero": "ranger",
		"turret_pivot": Vector3.ZERO, "barrel_pivot": Vector3(0.0, 1.5, 1.0),
	},
}

## Hand-held weapons: yaw turns the model's muzzle onto +Z, length is the muzzle-to-butt length in metres, grip the share of
## that length behind the pitch pivot.
const WEAPONS := {
	"bazooka": {"scene": "res://Players/Weapons/bazooka_stylized_toon/scene.gltf", "yaw": -PI / 2.0, "length": 0.9, "grip": 0.5},
	"rifle": {"scene": "res://Players/Weapons/m-16_rifle/scene.gltf", "yaw": PI / 2.0, "length": 0.65, "grip": 0.45},
}

const SHELL_SCENE := "res://Players/Weapons/tank_shell_bullet/scene.gltf"
const WEAPON_BITS := "res://Players/Weapons/KayKit_FantasyWeaponsBits_1.0_FREE/Assets/gltf/%s.gltf"
## Magic projectiles (RoundStats.projectile): a glowing sphere, or a Weapon Bits model whose nose (+Z in the pack) is turned onto -Z.
const PROJECTILES := {
	"fireball": {"glow": Color(1.0, 0.45, 0.10), "core": Color(1.0, 0.92, 0.55), "size": 0.55},
	"meteor": {"glow": Color(1.0, 0.35, 0.08), "rock": Color(0.22, 0.18, 0.16), "size": 0.8},
	"hail": {"glow": Color(0.55, 0.85, 1.0), "core": Color(0.92, 0.98, 1.0), "size": 0.45},
	"bolt": {"scene": "arrow_B"},
	"arrow": {"scene": "arrow_A"},
}
const WEAPON_NODE := "Weapon"

static var _parts: Dictionary = {}      # model id -> {"parts": Array of {mesh, xf, group}, "hull_min_y": float}
static var _tinted: Dictionary = {}     # [material, tint] -> StandardMaterial3D
static var _weapon_box: Dictionary = {} # weapon id -> AABB in the weapon's mount space


static func has_model(id: String) -> bool:
	return MODELS.has(id) and ResourceLoader.exists(String(MODELS[id]["scene"]))


## Fills the (empty) hull / turret / barrel nodes of a unit with the model and positions the turret and barrel pivots.
## `floor_y` is the unit-local height of the ground under it, `tint` multiplies the model's colours (team colour).
## Returns how far in front of the turret axis the muzzle is when the barrel is level.
static func assemble(id: String, hull: Node3D, turret: Node3D, barrel: Node3D, floor_y: float, tint: Color) -> float:
	var cfg: Dictionary = MODELS[id]
	if cfg.has("hero"):
		return _assemble_hero(cfg, turret, barrel, floor_y, tint)
	var data := _load_parts(id)
	var s := float(cfg["scale"])
	var bas := Basis(Vector3.UP, float(cfg.get("yaw", 0.0))) * Basis.from_scale(Vector3.ONE * s)
	var ring: Vector3 = cfg["turret_pivot"]
	var ring_xz := bas * Vector3(ring.x, 0.0, ring.z)
	var off := Vector3(-ring_xz.x, floor_y - s * float(data["hull_min_y"]), -ring_xz.z)
	var barrel_abs: Vector3 = bas * (cfg["barrel_pivot"] as Vector3) + off
	turret.position = Vector3(0.0, barrel_abs.y, 0.0)
	barrel.position = Vector3(barrel_abs.x, 0.0, barrel_abs.z)
	var rest := Basis(Vector3.RIGHT, deg_to_rad(float(cfg.get("rest_pitch_deg", 0.0))))   # lowers a gun the model carries raised

	if cfg.get("rig", false):
		var part: Dictionary = (data["parts"] as Array)[0]
		var rig := SoldierRig.create(id, part["mesh"], part["xf"])
		rig.transform = Transform3D(bas, off - turret.position)
		rig.barrel = barrel
		rig.mount_ready = barrel.position
		var carry := bas * SoldierRig.CARRY_MOUNT + off
		rig.mount_carry = Vector3(carry.x, carry.y - turret.position.y, carry.z)
		turret.add_child(rig)
		_tint_surfaces(rig.mesh_instance, tint)
		return barrel.position.z

	var tip := 0.0
	for part: Dictionary in data["parts"]:
		var mi := MeshInstance3D.new()
		mi.mesh = part["mesh"]
		var xf: Transform3D = part["xf"]
		match part["group"]:
			Group.HULL:
				mi.transform = Transform3D(bas, off) * xf
				hull.add_child(mi)
			Group.TURRET:
				mi.transform = Transform3D(bas, off - turret.position) * xf
				turret.add_child(mi)
			Group.BARREL:
				mi.transform = Transform3D(rest) * Transform3D(bas, off - barrel_abs) * xf
				barrel.add_child(mi)
				for v in (mi.mesh as Mesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array:
					tip = maxf(tip, (mi.transform * v).z)
		_tint_surfaces(mi, tint)
	if cfg.has("crew"):
		var crew: Dictionary = cfg["crew"]
		var offset: Vector3 = crew["offset"]
		var rig := HeroRig.build(String(crew["profile"]))
		rig.scale = Vector3.ONE * float(crew["scale"])
		rig.position = Vector3(offset.x, floor_y - turret.position.y + offset.y, offset.z)
		turret.add_child(rig)
		_tint_hero(rig, tint)
	return barrel.position.z + tip


## A standing character: the HeroRig on the turret node, feet on `floor_y`. The muzzle (`barrel_pivot`, in the character's units) is
## where shots leave; returns how far in front of the body axis that is.
static func _assemble_hero(cfg: Dictionary, turret: Node3D, barrel: Node3D, floor_y: float, tint: Color) -> float:
	var s := float(cfg["scale"])
	var muzzle: Vector3 = cfg["barrel_pivot"]
	turret.position = Vector3(0.0, floor_y + muzzle.y * s, 0.0)
	barrel.position = Vector3(muzzle.x * s, 0.0, muzzle.z * s)
	var rig := HeroRig.build(String(cfg["hero"]))
	rig.scale = Vector3.ONE * s
	rig.position = Vector3(0.0, floor_y - turret.position.y, 0.0)
	turret.add_child(rig)
	_tint_hero(rig, tint)
	return barrel.position.z


## Puts the soldier's weapon `weapon_id` ("bazooka", "rifle") on the barrel node, replacing the one held. Returns how far the
## muzzle is in front of the barrel node's origin. "" or an unknown id just empties the hands (returns 0).
static func equip(barrel: Node3D, weapon_id: String) -> float:
	for child in barrel.get_children():
		if child.name == WEAPON_NODE:
			barrel.remove_child(child)
			child.queue_free()
	if not WEAPONS.has(weapon_id):
		return 0.0
	var cfg: Dictionary = WEAPONS[weapon_id]
	var scene := load(String(cfg["scene"])) as PackedScene
	if scene == null:
		return 0.0
	var inst := scene.instantiate() as Node3D
	inst.name = WEAPON_NODE
	var box := _weapon_mount(weapon_id, inst)
	inst.transform = _weapon_basis(cfg, inst)
	inst.position = -Vector3(box.get_center().x, box.get_center().y, box.position.z + float(cfg["grip"]) * box.size.z)
	barrel.add_child(inst)
	return (1.0 - float(cfg["grip"])) * box.size.z


## A shell model scaled so it is `length` metres long, nose along local -Z (so `look_at` a target points it there), or null.
static func make_shell(length: float) -> Node3D:
	var scene := load(SHELL_SCENE) as PackedScene
	if scene == null:
		return null
	var inst := scene.instantiate() as Node3D
	var box := _bounds(inst)
	var k := length / box.size.y
	var holder := Node3D.new()
	inst.transform = Transform3D(Basis(Vector3.RIGHT, -PI / 2.0) * Basis.from_scale(Vector3.ONE * k), Vector3.ZERO)
	inst.position = Basis(Vector3.RIGHT, -PI / 2.0) * (-box.get_center() * k)   # centred on the node
	holder.add_child(inst)
	return holder


## What a gunnery round looks like in flight, `length` metres long (the spheres are `size` x length wide): "shell" is the tank shell
## model, the others are PROJECTILES. Nose along local -Z like `make_shell`; null when the model is missing.
static func make_projectile(id: String, length: float) -> Node3D:
	if not PROJECTILES.has(id):
		return make_shell(length)
	var cfg: Dictionary = PROJECTILES[id]
	if cfg.has("scene"):
		var scene := load(WEAPON_BITS % String(cfg["scene"])) as PackedScene
		if scene == null:
			return null
		var inst := scene.instantiate() as Node3D
		var box := _bounds(inst)
		var k := length / maxf(box.size.z, 0.0001)
		var holder := Node3D.new()
		inst.transform = Transform3D(Basis(Vector3.UP, PI) * Basis.from_scale(Vector3.ONE * k), Vector3.ZERO)
		inst.position = Basis(Vector3.UP, PI) * (-box.get_center() * k)
		holder.add_child(inst)
		return holder
	var holder := Node3D.new()
	var diameter := length * float(cfg["size"])
	if cfg.has("rock"):   # a rough lump with a hot underside
		var lump := _glow_sphere(Color(cfg["rock"]), diameter, false, 6, 4)
		lump.scale = Vector3(1.0, 0.85, 1.15)
		holder.add_child(lump)
	if cfg.has("core"):
		holder.add_child(_glow_sphere(Color(cfg["core"]), diameter * 0.55, true, 12, 6))
	var halo := _glow_sphere(Color(cfg["glow"], 0.55 if cfg.has("core") else 0.5), diameter * (1.0 if cfg.has("core") else 1.25), true, 12, 6)
	holder.add_child(halo)
	return holder


static func _glow_sphere(color: Color, diameter: float, unshaded: bool, segments: int, rings: int) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = diameter / 2.0
	mesh.height = diameter
	mesh.radial_segments = segments
	mesh.rings = rings
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	if unshaded:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		if color.a < 1.0:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	else:
		mat.roughness = 0.9
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.3, 0.05)
		mat.emission_energy_multiplier = 0.6
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


# --- internals -----------------------------------------------------------------

static func _weapon_basis(cfg: Dictionary, inst: Node3D) -> Transform3D:
	var box := _bounds(inst)
	var bas := Basis(Vector3.UP, float(cfg["yaw"]))
	var rotated := bas * box.size
	var along := absf(rotated.z)
	var k := float(cfg["length"]) / maxf(along, 0.0001)
	return Transform3D(bas * Basis.from_scale(Vector3.ONE * k), Vector3.ZERO)


## The weapon's bounding box once mounted (before the grip shift): centred on x / y, z from the butt (min) to the muzzle (max).
static func _weapon_mount(id: String, inst: Node3D) -> AABB:
	if not _weapon_box.has(id):
		var cfg: Dictionary = WEAPONS[id]
		var xf := _weapon_basis(cfg, inst)
		_weapon_box[id] = xf * _bounds(inst)
	return _weapon_box[id]


## Bounding box of every mesh below `n` in `n`'s own space (children transforms applied, not `n`'s).
static func _bounds(n: Node3D) -> AABB:
	var boxes: Array[AABB] = []
	_gather(n, Transform3D.IDENTITY, boxes)
	var merged := boxes[0]
	for b in boxes:
		merged = merged.merge(b)
	return merged


static func _gather(n: Node, xf: Transform3D, out: Array[AABB]) -> void:
	if n is MeshInstance3D:
		out.append(xf * (n as MeshInstance3D).get_aabb())
	for child in n.get_children():
		_gather(child, xf * ((child as Node3D).transform if child is Node3D else Transform3D.IDENTITY), out)


static func _tint_hero(rig: Node, tint: Color) -> void:
	for mi in rig.find_children("*", "MeshInstance3D", true, false):
		_tint_surfaces(mi as MeshInstance3D, tint)


static func _tint_surfaces(mi: MeshInstance3D, tint: Color) -> void:
	if tint.is_equal_approx(Color.WHITE):
		return
	for i in mi.mesh.get_surface_count():
		var mat := mi.mesh.surface_get_material(i) as BaseMaterial3D
		if mat == null:
			continue
		var key := [mat, tint]
		if not _tinted.has(key):
			var copy := mat.duplicate() as BaseMaterial3D
			copy.albedo_color = mat.albedo_color * tint
			_tinted[key] = copy
		mi.set_surface_override_material(i, _tinted[key])


## The model's parts sorted into groups, in model space; cut and cached on first use.
static func _load_parts(id: String) -> Dictionary:
	if _parts.has(id):
		return _parts[id]
	var cfg: Dictionary = MODELS[id]
	var inst := (load(String(cfg["scene"])) as PackedScene).instantiate() as Node3D
	var found: Array = []
	_find_meshes(inst, Transform3D.IDENTITY, found)
	var parts: Array = []
	for f: Array in found:
		var mi: MeshInstance3D = f[0]
		var xf: Transform3D = f[1]
		if cfg.has("cut"):
			var cut := _cut_mesh(mi.mesh, xf, cfg["cut"])
			for g: int in cut:
				parts.append({"mesh": cut[g], "xf": xf, "group": g})
		else:
			parts.append({"mesh": mi.mesh, "xf": xf, "group": _group_of(String(mi.name), cfg)})
	var hull_min := INF
	for part: Dictionary in parts:
		if part["group"] == Group.HULL:
			hull_min = minf(hull_min, ((part["xf"] as Transform3D) * (part["mesh"] as Mesh).get_aabb()).position.y)
	if hull_min == INF:   # nothing is a hull part (the octo cannon: everything turns with the aim): stand on the lowest point
		for part: Dictionary in parts:
			hull_min = minf(hull_min, ((part["xf"] as Transform3D) * (part["mesh"] as Mesh).get_aabb()).position.y)
	inst.free()
	_parts[id] = {"parts": parts, "hull_min_y": hull_min}
	return _parts[id]


static func _group_of(part_name: String, cfg: Dictionary) -> int:
	for prefix: String in cfg.get("barrel_parts", []):
		if part_name.begins_with(prefix):
			return Group.BARREL
	for prefix: String in cfg.get("turret_parts", []):
		if part_name.begins_with(prefix):
			return Group.TURRET
	return Group.HULL


static func _find_meshes(n: Node, xf: Transform3D, out: Array) -> void:
	if n is Node3D:
		xf = xf * (n as Node3D).transform
	if n is MeshInstance3D:
		out.append([n, xf])
	for child in n.get_children():
		_find_meshes(child, xf, out)


## Cuts a single-surface mesh into group -> compact ArrayMesh (vertices stay in the mesh's own space). A triangle belongs to the
## barrel when it lies on the gun axis ahead of the mantlet, to the turret when it is above the turret ring, else to the hull.
static func _cut_mesh(mesh: Mesh, xf: Transform3D, cut: Dictionary) -> Dictionary:
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var world := PackedVector3Array()
	world.resize(verts.size())
	for i in verts.size():
		world[i] = xf * verts[i]
	var tris := {Group.HULL: PackedInt32Array(), Group.TURRET: PackedInt32Array(), Group.BARREL: PackedInt32Array()}
	for t in range(0, indices.size(), 3):
		var a := world[indices[t]]
		var b := world[indices[t + 1]]
		var c := world[indices[t + 2]]
		var group := Group.HULL
		if (a.y + b.y + c.y) / 3.0 >= float(cut["turret_min_y"]):
			group = Group.TURRET
			var max_x := maxf(absf(a.x), maxf(absf(b.x), absf(c.x)))
			var min_z := minf(a.z, minf(b.z, c.z))
			if max_x <= float(cut["barrel_max_abs_x"]) and min_z >= float(cut["barrel_min_z"]):
				group = Group.BARREL
		var list: PackedInt32Array = tris[group]
		list.append(indices[t])
		list.append(indices[t + 1])
		list.append(indices[t + 2])
		tris[group] = list
	var out := {}
	for g: int in tris:
		if (tris[g] as PackedInt32Array).is_empty():
			continue
		out[g] = _compact(mesh, arrays, tris[g])
	return out


## A mesh of just the triangles in `index_list` (old vertex numbers), with the vertex arrays cut down to the vertices they use.
static func _compact(source: Mesh, arrays: Array, index_list: PackedInt32Array) -> ArrayMesh:
	var vertex_count := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var remap := {}
	var order := PackedInt32Array()
	var new_indices := PackedInt32Array()
	new_indices.resize(index_list.size())
	for i in index_list.size():
		var old := index_list[i]
		var n: int = remap.get(old, -1)
		if n < 0:
			n = order.size()
			remap[old] = n
			order.append(old)
		new_indices[i] = n
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	for slot in Mesh.ARRAY_MAX:
		var src: Variant = arrays[slot]
		if src == null or slot == Mesh.ARRAY_INDEX:
			continue
		out[slot] = _pick(src, order, vertex_count)
	out[Mesh.ARRAY_INDEX] = new_indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	mesh.surface_set_material(0, source.surface_get_material(0))
	return mesh


## The elements of a per-vertex array (any packed type, `stride` values per vertex) listed in `order`.
static func _pick(src: Variant, order: PackedInt32Array, vertex_count: int) -> Variant:
	var size: int = src.size()
	if size == 0 or vertex_count == 0 or size % vertex_count != 0:
		return null
	var stride := size / vertex_count
	var out: Variant = src.duplicate()
	out.resize(order.size() * stride)
	for i in order.size():
		for k in stride:
			out[i * stride + k] = src[order[i] * stride + k]
	return out
