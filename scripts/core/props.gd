class_name Props
extends RefCounted
## Catalogue of map props built from the KayKit Medieval Hexagon Pack (res://Hexagon Pack) - trees, rocks, buildings, walls... -
## Model names are the glTF file stems ("tree_single_A", "building_home_A_red", ...), so map data
## reads like "tree_single_A at (5, 5)"; `scene_path` finds the file for either source.
## Every prop occupies (blocks) its hex. Props with `los_radius` > 0 (trees, large rocks, buildings, walls, woods, tents)
## also block line of sight (see GridBoard.los_blocked); the low ones (small rocks, stumps, fences, ruins, supplies) can be seen over.
## Kind values are stored in layouts and tests: new kinds only go at the END of the enum.

enum Kind { TREE, ROCK_LARGE, ROCK_SMALL, BUILDING, WALL, FENCE, RUIN, SUPPLY, TENT, FOREST, GROVE, STUMPS }

const MODEL_DIR := "res://glTF/"
const PACK_DIR := "res://Hexagon Pack/Assets/gltf/"
const META_CELL := "prop_cell"   ## metadata on a prop's StaticBody3D: the axial cell it stands on

const TREE_MODELS: Array[String] = ["tree_single_A", "tree_single_B"]   # Hexagon Pack pines
const ROCK_LARGE_MODELS: Array[String] = ["mountain_A", "mountain_B", "mountain_C"]   # Hexagon Pack stacked crags
const ROCK_SMALL_MODELS: Array[String] = ["rock_single_A", "rock_single_B", "rock_single_C", "rock_single_D", "rock_single_E"]

# --- Hexagon Pack ---
const BUILDING_COLORS: Array[String] = ["blue", "green", "red", "yellow"]   ## every building comes in these (stem suffix)
const HOME_TYPES: Array[String] = ["home_A", "home_B"]
const CIVIC_TYPES: Array[String] = ["tavern", "church", "market", "well"]   ## a village's heart
const WORK_TYPES: Array[String] = ["blacksmith", "lumbermill", "windmill", "mine"]
const MILITARY_TYPES: Array[String] = ["barracks", "archeryrange", "tower_A", "tower_B", "tower_base", "tower_catapult"]
const WALL_MODELS: Array[String] = ["wall_straight"]
const FENCE_MODELS: Array[String] = ["fence_wood_straight", "fence_stone_straight"]
const RUIN_MODELS: Array[String] = ["building_destroyed", "building_scaffolding", "building_stage_B", "building_stage_C"]
const SUPPLY_MODELS: Array[String] = [
	"crate_A_big", "crate_A_small", "crate_B_big", "crate_B_small", "crate_long_A", "crate_long_B", "crate_long_C",
	"crate_long_empty", "crate_open", "barrel", "sack", "pallet", "resource_lumber", "resource_stone", "wheelbarrow",
	"bucket_arrows", "weaponrack", "target",
]
const TENT_MODELS: Array[String] = ["tent"]
const FOREST_MODELS: Array[String] = ["trees_A_medium", "trees_A_large", "trees_B_medium", "trees_B_large"]
const GROVE_MODELS: Array[String] = ["trees_A_small", "trees_B_small"]   ## a few small trees (the bushes' job: cover that is not a full forest)
const STUMP_MODELS: Array[String] = ["tree_single_A_cut", "tree_single_B_cut"]
## Pack folders (under PACK_DIR) of the models that are not buildings; buildings live in a folder per colour.
const PACK_FOLDERS := {
	"decoration/nature/": ["tree_single_A", "tree_single_B", "tree_single_A_cut", "tree_single_B_cut", "mountain_A", "mountain_B", "mountain_C",
		"rock_single_A", "rock_single_B", "rock_single_C", "rock_single_D", "rock_single_E",
		"trees_A_small", "trees_A_medium", "trees_A_large", "trees_B_small", "trees_B_medium", "trees_B_large"],
	"decoration/props/": ["crate_A_big", "crate_A_small", "crate_B_big", "crate_B_small", "crate_long_A", "crate_long_B", "crate_long_C",
		"crate_long_empty", "crate_open", "barrel", "sack", "pallet", "resource_lumber", "resource_stone", "wheelbarrow",
		"bucket_arrows", "weaponrack", "target", "tent"],
	"buildings/neutral/": ["wall_straight", "fence_wood_straight", "fence_stone_straight",
		"building_destroyed", "building_scaffolding", "building_stage_B", "building_stage_C"],
}

