class_name GridBoard
extends RefCounted
## Pure hex-grid logic: cell <-> world, terrain weights, blocking, occupancy, weighted pathfinding.
## No scene-tree dependency (besides Unit as a data holder), so it is easy to test.
##
## Cells are axial coordinates (x = q, y = r), pointy-top hexes, laid out as a rectangle of
## `size.x` columns by `size.y` rows ("odd-r" offset shape). `hex_size` is the circumradius.
## World layout: cell (0,0) is centred on the origin, rows grow along +z; y = 0 is floor level.
## The grid is only a *bookkeeping* layer: units stand wherever their body is, `cell` is derived.

const SQRT3 := 1.7320508075688772
const NO_CELL := Vector2i(-999999, -999999)
signal terrain_changed(cell: Vector2i, type: int)
signal prop_damaged(cell: Vector2i, hp: float)
signal prop_destroyed(cell: Vector2i, kind: int)
signal prop_restored(cell: Vector2i, kind: int)   ## a rewind brought a destroyed prop back

## Ground elevation: every cell has a level 0..MAX_LEVEL (0 = flat ground), ELEVATION_STEP metres each.
## Neighbours one level apart form a slope (walking it costs extra AP uphill, a little downhill). A difference
## of CLIFF_LEVELS or more is a cliff face: crossing it is allowed but costs a lot of AP, so units normally
## walk around. Height only ever costs AP, never hit points. See step_cost.
const MAX_LEVEL := 5
const ELEVATION_STEP := 0.5
const CLIFF_LEVELS := 2
const CLIMB_WEIGHT := 1.0          ## extra terrain weight per level climbed on a slope
const DESCENT_WEIGHT := 0.25       ## ... per level descended on a slope
const CLIFF_CLIMB_WEIGHT := 3.0    ## ... per level climbed up a cliff face
const CLIFF_DROP_WEIGHT := 1.5     ## ... per level dropped down a cliff face
const LOS_SAMPLE := 0.3            ## terrain line-of-sight sampling step, in hex sizes

const FIRE_DURATION := 3          ## rounds a fire burns before leaving scorched ground
const FIRE_SPREAD_BASE := 0.10    ## per-neighbour spread chance per round
const FIRE_SPREAD_WIND := 0.55    ## extra chance downwind at full wind strength
const DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1),
]
## Neighbour across edge i of the hex (edge i joins corner i and i+1, corners at 30 + 60*i degrees).
const EDGE_NEIGHBORS: Array[Vector2i] = [
	Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0),
	Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0),
]

var size: Vector2i      ## columns x rows
var hex_size: float     ## circumradius, metres

var _blocked: Dictionary = {}   # Vector2i -> true   (static obstacles)
var _props: Dictionary = {}     # Vector2i -> {"kind": Props.Kind, "model": String, "hp": float, "yaw": float or NAN}  (also in _blocked)
var _occluders := PackedVector3Array()   # (x, z, radius) of every line-of-sight blocking prop; rebuilt lazily
var _occluders_dirty := false
var _weights: Dictionary = {}   # Vector2i -> float  (terrain weight, default 1.0)
var _levels: Dictionary = {}    # Vector2i -> int  (elevation level, only non-zero)
var _terrain: Dictionary = {}   # Vector2i -> Terrain.Type (only non-grass cells)
var _fires: Dictionary = {}     # Vector2i -> rounds of fire left
var _occupied: Dictionary = {}  # Vector2i -> Unit
var _water: Dictionary = {}     # Vector2i -> true  (river / lake cells: walkable, at Terrain.WATER_WEIGHT, and immune to craters / fire)
var _bridges: Dictionary = {}   # Vector2i -> true  (road cells that cross a river)
var _exits: Dictionary = {}     # Vector2i (OUTSIDE the board) -> true: where a river leaves the map (tile selection only)
var _cells: Array[Vector2i] = []


func _init(p_size: Vector2i, p_hex_size: float = 1.0) -> void:
	size = p_size
	hex_size = p_hex_size
	for row in size.y:
		for col in size.x:
			_cells.append(offset_to_axial(Vector2i(col, row)))


# --- hex maths --------------------------------------------------------------

static func offset_to_axial(o: Vector2i) -> Vector2i:
	return Vector2i(o.x - floori(o.y * 0.5), o.y)


