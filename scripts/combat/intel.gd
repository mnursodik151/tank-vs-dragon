class_name Intel
extends RefCounted
## Fog of war + the spotting model behind the gunnery screen's distance readings. Every unit's sight has TWO rings:
##
##   * INNER ring = the unit's sight radius (UnitStats.sight_range), and any spotted area (drone / impact, no outer
##     ring): clear line of sight, fidelity LOS_FIDELITY, the distance is measured with the minimum deviation.
##   * OUTER ring = OUTER_BAND metres beyond the radius (units only): the target is still SEEN (drawn, targetable) but
##     its distance is only an estimate - fidelity falls from EDGE_FIDELITY (50%) to FLOOR_FIDELITY across the band, so
##     the deviation grows with the distance.
##   * Beyond that the target is fully concealed (fidelity 0): no model, no blip, no reading, for the screen and the AI.
##   * Trees, large rocks and higher ground block sight from a ground unit: a point behind one is hidden even inside
##     the rings (fidelity 0). Drones and spotted areas look from above.
##   * A reading is `true distance + z * sigma`, sigma = distance * lerp(SIGMA_WORST, SIGMA_BEST, fidelity).
##     `z` is a gaussian draw kept per target until the observer's next turn, so re-opening the panel
##     or nudging the aim never lets the player average the noise away; as fidelity improves the same
##     draw simply shrinks toward the true value.
##   * Sight can be expanded temporarily by "spotted areas": a shell landing outside line of sight
##     (spot_impact) or a special action such as an infantry drone (add_area).
##
## fidelity_at() is the single question a real fog of war would ask later (bigger maps).

const LOS_FIDELITY := 0.92
const EDGE_FIDELITY := 0.5
const FLOOR_FIDELITY := 0.1
const OUTER_BAND := 8.0         ## metres of the outer (estimate) ring beyond a unit's sight radius; past it targets are hidden
const SIGMA_BEST := 0.02        ## sigma as a fraction of distance at fidelity 1
const SIGMA_WORST := 0.30       ## ... and at fidelity 0
const IMPACT_RADIUS := 6.0      ## area revealed around a shell that lands outside line of sight
const IMPACT_ROUNDS := 2        ## ... for the rest of this round and the next
const PERSISTENT := 1000000      ## `rounds` of an area that stays until its owner dies (the ranger's eagle)

## Optional: when set, line-of-sight props on it hide points from ground units (see GridBoard.los_blocked).
var board: GridBoard

## {"team", "center": Vector3, "radius", "expires": last round it is active, "label", "node": marker, "owner": Unit or null}
var areas: Array[Dictionary] = []

var _round := 0
var _rng := RandomNumberGenerator.new()
var _noise: Dictionary = {}   # Unit instance id -> z


func _init() -> void:
	_rng.randomize()


# --- sight sources ------------------------------------------------------------