static var BUILDING_MODELS: Array[String] = _building_models()
static var _pack_folder: Dictionary = {}   # stem -> folder under PACK_DIR (filled lazily by scene_path)

## Optional INFO keys: "scale" (native size multiplier for pack models - kept in proportion to each other, only shrunk when the model
## would not fit the box; without it the model is scaled to FILL the box), "center" (centre the model on its cell, default true except
## trees - pack buildings keep the origin they were authored around), "cluster" (a cell holds this many models scattered about it, the
## first being the named one), "line" (walls and fences: aligned with the hex line the composer laid them on; `yaw_offset` turns models
## whose length is not along local x), "yaw_step" (random yaw snapped to this step), "jitter" (+- size variation, default 0.1).
## name; models; los_radius (metres, flat disc that hides what is behind it, 0 = see-through);
## height / width: the model is scaled to fit this box (metres, hex circumradius is 1 m); armor: ram damage dealt to a unit that
## charges into it; hp: hit points (props are destroyable, a destroyed prop leaves an open cell); cover: share of a
## blast's damage and push it soaks for a unit standing behind it; map_color: shot review.
static var INFO := {
	Kind.TREE: {"name": "tree", "models": TREE_MODELS, "los_radius": 0.7, "height": 3.4, "width": 2.4, "scale": 2.0, "armor": 6.0, "hp": 12.0, "cover": 0.35,
		"map_color": Color(0.20, 0.36, 0.20)},
	Kind.ROCK_LARGE: {"name": "large rock", "models": ROCK_LARGE_MODELS, "los_radius": 0.9, "height": 1.5, "width": 2.0, "armor": 10.0, "hp": 30.0, "cover": 0.6,
		"map_color": Color(0.42, 0.42, 0.45)},
	Kind.ROCK_SMALL: {"name": "small rocks", "models": ROCK_SMALL_MODELS, "los_radius": 0.0, "height": 0.45, "width": 0.8, "scale": 2.0, "cluster": 3, "armor": 2.0, "hp": 6.0, "cover": 0.15,
		"map_color": Color(0.30, 0.29, 0.27)},
	Kind.BUILDING: {"name": "building", "models": BUILDING_MODELS, "los_radius": 0.85, "height": 3.8, "width": 1.75, "scale": 1.6,
		"armor": 12.0, "hp": 36.0, "cover": 0.7, "center": false, "yaw_step": PI / 3.0, "jitter": 0.0,
		"map_color": Color(0.60, 0.36, 0.26)},
	Kind.WALL: {"name": "wall", "models": WALL_MODELS, "los_radius": 0.9, "height": 1.8, "width": 2.1, "scale": 1.0,
		"armor": 14.0, "hp": 30.0, "cover": 0.65, "line": true, "jitter": 0.0,
		"map_color": Color(0.50, 0.50, 0.54)},
	Kind.FENCE: {"name": "fence", "models": FENCE_MODELS, "los_radius": 0.0, "height": 1.2, "width": 1.8, "scale": 1.5,
		"armor": 1.0, "hp": 6.0, "cover": 0.1, "line": true, "yaw_offset": PI / 2.0, "jitter": 0.0,
		"map_color": Color(0.45, 0.33, 0.22)},
	Kind.RUIN: {"name": "ruin", "models": RUIN_MODELS, "los_radius": 0.0, "height": 1.8, "width": 1.75, "scale": 1.5,
		"armor": 5.0, "hp": 18.0, "cover": 0.4, "center": false, "yaw_step": PI / 3.0,
		"map_color": Color(0.38, 0.33, 0.30)},
	Kind.SUPPLY: {"name": "supplies", "models": SUPPLY_MODELS, "los_radius": 0.0, "height": 1.0, "width": 1.2, "scale": 3.0, "cluster": 3,
		"armor": 1.0, "hp": 6.0, "cover": 0.15,
		"map_color": Color(0.55, 0.42, 0.25)},
	Kind.TENT: {"name": "tent", "models": TENT_MODELS, "los_radius": 0.5, "height": 1.6, "width": 1.5, "scale": 2.6,
		"armor": 0.0, "hp": 8.0, "cover": 0.2, "center": false, "yaw_step": PI / 3.0,
		"map_color": Color(0.62, 0.55, 0.40)},
	Kind.GROVE: {"name": "grove", "models": GROVE_MODELS, "los_radius": 0.55, "height": 1.8, "width": 1.8, "scale": 1.2,
		"armor": 3.0, "hp": 10.0, "cover": 0.3,
		"map_color": Color(0.20, 0.38, 0.22)},
	Kind.STUMPS: {"name": "stumps", "models": STUMP_MODELS, "los_radius": 0.0, "height": 0.7, "width": 0.7, "scale": 2.5, "cluster": 3,
		"armor": 1.0, "hp": 4.0, "cover": 0.1,
		"map_color": Color(0.42, 0.30, 0.20)},
	Kind.FOREST: {"name": "woods", "models": FOREST_MODELS, "los_radius": 0.95, "height": 2.6, "width": 2.0, "scale": 1.7,
		"armor": 6.0, "hp": 24.0, "cover": 0.5,
		"map_color": Color(0.15, 0.30, 0.17)},
}


