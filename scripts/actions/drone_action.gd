class_name DroneAction
extends Action
## Special action: send a spotter to a point within the actor's SpotterSpec `reach`. A physical marker hovers there and the area around it
## (`spotter.radius`) counts as line of sight for the actor's team (see Intel). All the numbers (AP cost, reach, radius, cooldown, time on
## station) are the actor's SpotterSpec, so upgrades reach them.
## * Drone (infantry): stays on station `duration_rounds` turns (the launch turn and the next), then flies off; the launcher can send
##   another one only `cooldown_turns` of its own turns after the launch.
## * Eagle (the fantasy ranger, `spotter_kind` "eagle"): stays until the ranger dies, and the same action moves it to a new point -
##   once per own turn (its cooldown is 1). Its area is smaller than a drone's.

var target: Vector3
var spec: SpotterSpec   ## the actor's spotter parameters (null when its blueprint has no spotter: the action is then illegal)


func _init(p_actor: Unit, p_target: Vector3) -> void:
	super(p_actor)
	target = p_target
	spec = p_actor.spotter_spec()


func cost(_ctx: BattleContext) -> float:
	return spec.ap_cost if spec != null else INF


func in_range() -> bool:
	if spec == null:
		return false
	var flat := Vector2(target.x - actor.global_position.x, target.z - actor.global_position.z)
	return flat.length() <= spec.reach


func can_execute(ctx: BattleContext) -> bool:
	return spec != null and super(ctx) and spec.reach > 0.0 and actor.drone_cooldown <= 0 and in_range() \
		and ctx.board.in_bounds(ctx.board.world_to_cell(target))


func reversibility() -> Reversibility:
	return Reversibility.COSTLY   # it shows the player part of the fog: taking it back is a rewind


func execute(ctx: BattleContext) -> void:
	actor.spend_ap(cost(ctx))
	var ground := Vector3(target.x, ctx.board.surface_y(target), target.z)
	if spec.is_eagle():
		await _send_eagle(ctx, ground)
		return
	actor.drone_cooldown = spec.cooldown_turns
	var drone := Drone.new()
	drone.position = ground
	ctx.root.add_child(drone)
	drone.build(actor.team_color, spec.radius)
	actor.spotter = drone
	actor.spotter_area = ctx.intel.add_area(actor.team, target, spec.radius, spec.duration_rounds, "drone", drone, actor)
	await drone.fly_in(actor.global_position + Vector3(0.0, actor.stats.height + 0.6, 0.0))
	FloatingText.spawn(ctx.root, Vector3(target.x, Drone.HOVER_HEIGHT + 0.8, target.z), "DRONE ON STATION", Color(0.55, 0.95, 0.7))


## The eagle: flown out from the ranger the first time, afterwards moved (the area follows it).
func _send_eagle(ctx: BattleContext, ground: Vector3) -> void:
	actor.drone_cooldown = spec.cooldown_turns
	var eagle := actor.spotter as Eagle if is_instance_valid(actor.spotter) else null
	if eagle != null and ctx.intel.areas.has(actor.spotter_area):
		actor.spotter_area["center"] = Vector3(target.x, 0.0, target.z)
		await eagle.relocate(ground)
	else:
		eagle = Eagle.new()
		eagle.position = ground
		ctx.root.add_child(eagle)
		eagle.build(actor.team_color, spec.radius)
		actor.spotter = eagle
		actor.spotter_area = ctx.intel.add_area(actor.team, target, spec.radius, Intel.PERSISTENT, "eagle", eagle, actor)
		await eagle.fly_in(actor.global_position + Vector3(0.0, actor.stats.height + 0.6, 0.0))
	FloatingText.spawn(ctx.root, Vector3(target.x, eagle.hover_height() + 0.8, target.z), "EAGLE ON STATION", Color(0.55, 0.95, 0.7))


func describe() -> String:
	return "%s sends a %s to (%.1f, %.1f)" % [actor.stats.display_name, spec.spotter_kind if spec != null else "spotter", target.x, target.z]
