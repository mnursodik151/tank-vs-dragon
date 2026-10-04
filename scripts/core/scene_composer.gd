class_name SceneComposer
extends RefCounted
## Builds a SceneLayout for a map: raises hills (ground elevation), lays a meandering river between the two armies, then a village and
## the roads that tie the spawn zones, the village and the river bridges together, scatters foliage (trees in copses and as loners,
## large rocks, pebble clusters, groves, stumps) and undergrowth (rough ground), and finally medieval set pieces from the Hexagon Pack
## (a wall with towers, tent camps, ruins, dense woods, pasture fences) from a seed, so every game starts on a different map.
## The same seed always gives the same map (Game prints it; `--seed=N` replays it).
##
## It is a pipeline of passes over a shared set of taken cells; each pass is a `_place_*` method that only
## uses `_free` cells, so adding a pass (spawn points, objectives, ...) means one more method plus a field on
## SceneLayout. Cells inside `reserved` zones and `keep_clear` are never used. After the passes the result is
## checked: every reserved centre must stay connected on foot WITHOUT crossing a cliff (hills slope up gradually,
## a few have one sheer face), otherwise the next derived seed is tried.

const MAX_ATTEMPTS := 24
const EDGE_MARGIN := 1                 ## props keep this many columns/rows away from the map edge
const LONER_GAP := 3                   ## loner trees and large rocks keep this hex distance from their own kind
const COPSE_FAMILIES := {              ## tree model families (stems share a prefix), with pick weights
	"tree_single": 1.0,
}

var board_size := Vector2i(28, 22)
var hex_size := 1.0
## Offset cells that must stay open (spawn points). Each one clears the cells within `reserved_radius` hexes.
var reserved: Array[Vector2i] = []
var reserved_radius := 2
## Extra offset cells that must never get a prop or undergrowth.
var keep_clear: Array[Vector2i] = []

# density knobs (inclusive ranges)
var hills := Vector2i(4, 6)
var hill_ring_width := Vector2i(1, 2)  ## hexes per elevation level on a hill's slopes (1 = steep, 2 = gentle)
var cliff_chance := 0.45               ## share of hills with one side cut off sheer
var river_wander := 2                  ## rows either side of the middle (between the spawn zones) the river may drift
var bridges := Vector2i(1, 2)
var rough_patches := Vector2i(7, 10)
var rough_patch_size := Vector2i(3, 5)
var copses := Vector2i(3, 5)
var copse_trees := Vector2i(3, 5)
var copse_spacing := 6                 ## hex distance between copse centres
var loner_trees := Vector2i(4, 7)
var large_rocks := Vector2i(7, 11)
var small_rocks := Vector2i(9, 13)
var groves := Vector2i(6, 9)
var stumps := Vector2i(4, 6)
var village_chance := 0.9              ## chance of a village on the map
var village_buildings := Vector2i(4, 7)
var village_supplies := Vector2i(1, 3)
var fortifications := Vector2i(0, 1)   ## wall lines
var wall_length := Vector2i(3, 5)
var camps := Vector2i(1, 2)
var camp_tents := Vector2i(1, 2)       ## besides the camp's first tent
var camp_supplies := Vector2i(1, 2)
var ruin_sites := Vector2i(3, 5)
var woods := Vector2i(3, 4)            ## patches of dense forest
var wood_cells := Vector2i(2, 3)
var fence_lines := Vector2i(1, 2)
var fence_length := Vector2i(3, 5)

var _rng := RandomNumberGenerator.new()
var _board: GridBoard                  ## scratch board: bounds, neighbours, connectivity
var _taken := {}                       ## axial cell -> true (prop, or undergrowth)
var _blocked_zone := {}                ## axial cell -> true (reserved / keep clear / margin)
var _spawn_zone := {}                  ## axial cell -> true (reserved / keep clear): kept flat
var _reserved_zone := {}               ## axial cell -> true (reserved only): water and hills stay out
var _levels := {}                      ## axial cell -> elevation level
var _layout: SceneLayout
var _tree_cells: Array[Vector2i] = []
var _rock_cells: Array[Vector2i] = []
var _tree_near := {}                   ## axial cell -> true: within LONER_GAP - 1 hexes of a tree (loners keep their distance)
var _rock_near := {}                   ## same for large rocks
var _village_centre := GridBoard.NO_CELL
var _village_lane := GridBoard.NO_CELL ## a free cell beside the village's heart: the road goes there
var _river: Array[Vector2i] = []       ## the river's cells in flow order
var _river_dirs: Array[int] = []       ## _river_dirs[i] = direction (GridBoard.DIRS index) that led into _river[i]; the last entry leads out
var _water := {}                       ## axial cell -> true (river cells, bridges excluded)
var _bridge_sites: Array[Dictionary] = []   ## {cell, from, to}: the bridge cell and the two bank cells the road runs through
var _road := {}                        ## axial cell -> true


