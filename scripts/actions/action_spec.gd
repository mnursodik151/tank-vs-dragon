class_name ActionSpec
extends Tunable
## One thing a unit can do, as data: the unit's UnitBlueprint lists them and the toolbar, the AI and the action classes ask the
## unit's UnitProfile for them. The base class is enough for the actions whose numbers live elsewhere (MOVE uses the unit's move_*
## stats, SHOOT the unit's weapons); actions with parameters of their own are subclasses (RamSpec, SpotterSpec) whose exported
## variables are stats like any other (`ram.armor_wear`, `spotter.radius`).

enum Kind { MOVE, SHOOT, SPOTTER, RAM }

@export var kind: Kind = Kind.MOVE
@export var label := ""      ## toolbar text; empty = the default for the kind
@export var glyph := ""      ## toolbar icon; empty = the default for the kind


func scope() -> StringName:
	return &"action"


func implicit_tags() -> PackedStringArray:
	return PackedStringArray([String(Kind.keys()[kind]).to_lower()])


func display_label() -> String:
	if label != "":
		return label
	match kind:
		Kind.MOVE:
			return "Move"
		Kind.SHOOT:
			return "Fire"
		Kind.SPOTTER:
			return "Spotter"
		Kind.RAM:
			return "Ram"
	return "Action"


func display_glyph() -> String:
	if glyph != "":
		return glyph
	return String(Kind.keys()[kind]).to_lower()
