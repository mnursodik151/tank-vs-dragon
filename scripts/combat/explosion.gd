class_name Explosion
extends RefCounted
## Shell detonation. Per unit in the blast: damage with linear falloff, resolved against armor
## (HitResult), plus a radial physics impulse that unfreezes the body (TurnManager then waits for
## it to settle). Solid things between a blast and a unit - a tree, a rock, a hill - soak part of the damage and
## the push (cover); props in the blast are damaged too and are destroyed at 0 hp. Blasts also change the ground: big ones leave scorch marks and craters (costlier
## terrain), burning ones (incendiary, fireball: `RoundStats.fire_radius_factor`) set the cells around the impact on fire. Cluster rounds
## follow up with bomblets (see cluster()); the fantasy rounds add `airburst` (hail: a shell bursting overhead, ice stones falling) and
## `meteor` (a rock that bounces on over the ground on the physics engine, every landing a small burning blast).

## Launch speed = blast_impulse * falloff / mass^MASS_EXPONENT. 1.0 would be plain momentum
## (a tank barely moves next to infantry); lower values make heavy units easier to shove.
const MASS_EXPONENT := 0.5
const FLASH_MIN_RADIUS := 0.8    ## smaller blasts (bullets) show nothing
const SCORCH_MIN_RADIUS := 1.0   ## smaller blasts leave no mark and no crater
const SCORCH_LIMIT := 24         ## oldest marks are removed beyond this
const CRATER_FACTOR := 0.75      ## cells whose centre is within radius * factor become craters
const FIRE_FACTOR := 1.3         ## incendiary: cells within radius * factor ignite
const BURN_TURNS := 2            ## turns a unit keeps burning after an incendiary hit
const BOMBLET_DELAY := 0.09
const PROP_RADIUS := 0.5         ## a prop counts as a disc this wide when measuring blast distance
const TERRAIN_COVER := 0.5       ## share soaked when the ground itself (a hill) lies between blast and unit
const COVER_SLACK := 0.2         ## a blocker this close to the blast point is the surface it burst on, not cover
const HAIL_DELAY := 0.07         ## seconds between the ice stones of an airburst
const METEOR_SLIDE := 0.4        ## share of its sideways speed the rock keeps off the impact
const METEOR_MAX_SPEED := 9.0    ## the rock leaves its impact at most this fast (m/s)
const METEOR_MIN_LIFT := 4.5     ## ... and at least this much upward, so even a glancing hit visibly bounces


## Detonates `weapon` loaded with `round` at `point`. `direct` is the unit the projectile struck
## (gets the round's direct-hit bonus), `shot` receives the results for the game-state log.
## Returns one log line per affected unit.
static func detonate(ctx: BattleContext, point: Vector3, weapon: WeaponStats, ammo: RoundStats = null,
		direct: Unit = null, shot: ShotRecord = null, direct_prop: Vector2i = GridBoard.NO_CELL) -> PackedStringArray:
	var rs := ammo if ammo != null else RoundStats.new()
	if shot != null:
		shot.blasts += 1
	return _blast(ctx, point, weapon.blast_radius * rs.radius_mult, weapon.blast_damage * rs.damage_mult,
		weapon.penetration * rs.penetration_mult, weapon.blast_impulse * rs.impulse_mult, weapon.blast_lift,
		direct, rs.direct_hit_mult, rs.fire_radius_factor(), shot, direct_prop)


## Cluster follow-up: bomblets rain down around the impact, one after another. Awaitable.
static func cluster(ctx: BattleContext, point: Vector3, weapon: WeaponStats, ammo: RoundStats,
		shot: ShotRecord = null) -> PackedStringArray:
	var lines := PackedStringArray()
	for i in ammo.submunitions:
		await ctx.root.get_tree().create_timer(BOMBLET_DELAY).timeout
		var a := randf() * TAU
		var r := ammo.spread * sqrt(randf())
		var p := Vector3(point.x + cos(a) * r, 0.05, point.z + sin(a) * r)
		if not ctx.board.in_bounds(ctx.board.world_to_cell(p)):
			continue   # fell off the map
		if shot != null:
			shot.blasts += 1
		lines.append_array(_blast(ctx, p, ammo.sub_radius, ammo.sub_damage, weapon.penetration * ammo.sub_penetration_mult,
			ammo.sub_impulse, 0.2, null, 1.0, 0.0, shot, GridBoard.NO_CELL, true))
	return lines