## Composes a layout. Tries `seed`, then derived seeds, until the map is connected (almost always the first).
func compose(seed: int) -> SceneLayout:
	var attempt_seed := seed
	for i in MAX_ATTEMPTS:
		var layout := _compose_once(attempt_seed)
		if _is_connected(layout):
			layout.seed = seed
			return layout
		attempt_seed = hash([seed, i + 1])
	push_warning("SceneComposer: no connected layout in %d attempts for seed %d, using an empty map" % [MAX_ATTEMPTS, seed])
	var empty := SceneLayout.new()
	empty.seed = seed
	return empty


func _compose_once(seed: int) -> SceneLayout:
	_rng.seed = seed
	_board = GridBoard.new(board_size, hex_size)
	_taken.clear()
	_tree_cells.clear()
	_rock_cells.clear()
	_tree_near.clear()
	_rock_near.clear()
	_village_centre = GridBoard.NO_CELL
	_village_lane = GridBoard.NO_CELL
	_river.clear()
	_river_dirs.clear()
	_water.clear()
	_bridge_sites.clear()
	_road.clear()
	_layout = SceneLayout.new()
	_layout.seed = seed
	_levels.clear()
	_mark_blocked_zones()

	_place_hills()
	_place_river()
	_place_village()
	_place_roads()
	_place_rough()
	_place_copses()
	_place_loners()
	_place_large_rocks()
	_place_small_rocks()
	_place_groves()
	_place_stumps()
	_place_fortifications()
	_place_camps()
	_place_ruins()
	_place_woods()
	_place_fences()
	for c: Vector2i in _levels:
		_layout.levels[GridBoard.axial_to_offset(c)] = _levels[c]
	for c: Vector2i in _water:
		_layout.water.append(GridBoard.axial_to_offset(c))
	return _layout


# --- passes -----------------------------------------------------------------

## Ground elevation: a few mounds whose levels fall off one per `ring` hexes, so every flank is a walkable
## slope; some mounds are cut off along one direction, leaving a cliff face (a drop of 2+ levels) that units
## would rather walk around than cross. Spawn zones stay flat and the ground rises gradually away from them.
func _place_hills() -> void:
	for n in _count(hills):
		var centre := _random_cell(func(c: Vector2i) -> bool: return not _spawn_zone.has(c))
		if centre == GridBoard.NO_CELL:
			return
		var peak := clampi(1 + int(pow(_rng.randf(), 1.4) * GridBoard.MAX_LEVEL), 1, GridBoard.MAX_LEVEL)
		var ring := _count(hill_ring_width)
		var plateau := _rng.randi_range(0, 1)
		var cut_dir := -1
		var cut_at := 0.0
		if _rng.randf() < cliff_chance:
			cut_dir = _rng.randi() % 6
			cut_at = float(_rng.randi_range(0, 1)) + 0.4
		var cut_axis := (_board.cell_to_world(GridBoard.DIRS[maxi(cut_dir, 0)]) - _board.cell_to_world(Vector2i.ZERO)).normalized()
		var origin := _board.cell_to_world(centre)
		for c in _board.all_cells():
			var d := GridBoard.hex_distance(c, centre)
			var level := peak - maxi(0, ceili(float(d - plateau) / ring))
			if level <= 0:
				continue
			if cut_dir >= 0 and (_board.cell_to_world(c) - origin).dot(cut_axis) / (hex_size * GridBoard.SQRT3) > cut_at:
				continue
			if level == 1 and _rng.randf() < 0.25:
				continue   # ragged rim
			_levels[c] = maxi(int(_levels.get(c, 0)), level)
	# gradual approach to the spawn zones: one level per hex of distance from the nearest zone cell
	for c: Vector2i in _levels.keys():
		var nearest := 1000
		for z: Vector2i in _spawn_zone:
			nearest = mini(nearest, GridBoard.hex_distance(c, z))
		var capped := mini(int(_levels[c]), nearest)
		if capped <= 0:
			_levels.erase(c)
		else:
			_levels[c] = capped