## "building_home_A_red" for a type ("home_A") and a colour ("red").
static func building_model(type: String, color: String) -> String:
	return "building_%s_%s" % [type, color]


static func _building_models() -> Array[String]:
	var out: Array[String] = []
	for group: Array[String] in [HOME_TYPES, CIVIC_TYPES, WORK_TYPES, MILITARY_TYPES]:
		for type in group:
			for color in BUILDING_COLORS:
				out.append(building_model(type, color))
	return out


static func info(kind: Kind) -> Dictionary:
	return INFO[kind]


static func kind_name(kind: Kind) -> String:
	return INFO[kind]["name"]


static func models(kind: Kind) -> Array[String]:
	return INFO[kind]["models"]


static func los_radius(kind: Kind) -> float:
	return INFO[kind]["los_radius"]


## Armor value a charging unit runs into (see DashAction).
static func armor(kind: Kind) -> float:
	return INFO[kind]["armor"]


static func max_hp(kind: Kind) -> float:
	return INFO[kind]["hp"]


## Share (0..1) of an explosion's damage a prop soaks for a unit it stands in front of.
static func cover(kind: Kind) -> float:
	return INFO[kind]["cover"]


## Prop cell a physics collider belongs to (PropView tags every prop body), or NO_CELL.
static func cell_of(collider: Object) -> Vector2i:
	if collider != null and collider.has_meta(META_CELL):
		return collider.get_meta(META_CELL)
	return GridBoard.NO_CELL


static func blocks_los(kind: Kind) -> bool:
	return los_radius(kind) > 0.0


static func map_color(kind: Kind) -> Color:
	return INFO[kind]["map_color"]


## The glTF file of a model stem: a pack model (nature, props, neutral and coloured buildings) or one from res://glTF.
static func scene_path(model: String) -> String:
	if _pack_folder.is_empty():
		for folder: String in PACK_FOLDERS:
			for stem: String in PACK_FOLDERS[folder]:
				_pack_folder[stem] = folder
	if _pack_folder.has(model):
		return PACK_DIR + String(_pack_folder[model]) + model + ".gltf"
	if model.begins_with("building_"):   # building_<type>_<colour>
		return PACK_DIR + "buildings/" + model.get_slice("_", model.get_slice_count("_") - 1) + "/" + model + ".gltf"
	return MODEL_DIR + model + ".gltf"


## A stable model for a cell when the map does not name one.
static func pick_model(kind: Kind, cell: Vector2i) -> String:
	var list := models(kind)
	return list[absi(hash(cell)) % list.size()]
