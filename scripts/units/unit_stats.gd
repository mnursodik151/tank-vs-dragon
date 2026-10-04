class_name UnitStats
extends Tunable
## Data-only parameters of a unit: its body, resources, defence, physics and sight, plus its weapon loadout. Authored as a .tres in
## res://data/ and wrapped by a UnitBlueprint (which also says what the unit can DO); at run time every unit owns a clone of it
## (UnitProfile), so upgrades change the clone and never the .tres. Every number here is a stat (see StatCatalog) a StatModifier can reach.
## The defaults of the Defence / Physics / Action points groups are the values that used to be hard-coded in Unit.

enum Kind { INFANTRY, TANK }

@export var display_name: String = "Unit"
@export var kind: Kind = Kind.TANK
@export var max_hp: int = 10
@export var max_ap: float = 8.0              ## AP granted at the start of every turn
@export var move_ap_per_weight: float = 1.0  ## AP spent per unit of terrain weight entered (1 per normal hex)
@export var move_speed: float = 4.0          ## walk animation speed, m/s
@export var initiative: int = 10             ## higher acts first each round
@export var mass: float = 1.0
@export var model: String = ""               ## UnitModel id (glTF look); empty = placeholder boxes
@export var radius: float = 0.5
@export var height: float = 1.0
@export_group("Action points")
@export_range(0.0, 1.0, 0.01) var ap_carry: float = 0.0   ## share of the AP left unspent that carries into the next turn
@export var ap_carry_cap: float = 4.0                      ## ... but never more than this many AP
@export_group("Armor")
@export var armor_front: float = 0.0         ## plate strength per hull side (compared with penetration)
@export var armor_side: float = 0.0
@export var armor_rear: float = 0.0
@export_range(0.0, 1.0, 0.01) var max_absorb: float = 0.85   ## an armor plate never stops more than this share of a hit
@export_range(0.0, 1.0, 0.01) var wear_on_pen: float = 0.12  ## plate strength lost (fraction) when a hit penetrates it
@export var wear_on_absorb: float = 0.5      ## plate strength lost per point of damage it stopped
@export_range(0.0, 180.0, 1.0) var front_arc_deg: float = 50.0    ## a hit within this angle of the hull's heading meets the front plate
@export_range(0.0, 180.0, 1.0) var rear_arc_deg: float = 130.0    ## beyond this it meets the rear plate, in between the side
@export_group("Damage")
@export var damage_taken_mult: float = 1.0   ## scales every point of damage that gets through (0.8 = 20 % tougher)
@export var burn_damage: float = 1.0         ## hit points lost per turn while burning (ignores armor)
@export_range(0.0, 1.0, 0.01) var burn_armor_mult: float = 0.5    ## plate strength left while burning
@export var burn_duration_mult: float = 1.0  ## scales how many turns a fire hit keeps this unit burning
@export_group("Physics")
@export var friction: float = 0.6            ## body friction: how far a knocked unit slides
@export_range(0.0, 1.0, 0.01) var bounce: float = 0.1
@export var linear_damp: float = 1.0
@export var knockback_taken: float = 1.0     ## scales the launch speed of every blast / ram that shoves this unit
@export_group("Spotting")
@export var sight_range: float = 12.0        ## line-of-sight radius, metres: targets inside it are measured accurately
@export_group("Weapons")
@export var weapons: Array[WeaponStats] = [] ## main gun first, then auxiliary weapons


func scope() -> StringName:
	return &"unit"


func implicit_tags() -> PackedStringArray:
	return PackedStringArray([String(Kind.keys()[kind]).to_lower()])


func main_weapon() -> WeaponStats:
	return weapons[0] if not weapons.is_empty() else null


## True when `weapon` is one of this unit's weapons (or the authored resource one of them was cloned from).
func owns_weapon(weapon: WeaponStats) -> bool:
	for w in weapons:
		if w.same_as(weapon):
			return true
	return false


func has_armor() -> bool:
	return armor_front + armor_side + armor_rear > 0.0


func clone() -> Tunable:
	var c := super() as UnitStats
	var own: Array[WeaponStats] = []
	for w in weapons:
		own.append(w.clone() as WeaponStats)
	c.weapons = own
	return c


func reset_to_origin() -> void:
	super()
	for w in weapons:
		w.reset_to_origin()
