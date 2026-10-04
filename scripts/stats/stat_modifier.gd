class_name StatModifier
extends Resource
## One change an upgrade (or anything else) makes to a stat. Modifiers never edit the authored data: UnitProfile folds them into the
## unit's own clone of its parameter resources, in this order, per stat:
##   SET     replaces the base value (the last one wins)
##   ADD     flat amounts, summed:                        v + a1 + a2
##   PERCENT "increased by", summed then applied once:    v * (1 + p1 + p2)      (0.1 = +10 %)
##   SCALE   "more", each one multiplies on its own:      v * s1 * s2
## and the result is clamped to the stat's limits (StatCatalog). Booleans only react to SET (value >= 0.5 = true); a PackedFloat32Array
## stat (weapon.charge_levels) takes every op per element, SET fills all elements.

enum Op { ADD, PERCENT, SCALE, SET }

@export var stat: StringName = &""     ## StatCatalog id, e.g. &"weapon.muzzle_velocity"
@export var op: Op = Op.ADD
@export var value := 0.0
@export var source: StringName = &""   ## who added it (an upgrade id): remove_source() takes it away again
@export var target: StringName = &""   ## only the instance with this id (a weapon / round file stem); empty = every instance of the scope
@export var tag: StringName = &""      ## only instances carrying this tag; empty = no tag filter


static func make(p_stat: StringName, p_op: Op, p_value: float, p_source: StringName = &"",
		p_target: StringName = &"", p_tag: StringName = &"") -> StatModifier:
	var m := StatModifier.new()
	m.stat = p_stat
	m.op = p_op
	m.value = p_value
	m.source = p_source
	m.target = p_target
	m.tag = p_tag
	return m


## Whether this modifier reaches `res` (right scope, matching id and tag filters).
func applies_to(res: Tunable) -> bool:
	if StatCatalog.scope_of(stat) != res.scope():
		return false
	if target != &"" and res.ident() != target:
		return false
	return tag == &"" or res.has_tag(tag)


## Folds `mods` (all for one stat) into `base`.
static func fold(base: float, mods: Array[StatModifier]) -> float:
	var v := base
	var add := 0.0
	var pct := 0.0
	var scale := 1.0
	for m in mods:
		match m.op:
			Op.SET:
				v = m.value
			Op.ADD:
				add += m.value
			Op.PERCENT:
				pct += m.value
			Op.SCALE:
				scale *= m.value
	return (v + add) * (1.0 + pct) * scale


## Applies every modifier of `mods` that reaches `res` to its (already reset) values. The one place the rules above are enforced.
static func apply_all(res: Tunable, mods: Array[StatModifier]) -> void:
	var per_prop := {}   # property name -> Array[StatModifier]
	for m in mods:
		if m.applies_to(res):
			var prop := StatCatalog.prop_of(m.stat)
			if not per_prop.has(prop):
				per_prop[prop] = [] as Array[StatModifier]
			(per_prop[prop] as Array[StatModifier]).append(m)
	for prop: StringName in per_prop:
		var info := StatCatalog.info(StringName("%s.%s" % [res.scope(), prop]))
		if info == null:
			continue
		var list: Array[StatModifier] = per_prop[prop]
		if info.is_bool():
			var on: bool = res.get(prop)
			for m in list:
				if m.op == Op.SET:
					on = m.value >= 0.5
			res.set(prop, on)
		elif info.is_array():
			var arr: PackedFloat32Array = (res.get(prop) as PackedFloat32Array).duplicate()   # (by-reference type: edit a copy)
			for i in arr.size():
				arr[i] = info.fit(fold(arr[i], list))
			res.set(prop, arr)
		elif info.is_int():
			res.set(prop, int(info.fit(fold(float(res.get(prop)), list))))
		else:
			res.set(prop, info.fit(fold(float(res.get(prop)), list)))


func describe() -> String:
	var sign_text := "+" if value >= 0.0 else ""
	var text := ""
	match op:
		Op.ADD:
			text = "%s%s" % [sign_text, str(value)]
		Op.PERCENT:
			text = "%s%d%%" % [sign_text, roundi(value * 100.0)]
		Op.SCALE:
			text = "x%s" % str(value)
		Op.SET:
			text = "= %s" % str(value)
	var where := String(stat)
	if target != &"":
		where += " [%s]" % target
	if tag != &"":
		where += " <#%s>" % tag
	return "%s %s" % [where, text]