## Circles (flat centre, radius) a team can currently see into: its units' sight plus spotted areas.
func sources(team: int, units: Array[Unit]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for u in units:
		if u.is_alive() and u.team == team and u.stats.sight_range > 0.0:
			out.append({"center": u.global_position, "radius": u.stats.sight_range, "band": OUTER_BAND, "unit": u, "label": ""})
	for a in areas:
		if a["team"] == team and _owner_alive(a):
			out.append({"center": a["center"], "radius": a["radius"], "band": 0.0, "unit": null, "label": a["label"]})
	return out


## Fidelity (0..0.92) with which `team` sees the flat point `p`; 0 = not seen at all (beyond the outer ring or hidden).
func fidelity_at(team: int, units: Array[Unit], p: Vector3) -> float:
	var best := 0.0
	for s in sources(team, units):
		var f := fidelity_for(p, s["center"], s["radius"], s["band"])
		if board != null and s["unit"] != null and f > 0.0 and board.los_blocked(s["center"], p):
			f = 0.0   # behind a tree, rock or hill: hidden from a ground unit, in either ring
		best = maxf(best, f)
	return best


## True when `team` can see `target` at all - inner or outer ring - so the screen shows it and the AI may act on it.
## Anything else is unknown to that team: no model, no label, no blip, no reading.
func sees(team: int, units: Array[Unit], target: Unit) -> bool:
	return target.team == team or in_view(fidelity_at(team, units, target.global_position))


## Fidelity of a point at flat distance d from a source: LOS_FIDELITY inside the radius, EDGE_FIDELITY falling to
## FLOOR_FIDELITY across `band` metres beyond it, 0 past that.
static func fidelity_for(p: Vector3, center: Vector3, radius: float, band: float = OUTER_BAND) -> float:
	var d := Vector2(p.x - center.x, p.z - center.z).length()
	if d <= radius:
		return LOS_FIDELITY
	if d > radius + band:
		return 0.0
	return lerpf(EDGE_FIDELITY, FLOOR_FIDELITY, (d - radius) / maxf(band, 0.01))


## Inner ring: clear line of sight, minimum deviation.
static func in_los(fidelity: float) -> bool:
	return fidelity >= LOS_FIDELITY - 0.001


## Seen at all: inner ring or the outer (estimate) ring.
static func in_view(fidelity: float) -> bool:
	return fidelity > 0.0


static func sigma_fraction(fidelity: float) -> float:
	return lerpf(SIGMA_WORST, SIGMA_BEST, clampf(fidelity, 0.0, 1.0))


# --- readings -----------------------------------------------------------------

## `observer`'s reading of the distance to `target`:
## {"true", "est", "sigma", "fidelity", "los" (inner ring), "outer" (seen only in the outer ring)}. Positions are flat (y ignored).
func reading(observer: Unit, target: Unit, units: Array[Unit]) -> Dictionary:
	var rel := target.global_position - observer.global_position
	rel.y = 0.0
	var dist := rel.length()
	var f := fidelity_at(observer.team, units, target.global_position)
	var sigma := dist * sigma_fraction(f)
	return {"true": dist, "est": maxf(dist + _noise_for(target) * sigma, 0.0), "sigma": sigma,
		"fidelity": f, "los": in_los(f), "outer": in_view(f) and not in_los(f)}


func _noise_for(target: Unit) -> float:
	var id := target.get_instance_id()
	if not _noise.has(id):
		_noise[id] = clampf(_rng.randfn(0.0, 1.0), -2.5, 2.5)
	return _noise[id]


## A new observer starts acting: its readings are re-rolled.
func begin_turn(_observer: Unit) -> void:
	_noise.clear()


static func _owner_alive(area: Dictionary) -> bool:
	var owner: Variant = area.get("owner")
	return owner == null or (is_instance_valid(owner) and (owner as Unit).is_alive())


## A new round started: spotted areas past their time (or whose owner has died) are dropped.
func tick(round_number: int) -> void:
	_round = round_number
	var keep: Array[Dictionary] = []
	for a in areas:
		if a["expires"] >= round_number and _owner_alive(a):
			keep.append(a)
		else:
			var node: Variant = a.get("node")
			if node != null and is_instance_valid(node) and (node as Object).has_method("depart"):
				node.depart()   # a drone flies off when its time is up
	areas = keep


# --- memento (undo / rewind, see BattleSnapshot) ------------------------------

## The spotted areas as they are now: each record (kept by identity - a unit's `spotter_area` points at it) with a copy of its contents
## and where its marker stands.
func capture() -> Dictionary:
	var list: Array = []
	for a in areas:
		var node: Variant = a.get("node")
		var at := Vector3.ZERO
		if node != null and is_instance_valid(node) and (node as Node3D).is_inside_tree():
			at = (node as Node3D).global_position
		list.append({"record": a, "copy": a.duplicate(), "marker_at": at})
	return {"areas": list, "round": _round}


## Brings the areas back: records opened since vanish (their drone / eagle marker is freed), moved ones return.
func restore(state: Dictionary) -> void:
	var keep: Array[Dictionary] = []
	for entry: Dictionary in state["areas"]:
		var record: Dictionary = entry["record"]
		record.clear()
		record.merge(entry["copy"])
		keep.append(record)
		var node: Variant = record.get("node")
		if node != null and is_instance_valid(node) and (node as Node3D).is_inside_tree():
			(node as Node3D).global_position = entry["marker_at"]
	for a in areas:
		if not _holds(keep, a):
			var node: Variant = a.get("node")
			if node != null and is_instance_valid(node):
				(node as Node).queue_free()
	areas = keep
	_round = state["round"]


static func _holds(list: Array[Dictionary], record: Dictionary) -> bool:
	for r in list:
		if is_same(r, record):
			return true
	return false


# --- expanding sight ----------------------------------------------------------

## Opens a spotted area active this round and `rounds - 1` more. `node` (optional) is the physical
## marker (a Drone); it is told to depart when the area expires. `owner` (optional) is the unit it belongs to: the area ends
## with it. Returns the area record.
func add_area(team: int, center: Vector3, radius: float, rounds: int, label: String, node: Node = null, owner: Unit = null) -> Dictionary:
	var area := {"team": team, "center": Vector3(center.x, 0.0, center.z), "radius": radius,
		"expires": _round + rounds - 1, "label": label, "node": node, "owner": owner}
	areas.append(area)
	return area


## A shell of `team` landed at `point`. If that was outside the team's line of sight the surroundings
## become visible for a while. Returns true when a new area was opened.
func spot_impact(team: int, units: Array[Unit], point: Vector3) -> bool:
	if in_los(fidelity_at(team, units, point)):
		return false
	add_area(team, point, IMPACT_RADIUS, IMPACT_ROUNDS, "impact")
	return true
