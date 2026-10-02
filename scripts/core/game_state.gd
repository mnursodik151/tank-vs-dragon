class_name GameState
extends Node
## Game-state manager: the running record of the battle. ShootAction / Explosion feed it every
## shot (setup, wind, flight path, impact, per-unit results incl. armor outcomes); it keeps
## totals and the full shot log so an end screen or replay can be built on top later.
## Nothing here drives gameplay.

signal shot_recorded(record: ShotRecord)

const TRAIL_STRIDE := 3   ## keep every n-th flight sample

var shots: Array[ShotRecord] = []
var winner := TurnManager.NO_WINNER
var rounds_played := 0
var finished := false
var totals := {}

var _next_id := 1


func _init() -> void:
	reset()


func reset() -> void:
	shots.clear()
	winner = TurnManager.NO_WINNER
	rounds_played = 0
	finished = false
	_next_id = 1
	totals = {
		"shots": 0,
		"landed": 0,
		"damage_dealt": {0: 0.0, 1: 0.0},
		"friendly_damage": 0.0,
		"kills": {0: 0, 1: 0},
		"penetrations": 0,
		"armor_absorbed": 0,
		"craters": 0,
		"fires": 0,
		"ap_on_charges": 0.0,
		"longest_shot": 0.0,
		"rounds_by_type": {},
		"weapons": {},
	}


## Opens a record for a shot about to be fired.
func begin_shot(ctx: BattleContext, actor: Unit, params: FireParams, ap_cost: float) -> ShotRecord:
	var rec := ShotRecord.new()
	rec.id = _next_id
	_next_id += 1
	rec.round_number = ctx.round_number
	rec.shooter_name = actor.stats.display_name
	rec.shooter_team = actor.team
	rec.shooter_id = actor.get_instance_id()
	rec.shooter_pos = actor.global_position
	rec.weapon_name = params.weapon.display_name
	rec.round_name = params.ammo.display_name if params.ammo != null else "-"
	if params.ammo != null:
		rec.round_short = params.ammo.short_name
		rec.round_color = params.ammo.color
		rec.round_special = params.ammo.special
	rec.charges = params.charge
	rec.ap_cost = ap_cost
	rec.yaw = params.yaw
	rec.pitch = params.pitch
	rec.power = params.power
	rec.speed = params.speed()
	rec.wind_speed = ctx.wind.speed
	rec.wind_angle = ctx.wind.angle
	rec.burst = params.weapon.aiming == WeaponStats.Aiming.BURST
	rec.rounds = params.weapon.rounds_per_burst() if rec.burst else 1
	rec.origin = actor.muzzle_position(params.flat_dir())
	shots.append(rec)

	totals["shots"] += 1
	totals["ap_on_charges"] += (params.charge - 1) * params.weapon.charge_ap_extra
	totals["rounds_by_type"][rec.round_name] = totals["rounds_by_type"].get(rec.round_name, 0) + 1
	totals["weapons"][rec.weapon_name] = totals["weapons"].get(rec.weapon_name, 0) + 1
	return rec


## Closes a record when its (first) projectile has landed. `flight_path` is the raw sample list.
func finish_shot(rec: ShotRecord, impact: Vector3, landed: bool, flight_time: float, flight_path: PackedVector3Array = PackedVector3Array()) -> void:
	rec.impact = impact
	rec.landed = landed
	rec.flight_time = flight_time
	rec.distance = Vector2(impact.x - rec.origin.x, impact.z - rec.origin.z).length()
	for i in range(0, flight_path.size(), TRAIL_STRIDE):
		rec.trail.append(flight_path[i])
	if flight_path.size() > 0:
		rec.trail.append(flight_path[flight_path.size() - 1])
	if landed:
		totals["landed"] += 1
		totals["longest_shot"] = maxf(totals["longest_shot"], rec.distance)
	shot_recorded.emit(rec)


## Called by Explosion for every unit a blast struck. `blast` (optional) says where and how big the blast was:
## {"point": Vector3, "radius", "fire_radius" (incendiary ground fire, 0 = none), "direct": the shell struck this unit,
## "bomblet": cluster follow-up}. The unit's footprint at that moment is stored with it so the hit can be redrawn later
## (see GunneryPanel's last-shot sidebar).
func note_hit(rec: ShotRecord, victim: Unit, res: HitResult, blast: Dictionary = {}) -> void:
	if rec == null:
		return
	var entry := {
		"unit": victim.stats.display_name, "team": victim.team, "sector": res.sector_name(),
		"outcome": HitResult.Outcome.keys()[res.outcome], "damage": res.damage, "raw": res.raw_damage,
		"armor_before": res.armor_before, "armor_after": res.armor_after, "killed": res.killed,
		"unit_id": victim.get_instance_id(), "unit_pos": victim.global_position,
		"unit_radius": victim.stats.radius, "hull_yaw": victim.hull_yaw(),
	}
	entry.merge(blast, true)
	rec.results.append(entry)
	if victim.team == rec.shooter_team:
		totals["friendly_damage"] += res.damage
	else:
		totals["damage_dealt"][rec.shooter_team] += res.damage
		if res.killed:
			totals["kills"][rec.shooter_team] += 1
	if res.outcome == HitResult.Outcome.PENETRATED:
		totals["penetrations"] += 1
	elif res.outcome == HitResult.Outcome.ABSORBED:
		totals["armor_absorbed"] += 1


## The most recent gunnery (non-burst) shot `unit` has fired, or null. Finished or not, newest first.
func last_gunnery_shot_of(unit: Unit) -> ShotRecord:
	var id := unit.get_instance_id()
	for i in range(shots.size() - 1, -1, -1):
		if shots[i].shooter_id == id and not shots[i].burst:
			return shots[i]
	return null


func note_terrain(rec: ShotRecord, craters: int, fires: int) -> void:
	if rec != null:
		rec.craters += craters
		rec.fires += fires
	totals["craters"] += craters
	totals["fires"] += fires


func battle_finished(p_winner: int, p_rounds: int) -> void:
	winner = p_winner
	rounds_played = p_rounds
	finished = true


## Plain dictionary for an end screen.
func summary() -> Dictionary:
	return {
		"winner": winner, "rounds": rounds_played, "finished": finished,
		"totals": totals.duplicate(true), "shot_count": shots.size(),
	}


func summary_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var w := "draw" if winner == TurnManager.DRAW else "team %d" % winner
	out.append("Battle summary - winner: %s after %d rounds" % [w, rounds_played])
	out.append("  shots %d (landed %d), longest %.1f m, charge AP spent %.1f" % [
		totals["shots"], totals["landed"], totals["longest_shot"], totals["ap_on_charges"]])
	out.append("  damage dealt: team0 %.1f, team1 %.1f, friendly %.1f | kills: team0 %d, team1 %d" % [
		totals["damage_dealt"][0], totals["damage_dealt"][1], totals["friendly_damage"],
		totals["kills"][0], totals["kills"][1]])
	out.append("  armor: %d penetrations, %d hits absorbed | terrain: %d craters, %d fire cells" % [
		totals["penetrations"], totals["armor_absorbed"], totals["craters"], totals["fires"]])
	out.append("  rounds fired: %s" % str(totals["rounds_by_type"]))
	return out