## Inverse of offset_to_axial: (column, row) of an axial cell.
static func axial_to_offset(a: Vector2i) -> Vector2i:
	return Vector2i(a.x + floori(a.y * 0.5), a.y)


static func hex_distance(a: Vector2i, b: Vector2i) -> int:
	var dq := a.x - b.x
	var dr := a.y - b.y
	return (absi(dq) + absi(dq + dr) + absi(dr)) >> 1


static func axial_round(q: float, r: float) -> Vector2i:
	var s := -q - r
	var rq := roundf(q)
	var rr := roundf(r)
	var rs := roundf(s)
	var dq := absf(rq - q)
	var dr := absf(rr - r)
	var ds := absf(rs - s)
	if dq > dr and dq > ds:
		rq = -rr - rs
	elif dr > ds:
		rr = -rq - rs
	return Vector2i(int(rq), int(rr))


## Flat (x, z) position of the hex corner `i` (0..5) around `centre`.
func corner(centre: Vector3, i: int, radius: float = -1.0) -> Vector3:
	var r := hex_size if radius < 0.0 else radius
	var a := deg_to_rad(30.0 + 60.0 * i)
	return Vector3(centre.x + r * cos(a), centre.y, centre.z + r * sin(a))


# --- conversion -------------------------------------------------------------

func all_cells() -> Array[Vector2i]:
	return _cells


func in_bounds(c: Vector2i) -> bool:
	if c.y < 0 or c.y >= size.y:
		return false
	var col := c.x + floori(c.y * 0.5)
	return col >= 0 and col < size.x


## World position of a cell centre. `y` is an offset above the cell's ground (elevation included).
func cell_to_world(c: Vector2i, y: float = 0.0) -> Vector3:
	return Vector3(hex_size * SQRT3 * (c.x + c.y * 0.5), y + height_of(c), hex_size * 1.5 * c.y)


func world_to_cell(p: Vector3) -> Vector2i:
	var q := (SQRT3 / 3.0 * p.x - p.z / 3.0) / hex_size
	var r := (2.0 / 3.0 * p.z) / hex_size
	return axial_round(q, r)


## Centre of the board's bounding box on the floor (camera focus).
func world_center() -> Vector3:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in _cells:
		var p := cell_to_world(c)
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.z))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.z))
	return Vector3((lo.x + hi.x) * 0.5, 0.0, (lo.y + hi.y) * 0.5)


# --- terrain / occupancy ----------------------------------------------------

func set_blocked(c: Vector2i, blocked: bool = true) -> void:
	if blocked:
		_blocked[c] = true
	else:
		_blocked.erase(c)


func blocked_cells() -> Array:
	return _blocked.keys()


func is_blocked(c: Vector2i) -> bool:
	return _blocked.has(c)


# --- water and bridges ---------------------------------------------------------

## River / lake cell: units can wade through it, but every step costs Terrain.WATER_WEIGHT (a bridge is the cheap way across).
## Sight and shells cross it like open ground; it never gets craters or fire.
func add_water(c: Vector2i) -> void:
	if not in_bounds(c):
		return
	_water[c] = true
	set_weight(c, Terrain.WATER_WEIGHT)


func is_water(c: Vector2i) -> bool:
	return _water.has(c)


func water_cells() -> Array:
	return _water.keys()


## A road cell over a river: walkable like any road cell, drawn with a crossing tile.
func add_bridge(c: Vector2i) -> void:
	if in_bounds(c):
		_bridges[c] = true
		set_terrain(c, Terrain.Type.ROAD)


func is_bridge(c: Vector2i) -> bool:
	return _bridges.has(c)


## Marks the cell OUTSIDE the board that a river flows out to (so the edge cell's tile opens towards it).
func add_water_exit(c: Vector2i) -> void:
	if not in_bounds(c):
		_exits[c] = true


func is_water_exit(c: Vector2i) -> bool:
	return _exits.has(c)


# --- props (trees, rocks, groves) and line of sight ---------------------------

## Puts a prop on `c`: the cell becomes an obstacle, and for trees / large rocks it also blocks sight.
## `model` is a glTF file stem (see Props); empty picks a stable one for the cell. `yaw` (radians) fixes the facing of line props
## (walls, fences) and is NAN when the view may pick one.
func add_prop(c: Vector2i, kind: Props.Kind, model: String = "", yaw: float = NAN) -> void:
	if not in_bounds(c):
		return
	_props[c] = {"kind": kind, "model": model if model != "" else Props.pick_model(kind, c), "hp": Props.max_hp(kind), "yaw": yaw}
	_blocked[c] = true
	_occluders_dirty = true