## A river wandering from the west edge to the east edge between the two armies (rows around the middle of the spawn zones), at most
## one 60 degree turn at a time so the pack's straight and gentle-bend tiles are enough. It runs on flat ground (hills under it are
## levelled) and keeps out of the spawn zones; both ends open onto the sea tiles around the map.
func _place_river() -> void:
	var lo := board_size.y
	var hi := 0
	for o in reserved:
		lo = mini(lo, o.y)
		hi = maxi(hi, o.y)
	var mid := board_size.y / 2 if reserved.is_empty() else (lo + hi) / 2
	for attempt in 12:
		var row := clampi(mid + _rng.randi_range(-1, 1), 1, board_size.y - 2)
		var cur := GridBoard.offset_to_axial(Vector2i(-1, row))   # just off the west edge
		var cells: Array[Vector2i] = []
		var dirs: Array[int] = []
		var dir := 0
		var exit := GridBoard.NO_CELL
		var ok := true
		for step in 4 * board_size.x:
			var options := _river_options(cur, dir, mid, cells.is_empty())
			if options.is_empty():
				ok = false
				break
			var weights := {}
			for d: int in options:
				weights[str(d)] = float(options[d])
			dir = int(_weighted_pick(weights))
			cur += GridBoard.DIRS[dir]
			dirs.append(dir)
			if not _board.in_bounds(cur):
				exit = cur
				break
			cells.append(cur)
		if ok and exit != GridBoard.NO_CELL and cells.size() >= board_size.x / 2:
			_river = cells
			_river_dirs = dirs
			for c in cells:
				_water[c] = true
				_levels.erase(c)
				_take(c)
			_layout.water_exits.append(Vector2i(-1, row))
			_layout.water_exits.append(GridBoard.axial_to_offset(exit))
			return


## Where the river may flow next from `cur` (heading `dir`): direction -> weight. Only east, north-east and south-east, turning by
## at most one step; it is nudged back towards the middle rows.
func _river_options(cur: Vector2i, dir: int, mid: int, first: bool) -> Dictionary:
	var out := {}
	for d: int in [5, 0, 1]:
		if not first and d != dir and (d - dir + 6) % 6 > 1 and (dir - d + 6) % 6 > 1:
			continue   # no turn sharper than 60 degrees
		var n := cur + GridBoard.DIRS[d]
		if _board.in_bounds(n) and (_reserved_zone.has(n) or _taken.has(n)):
			continue
		var w := 2.0 if d == 0 else 1.0
		var drift := cur.y - mid
		if d == 5:   # SE: row + 1
			w *= 4.0 if drift <= -river_wander else (0.0 if drift >= river_wander else 1.0)
		elif d == 1:   # NE: row - 1
			w *= 4.0 if drift >= river_wander else (0.0 if drift <= -river_wander else 1.0)
		if w > 0.0:
			out[d] = w
	return out


## Roads: one main road from the north edge through the north army's zone, the village, a bridge, the south army's zone to the
## south edge, plus a branch road over a second bridge. Cells are found with A* over the free flat-ish ground; bridges are
## entered only along the road axis (the two bank cells), so every bridge cell fits a pack crossing tile.
func _place_roads() -> void:
	if _river.is_empty():
		return
	_choose_bridges()
	if _bridge_sites.is_empty():
		return
	var graph := _road_graph()
	var ids: Dictionary = graph["ids"]
	var astar: AStar2D = graph["astar"]
	var main_site: Dictionary = _bridge_sites[0]
	var bridge_row: int = (main_site["cell"] as Vector2i).y
	var north: Array[Vector2i] = []
	var south: Array[Vector2i] = []
	for o in reserved:
		var c := GridBoard.offset_to_axial(o)
		if c.y < bridge_row:
			north.append(c)
		else:
			south.append(c)
	var legs: Array[Vector2i] = []
	var top := _edge_cell(true, _centroid_col(north))
	var bottom := _edge_cell(false, _centroid_col(south))
	if top != GridBoard.NO_CELL:
		legs.append(top)
	if not north.is_empty():
		legs.append(_open_near(_centroid(north), ids))
	if _village_lane != GridBoard.NO_CELL and _village_lane.y < bridge_row:
		legs.append(_village_lane)
	legs.append(main_site["from"])
	legs.append(main_site["cell"])
	legs.append(main_site["to"])
	if _village_lane != GridBoard.NO_CELL and _village_lane.y >= bridge_row:
		legs.append(_village_lane)
	if not south.is_empty():
		legs.append(_open_near(_centroid(south), ids))
	if bottom != GridBoard.NO_CELL:
		legs.append(bottom)
	_lay_road(astar, ids, legs)
	for i in range(1, _bridge_sites.size()):   # branch roads: join the main road on both banks
		var site: Dictionary = _bridge_sites[i]
		var from_main := _nearest_road(site["from"], true)
		var to_main := _nearest_road(site["to"], false)
		var branch: Array[Vector2i] = []
		if from_main != GridBoard.NO_CELL:
			branch.append(from_main)
		branch.append_array([site["from"], site["cell"], site["to"]])
		if to_main != GridBoard.NO_CELL:
			branch.append(to_main)
		_lay_road(astar, ids, branch)
	for c: Vector2i in _road:
		_take(c)
		_layout.roads.append(GridBoard.axial_to_offset(c))
	for site in _bridge_sites:
		if _road.has(site["cell"]):
			_layout.bridges.append(GridBoard.axial_to_offset(site["cell"]))
			_water.erase(site["cell"])


