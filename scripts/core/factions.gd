class_name Factions
extends RefCounted
## The two factions the start menu offers. A faction is a roster of three UnitBlueprints in the same slots, so the spawn table, turn order and
## AI never care which one a side fields:
##   slot 0 = the main battle unit  (modern: Tank    / fantasy: Mage with a staff)
##   slot 1 = the artillery piece   (modern: Howitzer / fantasy: Octo Cannon pushed by a knight)
##   slot 2 = the scout / infantry  (modern: Infantry with a drone / fantasy: Ranger with a bow and an eagle)
## Both fire through the same gunnery system; only the ammunition differs (modern: HE, AP, incendiary, cluster / fantasy: Fireball,
## Meteor, Ballista, Hail). The numbers (hp, ap, armor, ranges) of a fantasy unit equal its modern counterpart so mixed battles are fair.

enum Id { MODERN, FANTASY }

const NAMES := {Id.MODERN: "MODERN", Id.FANTASY: "FANTASY"}
const BLURBS := {
	Id.MODERN: "Tank, Howitzer, Infantry (drone)",
	Id.FANTASY: "Mage, Octo Cannon, Ranger (eagle)",
}
const ROSTERS := {
	Id.MODERN: ["res://data/blueprints/tank.tres", "res://data/blueprints/howitzer.tres", "res://data/blueprints/infantry.tres"],
	Id.FANTASY: ["res://data/blueprints/mage.tres", "res://data/blueprints/octo_cannon.tres", "res://data/blueprints/ranger.tres"],
}


## The unit blueprints of `faction`, slot order (see above).
static func roster(faction: int) -> Array[UnitBlueprint]:
	var out: Array[UnitBlueprint] = []
	for path: String in ROSTERS[faction]:
		out.append(load(path) as UnitBlueprint)
	return out


static func faction_name(faction: int) -> String:
	return NAMES[faction]


## `--faction=fantasy` style argument values ("modern" / "fantasy", any case) -> Id, or -1.
static func parse(text: String) -> int:
	for id: int in NAMES:
		if String(NAMES[id]).to_lower() == text.to_lower():
			return id
	return -1
