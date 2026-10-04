class_name TakeBackAction
extends Action
## Base of the two take-back commands (UndoMoveAction, RewindAction): meta-commands a controller returns like any other action and
## TurnManager runs through the same validate / execute path, but which are not recorded themselves (you cannot undo an undo) and cost
## no AP. What is allowed is CommandHistory's business.


func cost(_ctx: BattleContext) -> float:
	return 0.0


func records_history() -> bool:
	return false


func reversibility() -> Reversibility:
	return Reversibility.NONE


## Why the take-back is refused right now (empty when it is allowed).
func refusal(_ctx: BattleContext) -> String:
	return ""


func can_execute(ctx: BattleContext) -> bool:
	return actor.is_alive() and refusal(ctx) == ""


func _finish(ctx: BattleContext) -> void:
	if ctx.view != null:
		ctx.view.clear_highlight()
