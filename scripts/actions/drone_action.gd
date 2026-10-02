class_name DroneAction
extends Action
## Special action: send a spotter to a point within the actor's `drone_range`. A physical marker hovers there and the area around it
## (`UnitStats.spotter_radius`) counts as line of sight for the actor's team (see Intel).
## * Drone (infantry): stays on station DRONE_ROUNDS turns (the launch turn and the next), then flies off; the launcher can send
##   another one only COOLDOWN_TURNS of its own turns after the launch.
## * Eagle (the fantasy ranger, `spotter_kind` "eagle"): stays until the ranger dies, and the same action moves it to a new point -
##   once per own turn (EAGLE_COOLDOWN). Its area is smaller than a drone's.

const AP_COST := 2.0
const COOLDOWN_TURNS := 3   ## launched on turn N, available again on turn N + 3
const EAGLE_COOLDOWN := 1   ## moved on turn N, available again on turn N + 1: once per turn

var target: Vector3


func _init(p_actor: Unit, p_target: Vector3) -> void:
	super(p_actor)
	target = p_target


func cost(_ctx: BattleContext) -> float:
	return AP_COST


func in_range() -> bool:
	var flat := Vector2(target.x - actor.global_position.x, target.z - actor.global_position.z)
	return flat.length() <= actor.stats.drone_range


func can_execute(ctx: BattleContext) -> bool:
	return super(ctx) and actor.stats.drone_range > 0.0 and actor.drone_cooldown <= 0 and in_range() \
		and ctx.board.in_bounds(ctx.board.world_to_cell(target))


func execute(ctx: BattleContext) -> void:
	actor.spend_ap(cost(ctx))
	var ground := Vector3(target.x, ctx.board.surface_y(target), target.z)
	if actor.stats.spotter_kind == "eagle":
		await _send_eagle(ctx, ground)
		return
	actor.drone_cooldown = COOLDOWN_TURNS
	var drone := Drone.new()
	drone.position = ground
	ctx.root.add_child(drone)
	drone.build(actor.team_color, actor.stats.spotter_radius)
	actor.spotter = drone
	actor.spotter_area = ctx.intel.add_area(actor.team, target, actor.stats.spotter_radius, Intel.DRONE_ROUNDS, "drone", drone, actor)
	await drone.fly_in(actor.global_position + Vector3(0.0, actor.stats.height + 0.6, 0.0))
	FloatingText.spawn(ctx.root, Vector3(target.x, Drone.HOVER_HEIGHT + 0.8, target.z), "DRONE ON STATION", Color(0.55, 0.95, 0.7))


## The eagle: flown out from the ranger the first time, afterwards moved (the area follows it).
func _send_eagle(ctx: BattleContext, ground: Vector3) -> void:
	actor.drone_cooldown = EAGLE_COOLDOWN
	var eagle := actor.spotter as Eagle if is_instance_valid(actor.spotter) else null
	if eagle != null and ctx.intel.areas.has(actor.spotter_area):
		actor.spotter_area["center"] = Vector3(target.x, 0.0, target.z)
		await eagle.relocate(ground)
	else:
		eagle = Eagle.new()
		eagle.position = ground
		ctx.root.add_child(eagle)
		eagle.build(actor.team_color, actor.stats.spotter_radius)
		actor.spotter = eagle
		actor.spotter_area = ctx.intel.add_area(actor.team, target, actor.stats.spotter_radius, Intel.PERSISTENT, "eagle", eagle, actor)
		await eagle.fly_in(actor.global_position + Vector3(0.0, actor.stats.height + 0.6, 0.0))
	FloatingText.spawn(ctx.root, Vector3(target.x, eagle.hover_height() + 0.8, target.z), "EAGLE ON STATION", Color(0.55, 0.95, 0.7))


func describe() -> String:
	return "%s sends a %s to (%.1f, %.1f)" % [actor.stats.display_name, actor.stats.spotter_kind, target.x, target.z]
