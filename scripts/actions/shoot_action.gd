class_name ShootAction
extends Action
## Fire one of the actor's weapons with FireParams (round, charge, yaw / pitch / power) chosen by a
## firing input or the AI. Nothing is predicted: the weapon's own inaccuracy is rolled at launch,
## wind pushes the projectile in flight (heavier rounds less), and Explosion hands bodies to the
## physics engine. GUNNERY weapons launch one shell (with the shot camera and a parabolic trail);
## BURST weapons spray `burst_rounds` bullets with growing spread. Every shot is logged in GameState.

const AIM_SETTLE_TIME := 0.3
const BURST_SETTLE_TIME := 0.15
const CAMERA_HOLD := 1.1   ## seconds the shot camera lingers on the impact

var weapon: WeaponStats
var params: FireParams
var rng := RandomNumberGenerator.new()

var _pending := 0   # projectiles / bomblets still to resolve
var _record: ShotRecord


func _init(p_actor: Unit, p_params: FireParams) -> void:
	super(p_actor)
	params = p_params
	weapon = p_params.weapon
	rng.randomize()


func cost(_ctx: BattleContext) -> float:
	return params.total_cost()


func can_execute(ctx: BattleContext) -> bool:
	return super(ctx) and actor.stats.weapons.has(weapon)


func execute(ctx: BattleContext) -> void:
	var total := cost(ctx)
	actor.spend_ap(total)
	if ctx.state != null:
		_record = ctx.state.begin_shot(ctx, actor, params, total)
	actor.equip(weapon)
	actor.aim(params.flat_dir(), params.pitch)
	actor.begin_aim()
	var burst := weapon.aiming == WeaponStats.Aiming.BURST
	await actor.get_tree().create_timer(BURST_SETTLE_TIME if burst else AIM_SETTLE_TIME).timeout

	if burst:
		for i in weapon.burst_rounds:
			var spread := deg_to_rad(weapon.spread_deg + weapon.spread_growth_deg * i)
			_launch(ctx, params.yaw + rng.randfn(0.0, spread * 0.5), params.pitch + rng.randfn(0.0, spread * 0.5), false)
			if i < weapon.burst_rounds - 1:
				await actor.get_tree().create_timer(weapon.round_interval).timeout
	else:
		var err := deg_to_rad(weapon.aim_error_deg)
		var shell := _launch(ctx, params.yaw + rng.randfn(0.0, err), params.pitch + rng.randfn(0.0, err), true)
		if ctx.camera != null and ctx.visible_to_viewer(actor):   # no free look at a gun hidden in the fog
			ctx.camera.follow(shell)

	while _pending > 0:
		await actor.get_tree().physics_frame
	if burst and ctx.state != null and _record != null:
		ctx.state.finish_shot(_record, _record.impact, true, 0.0)
	actor.lower_barrel()
	# Let the physics server step once so launched bodies are live before settle polling.
	await actor.get_tree().physics_frame


func _launch(ctx: BattleContext, yaw: float, pitch: float, dramatic: bool) -> Shell:
	var shot := FireParams.make(weapon, yaw, pitch, params.power, params.charge, params.ammo)
	var color := params.ammo.color if params.ammo != null else weapon.tracer_color
	actor.play_fire()
	var shell := Shell.new()
	ctx.root.add_child(shell)
	var exclude: Array[RID] = [actor.get_rid()]
	_pending += 1
	if params.ammo != null and params.ammo.special == RoundStats.Special.AIRBURST:
		shell.fuse_distance = params.ammo.fuse_distance
	shell.impacted.connect(_on_impact.bind(ctx, shell, dramatic))
	shell.launch(actor.muzzle_position(shot.flat_dir()), shot.velocity(), exclude,
		ctx.wind.accel() * params.wind_scale(), weapon.shell_radius, color, dramatic,
		params.ammo.projectile if params.ammo != null else "shell")
	return shell


func _on_impact(point: Vector3, hit: bool, collider: Object, ctx: BattleContext, shell: Shell, dramatic: bool) -> void:
	if dramatic:
		if ctx.camera != null:
			ctx.camera.release(CAMERA_HOLD)
		# A shell landing outside our line of sight lights up the area around it for a while.
		if hit and ctx.intel.spot_impact(actor.team, ctx.units, point):
			FloatingText.spawn(ctx.root, point + Vector3(0.0, 1.2, 0.0), "SPOTTED", Color(0.55, 0.95, 0.7))
		if ctx.state != null and _record != null:
			ctx.state.finish_shot(_record, point, hit, shell.flight_time, shell.path)
	elif _record != null:
		_record.impact = point
	if hit:
		var special := params.ammo.special if params.ammo != null else RoundStats.Special.NONE
		if special == RoundStats.Special.AIRBURST:
			await _hail(ctx, point, shell, collider)
		else:
			var lines := Explosion.detonate(ctx, point, weapon, params.ammo, collider as Unit, _record, Props.cell_of(collider))
			if ctx.verbose:
				for line in lines:
					print("    ", line)
			var extra := PackedStringArray()
			if special == RoundStats.Special.CLUSTER:
				extra = await Explosion.cluster(ctx, point, weapon, params.ammo, _record)
			elif special == RoundStats.Special.METEOR:
				extra = await Explosion.meteor(ctx, point, shell.impact_normal, shell.impact_velocity, weapon, params.ammo, _record)
			if ctx.verbose:
				for line in extra:
					print("    ", line)
	elif ctx.verbose:
		print("    round lost")
	_pending -= 1


## Hail: the shell bursts above the target (`shell.airburst`) or, if something stopped it first, where it struck; the ice stones come down
## around where it would have landed. A unit it struck directly still takes a small direct blast.
func _hail(ctx: BattleContext, point: Vector3, shell: Shell, collider: Object) -> void:
	var landing := point
	if shell.airburst:
		landing = shell.burst_landing
	elif collider is Unit:
		for line in Explosion.detonate(ctx, point, weapon, params.ammo, collider as Unit, _record):
			if ctx.verbose:
				print("    ", line)
	var lines := await Explosion.airburst(ctx, point, landing, weapon, params.ammo, _record)
	if ctx.verbose:
		for line in lines:
			print("    ", line)


func describe() -> String:
	var rname := params.ammo.display_name if params.ammo != null else "-"
	return "%s fires %s [%s, charge %d] (yaw %.1f, pitch %.1f, power %d%%)" % [
		actor.stats.display_name, weapon.display_name, rname, params.charge,
		rad_to_deg(params.yaw), rad_to_deg(params.pitch), roundi(params.power * 100.0)]