## Props.Kind of the prop standing on `c`, or -1.
func prop_at(c: Vector2i) -> int:
	return _props[c]["kind"] if _props.has(c) else -1


func prop_hp(c: Vector2i) -> float:
	return _props[c]["hp"] if _props.has(c) else 0.0


## Hurts the prop on `c`; at 0 hp it is destroyed: the cell opens up and sight lines clear. Returns the hp left.
func damage_prop(c: Vector2i, amount: float) -> float:
	if not _props.has(c) or amount <= 0.0:
		return prop_hp(c)
	var left := maxf(0.0, float(_props[c]["hp"]) - amount)
	_props[c]["hp"] = left
	if left > 0.001:
		prop_damaged.emit(c, left)
		return left
	var kind: int = _props[c]["kind"]
	_props.erase(c)
	_blocked.erase(c)
	_occluders_dirty = true
	prop_destroyed.emit(c, kind)
	return 0.0


func prop_model(c: Vector2i) -> String:
	return _props[c]["model"] if _props.has(c) else ""


## Facing the layout gave the prop on `c` (radians), or NAN when the view picks one.
func prop_yaw(c: Vector2i) -> float:
	return _props[c]["yaw"] if _props.has(c) else NAN


func prop_cells() -> Array:
	return _props.keys()


## (x, z, radius) of every flat disc that hides what stands behind it (trees, large rocks).
func los_occluders() -> PackedVector3Array:
	if _occluders_dirty:
		_occluders.clear()
		for c: Vector2i in _props:
			var radius := Props.los_radius(_props[c]["kind"])
			if radius > 0.0:
				var p := cell_to_world(c)
				_occluders.append(Vector3(p.x, p.z, radius))
		_occluders_dirty = false
	return _occluders


## True when a tree or large rock stands between the flat points `a` and `b`, or higher ground rises above the
## straight line joining them (their y values are the eye heights). A prop that contains either end does not
## count: you can see the tree you are looking at, and a unit never stands in one.
func los_blocked(a: Vector3, b: Vector3) -> bool:
	var pa := Vector2(a.x, a.z)
	var pb := Vector2(b.x, b.z)
	for o in los_occluders():
		var centre := Vector2(o.x, o.y)
		if pa.distance_to(centre) < o.z or pb.distance_to(centre) < o.z:
			continue
		if _segment_distance(pa, pb, centre) < o.z:
			return true
	return terrain_blocks(a, b)


## True when the ground between `a` and `b` rises above the line joining them (y values are eye heights).
func terrain_blocks(a: Vector3, b: Vector3) -> bool:
	if _levels.is_empty():
		return false
	var steps := ceili(Vector2(b.x - a.x, b.z - a.z).length() / (hex_size * LOS_SAMPLE))
	for s in range(1, steps):
		var p := a.lerp(b, float(s) / steps)
		if height_of(world_to_cell(p)) > p.y:
			return true
	return false


## Flat (x, z) polygons of the ground hidden from `from` by occluders within `reach` metres: each is the
## quad behind one tree / rock, as seen from `from`, long enough to leave the reach circle.
func los_shadows(from: Vector3, reach: float) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	var s := Vector2(from.x, from.z)
	for o in los_occluders():
		var centre := Vector2(o.x, o.y)
		var dist := s.distance_to(centre)
		if dist <= o.z or dist > reach + o.z:
			continue
		var side := (centre - s).normalized().orthogonal() * o.z
		var t1 := centre + side
		var t2 := centre - side
		var far := reach * 2.0 + 2.0
		out.append(PackedVector2Array([t1, t1 + (t1 - s).normalized() * far, t2 + (t2 - s).normalized() * far, t2]))
	return out


static func _segment_distance(a: Vector2, b: Vector2, p: Vector2) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	var t := 0.0 if len2 < 0.000001 else clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return (a + ab * t).distance_to(p)


## Terrain weight of entering `c`. 1.0 is open ground; larger = more AP per step.
func set_weight(c: Vector2i, weight: float) -> void:
	if is_equal_approx(weight, 1.0):
		_weights.erase(c)
	else:
		_weights[c] = weight


func weight_of(c: Vector2i) -> float:
	return _weights.get(c, 1.0)


