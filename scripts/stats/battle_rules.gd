class_name BattleRules
extends Tunable
## Parameters of the battle that belong to a side, not to a unit: how much REWINDING is allowed. (Undoing a move has no rules at all.)
## The numbers are stats too (`rules.rewind_charges`...), so a roguelike upgrade can grant extra rewinds like any other bonus
## (see RunState / Upgrade).

@export_group("Rewind")
@export var rewind_charges: int = 1              ## per battle: each rewind of a turn that holds a shot / ram / spotter action uses one
@export var rewind_window_sec: float = 0.0       ## > 0: a rewind only reaches actions younger than this many real seconds (0 = no limit)


func scope() -> StringName:
	return &"rules"
