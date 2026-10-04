class_name Upgrade
extends Tunable
## A roguelike upgrade: a named bundle of StatModifiers plus who it applies to. It can be authored as a .tres or built in code
## (`Upgrade.make`). Modifiers on unit-side stats (`unit.*`, `weapon.*`, `round.*`, `ram.*`, `spotter.*`) reach the units it applies to;
## modifiers on `rules.*` stats reach the side's BattleRules (extra rewinds...). See RunState for how a run collects them.

@export var title := ""
@export_multiline var description := ""
@export var modifiers: Array[StatModifier] = []
## Which units get it: blueprint ids and / or tags (UnitBlueprint.ident / has_tag). Both empty = every unit of the side.
@export var unit_ids: PackedStringArray = PackedStringArray()
@export var unit_tags: PackedStringArray = PackedStringArray()


static func make(p_id: StringName, p_title: String, p_modifiers: Array, p_unit_ids: Array = [], p_unit_tags: Array = []) -> Upgrade:
	var u := Upgrade.new()
	u.id = p_id
	u.title = p_title
	for m in p_modifiers:
		u.modifiers.append(m as StatModifier)
	u.unit_ids = PackedStringArray(p_unit_ids)
	u.unit_tags = PackedStringArray(p_unit_tags)
	return u


func scope() -> StringName:
	return &"upgrade"


## Whether a unit built from `blueprint` receives this upgrade's unit-side modifiers.
func applies_to(blueprint: UnitBlueprint) -> bool:
	if unit_ids.is_empty() and unit_tags.is_empty():
		return true
	if unit_ids.has(String(blueprint.ident())):
		return true
	for t in unit_tags:
		if blueprint.has_tag(StringName(t)):
			return true
	return false


## Copies of the unit-side modifiers, stamped with this upgrade's id as their source (so `remove_source` can undo them).
func unit_modifiers() -> Array[StatModifier]:
	return _stamped(false)


## Copies of the `rules.*` modifiers.
func rule_modifiers() -> Array[StatModifier]:
	return _stamped(true)


func _stamped(rules: bool) -> Array[StatModifier]:
	var out: Array[StatModifier] = []
	for m in modifiers:
		if (StatCatalog.scope_of(m.stat) == &"rules") != rules:
			continue
		var c := m.duplicate() as StatModifier
		c.source = ident()   # an upgrade owns its modifiers: removing it removes exactly these
		out.append(c)
	return out