## Hail: the shell bursts in the air at `point` and `ammo.submunitions` ice stones fall into a circle of `ammo.spread` metres around
## `landing` (where the shell would have come down: the burst is only a little before it). Stones fall one after another, each a small
## blast on the ground (no craters, no fire). Awaitable; returns one log line per affected unit.
static func airburst(ctx: BattleContext, point: Vector3, landing: Vector3, weapon: WeaponStats, ammo: RoundStats,
		shot: ShotRecord = null) -> PackedStringArray:
	var lines := PackedStringArray()
	if shot != null:
		shot.blasts += 1
	_spawn_flash(ctx.root, point, 1.4, Color(ammo.color, 0.9))
	var pending := [ammo.submunitions]   # a one-element array: the stones' coroutines share the count
	for i in ammo.submunitions:
		await ctx.root.get_tree().create_timer(HAIL_DELAY).timeout
		var a := randf() * TAU
		var r := ammo.spread * sqrt(randf())
		var p := Vector3(landing.x + cos(a) * r, 0.0, landing.z + sin(a) * r)
		if not ctx.board.in_bounds(ctx.board.world_to_cell(p)):
			pending[0] -= 1   # fell off the map
			continue
		p.y = ctx.board.surface_y(p) + 0.05
		_hail_stone(ctx, point, p, weapon, ammo, shot, lines, pending)
	while pending[0] > 0:
		await ctx.root.get_tree().physics_frame
	return lines


static func _hail_stone(ctx: BattleContext, from: Vector3, to: Vector3, weapon: WeaponStats, ammo: RoundStats,
		shot: ShotRecord, lines: PackedStringArray, pending: Array) -> void:
	var stone := UnitModel.make_projectile("hail", 0.5)
	var fall := clampf((from.y - to.y) / 11.0, 0.2, 0.55)
	if stone != null:
		ctx.root.add_child(stone)
		stone.global_position = from
		var tween := stone.create_tween()
		tween.tween_property(stone, "global_position", to, fall).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		await tween.finished
		stone.queue_free()
	else:
		await ctx.root.get_tree().create_timer(fall).timeout
	if shot != null:
		shot.blasts += 1
	lines.append_array(_blast(ctx, to, ammo.sub_radius, ammo.sub_damage, weapon.penetration * ammo.sub_penetration_mult, ammo.sub_impulse, 0.2,
		null, 1.0, 0.0, shot, GridBoard.NO_CELL, true))
	pending[0] -= 1


## Meteor: after its impact blast (`detonate`) the rock bounces on from `point` as a physics body (see Meteor), reflected off the surface
## it struck (`normal`) at `ammo.restitution` of its speed. Every time it lands again - on the ground, a prop or a unit - a small burning
## blast goes off there and the cell it is in is set on fire, so a meteor leaves a line of burning tiles. Awaitable; returns the log lines.
static func meteor(ctx: BattleContext, point: Vector3, normal: Vector3, velocity: Vector3, weapon: WeaponStats, ammo: RoundStats,
		shot: ShotRecord = null) -> PackedStringArray:
	var lines := PackedStringArray()
	var n := normal.normalized() if normal.length() > 0.1 else Vector3.UP
	var vn := velocity.dot(n)
	var out := (velocity - n * vn) * METEOR_SLIDE + n * absf(vn) * ammo.restitution
	if out.y < METEOR_MIN_LIFT:
		out.y = METEOR_MIN_LIFT
	if out.length() > METEOR_MAX_SPEED:
		out = out.normalized() * METEOR_MAX_SPEED
	var rock := Meteor.new()
	ctx.root.add_child(rock)
	rock.start(point + n * (Meteor.RADIUS + 0.05), out, ammo)
	if ctx.camera != null:
		ctx.camera.follow(rock)
	rock.bounced.connect(func(at: Vector3, collider: Object) -> void:
		var ground := Vector3(at.x, ctx.board.surface_y(at) + 0.05, at.z)
		if shot != null:
			shot.blasts += 1
		lines.append_array(_blast(ctx, ground, ammo.sub_radius, ammo.sub_damage, weapon.penetration * ammo.sub_penetration_mult, ammo.sub_impulse, 0.3,
			collider as Unit, 1.0, maxf(ammo.fire_radius_factor(), 0.5), shot, GridBoard.NO_CELL, true))
		var cell := ctx.board.world_to_cell(ground)
		if ctx.board.in_bounds(cell):
			ctx.board.ignite(cell, GridBoard.FIRE_DURATION))
	await rock.finished
	if ctx.camera != null:
		ctx.camera.release(0.8)
	return lines


