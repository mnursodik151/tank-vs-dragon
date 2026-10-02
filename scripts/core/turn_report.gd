class_name TurnReport
extends RefCounted
## What a hot-seat player is told when the turn comes back to them: the enemy shots fired since their last report that
## hit their units or landed inside their line of sight - the damage done and the general direction the fire came from
## (the same marker + trajectory the shot review shows for enemy shots; no weapon or round data).

const COMPASS := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
const MAX_ENTRIES := 8


## Entries (oldest first) for `team`, covering shots with `id` > `after_id`:
## {"id", "from": compass text of where the fire came from, "impact": Vector3, "trail": PackedVector3Array, "origin": Vector3,
##  "origin_seen": bool, "hits": [{"unit", "damage", "sector", "outcome", "killed", "pos"}]}
static func build(state: GameState, ctx: BattleContext, team: int, after_id: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for rec in state.shots:
		if rec.id <= after_id or rec.shooter_team == team or not rec.landed:
			continue
		var hits := _hits_on(rec, team)
		var seen_impact := Intel.in_view(ctx.intel.fidelity_at(team, ctx.units, rec.impact))
		if hits.is_empty() and not seen_impact:
			continue
		var trail := rec.trail
		if trail.size() < 2:
			trail = PackedVector3Array([rec.origin, rec.impact])
		out.append({
			"id": rec.id, "from": direction_text(rec.origin, rec.impact), "impact": rec.impact, "trail": trail,
			"origin": rec.origin, "origin_seen": Intel.in_view(ctx.intel.fidelity_at(team, ctx.units, rec.shooter_pos)),
			"hits": hits,
		})
	if out.size() > MAX_ENTRIES:
		out = out.slice(out.size() - MAX_ENTRIES)
	return out


## Where the fire came from, as a compass point (north = -Z, east = +X), e.g. "NE".
static func direction_text(origin: Vector3, impact: Vector3) -> String:
	var back := Vector2(origin.x - impact.x, origin.z - impact.z)
	if back.length() < 0.01:
		return "?"
	var a := atan2(back.x, -back.y)   # 0 = north, clockwise
	return COMPASS[posmod(roundi(a / (PI / 4.0)), 8)]


## The record's results on `team`'s units, one line per unit (a cluster shot hits it several times).
static func _hits_on(rec: ShotRecord, team: int) -> Array[Dictionary]:
	var by_unit := {}
	var out: Array[Dictionary] = []
	for r in rec.results:
		if r["team"] != team:
			continue
		var id: int = r["unit_id"]
		if by_unit.has(id):
			var e: Dictionary = by_unit[id]
			e["damage"] += r["damage"]
			e["killed"] = e["killed"] or r["killed"]
			continue
		var e := {"unit": r["unit"], "damage": r["damage"], "sector": r["sector"], "outcome": String(r["outcome"]).to_lower(),
			"killed": r["killed"], "pos": r["unit_pos"]}
		by_unit[id] = e
		out.append(e)
	return out