## Picks 1-2 bridge sites along straight stretches of the river: the cell, and the bank cells on both sides along a road axis
## (60 or 120 degrees off the river), every other neighbour dry and the banks level with each other.
func _choose_bridges() -> void:
	var candidates: Array[Dictionary] = []
	for i in range(3, _river.size() - 3):
		if _river_dirs[i] != _river_dirs[i + 1]:
			continue
		var cell := _river[i]
		var kr := _river_dirs[i]
		for a in [1, 2]:
			var from := cell + GridBoard.DIRS[(kr + a) % 6]
			var to := cell + GridBoard.DIRS[(kr + a + 3) % 6]
			if not _bank_ok(from) or not _bank_ok(to) or not _levels_close(from, to):
				continue
			var dry := true
			for k in 6:
				var n := cell + GridBoard.DIRS[k]
				if k == kr or k == (kr + 3) % 6 or n == from or n == to:
					continue
				dry = dry and not _water.has(n) and _board.in_bounds(n)
			if dry:
				var north_first := from.y <= to.y
				candidates.append({"cell": cell, "from": from if north_first else to, "to": to if north_first else from, "index": i})
	if candidates.is_empty():
		return
	var want := _count(bridges)
	_bridge_sites.append(candidates[_rng.randi() % candidates.size()])
	for n in want - 1:
		var far := candidates.filter(func(k: Dictionary) -> bool:
			return _bridge_sites.all(func(o: Dictionary) -> bool: return absi(int(k["index"]) - int(o["index"])) >= 6))
		if far.is_empty():
			break
		_bridge_sites.append(far[_rng.randi() % far.size()])


func _bank_ok(c: Vector2i) -> bool:
	return _board.in_bounds(c) and not _water.has(c) and not _taken.has(c)


func _levels_close(a: Vector2i, b: Vector2i) -> bool:
	return absi(int(_levels.get(a, 0)) - int(_levels.get(b, 0))) < GridBoard.CLIFF_LEVELS


## An AStar2D over the dry, untaken cells (no cliff steps; hills cost more); bridge cells hang off their two bank cells only.
func _road_graph() -> Dictionary:
	var astar := AStar2D.new()
	var ids := {}
	for c in _board.all_cells():
		ids[c] = ids.size()
		astar.add_point(ids[c], Vector2(c), 1.0 + 0.6 * float(_levels.get(c, 0)))
	var usable := func(c: Vector2i) -> bool: return ids.has(c) and not _taken.has(c)
	for c in _board.all_cells():
		if not usable.call(c):
			continue
		for d in GridBoard.DIRS:
			var n: Vector2i = c + d
			if usable.call(n) and _levels_close(c, n):
				astar.connect_points(ids[c], ids[n], true)
	for site in _bridge_sites:
		astar.connect_points(ids[site["cell"]], ids[site["from"]], true)
		astar.connect_points(ids[site["cell"]], ids[site["to"]], true)
	return {"astar": astar, "ids": ids}


## Adds the cells of the A* path through consecutive waypoints to `_road`.
func _lay_road(astar: AStar2D, ids: Dictionary, waypoints: Array[Vector2i]) -> void:
	for i in range(1, waypoints.size()):
		var a := waypoints[i - 1]
		var b := waypoints[i]
		if a == b or not ids.has(a) or not ids.has(b):
			continue
		for id in astar.get_id_path(ids[a], ids[b]):
			_road[Vector2i(astar.get_point_position(id))] = true
		_road[a] = true
		_road[b] = true


## A free edge cell (top row or bottom row) near column `col`: where the road leaves the map.
func _edge_cell(top: bool, col: int) -> Vector2i:
	var row := 0 if top else board_size.y - 1
	for spread in 6:
		for sign in [1, -1]:
			var c := GridBoard.offset_to_axial(Vector2i(clampi(col + spread * sign, 1, board_size.x - 2), row))
			if _board.in_bounds(c) and not _taken.has(c):
				return c
	return GridBoard.NO_CELL


