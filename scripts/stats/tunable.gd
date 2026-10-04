class_name Tunable
extends Resource
## Base of every resource that carries tunable parameters (UnitStats, WeaponStats, RoundStats, the action specs, BattleRules).
## It gives them an identity (`ident`, `tags`) so a StatModifier can say "all rounds tagged incendiary" or "the weapon tank_cannon",
## and the clone / reset machinery UnitProfile uses: the authored .tres is never touched - every unit works on its own clone and a
## rebuild resets the clone from its `origin` before the modifiers are folded in again.

## Optional explicit id. Empty = the file stem of the authored resource ("tank_cannon" for data/weapons/tank_cannon.tres).
@export var id: StringName = &""
## Free-form labels a modifier can filter on ("explosive", "heavy"...). `implicit_tags()` adds the ones derived from the numbers.
@export var tags: PackedStringArray = PackedStringArray()

## The authored resource this one was cloned from (null on the authored resource itself).
var origin: Tunable

const _SKIP_PROPS := ["resource_path", "resource_name", "resource_local_to_scene", "resource_scene_unique_id", "script", "origin"]


## Stat scope of this resource kind ("unit", "weapon", "round", "ram", "spotter", "rules"); see StatCatalog.
func scope() -> StringName:
	return &""


func ident() -> StringName:
	if id != &"":
		return id
	if origin != null:
		return origin.ident()
	return StringName(resource_path.get_file().get_basename())


## Tags that follow from the resource's own numbers (a burst weapon is "burst"...). Override per kind.
func implicit_tags() -> PackedStringArray:
	return PackedStringArray()


func has_tag(tag: StringName) -> bool:
	return tags.has(String(tag)) or implicit_tags().has(String(tag))


## True when `other` is this resource or its authored original (or a clone of the same original).
func same_as(other: Tunable) -> bool:
	if other == null:
		return false
	if other == self:
		return true
	var mine := origin if origin != null else self
	var theirs := other.origin if other.origin != null else other
	return mine == theirs


## A deep copy that remembers where it came from. Subclasses clone their child resources too.
func clone() -> Tunable:
	var c: Tunable = duplicate()
	c.origin = origin if origin != null else self
	if c.id == &"":
		c.id = ident()
	return c


## Puts every stored value back to what the authored resource says (in place, so references to the clone stay valid).
## Child resources are reset by the subclasses.
func reset_to_origin() -> void:
	if origin == null:
		return
	for p: Dictionary in get_property_list():
		var name: String = p["name"]
		if not (int(p["usage"]) & PROPERTY_USAGE_STORAGE) or _SKIP_PROPS.has(name):
			continue
		var t: int = p["type"]
		if t == TYPE_BOOL or t == TYPE_INT or t == TYPE_FLOAT or t == TYPE_STRING or t == TYPE_STRING_NAME \
				or t == TYPE_COLOR or t == TYPE_PACKED_FLOAT32_ARRAY or t == TYPE_PACKED_STRING_ARRAY:
			var value: Variant = origin.get(name)
			if t == TYPE_PACKED_FLOAT32_ARRAY or t == TYPE_PACKED_STRING_ARRAY:
				value = value.duplicate()   # packed arrays are passed by reference: never share the authored buffer
			set(name, value)
