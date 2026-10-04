class_name UndoMoveAction
extends TakeBackAction
## Takes back the most recent action when it was a move: the unit walks back (it is simply put back), the AP are refunded. Free and
## without rules - no charge, no time limit, in every game mode. Anything that is not a move needs the RewindAction.


func refusal(ctx: BattleContext) -> String:
	return ctx.history.refusal_move()


func execute(ctx: BattleContext) -> void:
	ctx.history.undo_move(ctx)
	_finish(ctx)


func describe() -> String:
	return "%s takes back the last move" % actor.stats.display_name
