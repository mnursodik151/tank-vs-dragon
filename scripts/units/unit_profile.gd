class_name UnitProfile
extends RefCounted
## The orchestrator of one unit: it owns the unit's private, upgradable copy of its blueprint and answers every question about its
## parameters.
##   * `stats`     effective UnitStats (weapons -> rounds below it) - what the game code reads (`unit.stats.max_hp`)
##   * `actions`   effective ActionSpecs: what the unit can do and the numbers of those actions (`ram()`, `spotter()`)
##   * `modifiers` the upgrades in force; `add_modifiers` / `remove_source` re-derive everything from the authored blueprint
##   * queries     `stat(id)`, `base_stat(id)`, `params()`, `describe_params()`, `meta()` - every number, with its metadata
## The blueprint's own resources are never changed: a rebuild resets each clone from its `origin` and folds the modifiers in again,
## in place, so references to a weapon / round clone (toolbar entries, the gunnery panel) stay valid.

signal changed

var blueprint: UnitBlueprint
var stats: UnitStats
var actions: Array[ActionSpec] = []
var modifiers: Array[StatModifier] = []


static func create(p_blueprint: UnitBlueprint, p_modifiers: Array = []) -> UnitProfile:
	var p := UnitProfile.new()
	p.blueprint = p_blueprint
	p.stats = p_blueprint.stats.clone() as UnitStats
	for a in p_blueprint.actions:
		p.actions.append(a.clone() as ActionSpec)
	for m in p_modifiers:
		p._accept(m as StatModifier)
	p.rebuild()
	return p


func _accept(m: StatModifier) -> void:
	if not StatCatalog.has(m.stat):
		push_warning("UnitProfile: unknown stat '%s' in a modifier from '%s'" % [m.stat, m.source])
	modifiers.append(m)


# --- modifiers ------------------------------------------------------------------

func add_modifiers(list: Array) -> void:
	for m in list:
		_accept(m as StatModifier)
	rebuild()


func add_modifier(m: StatModifier) -> void:
	add_modifiers([m])


## Takes away everything one source (an upgrade id) added.
func remove_source(source: StringName) -> void:
	modifiers = modifiers.filter(func(m: StatModifier) -> bool: return m.source != source)
	rebuild()


func clear_modifiers() -> void:
	modifiers.clear()
	rebuild()


## Re-derives every effective number: reset each clone to the authored values, then fold the modifiers in.
func rebuild() -> void:
	stats.reset_to_origin()
	for a in actions:
		a.reset_to_origin()
	for res in instances():
		StatModifier.apply_all(res, modifiers)
	changed.emit()


# --- structure ------------------------------------------------------------------

## Every parameter resource of this unit: the stats, each weapon, each weapon's rounds, each action spec.
func instances() -> Array[Tunable]:
	var out: Array[Tunable] = [stats]
	for w in stats.weapons:
		out.append(w)
		for r in w.rounds:
			out.append(r)
	for a in actions:
		out.append(a)
	return out


func instances_of(scope: StringName) -> Array[Tunable]:
	var out: Array[Tunable] = []
	for res in instances():
		if res.scope() == scope:
			out.append(res)
	return out


## The effective spec of an action, or null when the unit cannot do it.
func action(kind: ActionSpec.Kind) -> ActionSpec:
	for a in actions:
		if a.kind == kind:
			return a
	return null


func can(kind: ActionSpec.Kind) -> bool:
	return action(kind) != null


func ram() -> RamSpec:
	return action(ActionSpec.Kind.RAM) as RamSpec


func spotter() -> SpotterSpec:
	return action(ActionSpec.Kind.SPOTTER) as SpotterSpec


# --- stat queries ---------------------------------------------------------------

## Effective value of stat `id`. For the scopes with several instances (weapon, round) pass the one you mean, otherwise the first
## (the main weapon, its first round). Null when the unit has no such instance.
func stat(id: StringName, instance: Tunable = null) -> Variant:
	var res := _instance_for(id, instance)
	return res.get(StatCatalog.prop_of(id)) if res != null else null


## The authored (un-upgraded) value of the same stat.
func base_stat(id: StringName, instance: Tunable = null) -> Variant:
	var res := _instance_for(id, instance)
	if res == null:
		return null
	var src := res.origin if res.origin != null else res
	return src.get(StatCatalog.prop_of(id))


## Modifiers that currently reach stat `id` of `instance`.
func modifiers_for(id: StringName, instance: Tunable = null) -> Array[StatModifier]:
	var out: Array[StatModifier] = []
	var res := _instance_for(id, instance)
	if res == null:
		return out
	for m in modifiers:
		if m.stat == id and m.applies_to(res):
			out.append(m)
	return out


func _instance_for(id: StringName, instance: Tunable) -> Tunable:
	var scope := StatCatalog.scope_of(id)
	if instance != null:
		return instance if instance.scope() == scope else null
	var all := instances_of(scope)
	return all[0] if not all.is_empty() else null


# --- metadata ------------------------------------------------------------------

## Every effective number of the unit under a unique key:
##   unit.max_hp   weapon:tank_cannon.muzzle_velocity   round:tank_cannon/ap.weight   ram.armor_wear   spotter.reach
func params() -> Dictionary:
	var out := {}
	for row in describe_params():
		out[row["key"]] = row["value"]
	return out


## One row per number with its metadata: key, stat id, label, group, scope, instance id, base and effective value, whether upgrades
## changed it (`modified`), the sources that did, and its limits.
func describe_params() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for res in instances():
		var scope := res.scope()
		if not StatCatalog.scopes().has(scope):
			continue
		var prefix := _key_prefix(res)
		var src := res.origin if res.origin != null else res
		for sid in StatCatalog.ids(scope):
			var si := StatCatalog.info(sid)
			var value: Variant = res.get(si.prop)
			var base: Variant = src.get(si.prop)
			var sources: Array[StringName] = []
			for m in modifiers_for(sid, res):
				if not sources.has(m.source):
					sources.append(m.source)
			rows.append({
				"key": "%s.%s" % [prefix, si.prop], "stat": sid, "label": si.label, "group": si.group, "scope": scope,
				"instance": res.ident(), "value": value, "base": base, "modified": value != base, "sources": sources,
				"min": si.minimum, "max": si.maximum,
			})
	return rows


func _key_prefix(res: Tunable) -> String:
	match res.scope():
		&"weapon":
			return "weapon:%s" % res.ident()
		&"round":
			for w in stats.weapons:
				if w.rounds.has(res):
					return "round:%s/%s" % [w.ident(), res.ident()]
	return String(res.scope())


## Everything a menu, tooltip or tool needs about this unit in one dictionary.
func meta() -> Dictionary:
	var acts: Array[Dictionary] = []
	for a in actions:
		acts.append({"kind": ActionSpec.Kind.keys()[a.kind], "label": a.display_label(), "glyph": a.display_glyph()})
	var weapons: Array[String] = []
	for w in stats.weapons:
		weapons.append(w.display_name)
	var mods: Array[String] = []
	for m in modifiers:
		mods.append(m.describe())
	return {
		"id": blueprint.ident(), "name": stats.display_name, "tags": blueprint.tags, "implicit_tags": blueprint.implicit_tags(),
		"meta": blueprint.meta, "actions": acts, "weapons": weapons, "modifiers": mods, "params": params(),
	}
