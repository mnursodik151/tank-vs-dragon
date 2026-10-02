class_name RoundStats
extends Resource
## Data-only ammunition type for GUNNERY weapons (res://data/rounds/*.tres, res://data/fantasy/rounds/*.tres). A round does not
## replace the weapon's numbers, it modifies them. `weight` changes the flight physics:
## heavier rounds leave the barrel slower (same energy: v ~ 1/sqrt(weight)) but are pushed
## around less by wind (drift ~ 1/weight).

## NONE = a plain blast (an AP-style round is NONE with big penetration / direct-hit multipliers), INCENDIARY / CLUSTER = the modern
## specials, METEOR = after its impact blast the round bounces on as a physics body (see Meteor), AIRBURST = the shell bursts in the air
## above the target and showers submunitions (see Explosion.airburst).
enum Special { NONE, INCENDIARY, CLUSTER, METEOR, AIRBURST }

const INCENDIARY_FIRE_FACTOR := 1.3   ## ground fire radius / blast radius of the classic incendiary round

@export var display_name: String = "Normal"
@export var short_name: String = "HE"
@export_multiline var description: String = ""
@export var color: Color = Color(1.0, 0.85, 0.3)
@export var special: Special = Special.NONE
@export var projectile: String = "shell"       ## look of the round in flight: shell, fireball, meteor, bolt, hail, arrow (UnitModel.make_projectile)
@export_group("Flight")
@export var weight: float = 1.0
@export_group("Effect multipliers")
@export var damage_mult: float = 1.0
@export var radius_mult: float = 1.0
@export var penetration_mult: float = 1.0
@export var impulse_mult: float = 1.0
@export var direct_hit_mult: float = 1.0       ## extra damage to the unit the shell actually strikes
@export_group("Fire")
@export var fire_factor: float = 0.0           ## > 0: the ground within blast radius * this burns (craters are skipped); units in the blast catch fire
@export_group("Cluster")
@export var submunitions: int = 5
@export var spread: float = 2.8                ## metres, bomblets land uniformly in this radius
@export var sub_damage: float = 2.0
@export var sub_radius: float = 0.9
@export_group("Meteor")
@export var bounces: int = 3                   ## METEOR: how many times the rock hits the ground again after the impact
@export var restitution: float = 0.55          ## METEOR: how much of its speed it keeps on a bounce
@export_group("Airburst")
@export var fuse_distance: float = 4.5         ## AIRBURST: proximity fuse - the shell bursts when ground / a unit is this far ahead on its flight path
                                               ## (about 3 m above the ground on a 45 degree descent, lower on a flat one)


func velocity_mult() -> float:
	return 1.0 / sqrt(maxf(weight, 0.1))


func wind_mult() -> float:
	return 1.0 / maxf(weight, 0.1)


## Ground-fire radius as a share of the blast radius (0 = the round does not burn anything).
func fire_radius_factor() -> float:
	if fire_factor > 0.0:
		return fire_factor
	return INCENDIARY_FIRE_FACTOR if special == Special.INCENDIARY else 0.0


func burns() -> bool:
	return fire_radius_factor() > 0.0
