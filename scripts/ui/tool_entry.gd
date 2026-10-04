class_name ToolEntry
extends RefCounted
## One slot on the player's toolbar: Move, one of the unit's weapons, Drone (spotters) or Ram.

enum Kind { MOVE, WEAPON, RAM, DRONE }

var kind: Kind = Kind.MOVE
var weapon: WeaponStats
var spec: ActionSpec        ## the action this slot performs (SHOOT: shared by every weapon slot)
var label := ""
var glyph := ""


## The toolbar for `unit`, in the order its blueprint lists the actions it can do (Move, one slot per weapon with the main gun
## first, the spotter, Ram).
static func build_for(unit: Unit) -> Array[ToolEntry]:
	var out: Array[ToolEntry] = []
	for a in unit.profile.actions:
		match a.kind:
			ActionSpec.Kind.MOVE:
				out.append(_make(Kind.MOVE, null, a, a.display_label(), a.display_glyph()))
			ActionSpec.Kind.SHOOT:
				for w in unit.stats.weapons:
					out.append(_make(Kind.WEAPON, w, a, w.display_name, w.glyph))
			ActionSpec.Kind.SPOTTER:
				var sp := a as SpotterSpec
				out.append(_make(Kind.DRONE, null, a, sp.spotter_name(), sp.spotter_kind))
			ActionSpec.Kind.RAM:
				out.append(_make(Kind.RAM, null, a, a.display_label(), a.display_glyph()))
	return out


static func _make(p_kind: Kind, p_weapon: WeaponStats, p_spec: ActionSpec, p_label: String, p_glyph: String) -> ToolEntry:
	var e := ToolEntry.new()
	e.kind = p_kind
	e.weapon = p_weapon
	e.spec = p_spec
	e.label = p_label
	e.glyph = p_glyph
	return e


## Fixed AP cost shown on the slot (Move and Ram are priced per hex travelled, so they have none).
func cost() -> float:
	match kind:
		Kind.WEAPON:
			return weapon.ap_cost
		Kind.DRONE:
			return (spec as SpotterSpec).ap_cost
	return 0.0
