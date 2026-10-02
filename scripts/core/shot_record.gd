class_name ShotRecord
extends RefCounted
## Everything worth remembering about one shot, kept by GameState for the future end screen /
## replay: who fired what, how it was set up, the wind, the flight path and what it did.

var id := 0
var round_number := 0
var shooter_name := ""
var shooter_team := 0
var shooter_id := 0           ## Unit.get_instance_id() of the shooter (find "this unit's last shot")
var shooter_pos := Vector3.ZERO   ## where the shooter stood when firing
var weapon_name := ""
var round_name := "-"
var round_short := "-"
var round_color := Color.WHITE
var round_special := 0        ## RoundStats.Special of the round fired
var charges := 1
var ap_cost := 0.0
var yaw := 0.0
var pitch := 0.0
var power := 0.0
var speed := 0.0
var wind_speed := 0.0
var wind_angle := 0.0
var burst := false
var rounds := 1

var origin := Vector3.ZERO
var impact := Vector3.ZERO
var distance := 0.0           ## flat distance from muzzle to impact
var flight_time := 0.0
var landed := false           ## false when the projectile was lost off the map
var trail := PackedVector3Array()   ## decimated flight path (gunnery shots)

var results: Array[Dictionary] = []  ## one entry per unit struck
var blasts := 0               ## explosions caused (cluster = main + bomblets)
var craters := 0              ## cells turned into craters
var fires := 0                ## cells set on fire


func to_dict() -> Dictionary:
	return {
		"id": id, "round": round_number, "shooter": shooter_name, "team": shooter_team,
		"weapon": weapon_name, "round_type": round_name, "charges": charges, "ap": ap_cost,
		"yaw_deg": rad_to_deg(yaw), "pitch_deg": rad_to_deg(pitch), "power": power, "speed": speed,
		"wind_speed": wind_speed, "wind_angle_deg": rad_to_deg(wind_angle),
		"burst": burst, "rounds": rounds,
		"origin": origin, "impact": impact, "distance": distance, "flight_time": flight_time,
		"landed": landed, "trail_points": trail.size(),
		"results": results.duplicate(true), "blasts": blasts, "craters": craters, "fires": fires,
	}
