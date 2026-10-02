class_name Unit
extends RigidBody3D
## A tactical unit (tank, artillery piece, infantry...).
##
## Logical position is `cell` (derived from where the body is). The body is FROZEN (kinematic)
## while the game logic owns it; physics only takes over briefly (knockback, falling) and hands
## control back once the body settles (see TurnManager._settle / GridBoard.resync).
## Units are NOT snapped to cell centres: they stay wherever they were walked or knocked to.

signal died(unit: Unit)

const LAYER_TERRAIN := 1 << 0
const LAYER_UNITS := 1 << 1

var stats: UnitStats
var team: int = 0
var team_color := Color.WHITE                       ## the tint chosen for this unit's side (start menu)
var cell: Vector2i = Vector2i.ZERO
var hp: float = 0.0
var ap: float = 0.0
var armor := PackedFloat32Array([0.0, 0.0, 0.0])   ## current plate strength: front, side, rear
var drone_cooldown := 0                             ## own turns until the next drone launch (or, for an eagle, move) is allowed
var spotter: Drone                                  ## the drone / eagle this unit has out (null when none)
var spotter_area: Dictionary = {}                   ## its Intel area record (an eagle's moves with it)
var burning := 0                                   ## turns of burning left (halves armor, 1 dmg per turn)

const BURN_DAMAGE := 1.0
const BURN_ARMOR_MULT := 0.5
const MAX_ABSORB := 0.85       ## an armor plate never stops more than this share of a hit
const WEAR_ON_PEN := 0.12      ## plate strength lost (fraction) when a hit penetrates it
const WEAR_ON_ABSORB := 0.5    ## plate strength lost per point of damage it stopped
const FRONT_ARC_DEG := 50.0    ## hit within this angle of the hull's heading = front plate
const REAR_ARC_DEG := 130.0    ## beyond this = rear plate, in between = side

var _dead := false
var _label: Label3D
var _ring: MeshInstance3D
var _concealed := false   # hidden from the player: outside their line of sight (see set_concealed)
var _hull: Node3D     # rotates to the travel direction
var _turret: Node3D   # rotates to the aim direction
var _barrel: Node3D   # pitches up/down (child of the turret)
var _muzzle_forward := 1.0
var _weapon_model := ""   # id of the hand-held weapon model currently shown (soldiers)
var _rig: SoldierRig      # the animated body of a soldier / hero, or the crew of a gun (null for tanks / placeholders)

const TEAM_TINT := 0.35        ## how much of the team colour is mixed into a model's own colours
const TEAM_RING_ALPHA := 0.55


func _init() -> void:
	collision_layer = LAYER_UNITS
	collision_mask = LAYER_TERRAIN | LAYER_UNITS
	axis_lock_angular_x = true
	axis_lock_angular_y = true
	axis_lock_angular_z = true
	continuous_cd = true
	linear_damp = 1.0
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	var mat := PhysicsMaterial.new()
	mat.friction = 0.6
	mat.bounce = 0.1
	physics_material_override = mat


## Builds the collider + visuals: the glTF model named by `stats.model` (see UnitModel) or, without one, placeholder boxes.
## Nothing else depends on the visuals (only `face`, `aim`, `equip` and `muzzle_position` touch the nodes).
func configure(p_stats: UnitStats, p_team: int, color: Color) -> void:
	stats = p_stats
	team = p_team
	team_color = color
	hp =float(stats.max_hp)
	armor = PackedFloat32Array([stats.armor_front, stats.armor_side, stats.armor_rear])
	mass = stats.mass

	var shape := CylinderShape3D.new()
	shape.radius = stats.radius
	shape.height = stats.height
	var col := CollisionShape3D.new()
	col.shape = shape
	add_child(col)

	_build_visuals(color)

	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.pixel_size = 0.008
	UiTheme.style_label3d(_label, UiTheme.LARGE * 3 / 2)
	_label.no_depth_test = true
	_label.position = Vector3(0.0, stats.height / 2.0 + 0.45, 0.0)
	add_child(_label)
	refresh_label()


