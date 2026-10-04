class_name RunState
extends RefCounted
## The roguelike layer, kept in static variables so it survives scene changes (like BattleConfig): the upgrades the player has
## collected during the current run. While a run is `active`, single-player battles hand the player's side these upgrades:
##   `Game` builds each player unit's UnitProfile with `unit_modifiers(blueprint)` and the side's BattleRules with `rules()`.
## Nothing here is used unless a run is started, so a plain skirmish plays exactly like the authored data.

static var active := false
static var upgrades: Array[Upgrade] = []


static func reset() -> void:
	active = false
	upgrades.clear()


static func start() -> void:
	reset()
	active = true


static func add(upgrade: Upgrade) -> void:
	upgrades.append(upgrade)


## Every unit-side modifier the run's upgrades give a unit of `blueprint` (empty when no run is active).
static func unit_modifiers(blueprint: UnitBlueprint) -> Array[StatModifier]:
	var out: Array[StatModifier] = []
	if not active:
		return out
	for u in upgrades:
		if u.applies_to(blueprint):
			out.append_array(u.unit_modifiers())
	return out


## The player's side rules: authored defaults with the run's `rules.*` modifiers folded in.
static func rules() -> BattleRules:
	var live := BattleRules.new()
	var mods: Array[StatModifier] = []
	if active:
		for u in upgrades:
			mods.append_array(u.rule_modifiers())
	StatModifier.apply_all(live, mods)
	return live
