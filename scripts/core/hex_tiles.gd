class_name HexTiles
extends RefCounted
## Which Hexagon Pack road / river tile fits a cell. Every tile is described by the edges it touches: bit k of a mask = the
## tile reaches the neighbour in GridBoard.DIRS[k] (measured from the pack's own render, tile unrotated). Turning a tile by
## `r` * 60 degrees (yaw, Basis(UP, r * PI / 3)) moves bit k to bit k + r, and the pack has every class of edge set
## (dead end, straight, both bends, all junctions up to a full star), so any mask except "nothing" has a tile.
## Roads and rivers share the masks; the two crossing tiles carry a river mask AND a road mask (their road stops at the banks:
## the bridge models fill the gap).

const DIR := "res://Hexagon Pack/Assets/gltf/"   ## tile and model paths below are relative to this

## tile (relative to DIR, no extension) -> edge mask
const ROADS := {
	"tiles/roads/hex_road_M": 0b001000,   # dead end
	"tiles/roads/hex_road_A": 0b001001,   # straight
	"tiles/roads/hex_road_B": 0b001010,   # wide bend (120 deg)
	"tiles/roads/hex_road_C": 0b001100,   # sharp bend (60 deg)
	"tiles/roads/hex_road_D": 0b101010,   # Y
	"tiles/roads/hex_road_E": 0b001011,   # straight + one side
	"tiles/roads/hex_road_F": 0b101001,   # straight + the other side
	"tiles/roads/hex_road_G": 0b011100,   # three in a row
	"tiles/roads/hex_road_H": 0b011101,
	"tiles/roads/hex_road_I": 0b110110,
	"tiles/roads/hex_road_J": 0b111001,
	"tiles/roads/hex_road_K": 0b111110,
	"tiles/roads/hex_road_L": 0b111111,
}
const RIVERS := {
	"tiles/rivers/hex_river_A": 0b001001,
	"tiles/rivers/hex_river_A_curvy": 0b001001,
	"tiles/rivers/hex_river_B": 0b001010,
	"tiles/rivers/hex_river_C": 0b001100,
	"tiles/rivers/hex_river_D": 0b101010,
	"tiles/rivers/hex_river_E": 0b001011,
	"tiles/rivers/hex_river_F": 0b101001,
	"tiles/rivers/hex_river_G": 0b011100,
	"tiles/rivers/hex_river_H": 0b011101,
	"tiles/rivers/hex_river_I": 0b110110,
	"tiles/rivers/hex_river_J": 0b111001,
	"tiles/rivers/hex_river_K": 0b111110,
	"tiles/rivers/hex_river_L": 0b111111,
}
## tile -> [river mask, road mask]
const CROSSINGS := {
	"tiles/rivers/hex_river_crossing_A": [0b001001, 0b100100],
	"tiles/rivers/hex_river_crossing_B": [0b001001, 0b010010],
}

## crossing tile -> the arched stone bridge model that spans its river (same pivot, same turn)
const BRIDGES := {
	"tiles/rivers/hex_river_crossing_A": "buildings/neutral/building_bridge_A",
	"tiles/rivers/hex_river_crossing_B": "buildings/neutral/building_bridge_B",
}

static var _tables: Dictionary = {}   # "roads" / "rivers" -> {mask -> Array of [tile, rotation]}


## Mask `mask` turned `rotation` * 60 degrees.
static func rotated(mask: int, rotation: int) -> int:
	var r := rotation % 6
	return ((mask << r) | (mask >> (6 - r))) & 0b111111


static func mask_of(dirs: Array) -> int:
	var m := 0
	for k: int in dirs:
		m |= 1 << k
	return m


static func yaw_of(rotation: int) -> float:
	return rotation * PI / 3.0


## {"tile", "yaw"} of a road tile joining exactly the edges in `mask` (several look-alikes are told apart by `salt`),
## or {} when no edge is set (a plain grass tile does).
static func road(mask: int, salt: int = 0) -> Dictionary:
	return _pick("roads", ROADS, mask, salt)


## Same for a river (a lake cell with all six neighbours wet is a full "star" tile). A single edge has no tile of its own:
## it gets the straight one, which also reaches the opposite edge.
static func river(mask: int, salt: int = 0) -> Dictionary:
	if mask != 0 and (mask & (mask - 1)) == 0:   # exactly one bit
		mask = rotated(mask, 3) | mask
	return _pick("rivers", RIVERS, mask, salt)


## The crossing tile for a bridge cell: the river runs along `river_mask`, the road along `road_mask` (best fit when the
## road mask has extra edges).
static func crossing(river_mask: int, road_mask: int) -> Dictionary:
	var best := {}
	var best_score := -1
	for tile: String in CROSSINGS:
		for r in 6:
			if rotated(int(CROSSINGS[tile][0]), r) != river_mask:
				continue
			var roads := rotated(int(CROSSINGS[tile][1]), r)
			var score := _bits(roads & road_mask) * 2 - _bits(roads & ~road_mask)
			if score > best_score:
				best_score = score
				best = {"tile": tile, "yaw": yaw_of(r), "bridge": BRIDGES[tile]}
	return best


static func _pick(set_name: String, tiles: Dictionary, mask: int, salt: int) -> Dictionary:
	if mask == 0:
		return {}
	if not _tables.has(set_name):
		var table := {}
		for tile: String in tiles:
			for r in 6:
				var m := rotated(int(tiles[tile]), r)
				if not table.has(m):
					table[m] = []
				(table[m] as Array).append([tile, r])
		_tables[set_name] = table
	var options: Array = (_tables[set_name] as Dictionary).get(mask, [])
	if options.is_empty():
		return {}
	var choice: Array = options[absi(salt) % options.size()]
	return {"tile": choice[0], "yaw": yaw_of(int(choice[1]))}


static func _bits(m: int) -> int:
	var n := 0
	while m != 0:
		n += m & 1
		m >>= 1
	return n