func weighted_cells() -> Array:
	return _weights.keys()


# --- elevation ----------------------------------------------------------------

func set_level(c: Vector2i, level: int) -> void:
	level = clampi(level, 0, MAX_LEVEL)
	if level == 0:
		_levels.erase(c)
	else:
		_levels[c] = level


func level_of(c: Vector2i) -> int:
	return _levels.get(c, 0)


func height_of(c: Vector2i) -> float:
	return float(_levels.get(c, 0)) * ELEVATION_STEP


## Ground height under the flat position of `p`.
func surface_y(p: Vector3) -> float:
	return height_of(world_to_cell(p))


## Cells above ground level.
func elevated_cells() -> Array:
	return _levels.keys()


## True when stepping from `from` to the adjacent cell `to` crosses a cliff face.
func is_cliff(from: Vector2i, to: Vector2i) -> bool:
	return absi(level_of(to) - level_of(from)) >= CLIFF_LEVELS


## Terrain weight of stepping onto the adjacent cell `to` from `from`: its own weight plus the climb or
## descent. INF when `allow_cliffs` is off and the step is a cliff.
func step_cost(from: Vector2i, to: Vector2i, allow_cliffs: bool = true) -> float:
	var diff := level_of(to) - level_of(from)
	var cliff := absi(diff) >= CLIFF_LEVELS
	if cliff and not allow_cliffs:
		return INF
	var w := weight_of(to)
	if diff > 0:
		w += (CLIFF_CLIMB_WEIGHT if cliff else CLIMB_WEIGHT) * diff
	elif diff < 0:
		w += (CLIFF_DROP_WEIGHT if cliff else DESCENT_WEIGHT) * -diff
	return w


# --- terrain types, craters, fire -------------------------------------------

func terrain_at(c: Vector2i) -> Terrain.Type:
	return _terrain.get(c, Terrain.Type.GRASS)


## Cells whose terrain differs from plain grass.
func terrain_cells() -> Array:
	return _terrain.keys()


## Changes a cell's terrain (and with it the AP weight of entering it). Obstacles are untouched.
func set_terrain(c: Vector2i, t: Terrain.Type) -> void:
	if not in_bounds(c) or _blocked.has(c) or _water.has(c):
		return
	if t == Terrain.Type.GRASS:
		_terrain.erase(c)
	else:
		_terrain[c] = t
	if t != Terrain.Type.FIRE:
		_fires.erase(c)
	set_weight(c, Terrain.weight(t))
	terrain_changed.emit(c, t)