func _build_visuals(color: Color) -> void:
	var r := stats.radius
	var h := stats.height
	_hull = Node3D.new()
	_turret = Node3D.new()
	_barrel = Node3D.new()
	add_child(_hull)
	add_child(_turret)
	_turret.add_child(_barrel)
	_add_team_ring(color)
	if UnitModel.has_model(stats.model):
		_muzzle_forward = UnitModel.assemble(stats.model, _hull, _turret, _barrel, -h / 2.0, Color.WHITE.lerp(color, TEAM_TINT))
		_rig = (_turret.get_node_or_null("SoldierRig") if _turret.has_node("SoldierRig") else _turret.get_node_or_null("HeroRig")) as SoldierRig
		if has_weapon():
			equip(stats.weapons[0])
		return

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	var dark := StandardMaterial3D.new()
	dark.albedo_color = color.darkened(0.45)

	var barrel_len := 0.0
	var barrel_radius := 0.07
	if stats.kind == UnitStats.Kind.TANK:
		_hull.add_child(_mesh(_box(Vector3(r * 1.5, h * 0.45, r * 1.8)), mat, Vector3(0.0, -h / 2.0 + h * 0.225, 0.0)))
		_turret.position = Vector3(0.0, -h / 2.0 + h * 0.45 + h * 0.15, 0.0)
		_turret.add_child(_mesh(_box(Vector3(r * 1.0, h * 0.3, r * 1.1)), dark, Vector3.ZERO))
		_barrel.position = Vector3(0.0, 0.0, r * 0.45)
		barrel_len = r * 1.5
	else:
		var capsule := CapsuleMesh.new()
		capsule.radius = r
		capsule.height = h
		_hull.add_child(_mesh(capsule, mat, Vector3.ZERO))
		_turret.position = Vector3(0.0, h * 0.15, 0.0)
		_barrel.position = Vector3(0.0, 0.0, r * 0.5)
		barrel_len = r * 2.2
		barrel_radius = 0.05

	var tube := CylinderMesh.new()
	tube.top_radius = barrel_radius
	tube.bottom_radius = barrel_radius
	tube.height = barrel_len
	var tube_mi := _mesh(tube, dark, Vector3(0.0, 0.0, barrel_len / 2.0))
	tube_mi.rotation_degrees.x = 90.0  # cylinder axis Y -> +Z
	_barrel.add_child(tube_mi)
	_muzzle_forward = _barrel.position.z + barrel_len


## A flat disc in the team colour on the ground under the unit (the models keep their own paint, the ring tells the sides apart).
func _add_team_ring(color: Color) -> void:
	var disc := CylinderMesh.new()
	disc.top_radius = stats.radius * 1.3
	disc.bottom_radius = disc.top_radius
	disc.height = 0.02
	disc.radial_segments = 24
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color, TEAM_RING_ALPHA)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var ring := _mesh(disc, mat, Vector3(0.0, -stats.height / 2.0 + 0.03, 0.0))
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.name = "TeamRing"
	_ring = ring
	add_child(ring)


## Shows the hand-held model of `weapon` (soldiers; tanks and guns have their barrel built in). Cheap when already shown.
func equip(weapon: WeaponStats) -> void:
	if weapon == null or weapon.model == "" or weapon.model == _weapon_model or not UnitModel.has_model(stats.model):
		return
	_weapon_model = weapon.model
	_muzzle_forward = _barrel.position.z + UnitModel.equip(_barrel, weapon.model)


