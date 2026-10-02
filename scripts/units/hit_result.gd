class_name HitResult
extends RefCounted
## Outcome of one projectile/blast striking a unit, after armor.

enum Outcome { UNARMORED, PENETRATED, ABSORBED, RAMMED }
enum Sector { FRONT, SIDE, REAR }

var raw_damage := 0.0      ## damage before armor
var damage := 0.0          ## damage actually dealt
var outcome: Outcome = Outcome.UNARMORED
var sector: Sector = Sector.FRONT
var armor_before := 0.0    ## effective plate strength that met the hit
var armor_after := 0.0     ## plate strength left on that side
var killed := false


func sector_name() -> String:
	return Sector.keys()[sector].capitalize()


func reduction() -> float:
	return 1.0 - damage / raw_damage if raw_damage > 0.001 else 0.0


## Short text for the floating combat popup.
func popup_text() -> String:
	match outcome:
		Outcome.PENETRATED:
			return "PEN %s -%.1f" % [sector_name(), damage]
		Outcome.RAMMED:
			return "RAM %s -%.1f" % [sector_name(), damage]
		Outcome.ABSORBED:
			return "%s armor -%.1f (%d%% stopped)" % [sector_name(), damage, roundi(reduction() * 100.0)]
	return "-%.1f" % damage
