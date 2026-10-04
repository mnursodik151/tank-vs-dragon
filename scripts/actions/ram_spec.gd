class_name RamSpec
extends ActionSpec
## Parameters of the Ram (DashAction): a straight charge priced like a walk. Defaults are the values that used to be constants there.

@export var speed_mult: float = 2.0            ## the run animates faster than a walk
@export var max_run: float = 60.0              ## hard cap on the run length, metres
@export var damage_mult: float = 1.0           ## scales the damage the ram deals (the struck plate / prop takes armor x this)
@export var ap_cost_mult: float = 1.0          ## scales the AP price of the run
@export var armor_wear: float = 0.5            ## plate strength lost per point of ram damage taken
@export var knock_per_armor: float = 0.6       ## launch speed (m/s, for mass 1) per point of armor difference
@export var knock_mass_exponent: float = 0.3   ## launch speed falls with mass^this: heavier units are shoved less


func _init() -> void:
	kind = Kind.RAM


func scope() -> StringName:
	return &"ram"