func _centroid(cells: Array[Vector2i]) -> Vector2i:
	var sum := Vector2i.ZERO
	for c in cells:
		sum += c
	return sum / maxi(cells.size(), 1)


func _centroid_col(cells: Array[Vector2i]) -> int:
	if cells.is_empty():
		return board_size.x / 2
	return GridBoard.axial_to_offset(_centroid(cells)).x


## The untaken cell closest to `c`.
func _open_near(c: Vector2i, ids: Dictionary) -> Vector2i:
	var best := c
	var best_d := 1000
	for k in _board.all_cells():
		if _taken.has(k) or not ids.has(k):
			continue
		var d := GridBoard.hex_distance(k, c)
		if d < best_d:
			best_d = d
			best = k
	return best


## The road cell nearest to `c` on its side of the river (`north`: rows above, else below).
func _nearest_road(c: Vector2i, north: bool) -> Vector2i:
	var best := GridBoard.NO_CELL
	var best_d := 1000
	for r: Vector2i in _road:
		if (r.y <= c.y) != north and r.y != c.y:
			continue
		var d := GridBoard.hex_distance(r, c)
		if d < best_d:
			best_d = d
			best = r
	return best


## Undergrowth: small blobs of ROUGH ground, grown cell by cell from a random seed cell.
func _place_rough() -> void:
	for p in _count(rough_patches):
		var start := _random_free()
		if start == GridBoard.NO_CELL:
			return
		var blob: Array[Vector2i] = [start]
		_take(start)
		for k in _count(rough_patch_size) - 1:
			var options := _free_neighbours_of(blob)
			if options.is_empty():
				break
			var c: Vector2i = options[_rng.randi() % options.size()]
			blob.append(c)
			_take(c)
		for c in blob:
			_layout.rough.append(GridBoard.axial_to_offset(c))


## Groups of one tree family (with the odd stranger) around a few centres kept apart from each other.
func _place_copses() -> void:
	var centres: Array[Vector2i] = []
	for n in _count(copses):
		var centre := _random_free(func(c: Vector2i) -> bool:
			return centres.all(func(o: Vector2i) -> bool: return GridBoard.hex_distance(c, o) >= copse_spacing))
		if centre == GridBoard.NO_CELL:
			break
		centres.append(centre)
		var family := _weighted_pick(COPSE_FAMILIES)
		var spots: Array[Vector2i] = []
		for c in _board.all_cells():
			if _free(c) and GridBoard.hex_distance(c, centre) <= 2:
				spots.append(c)
		# nearest first, with jitter so the copse is ragged rather than a perfect disc
		spots.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return GridBoard.hex_distance(a, centre) + _jitter(a) < GridBoard.hex_distance(b, centre) + _jitter(b))
		for i in mini(_count(copse_trees), spots.size()):
			var from_family := _rng.randf() > 0.15
			_add_prop(Props.Kind.TREE, spots[i], _tree_model(family if from_family else ""))


func _place_loners() -> void:
	for n in _count(loner_trees):
		var c := _random_free(func(c: Vector2i) -> bool: return not _tree_near.has(c))
		if c == GridBoard.NO_CELL:
			return
		_add_prop(Props.Kind.TREE, c, _tree_model(""))


func _place_large_rocks() -> void:
	var models := Props.models(Props.Kind.ROCK_LARGE)
	for n in _count(large_rocks):
		var c := _random_free(func(c: Vector2i) -> bool: return not _rock_near.has(c))
		if c == GridBoard.NO_CELL:
			return
		_add_prop(Props.Kind.ROCK_LARGE, c, models[_rng.randi() % models.size()])


func _place_small_rocks() -> void:
	var models := Props.models(Props.Kind.ROCK_SMALL)
	for n in _count(small_rocks):
		var c := _random_free()
		if c == GridBoard.NO_CELL:
			return
		_add_prop(Props.Kind.ROCK_SMALL, c, models[_rng.randi() % models.size()])


## Groves (a few small trees) like company: most hug a tree or a large rock, the rest stand alone.
func _place_groves() -> void:
	var models := Props.models(Props.Kind.GROVE)
	var anchors := _tree_cells + _rock_cells
	for n in _count(groves):
		var c := GridBoard.NO_CELL
		if not anchors.is_empty() and _rng.randf() < 0.6:
			var near: Array[Vector2i] = []
			for a in anchors:
				for d in GridBoard.DIRS:
					if _free(a + d):
						near.append(a + d)
			if not near.is_empty():
				c = near[_rng.randi() % near.size()]
		if c == GridBoard.NO_CELL:
			c = _random_free()
		if c == GridBoard.NO_CELL:
			return
		_add_prop(Props.Kind.GROVE, c, models[_rng.randi() % models.size()])


