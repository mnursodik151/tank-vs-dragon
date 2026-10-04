class_name UnitBlueprint
extends Tunable
## The template of a unit type, authored as a .tres in res://data/blueprints/: its base parameters (`stats`, which also holds the weapon
## loadout and through it the rounds), the actions it can perform with their own parameters (`actions`) and free metadata (`meta`).
## A blueprint is immutable data; UnitProfile is the live, upgradable instance a Unit works with.

@export var stats: UnitStats
@export var actions: Array[ActionSpec] = []
## Free-form description for menus and tools: role, blurb, faction, anything ("role": "artillery").
@export var meta: Dictionary = {}


func scope() -> StringName:
	return &"blueprint"


func implicit_tags() -> PackedStringArray:
	return stats.implicit_tags() if stats != null else PackedStringArray()


func display_name() -> String:
	return stats.display_name if stats != null else String(ident())


func has_action(kind: ActionSpec.Kind) -> bool:
	return spec(kind) != null


## The authored spec of `kind`, or null when this unit cannot do it.
func spec(kind: ActionSpec.Kind) -> ActionSpec:
	for a in actions:
		if a.kind == kind:
			return a
	return null
