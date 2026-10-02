class_name Action
extends RefCounted
## Command pattern. Controllers *decide* an Action; TurnManager validates and executes it.
## Subclasses override cost(), can_execute(), execute() (may await) and describe().

const AP_EPSILON := 0.001

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


func describe() -> String:
	return "Action"