## Open cells whose centre lies within `radius` metres (flat) of `point`.
func cells_within(point: Vector3, radius: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in _cells:
		if _blocked.has(c) or _water.has(c):
			continue
		var p := cell_to_world(c)
		if Vector2(p.x - point.x, p.z - point.z).length() <= radius:
			out.append(c)
	return out


## Turns the cells around an impact into craters (costlier to cross). Returns how many changed.
func crater_area(point: Vector3, radius: float) -> int:
	var cells := cells_within(point, radius)
	for c in cells:
		set_terrain(c, Terrain.Type.CRATER)
	return cells.size()


## Sets the cells around an impact on fire. Returns how many ignited.
func ignite_area(point: Vector3, radius: float) -> int:
	var count := 0
	for c in cells_within(point, radius):
		if terrain_at(c) != Terrain.Type.FIRE:
			ignite(c, FIRE_DURATION)
			count += 1
	return count


func ignite(c: Vector2i, rounds: int) -> void:
	if not in_bounds(c) or _blocked.has(c) or _water.has(c):
		return
	set_terrain(c, Terrain.Type.FIRE)
	_fires[c] = rounds


func is_burning(c: Vector2i) -> bool:
	return _fires.has(c)


func fire_cells() -> Array:
	return _fires.keys()


## Advances every fire by one round: fires burn down (and leave scorched ground) or spread to
## flammable neighbours. `wind_push` is the wind direction scaled 0..1 by its strength; spreading
## downwind is far more likely.
func tick_fires(wind_push: Vector3, rng: RandomNumberGenerator) -> void:
	var to_ignite: Array[Vector2i] = []
	var burnt_out: Array[Vector2i] = []
	for c: Vector2i in _fires.keys():
		_fires[c] -= 1
		if _fires[c] <= 0:
			burnt_out.append(c)
			continue
		if _fires[c] < 2:
			continue   # dying fires no longer spread
		var here := cell_to_world(c)
		for d in DIRS:
			var n := c + d
			if not in_bounds(n) or _blocked.has(n) or _water.has(n) or not Terrain.flammable(terrain_at(n)):
				continue
			var heading := (cell_to_world(n) - here).normalized()
			var chance := FIRE_SPREAD_BASE + FIRE_SPREAD_WIND * maxf(0.0, heading.dot(wind_push))
			if rng.randf() < chance:
				to_ignite.append(n)
	for c in burnt_out:
		set_terrain(c, Terrain.Type.SCORCH)
	for n in to_ignite:
		if terrain_at(n) != Terrain.Type.FIRE:
			ignite(n, FIRE_DURATION - 1)


# --- memento (undo / rewind, see BattleSnapshot) ------------------------------

## The parts of the board a battle changes: prop hit points / destruction, terrain (craters, scorch), fires. The map itself
## (levels, water, roads) never changes during a battle and is not captured; unit placement is re-derived by `resync`.
func capture() -> Dictionary:
	return {"props": _props.duplicate(true), "blocked": _blocked.duplicate(), "terrain": _terrain.duplicate(),
		"weights": _weights.duplicate(), "fires": _fires.duplicate()}


## Puts the board back as `state` says and tells the views what came back (`terrain_changed`, `prop_restored`).
func restore(state: Dictionary) -> void:
	var old_terrain := _terrain
	var old_props := _props
	_props = (state["props"] as Dictionary).duplicate(true)
	_blocked = (state["blocked"] as Dictionary).duplicate()
	_terrain = (state["terrain"] as Dictionary).duplicate()
	_weights = (state["weights"] as Dictionary).duplicate()
	_fires = (state["fires"] as Dictionary).duplicate()
	_occluders_dirty = true
	var touched := {}
	for c: Vector2i in old_terrain:
		touched[c] = true
	for c: Vector2i in _terrain:
		touched[c] = true
	for c: Vector2i in touched:
		if old_terrain.get(c, Terrain.Type.GRASS) != _terrain.get(c, Terrain.Type.GRASS):
			terrain_changed.emit(c, _terrain.get(c, Terrain.Type.GRASS))
	for c: Vector2i in _props:
		if not old_props.has(c):
			prop_restored.emit(c, _props[c]["kind"])


func unit_at(c: Vector2i) -> Unit:
	return _occupied.get(c, null) as Unit


func is_walkable(c: Vector2i) -> bool:
	return in_bounds(c) and not _blocked.has(c) and not _occupied.has(c)


func place(unit: Unit, c: Vector2i) -> void:
	remove(unit)
	unit.cell = c
	_occupied[c] = unit


func remove(unit: Unit) -> void:
	if _occupied.get(unit.cell, null) == unit:
		_occupied.erase(unit.cell)


# --- queries ----------------------------------------------------------------

## Dijkstra over terrain weights. Other units and obstacles block; `origin` is always allowed.
## Returns {"dist": cell -> cost, "prev": cell -> previous cell}. Stops early at `goal`
## and never expands beyond `max_cost`.
func _search(origin: Vector2i, max_cost: float, goal: Vector2i = NO_CELL, allow_cliffs: bool = true) -> Dictionary:
	var dist: Dictionary = {origin: 0.0}
	var prev: Dictionary = {}
	var open: Array[Vector2i] = [origin]
	var closed: Dictionary = {}
	while not open.is_empty():
		var best := 0
		for i in range(1, open.size()):
			if dist[open[i]] < dist[open[best]]:
				best = i
		var cur: Vector2i = open[best]
		open.remove_at(best)
		if closed.has(cur):
			continue
		closed[cur] = true
		if cur == goal:
			break
		for d in DIRS:
			var n := cur + d
			if closed.has(n) or not is_walkable(n):
				continue
			var step := step_cost(cur, n, allow_cliffs)
			if is_inf(step):
				continue
			var nd: float = dist[cur] + step
			if nd > max_cost:
				continue
			if not dist.has(n) or nd < dist[n]:
				dist[n] = nd
				prev[n] = cur
				open.append(n)
	return {"dist": dist, "prev": prev}


## Cheapest path (inclusive of both ends). Empty array when unreachable.
func find_path(origin: Vector2i, goal: Vector2i, max_cost: float = INF, allow_cliffs: bool = true) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	if not in_bounds(origin) or not in_bounds(goal):
		return path
	var res := _search(origin, max_cost, goal, allow_cliffs)
	var prev: Dictionary = res["prev"]
	if goal != origin and not prev.has(goal):
		return path
	var cur := goal
	path.append(cur)
	while cur != origin:
		cur = prev[cur]
		path.append(cur)
	path.reverse()
	return path


## Total terrain weight of a path (the origin cell is free, every entered cell is paid, climbs included).
func path_cost(path: Array[Vector2i]) -> float:
	var total := 0.0
	for i in range(1, path.size()):
		total += step_cost(path[i - 1], path[i])
	return total


## cell -> accumulated weight for every cell reachable within `max_cost` (includes `origin` at 0).
func reachable(origin: Vector2i, max_cost: float, allow_cliffs: bool = true) -> Dictionary:
	return _search(origin, max_cost, NO_CELL, allow_cliffs)["dist"]


func nearest_walkable(c: Vector2i) -> Vector2i:
	if is_walkable(c):
		return c
	for r in range(1, size.x + size.y + 1):
		for dx in range(-r, r + 1):
			for dz in range(maxi(-r, -dx - r), mini(r, -dx + r) + 1):
				var n := c + Vector2i(dx, dz)
				if hex_distance(c, n) == r and is_walkable(n):
					return n
	return c


## Turns a cell path into a smooth walk: straight lines replace hex zig-zags wherever the
## corridor stays on open, free ground. `start`/`end` are exact world points (y is kept
## from `end`), `clearance` is the unit radius used to keep the corridor off obstacles.
func smooth_route(start: Vector3, path: Array[Vector2i], end: Vector3, mover: Unit, clearance: float) -> Array[Vector3]:
	var pts: Array[Vector3] = [start]
	var rest := end.y - surface_y(end)   # standing height above the ground
	for k in range(1, path.size() - 1):
		pts.append(cell_to_world(path[k], rest))
	pts.append(end)
	var on_path: Dictionary = {}
	for c in path:
		on_path[c] = true

	var out: Array[Vector3] = []
	var i := 0
	while i < pts.size() - 1:
		var j := pts.size() - 1
		while j > i + 1 and not _corridor_clear(pts[i], pts[j], mover, clearance, on_path):
			j -= 1
		out.append(pts[j])
		i = j
	return out


func _corridor_clear(a: Vector3, b: Vector3, mover: Unit, clearance: float, on_path: Dictionary) -> bool:
	var level_a := level_of(world_to_cell(a))
	var level_b := level_of(world_to_cell(b))
	var low := mini(level_a, level_b)
	var high := maxi(level_a, level_b)
	var seg := b - a
	seg.y = 0.0
	var length := seg.length()
	if length < 0.001:
		return true
	var dir := seg / length
	var side := Vector3(-dir.z, 0.0, dir.x) * clearance
	var steps := ceili(length / (hex_size * 0.25))
	for s in range(steps + 1):
		var p := a.lerp(b, float(s) / steps)
		for offset in [Vector3.ZERO, side, -side]:
			var c := world_to_cell(p + offset)
			if on_path.has(c):
				continue
			if not in_bounds(c) or _blocked.has(c) or weight_of(c) > 1.0:
				return false
			if level_of(c) < low or level_of(c) > high:
				return false
			var other := unit_at(c)
			if other != null and other != mover:
				return false
	return true


# --- physics hand-back ------------------------------------------------------

## After physics settles: re-derive every unit's logical cell from where its body ended up.
## Bodies keep their exact positions (no snapping to cell centres), they are only frozen.
## A body resting inside an obstacle cell (e.g. on top of it) is moved to the nearest free cell.
func resync(units: Array[Unit]) -> void:
	_occupied.clear()
	for u in units:
		if not u.is_alive():
			continue
		var c := world_to_cell(u.global_position)
		if not in_bounds(c) or _blocked.has(c):
			c = nearest_walkable(_clamp_to_board(c))
			u.snap_to(cell_to_world(c, u.rest_height()))
		else:
			u.freeze_in_place()
		u.cell = c
		_occupied[c] = u


func _clamp_to_board(c: Vector2i) -> Vector2i:
	var row := clampi(c.y, 0, size.y - 1)
	var col := clampi(c.x + floori(c.y * 0.5), 0, size.x - 1)
	return Vector2i(col - floori(row * 0.5), row)
