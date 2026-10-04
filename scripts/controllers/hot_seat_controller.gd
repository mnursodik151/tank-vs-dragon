class_name HotSeatController
extends UnitController
## Two people share one screen: wraps the PlayerController and, whenever the turn passes to the other player, first
## shows the HandoffScreen cover (the board is hidden until the next player confirms) followed by a damage report of
## the enemy fire since that player's last hand-off (TurnReport).

var inner: UnitController
var handoff: HandoffScreen

var _last_team := -1
var _reported := {}   # team -> id of the last shot already covered by a report


func decide(unit: Unit, ctx: BattleContext) -> Action:
	if unit.team != _last_team:
		_last_team = unit.team
		var report := TurnReport.build(ctx.state, ctx, unit.team, _reported.get(unit.team, 0))
		if not ctx.state.shots.is_empty():
			_reported[unit.team] = ctx.state.shots[ctx.state.shots.size() - 1].id
		await handoff.run(unit.team, unit, ctx, report)
	return await inner.decide(unit, ctx)


func holds_turn(unit: Unit, ctx: BattleContext) -> bool:
	return inner.holds_turn(unit, ctx)
