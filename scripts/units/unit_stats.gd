class_name UnitStats
extends Resource
## Data-only unit definition. Duplicate a .tres in res://data/ to make a new unit type.

enum Kind { INFANTRY, TANK }

@export var display_name: String = "Unit"
@export var kind: Kind = Kind.TANK
@export var max_hp: int = 10
@export var max_ap: float = 8.0
@export var move_ap_per_weight: float = 1.0  ## AP spent per unit of terrain weight entered (1 per normal hex)
@export var move_speed: float = 4.0          ## walk animation speed, m/s
@export var initiative: int = 10             ## higher acts first each round
@export var mass: float = 1.0
@export var model: String = ""               ## UnitModel id (glTF look); empty = placeholder boxes
@export var radius: float = 0.5
@export var height: float = 1.0
@export_group("Armor")
@export var armor_front: float = 0.0         ## plate strength per hull side (compared with penetration)
@export var armor_side: float = 0.0
@export var armor_rear: float = 0.0
@export_group("Spotting")
@export var sight_range: float = 12.0        ## line-of-sight radius, metres: targets inside it are measured accurately
@export var drone_range: float = 0.0         ## > 0: can launch a spotting drone up to this far (0 = no drone)
@export var spotter_kind: String = "drone"   ## "drone" (flies off after 2 rounds) or "eagle" (stays until moved - once per turn - or its owner dies)
@export var spotter_radius: float = 7.0      ## metres of ground its spotted area covers
@export_group("Weapons")
@export var weapons: Array[WeaponStats] = [] ## main gun first, then auxiliary weapons


func main_weapon() -> WeaponStats:
	return weapons[0] if not weapons.is_empty() else null


## "Drone" / "Eagle": what the spotting tool is called.
func spotter_name() -> String:
	return spotter_kind.capitalize()


func has_armor() -> bool:
	return armor_front + armor_side + armor_rear > 0.0