static func _blast(ctx: BattleContext, point: Vector3, radius: float, damage: float, pen: float,
		impulse: float, lift: float, direct: Unit, direct_mult: float, fire_factor: float,
		shot: ShotRecord, direct_prop: Vector2i = GridBoard.NO_CELL, bomblet: bool = false) -> PackedStringArray:
	var incendiary := fire_factor > 0.0   # burning blast: sets units and the ground on fire (fire_factor x radius), no craters
	var lines := PackedStringArray()
	for u in ctx.alive_units():
		var offset := u.global_position - point
		var surface := maxf(offset.length() - u.stats.radius, 0.0)
		var is_direct := u == direct
		if surface > radius and not is_direct:
			continue
		var falloff := 1.0 if is_direct else 1.0 - minf(surface / maxf(radius, 0.01), 1.0)
		var cover := 0.0 if is_direct else _cover(ctx, point, u)
		var dealt := damage * falloff * (direct_mult if is_direct else 1.0) * (1.0 - cover)
		var res := u.take_hit(dealt, pen, point - u.global_position)
		if ctx.state != null:
			ctx.state.note_hit(shot, u, res, {"point": point, "radius": radius, "direct": is_direct, "cover": cover,
				"bomblet": bomblet, "fire_radius": radius * fire_factor if incendiary else 0.0})
		lines.append("%s %s%s" % [u.stats.display_name, res.popup_text(), " (destroyed)" if res.killed else ""])
		if res.damage > 0.05 or res.outcome != HitResult.Outcome.UNARMORED:
			var tint := Color(1.0, 0.6, 0.25) if res.outcome == HitResult.Outcome.PENETRATED else \
				(Color(0.65, 0.8, 1.0) if res.outcome == HitResult.Outcome.ABSORBED else Color.WHITE)
			var popup := res.popup_text() + (" (cover %d%%)" % roundi(cover * 100.0) if cover > 0.0 else "")
			FloatingText.spawn(ctx.root, u.global_position + Vector3(0.0, u.stats.height / 2.0 + 0.9, 0.0), popup, tint)
		if incendiary and u.is_alive():
			u.ignite(BURN_TURNS)
			FloatingText.spawn(ctx.root, u.global_position + Vector3(0.0, u.stats.height / 2.0 + 0.5, 0.0), "ARMOR SOFTENED", Color(1.0, 0.5, 0.2))
		if not u.is_alive() or impulse <= 0.0:
			continue
		var away := Vector3(offset.x, 0.0, offset.z)
		if away.length() < 0.05:
			away = Vector3.RIGHT.rotated(Vector3.UP, randf() * TAU)
		var dir := (away.normalized() + Vector3.UP * lift).normalized()
		# Unit.launch divides by mass, so pre-multiply to land on mass^MASS_EXPONENT overall.
		u.launch(dir * impulse * falloff * (1.0 - cover) * pow(u.stats.mass, 1.0 - MASS_EXPONENT))

	lines.append_array(_damage_props(ctx, point, radius, damage, direct_mult, direct_prop))
	if radius >= FLASH_MIN_RADIUS:
		_spawn_flash(ctx.root, point, radius, Color(1.0, 0.55, 0.15, 0.85) if not incendiary else Color(1.0, 0.35, 0.08, 0.9))
	if radius >= SCORCH_MIN_RADIUS:
		_spawn_scorch(ctx.root, point, radius)
		var craters := 0
		var fires := 0
		if point.y - ctx.board.surface_y(point) < 1.6:   # ground-level impact (not the top of an obstacle)
			if incendiary:
				fires = ctx.board.ignite_area(point, radius * fire_factor)
			else:
				craters = ctx.board.crater_area(point, radius * CRATER_FACTOR)
		if (craters > 0 or fires > 0) and ctx.state != null:
			ctx.state.note_terrain(shot, craters, fires)
	return lines


