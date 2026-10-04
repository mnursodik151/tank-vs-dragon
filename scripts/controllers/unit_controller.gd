class_name UnitController
extends Node
## Strategy interface: PlayerController and AIController both implement decide().
## decide() may await. Return an Action to perform, or null to end the unit's turn.


func decide(_unit: Unit, _ctx: BattleContext) -> Action:
	return null


## True while the turn must stay open although the unit is out of AP - a controller whose player can still take something back
## returns true so the turn does not end under their hands. Scripted controllers keep the default.
func holds_turn(_unit: Unit, _ctx: BattleContext) -> bool:
	return false
