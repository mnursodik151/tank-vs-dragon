class_name Action
extends RefCounted
## Command pattern. Controllers *decide* an Action; TurnManager validates, records it in the CommandHistory (a BattleSnapshot taken
## just before it runs) and executes it. Subclasses override cost(), can_execute(), execute() (may await) and describe(), and say
## through reversibility() how taking them back is treated. Taking back is itself a command (UndoMoveAction, RewindAction) so controllers need no extra channel.

const AP_EPSILON := 0.001

## How taking an action back is treated (see CommandHistory): FREE = a move: undo it at any time, no rules; COSTLY = (shots, rams,
## spotters) only by rewinding the turn, which needs a rewind charge; NONE = never.
enum Reversibility { FREE, COSTLY, NONE }

var actor: Unit


func _init(p_actor: Unit) -> void:
	actor = p_actor


## AP this action costs right now (may depend on the board, e.g. path weight).
func cost(_ctx: BattleContext) -> float:
	return 1.0


func can_execute(ctx: BattleContext) -> bool:
	return actor.is_alive() and actor.ap + AP_EPSILON >= cost(ctx)


func execute(_ctx: BattleContext) -> void:
	pass


func reversibility() -> Reversibility:
	return Reversibility.COSTLY


## False for meta-commands (TakeBackAction) that must not end up in the history themselves.
func records_history() -> bool:
	return true


func describe() -> String:
	return "Action"