## Felled trees: stump clusters beside the copses (that is where the wood came from), some out in the open.
func _place_stumps() -> void:
	var models := Props.models(Props.Kind.STUMPS)
	for n in _count(stumps):
		var c := GridBoard.NO_CELL
		if not _tree_cells.is_empty() and _rng.randf() < 0.7:
			var near: Array[Vector2i] = []
			for t in _tree_cells:
				for d in GridBoard.DIRS:
					if _free(t + d):
						near.append(t + d)
			if not near.is_empty():
				c = near[_rng.randi() % near.size()]
		if c == GridBoard.NO_CELL:
			c = _random_free()
		if c == GridBoard.NO_CELL:
			return
		_add_prop(Props.Kind.STUMPS, c, models[_rng.randi() % models.size()])


# --- Hexagon Pack set pieces (placed after the foliage) ----------

## A hamlet in one colour: a civic building (well, market, church, tavern) in the middle, homes and workshops around it with a gap
## between every two buildings, and a few supply piles in the lanes.
func _place_village() -> void:
	if _rng.randf() >= village_chance:
		return
	var color: String = Props.BUILDING_COLORS[_rng.randi() % Props.BUILDING_COLORS.size()]
	var centre := _random_free(func(k: Vector2i) -> bool: return _count_around(k, 2, _flat_free) >= 12)
	if centre == GridBoard.NO_CELL:
		return
	var spots: Array[Vector2i] = []
	for k in _board.all_cells():
		if _flat_free(k) and GridBoard.hex_distance(k, centre) <= 3:
			spots.append(k)
	spots.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return GridBoard.hex_distance(a, centre) + _jitter(a) < GridBoard.hex_distance(b, centre) + _jitter(b))
	var chosen: Array[Vector2i] = []
	var want := _count(village_buildings)
	for spot in spots:
		if chosen.size() >= want:
			break
		if chosen.all(func(o: Vector2i) -> bool: return GridBoard.hex_distance(spot, o) >= 2):
			chosen.append(spot)
	for i in chosen.size():
		var pool: Array[String] = Props.CIVIC_TYPES if i == 0 else (Props.HOME_TYPES if _rng.randf() < 0.7 else Props.WORK_TYPES)
		_add_prop(Props.Kind.BUILDING, chosen[i], Props.building_model(pool[_rng.randi() % pool.size()], color))
	_village_centre = centre
	var lanes: Array[Vector2i] = []
	for k in _free_neighbours_of(chosen):
		if not _levels.has(k):
			lanes.append(k)
	var heart_lanes: Array[Vector2i] = []
	for k in _free_neighbours_of([chosen[0]]):
		if lanes.has(k):
			heart_lanes.append(k)
	if not heart_lanes.is_empty():
		_village_lane = _take_random(heart_lanes)   # the road comes through here
		lanes.erase(_village_lane)
	var piles := Props.models(Props.Kind.SUPPLY)
	for n in _count(village_supplies):
		if lanes.is_empty():
			break
		_add_prop(Props.Kind.SUPPLY, _take_random(lanes), piles[_rng.randi() % piles.size()])


## Straight stone walls laid along a hex line (sometimes with a gap in the middle as a gate), with a tower at one end.
func _place_fortifications() -> void:
	for n in _count(fortifications):
		var line := _find_line(_count(wall_length))
		if line.is_empty():
			return
		var cells: Array[Vector2i] = line["cells"]
		var gap := cells.size() >= 4 and _rng.randf() < 0.6
		for i in cells.size():
			if not (gap and i == cells.size() >> 1):
				_add_prop(Props.Kind.WALL, cells[i], "wall_straight", line["yaw"])
		var tower: Vector2i = cells[0] - (line["dir"] as Vector2i)
		if _free(tower):
			var types := Props.MILITARY_TYPES.slice(2)   # the towers
			var color: String = Props.BUILDING_COLORS[_rng.randi() % Props.BUILDING_COLORS.size()]
			_add_prop(Props.Kind.BUILDING, tower, Props.building_model(types[_rng.randi() % types.size()], color))


