class_name RewindAction
extends TakeBackAction
## Takes back the whole turn: the unit is where it began the turn, AP refilled, damage healed, craters and destroyed props restored. A
## turn of moves only rewinds for free; one that includes a shot, ram or spotter costs a rewind charge (BattleRules `rewind_charges`,
## `rewind_window_sec`).


func refusal(ctx: BattleContext) -> String:
	return ctx.history.refusal_rewind(ctx)


func execute(ctx: BattleContext) -> void:
	ctx.history.rewind(ctx)
	_finish(ctx)


func describe() -> String:
	return "%s rewinds the turn" % actor.stats.display_name
