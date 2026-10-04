class_name StatCatalog
extends RefCounted
## The ledger of every tunable number in the game. It is NOT a hand-kept list: it is read off the exported variables of the parameter
## resources (UnitStats, WeaponStats, RoundStats, RamSpec, SpotterSpec, BattleRules), so a new `@export var x: float` is a stat the moment
## it exists and cannot be forgotten. Stat ids are "<scope>.<variable>" - `unit.max_hp`, `weapon.muzzle_velocity`, `round.weight`,
## `ram.armor_wear`, `spotter.radius`, `rules.rewind_charges`.
##
## Metadata per stat (`StatInfo`): label, group (the resource's `@export_group`), type, and limits - read from `@export_range`, otherwise
## "never below 0" (angles excepted). Strings, colours, enums and resource references are settings, not stats, and are left out.
##   StatCatalog.info(&"weapon.muzzle_velocity").label   -> "Muzzle Velocity"
##   StatCatalog.ids(&"round")                           -> every round stat

## One stat's metadata.
class StatInfo extends RefCounted:
	var id: StringName
	var scope: StringName
	var prop: StringName
	var label := ""
	var group := ""
	var type := TYPE_FLOAT         ## TYPE_FLOAT, TYPE_INT, TYPE_BOOL or TYPE_PACKED_FLOAT32_ARRAY
	var minimum := 0.0
	var maximum := INF
	var step := 0.0

	func is_int() -> bool:
		return type == TYPE_INT

	func is_bool() -> bool:
		return type == TYPE_BOOL

	func is_array() -> bool:
		return type == TYPE_PACKED_FLOAT32_ARRAY

	## Clamps (and for integers rounds) a value to the stat's limits.
	func fit(v: float) -> float:
		if type == TYPE_BOOL:
			return 1.0 if v >= 0.5 else 0.0
		v = clampf(v, minimum, maximum)
		return roundf(v) if type == TYPE_INT else v


static var _infos: Dictionary = {}     # StringName id -> StatInfo
static var _by_scope: Dictionary = {}  # StringName scope -> Array[StringName]


## Scope name -> the resource script that defines its stats.
static func scopes() -> Dictionary:
	return {&"unit": UnitStats, &"weapon": WeaponStats, &"round": RoundStats, &"ram": RamSpec, &"spotter": SpotterSpec, &"rules": BattleRules}


static func info(id: StringName) -> StatInfo:
	_build()
	return _infos.get(id)


static func has(id: StringName) -> bool:
	_build()
	return _infos.has(id)


## Every stat id, optionally of one scope only.
static func ids(scope: StringName = &"") -> Array[StringName]:
	_build()
	var out: Array[StringName] = []
	if scope == &"":
		for k: StringName in _infos:
			out.append(k)
	else:
		out.assign(_by_scope.get(scope, []))
	return out


## "weapon" of &"weapon.muzzle_velocity".
static func scope_of(id: StringName) -> StringName:
	return StringName(String(id).get_slice(".", 0))


## "muzzle_velocity" of &"weapon.muzzle_velocity".
static func prop_of(id: StringName) -> StringName:
	return StringName(String(id).get_slice(".", 1))


static func _build() -> void:
	if not _infos.is_empty():
		return
	var all := scopes()
	for scope: StringName in all:
		var script: Script = all[scope]
		var ids_here: Array = []
		var group := ""
		for p: Dictionary in script.get_script_property_list():
			var usage: int = p["usage"]
			if usage & PROPERTY_USAGE_GROUP:
				group = p["name"]
				continue
			if not (usage & PROPERTY_USAGE_EDITOR) or not (usage & PROPERTY_USAGE_STORAGE):
				continue
			var t: int = p["type"]
			if t != TYPE_FLOAT and t != TYPE_INT and t != TYPE_BOOL and t != TYPE_PACKED_FLOAT32_ARRAY:
				continue
			if int(p["hint"]) == PROPERTY_HINT_ENUM:
				continue   # an enum is a choice, not a quantity
			var si := StatInfo.new()
			si.scope = scope
			si.prop = p["name"]
			si.id = StringName("%s.%s" % [scope, si.prop])
			si.label = String(si.prop).capitalize()
			si.group = group
			si.type = t
			if not String(si.prop).ends_with("_deg"):
				si.minimum = 0.0
			else:
				si.minimum = -INF
			if int(p["hint"]) == PROPERTY_HINT_RANGE:
				var parts := String(p["hint_string"]).split(",")
				if parts.size() >= 2:
					si.minimum = float(parts[0])
					si.maximum = float(parts[1])
				if parts.size() >= 3 and parts[2].is_valid_float():
					si.step = float(parts[2])
			_infos[si.id] = si
			ids_here.append(si.id)
		_by_scope[scope] = ids_here
