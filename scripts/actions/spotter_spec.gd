class_name SpotterSpec
extends ActionSpec
## Parameters of the spotting action (DroneAction): send a drone (flies off after `duration_rounds`) or an eagle (stays until moved or
## its owner dies) to a point within `reach`; the ground around it counts as line of sight for the team.

@export var spotter_kind: String = "drone"   ## "drone" or "eagle" (a setting, not a stat)
@export var reach: float = 22.0              ## how far from the unit the spotter can be sent, metres
@export var radius: float = 7.0              ## metres of ground its spotted area covers
@export var ap_cost: float = 2.0
@export var cooldown_turns: int = 3          ## own turns before it can be used again (an eagle: 1 = once per turn)
@export var duration_rounds: int = 2         ## drone only: rounds on station (the launch round + the next)


func _init() -> void:
	kind = Kind.SPOTTER


func scope() -> StringName:
	return &"spotter"


func is_eagle() -> bool:
	return spotter_kind == "eagle"


## "Drone" / "Eagle": what the spotting tool is called.
func spotter_name() -> String:
	return spotter_kind.capitalize()