## Share (0..1) of a blast at `point` that something solid between it and unit `u` soaks. The first blocker on the
## line from the unit toward the blast counts: a prop gives its own cover value, bare ground (a hill) TERRAIN_COVER.
static func _cover(ctx: BattleContext, point: Vector3, u: Unit) -> float:
	if ctx.root == null or not ctx.root.is_inside_tree():
		return 0.0
	var from := u.global_position
	var to := point + Vector3(0.0, 0.1, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, to, Unit.LAYER_TERRAIN)
	var hit := ctx.root.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or from.distance_to(hit["position"]) > from.distance_to(to) - COVER_SLACK:
		return 0.0
	var cell := Props.cell_of(hit["collider"])
	if cell == GridBoard.NO_CELL:
		return TERRAIN_COVER
	var kind := ctx.board.prop_at(cell)
	return Props.cover(kind as Props.Kind) if kind >= 0 else 0.0


## Props inside the blast take damage with the same falloff as units (the prop a shell struck takes it in full).
static func _damage_props(ctx: BattleContext, point: Vector3, radius: float, damage: float, direct_mult: float,
		direct_prop: Vector2i) -> PackedStringArray:
	var lines := PackedStringArray()
	for c: Vector2i in ctx.board.prop_cells():
		var centre := ctx.board.cell_to_world(c)
		var surface := maxf(Vector2(point.x - centre.x, point.z - centre.z).length() - PROP_RADIUS, 0.0)
		var is_direct := c == direct_prop
		if surface > radius and not is_direct:
			continue
		var falloff := 1.0 if is_direct else 1.0 - minf(surface / maxf(radius, 0.01), 1.0)
		var dealt := damage * falloff * (direct_mult if is_direct else 1.0)
		if dealt < 0.05:
			continue
		var name := Props.kind_name(ctx.board.prop_at(c) as Props.Kind)
		var left := ctx.board.damage_prop(c, dealt)
		var text := "%s -%.0f" % [name, dealt] if left > 0.0 else "%s destroyed" % name
		lines.append(text)
		FloatingText.spawn(ctx.root, centre + Vector3(0.0, 1.2, 0.0), text, Color(0.8, 0.75, 0.55))
	return lines


static func _spawn_flash(root: Node3D, point: Vector3, radius: float, color: Color) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.scale = Vector3.ONE * radius * 0.3
	root.add_child(mi)
	mi.global_position = point
	var tween := mi.create_tween()
	tween.set_parallel(true)
	tween.tween_property(mi, "scale", Vector3.ONE * radius, 0.35)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.35)
	tween.chain().tween_callback(mi.queue_free)


static func _spawn_scorch(root: Node3D, point: Vector3, radius: float) -> void:
	var marks := root.get_tree().get_nodes_in_group("scorch")
	while marks.size() >= SCORCH_LIMIT:
		marks.pop_front().queue_free()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 1.0
	mesh.bottom_radius = 1.0
	mesh.height = 0.01
	mesh.radial_segments = 24
	mesh.rings = 1
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.05, 0.04, 0.04, 0.55)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.add_to_group("scorch")
	mi.scale = Vector3(radius * 0.7, 1.0, radius * 0.7)
	root.add_child(mi)
	mi.global_position = Vector3(point.x, 0.026, point.z)
