class_name BattleContext
extends RefCounted
## Shared handle passed to actions and controllers so they never reach into the scene tree.

var board: GridBoard:
	set(value):
		board = value
		intel.board = value   # trees and large rocks hide things from ground units' sight
var view: BoardView
var guide: GuideView
var wind := Wind.new()
var intel := Intel.new()  ## spotting: how well each team can measure distances (see Intel)
var camera: TacticsCamera
var state: GameState
var round_number := 0
var root: Node3D          ## parent for transient world nodes (shells, explosion flashes)
var units: Array[Unit] = []
var verbose := false
## Whose eyes the screen looks through: enemy units outside this team's line of sight are hidden (model, label, radar
## blip, camera pans). -1 = see everything (AI vs AI).
var viewer_team := 0
var history := CommandHistory.new()   ## the current turn's executed actions, for undo / rewind (see CommandHistory)
var _rules: Dictionary = {}           # team -> BattleRules
## Set when the battle is over: the screen shows every unit (the AI's own sight rules are unaffected).
var reveal_all := false


## The undo rules of `team` (authored defaults until `set_rules` gives it others).
func rules_for(team: int) -> BattleRules:
	if not _rules.has(team):
		_rules[team] = BattleRules.new()
	return _rules[team]


func set_rules(team: int, rules: BattleRules) -> void:
	_rules[team] = rules


func alive_units() -> Array[Unit]:
	var out: Array[Unit] = []
	for u in units:
		if u.is_alive():
			out.append(u)
	return out


func enemies_of(unit: Unit) -> Array[Unit]:
	var out: Array[Unit] = []
	for u in units:
		if u.is_alive() and u.team != unit.team:
			out.append(u)
	return out


## Living enemies of `unit` that its team can currently see (everything else about them is unknown to it).
func visible_enemies_of(unit: Unit) -> Array[Unit]:
	var out: Array[Unit] = []
	for u in enemies_of(unit):
		if intel.sees(unit.team, units, u):
			out.append(u)
	return out


## Whether the player's screen may show `u`: own team always, enemies only inside the viewer team's line of sight.
func visible_to_viewer(u: Unit) -> bool:
	return reveal_all or viewer_team < 0 or intel.sees(viewer_team, units, u)

