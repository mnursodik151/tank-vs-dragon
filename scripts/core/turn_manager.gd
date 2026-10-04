class_name TurnManager
extends Node
## Owns turn order and the Plan -> Execute -> Settle loop.
##
## Physics never drives game logic directly: after every action we wait for all bodies to
## come to rest, then re-derive logical cells from where they ended up (GridBoard.resync).

enum State { IDLE, PLAN, EXECUTE, SETTLE, END_TURN, FINISHED }

signal state_changed(new_state: State)
signal round_started(round_number: int)
signal turn_started(unit: Unit)
signal turn_ended(unit: Unit)
signal action_executed(action: Action)
signal battle_over(winning_team: int)

const NO_WINNER := -1
const DRAW := -2

@export var settle_timeout: float = 4.0       ## hard cap so a jittering body cannot stall the game
@export var calm_frames_required: int = 10    ## consecutive physics frames below the speed epsilon
@export var kill_plane_y: float = -3.0        ## units below this height have fallen off the board
@export var max_rounds: int = 100
@export var verbose: bool = false

var state: State = State.IDLE
var current_unit: Unit
var round_number: int = 0

var _ctx: BattleContext
var _controllers: Dictionary = {}  # team (int) -> UnitController


func start(ctx: BattleContext, controllers: Dictionary) -> void:
	_ctx = ctx
	_ctx.verbose = verbose
	_controllers = controllers
	_ctx.board.resync(_ctx.units)
	_run_battle()


func _run_battle() -> void:
	while round_number < max_rounds:
		var result := _check_winner()
		if result != NO_WINNER:
			_finish(result)
			return
		round_number += 1
		_ctx.round_number = round_number
		_ctx.intel.tick(round_number)
		round_started.emit(round_number)
		for unit in _turn_order():
			if not unit.is_alive():
				continue
			await _run_turn(unit)
			result = _check_winner()
			if result != NO_WINNER:
				_finish(result)
				return
	_finish(DRAW)


func _run_turn(unit: Unit) -> void:
	current_unit = unit
	if _ctx.board.is_burning(unit.cell):
		unit.ignite(Explosion.BURN_TURNS)   # standing in fire sets you alight
	_ctx.intel.begin_turn(unit)              # distance readings are re-rolled for the new observer
	unit.begin_turn()                        # burning units take damage here
	_ctx.history.begin_turn(unit)            # a fresh undo history: nothing of an earlier turn can be taken back
	turn_started.emit(unit)
	if not unit.is_alive():
		if verbose:
			print("    %s burned to death" % unit.stats.display_name)
		return
	var controller: UnitController = _controllers.get(unit.team)
	if controller == null:
		push_error("No controller registered for team %d" % unit.team)
		return

	# The turn runs while there is AP - or, for a controller that lets its player take actions back, while something is still
	# undoable (the player then ends the turn explicitly).
	while unit.is_alive() and (unit.ap > Action.AP_EPSILON or controller.holds_turn(unit, _ctx)):
		_set_state(State.PLAN)
		var action: Action = await controller.decide(unit, _ctx)
		if action == null:
			break
		if not action.can_execute(_ctx):
			push_warning("Illegal action rejected: %s" % action.describe())
			break

		_set_state(State.EXECUTE)
		if verbose:
			print("[R%d] %s" % [round_number, action.describe()])
		if action.records_history():
			_ctx.history.record(action, _ctx)   # snapshot of the battle just before the action, for undo / rewind
		await action.execute(_ctx)
		action_executed.emit(action)

		_set_state(State.SETTLE)
		await _settle()
		if _check_winner() != NO_WINNER:
			break

	_set_state(State.END_TURN)
	_ctx.history.end_turn()
	_ctx.view.clear_highlight()
	_ctx.guide.clear()
	turn_ended.emit(unit)
	# Guarantees at least one frame per turn, even if controllers return instantly.
	await get_tree().process_frame


## Wait until every body is at rest (or timeout), then hand positions back to the grid.
func _settle() -> void:
	var step := 1.0 / Engine.physics_ticks_per_second
	var elapsed := 0.0
	var calm_frames := 0
	while elapsed < settle_timeout:
		await get_tree().physics_frame
		elapsed += step
		var all_calm := true
		for u in _ctx.units:
			if not u.is_alive():
				continue
			if u.global_position.y < kill_plane_y:
				u.die()  # fell off the board
				if verbose:
					print("    %s fell off the board" % u.stats.display_name)
				continue
			if not u.is_settled():
				all_calm = false
		calm_frames = calm_frames + 1 if all_calm else 0
		if calm_frames >= calm_frames_required:
			break
	_ctx.board.resync(_ctx.units)


func _turn_order() -> Array[Unit]:
	var order := _ctx.alive_units()
	order.sort_custom(func(a: Unit, b: Unit) -> bool: return a.stats.initiative > b.stats.initiative)
	return order


func _check_winner() -> int:
	var teams: Dictionary = {}
	for u in _ctx.units:
		if u.is_alive():
			teams[u.team] = true
	if teams.is_empty():
		return DRAW
	if teams.size() == 1:
		return teams.keys()[0]
	return NO_WINNER


func _finish(winner: int) -> void:
	_set_state(State.FINISHED)
	if verbose:
		print("Battle over: %s" % ("draw" if winner == DRAW else "team %d wins" % winner))
	battle_over.emit(winner)


func _set_state(new_state: State) -> void:
	state = new_state
	state_changed.emit(new_state)