## A few tents with supply piles around them.
func _place_camps() -> void:
	var piles := Props.models(Props.Kind.SUPPLY)
	for n in _count(camps):
		var centre := _random_free(func(k: Vector2i) -> bool: return _count_around(k, 1, _free) >= 5)
		if centre == GridBoard.NO_CELL:
			return
		_add_prop(Props.Kind.TENT, centre, "tent")
		var near := _free_neighbours_of([centre])
		for i in _count(camp_tents):
			if not near.is_empty():
				_add_prop(Props.Kind.TENT, _take_random(near), "tent")
		for i in _count(camp_supplies):
			if not near.is_empty():
				_add_prop(Props.Kind.SUPPLY, _take_random(near), piles[_rng.randi() % piles.size()])


## Collapsed buildings and building sites standing alone: low enough to see over, solid enough to hide behind.
func _place_ruins() -> void:
	var ruins := Props.models(Props.Kind.RUIN)
	for n in _count(ruin_sites):
		var c := _random_free()
		if c == GridBoard.NO_CELL:
			return
		_add_prop(Props.Kind.RUIN, c, ruins[_rng.randi() % ruins.size()])


## Dense woods: a few touching cells of one tree family (pack "A" or "B") in assorted sizes.
func _place_woods() -> void:
	for n in _count(woods):
		var start := _random_free()
		if start == GridBoard.NO_CELL:
			return
		var family := "trees_%s_" % ("A" if _rng.randf() < 0.5 else "B")
		var pool: Array[String] = []
		for m in Props.models(Props.Kind.FOREST):
			if m.begins_with(family):
				pool.append(m)
		var blob: Array[Vector2i] = [start]
		_take(start)
		for k in _count(wood_cells) - 1:
			var options := _free_neighbours_of(blob)
			if options.is_empty():
				break
			var next := options[_rng.randi() % options.size()]
			blob.append(next)
			_take(next)
		for c in blob:
			_add_prop(Props.Kind.FOREST, c, pool[_rng.randi() % pool.size()])


## Pasture fences along a hex line, close to the village when there is one.
func _place_fences() -> void:
	var models := Props.models(Props.Kind.FENCE)
	for n in _count(fence_lines):
		var line := _find_line(_count(fence_length), _village_centre, 5)
		if line.is_empty():
			return
		var model := models[_rng.randi() % models.size()]
		for c: Vector2i in line["cells"]:
			_add_prop(Props.Kind.FENCE, c, model, line["yaw"])


# --- helpers ----------------------------------------------------------------

func _mark_blocked_zones() -> void:
	_blocked_zone.clear()
	for c in _board.all_cells():
		var o := GridBoard.axial_to_offset(c)
		if o.x < EDGE_MARGIN or o.y < EDGE_MARGIN or o.x >= board_size.x - EDGE_MARGIN or o.y >= board_size.y - EDGE_MARGIN:
			_blocked_zone[c] = true
	for o in reserved:
		var centre := GridBoard.offset_to_axial(o)
		for c in _board.all_cells():
			if GridBoard.hex_distance(c, centre) <= reserved_radius:
				_blocked_zone[c] = true
	for o in keep_clear:
		_blocked_zone[GridBoard.offset_to_axial(o)] = true
	_spawn_zone.clear()
	_reserved_zone.clear()
	for o in reserved:
		var centre := GridBoard.offset_to_axial(o)
		for c in _board.all_cells():
			if GridBoard.hex_distance(c, centre) <= reserved_radius:
				_spawn_zone[c] = true
				_reserved_zone[c] = true
	for o in keep_clear:
		_spawn_zone[GridBoard.offset_to_axial(o)] = true


func _free(c: Vector2i) -> bool:
	return _board.in_bounds(c) and not _taken.has(c) and not _blocked_zone.has(c)


func _take(c: Vector2i) -> void:
	_taken[c] = true


## `yaw` (radians) is only for line props (walls, fences); NAN leaves the facing to the view.
func _add_prop(kind: Props.Kind, c: Vector2i, model: String, yaw: float = NAN) -> void:
	_take(c)
	if is_nan(yaw):
		_layout.props.append([kind, GridBoard.axial_to_offset(c), model])
	else:
		_layout.props.append([kind, GridBoard.axial_to_offset(c), model, yaw])
	if kind == Props.Kind.TREE:
		_tree_cells.append(c)
		_mark_near(_tree_near, c)
	elif kind == Props.Kind.ROCK_LARGE:
		_rock_cells.append(c)
		_mark_near(_rock_near, c)


## Flags every cell closer than LONER_GAP hexes to `c` in `zone`.
func _mark_near(zone: Dictionary, c: Vector2i) -> void:
	for cell in _disc(c, LONER_GAP - 1):
		zone[cell] = true


