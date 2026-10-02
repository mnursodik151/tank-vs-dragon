class_name ToolEntry
extends RefCounted
## One slot on the player's toolbar: Move, one of the unit's weapons, Drone (spotters) or Ram.

enum Kind { MOVE, WEAPON, RAM, DRONE }

var kind: Kind = Kind.MOVE
var weapon: WeaponStats
var label := ""
var glyph := ""


## The toolbar for `unit`: Move, every weapon (main gun first), Ram.
static func build_for(unit: Unit) -> Array[ToolEntry]:
	var out: Array[ToolEntry] = []
	out.append(_make(Kind.MOVE, null, "Move", "move"))
	for w in unit.stats.weapons:
		out.append(_make(Kind.WEAPON, w, w.display_name, w.glyph))
	if unit.stats.drone_range > 0.0:
		out.append(_make(Kind.DRONE, null, unit.stats.spotter_name(), unit.stats.spotter_kind))
	out.append(_make(Kind.RAM, null, "Ram", "ram"))
	return out


static func _make(p_kind: Kind, p_weapon: WeaponStats, p_label: String, p_glyph: String) -> ToolEntry:
	var e := ToolEntry.new()
	e.kind = p_kind
	e.weapon = p_weapon
	e.label = p_label
	e.glyph = p_glyph
	return e


## Fixed AP cost shown on the slot (Move and Ram are priced per hex travelled, so they have none).
func cost() -> float:
	match kind:
		Kind.WEAPON:
			return weapon.ap_cost
		Kind.DRONE:
			return DroneAction.AP_COST
	return 0.0