func _mesh(mesh: Mesh, mat: Material, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	return mi


func _box(box_size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = box_size
	return m


func rest_height() -> float:
	return stats.height / 2.0 + 0.02


func has_weapon() -> bool:
	return not stats.weapons.is_empty()


func is_alive() -> bool:
	return not _dead and hp > 0.0


func begin_turn() -> void:
	ap = stats.max_ap
	if drone_cooldown > 0:
		drone_cooldown -= 1
	if burning > 0:
		burning -= 1
		take_damage(BURN_DAMAGE)
		if is_inside_tree():
			FloatingText.spawn(get_parent(), global_position + Vector3(0.0, stats.height / 2.0 + 0.8, 0.0),
				"BURNING -%.0f" % BURN_DAMAGE, Color(1.0, 0.55, 0.2))
	refresh_label()


func spend_ap(amount: float) -> void:
	ap = maxf(0.0, ap - amount)
	refresh_label()


## Direct damage that ignores armor (burning).
func take_damage(amount: float) -> void:
	hp = maxf(0.0, hp - amount)
	refresh_label()
	if hp <= 0.0001:
		die()


## Sets the unit on fire for `turns` of its own turns: armor effectiveness is halved meanwhile.
func ignite(turns: int) -> void:
	if is_alive():
		burning = maxi(burning, turns)
		refresh_label()


## Which hull side a hit at `to_hit` (vector from this unit toward the impact) lands on.
func armor_sector(to_hit: Vector3) -> HitResult.Sector:
	var flat := Vector3(to_hit.x, 0.0, to_hit.z)
	if flat.length() < 0.05:
		return HitResult.Sector.SIDE   # straight above / on top
	var yaw := _hull.rotation.y if _hull != null else 0.0
	var forward := Vector3(sin(yaw), 0.0, cos(yaw))
	var angle := rad_to_deg(forward.angle_to(flat.normalized()))
	if angle <= FRONT_ARC_DEG:
		return HitResult.Sector.FRONT
	if angle >= REAR_ARC_DEG:
		return HitResult.Sector.REAR
	return HitResult.Sector.SIDE


## Plate strength that currently meets a hit on `sector` (burning halves it).
func effective_armor(sector: int) -> float:
	return armor[sector] * (BURN_ARMOR_MULT if burning > 0 else 1.0)


## Resolves a hit against armor. A hit whose `pen`etration reaches the plate strength bypasses it
## (full damage, plate wears a little). Weaker hits are partly stopped - the weaker, the more -
## up to MAX_ABSORB, and every stopped point wears the plate down until it is depleted.
func take_hit(damage: float, pen: float, to_hit: Vector3) -> HitResult:
	var res := HitResult.new()
	res.raw_damage = damage
	res.sector = armor_sector(to_hit)
	var plate := effective_armor(res.sector)
	res.armor_before = plate
	if plate <= 0.01:
		res.outcome = HitResult.Outcome.UNARMORED
		res.damage = damage
	elif pen >= plate:
		res.outcome = HitResult.Outcome.PENETRATED
		res.damage = damage
		armor[res.sector] = maxf(0.0, armor[res.sector] - armor[res.sector] * WEAR_ON_PEN)
	else:
		var stopped := clampf((plate - pen) / plate, 0.0, 1.0) * MAX_ABSORB
		res.outcome = HitResult.Outcome.ABSORBED
		res.damage = damage * (1.0 - stopped)
		armor[res.sector] = maxf(0.0, armor[res.sector] - damage * stopped * WEAR_ON_ABSORB)
	res.armor_after = armor[res.sector]
	hp = maxf(0.0, hp - res.damage)
	res.killed = hp <= 0.0001
	refresh_label()
	if res.killed:
		die()
	else:
		_flinch(res.damage)
	return res


## Ram collision: `damage` (the other party's armor value) is dealt straight to hp, armor does not
## soften it. The plate on `sector` wears down by `wear` * the damage taken.
func take_ram(damage: float, sector: HitResult.Sector, wear: float) -> HitResult:
	var res := HitResult.new()
	res.outcome = HitResult.Outcome.RAMMED
	res.sector = sector
	res.raw_damage = damage
	res.damage = damage
	res.armor_before = armor[sector]
	armor[sector] = maxf(0.0, armor[sector] - damage * wear)
	res.armor_after = armor[sector]
	hp = maxf(0.0, hp - damage)
	res.killed = hp <= 0.0001
	refresh_label()
	if res.killed:
		die()
	else:
		_flinch(res.damage)
	return res


## A soldier staggers when it takes damage (anything that actually hurt, not a fully absorbed hit).
func _flinch(damage: float) -> void:
	if _rig != null and damage > 0.01:
		_rig.set_state(SoldierRig.State.HIT)


## Starts the wind-up of a shot (the ranger draws, the mage raises the staff); `play_fire` then releases it.
func begin_aim() -> void:
	if _rig != null and is_alive():
		_rig.set_state(SoldierRig.State.AIM)


## Plays the firing animation (soldiers, heroes); called once per projectile / burst round.
func play_fire() -> void:
	if _rig != null and is_alive():
		_rig.set_state(SoldierRig.State.FIRE)


func die() -> void:
	if _dead:
		return
	_dead = true
	hp = 0.0
	freeze = true
	collision_layer = 0
	collision_mask = 0
	if _rig != null and is_inside_tree():
		# the body falls and lies there a while before the unit is hidden like the others
		_rig.set_state(SoldierRig.State.DEATH)
		_label.visible = false
		get_tree().create_timer(SoldierRig.DEATH_LINGER).timeout.connect(_hide_corpse)
	else:
		visible = false
	died.emit(self)


func _hide_corpse() -> void:
	visible = false


## Hides (or shows again) everything the player could read off this unit: the model, the team ring and the
## HP / AP / armor label. Physics, collisions and game logic are untouched. Corpses are left as they are.
func set_concealed(value: bool) -> void:
	if value == _concealed or _dead:
		return
	_concealed = value
	for node: Node3D in [_hull, _turret, _ring, _label]:
		if node != null:
			node.visible = not value


func is_concealed() -> bool:
	return _concealed


## Hull heading (yaw, radians) - the direction armor sectors are measured from.
func hull_yaw() -> float:
	return _hull.rotation.y if _hull != null else 0.0


func refresh_label() -> void:
	if _label == null:
		return
	var text := "%d/%d HP  %.1f AP" % [ceili(hp), stats.max_hp, ap]
	if stats.has_armor():
		text += "\nARM %d/%d/%d" % [roundi(armor[0]), roundi(armor[1]), roundi(armor[2])]
	if burning > 0:
		text += "  BURNING"
	_label.text = text


# --- facing / aiming --------------------------------------------------------

## Turns hull and turret toward a flat direction.
func face(dir: Vector3) -> void:
	if Vector2(dir.x, dir.z).length() < 0.001:
		return
	var yaw := atan2(dir.x, dir.z)
	_hull.rotation.y = yaw
	_turret.rotation.y = yaw


## Points the turret along `dir` (flat) and raises the barrel by `pitch` radians.
func aim(dir: Vector3, pitch: float) -> void:
	if Vector2(dir.x, dir.z).length() >= 0.001:
		_turret.rotation.y = atan2(dir.x, dir.z)
	_barrel.rotation.x = -pitch


func lower_barrel() -> void:
	_barrel.rotation.x = 0.0
	if _rig != null and _rig.state == SoldierRig.State.AIM and is_alive():
		_rig.set_state(SoldierRig.State.IDLE)   # the bow is let down / the staff lowered when no shot follows


## World position where a shell leaves the barrel when firing along the flat direction `dir`.
func muzzle_position(dir: Vector3) -> Vector3:
	var flat := Vector3(dir.x, 0.0, dir.z).normalized()
	var side := Vector3(flat.z, 0.0, -flat.x) * _barrel.position.x   # a soldier holds the weapon beside the body axis
	return global_position + Vector3(0.0, _turret.position.y, 0.0) + flat * _muzzle_forward + side


# --- movement / physics hand-over -------------------------------------------

## Kinematic walk along world-space waypoints, facing each leg. Awaitable.
func walk(waypoints: Array[Vector3], speed_mult: float = 1.0) -> void:
	if waypoints.is_empty():
		return
	freeze = true
	if _rig != null:
		_rig.set_state(SoldierRig.State.MOVE, stats.move_speed * speed_mult)
	var tween := create_tween()
	var from := global_position
	for wp in waypoints:
		var leg := wp - from
		tween.tween_callback(face.bind(leg))
		tween.tween_property(self, "global_position", wp, maxf(from.distance_to(wp), 0.01) / (stats.move_speed * speed_mult))
		from = wp
	await tween.finished
	if _rig != null:
		_rig.set_state(SoldierRig.State.IDLE)


## Hands the body to the physics engine with an initial impulse (mass-scaled).
func launch(impulse: Vector3) -> void:
	freeze = false
	sleeping = false
	linear_velocity = impulse / mass


func is_settled(speed_epsilon: float = 0.05) -> bool:
	return not is_alive() or freeze or sleeping or linear_velocity.length() < speed_epsilon


## Gives control back to the grid without moving the body.
func freeze_in_place() -> void:
	freeze = true
	linear_velocity = Vector3.ZERO


## Freeze and teleport (used when the body must be relocated, e.g. it came to rest inside terrain).
func snap_to(world_pos: Vector3) -> void:
	freeze = true
	linear_velocity = Vector3.ZERO
	global_position = world_pos
