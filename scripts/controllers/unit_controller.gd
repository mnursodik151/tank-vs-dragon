class_name UnitController
extends Node
## Strategy interface: PlayerController and AIController both implement decide().
## decide() may await. Return an Action to perform, or null to end the unit's turn.


func decide(_unit: Unit, _ctx: BattleContext) -> Action:
	return null
