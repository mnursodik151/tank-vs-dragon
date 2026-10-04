class_name WeaponStats
extends Tunable
## Data-only weapon definition. One .tres per weapon in res://data/weapons/.
## A unit carries several (main gun first, auxiliary weapons after) and the toolbar lists them.

## GUNNERY: coarse bearing in the world, then the gunnery panel (round, charges, elevation,
## fine traverse, power charge). BURST: aim in the world and click; a spread burst leaves the barrel.
enum Aiming { GUNNERY, BURST }

@export var display_name: String = "Gun"
@export var glyph: String = "cannon"           ## toolbar icon: cannon, howitzer, rocket, mg, rifle, staff, octo, bow, bolts
@export var model: String = ""                 ## hand-held model a soldier shows while using it (UnitModel.WEAPONS), "" = none
@export var aiming: Aiming = Aiming.GUNNERY
@export var ap_cost: float = 3.0               ## base cost (1 charge)
@export_group("Ballistics")
@export var muzzle_velocity: float = 24.0      ## m/s at full power with the LAST charge level
@export var charge_levels: PackedFloat32Array = PackedFloat32Array([1.0])  ## velocity fraction per charge (1..n)
@export var charge_ap_extra: float = 1.0       ## extra AP per charge beyond the first
@export var min_power: float = 0.2             ## lowest power-bar fraction that still fires
@export var pitch_min_deg: float = -5.0        ## barrel elevation limits (GUNNERY)
@export var pitch_max_deg: float = 30.0
@export var default_pitch_deg: float = 8.0
@export var traverse_deg: float = 12.0         ## fine traverse (+/-) available in the gunnery panel
@export var charge_time: float = 1.4           ## seconds to charge the power bar from 0 to full
@export var shell_radius: float = 0.12         ## visual size of the projectile
@export var tracer_color: Color = Color(1.0, 0.85, 0.3)   ## BURST: colour of the bullets (gunnery rounds take their own colour)
@export var rounds: Array[RoundStats] = []     ## ammunition choices in the gunnery panel (empty = plain)
@export_group("Accuracy")
@export var aim_error_deg: float = 0.4         ## GUNNERY: gaussian angular error at launch (yaw and pitch)
@export var burst_rounds: int = 1              ## BURST: rounds per trigger pull
@export var round_interval: float = 0.07
@export var spread_deg: float = 1.2            ## BURST: gaussian spread of the first round
@export var spread_growth_deg: float = 0.35    ## BURST: extra spread per round (recoil)
@export_group("Reach (AI / hints)")
@export var min_range: float = 2.0
@export var max_range: float = 15.0
@export var high_arc: bool = false             ## AI: prefer the lob solution
@export_group("Blast")
@export var penetration: float = 6.0           ## compared against armor plate strength
@export var blast_radius: float = 1.6          ## metres, measured from the unit's surface
@export var blast_damage: float = 6.0          ## damage at the centre, linear falloff to the edge
@export var blast_impulse: float = 10.0        ## launch impulse at the centre (see Explosion.MASS_EXPONENT)
@export var blast_lift: float = 0.4            ## upward share of the knockback direction


func scope() -> StringName:
	return &"weapon"


func implicit_tags() -> PackedStringArray:
	return PackedStringArray(["burst" if aiming == Aiming.BURST else "gunnery"])


func clone() -> Tunable:
	var c := super() as WeaponStats
	var own: Array[RoundStats] = []
	for r in rounds:
		own.append(r.clone() as RoundStats)
	c.rounds = own
	return c


func reset_to_origin() -> void:
	super()
	for r in rounds:
		r.reset_to_origin()


func max_charges() -> int:
	return maxi(charge_levels.size(), 1)


## Velocity fraction for charge level `charge` (1-based).
func charge_scale(charge: int) -> float:
	if charge_levels.is_empty():
		return 1.0
	return charge_levels[clampi(charge - 1, 0, charge_levels.size() - 1)]


func total_cost(charge: int) -> float:
	return ap_cost + charge_ap_extra * float(maxi(charge - 1, 0))


func rounds_per_burst() -> int:
	return burst_rounds