## The cells within `radius` hexes of `centre` (itself included), bounds not checked.
func _disc(centre: Vector2i, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dq in range(-radius, radius + 1):
		for dr in range(maxi(-radius, -dq - radius), mini(radius, -dq + radius) + 1):
			out.append(centre + Vector2i(dq, dr))
	return out


## A random cell of the board passing `accept`, or NO_CELL.
func _random_cell(accept: Callable) -> Vector2i:
	var options: Array[Vector2i] = []
	for c in _board.all_cells():
		if accept.call(c):
			options.append(c)
	if options.is_empty():
		return GridBoard.NO_CELL
	return options[_rng.randi() % options.size()]


## A random free cell passing `accept` (all free cells when empty), or NO_CELL.
func _random_free(accept: Callable = Callable()) -> Vector2i:
	var options: Array[Vector2i] = []
	for c in _board.all_cells():
		if _free(c) and (accept.is_null() or accept.call(c)):
			options.append(c)
	if options.is_empty():
		return GridBoard.NO_CELL
	return options[_rng.randi() % options.size()]


## Free ground that is also flat (no hill): where buildings go.
func _flat_free(c: Vector2i) -> bool:
	return _free(c) and not _levels.has(c)


## How many cells within `radius` hexes of `centre` (itself included) pass `accept`.
func _count_around(centre: Vector2i, radius: int, accept: Callable) -> int:
	var n := 0
	for c in _disc(centre, radius):
		if _board.in_bounds(c) and accept.call(c):
			n += 1
	return n


## Removes and returns a random element.
func _take_random(options: Array[Vector2i]) -> Vector2i:
	var i := _rng.randi() % options.size()
	var c := options[i]
	options.remove_at(i)
	return c


## `length` free cells in a row along a random hex direction ({"cells", "dir", "yaw"}, yaw laying a model's local x along the row),
## starting within `anchor_radius` of `anchor` when one is given. Empty when nothing fits after a few tries.
func _find_line(length: int, anchor := GridBoard.NO_CELL, anchor_radius := 0) -> Dictionary:
	var starts: Array[Vector2i] = []   # the free cells do not change while a line is searched for
	for c in _board.all_cells():
		if _free(c):
			starts.append(c)
	if starts.is_empty():
		return {}
	for attempt in 30:
		var start := starts[_rng.randi() % starts.size()]
		if anchor != GridBoard.NO_CELL and GridBoard.hex_distance(start, anchor) > anchor_radius:
			continue
		var dir := GridBoard.DIRS[_rng.randi() % GridBoard.DIRS.size()]
		var cells: Array[Vector2i] = []
		for k in length:
			var c := start + dir * k
			if not _free(c):
				break
			cells.append(c)
		if cells.size() == length:
			var step := _board.cell_to_world(start + dir) - _board.cell_to_world(start)
			return {"cells": cells, "dir": dir, "yaw": atan2(-step.z, step.x)}
	return {}


func _free_neighbours_of(cells: Array[Vector2i]) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in cells:
		for d in GridBoard.DIRS:
			var n := c + d
			if _free(n) and not out.has(n):
				out.append(n)
	return out


func _count(range_: Vector2i) -> int:
	return _rng.randi_range(range_.x, range_.y)


func _jitter(c: Vector2i) -> float:
	return float(absi(hash([c, _rng.seed])) % 100) / 100.0 * 1.6


func _weighted_pick(weights: Dictionary) -> String:
	var total := 0.0
	for k: String in weights:
		total += float(weights[k])
	var roll := _rng.randf() * total
	for k: String in weights:
		roll -= float(weights[k])
		if roll <= 0.0:
			return k
	return weights.keys()[0]


## A tree model of the given family prefix ("Pine"), or from any family when empty.
func _tree_model(family: String) -> String:
	var pool: Array[String] = []
	for m in Props.models(Props.Kind.TREE):
		if family == "" or m.begins_with(family):
			pool.append(m)
	return pool[_rng.randi() % pool.size()]


## Every reserved centre must reach the first one over open ground (props and water block movement, bridges are road cells,
## cliffs are not crossed).
func _is_connected(layout: SceneLayout) -> bool:
	if reserved.size() < 2:
		return true
	var board := GridBoard.new(board_size, hex_size)
	layout.apply(board)
	var first := GridBoard.offset_to_axial(reserved[0])
	for i in range(1, reserved.size()):
		if board.find_path(first, GridBoard.offset_to_axial(reserved[i]), INF, false).is_empty():
			return false
	return true
