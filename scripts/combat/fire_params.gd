class_name FireParams
extends RefCounted
## What a firing input (gunnery panel, burst click, AI) hands to ShootAction: the weapon, the
## ammunition and charge level, plus the barrel's yaw / pitch and the power-bar value.
## No prediction is attached - where the shell lands is decided by physics (and wind) after launch.
##
## Muzzle speed = weapon.muzzle_velocity * charge_scale(charge) * power * round.velocity_mult
## (heavier rounds leave the barrel slower).

var weapon: WeaponStats
var ammo: RoundStats           ## null = plain (BURST weapons)
var charge := 1                ## 1..weapon.max_charges()
var yaw := 0.0                 ## radians, atan2(x, z) of the flat aim direction
var pitch := 0.0               ## radians above the horizon
var power := 1.0               ## 0..1 of the power bar for this charge level


static func make(p_weapon: WeaponStats, p_yaw: float, p_pitch: float, p_power: float = 1.0,
		p_charge: int = 1, p_ammo: RoundStats = null) -> FireParams:
	var p := FireParams.new()
	p.weapon = p_weapon
	p.yaw = p_yaw
	p.pitch = p_pitch
	p.charge = clampi(p_charge, 1, p_weapon.max_charges())
	p.ammo = p_ammo
	p.power = clampf(p_power, p_weapon.min_power if p_weapon.aiming == WeaponStats.Aiming.GUNNERY else 1.0, 1.0)
	return p


func flat_dir() -> Vector3:
	return Vector3(sin(yaw), 0.0, cos(yaw))


func direction() -> Vector3:
	return Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))


func velocity_scale() -> float:
	return weapon.charge_scale(charge) * (ammo.velocity_mult() if ammo != null else 1.0)


func wind_scale() -> float:
	return ammo.wind_mult() if ammo != null else 1.0


## Muzzle speed with the power bar at `at_power` (default: this shot's power).
func speed(at_power: float = -1.0) -> float:
	return weapon.muzzle_velocity * velocity_scale() * (power if at_power < 0.0 else at_power)


func velocity() -> Vector3:
	return direction() * speed()


func total_cost() -> float:
	return weapon.total_cost(charge)
