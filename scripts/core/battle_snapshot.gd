class_name BattleSnapshot
extends RefCounted
## Memento of the whole battle at one instant (between two actions, when everything is at rest). Each stateful subsystem keeps its own
## capture / restore pair - units (`Unit.capture`), the board (props, terrain, fires), what the teams know (`Intel`), the battle record
## (`GameState`) - and this class only strings them together plus the scorch decals on the ground. CommandHistory takes one before each
## action so any action - even a shot whose blast cratered the ground, destroyed a tree and killed a unit - can be taken back.
## What is deliberately NOT restored: the wind and the round counter (they only change between rounds, never inside a turn),
## the observer's distance-reading noise (so re-aiming after a rewind sees the same readings), and purely transient effects
## (floating text, flashes, shell trails).

var _units: Array = []        # [[Unit, state], ...]
var _board: Dictionary
var _intel: Dictionary
var _record: Dictionary
var _decals: Array[Node] = []


static func take(ctx: BattleContext) -> BattleSnapshot:
	var snap := BattleSnapshot.new()
	for u in ctx.units:
		snap._units.append([u, u.capture()])
	snap._board = ctx.board.capture()
	snap._intel = ctx.intel.capture()
	if ctx.state != null:
		snap._record = ctx.state.capture()
	if ctx.root != null and ctx.root.is_inside_tree():
		snap._decals.assign(ctx.root.get_tree().get_nodes_in_group("scorch"))
	return snap


func restore(ctx: BattleContext) -> void:
	for pair: Array in _units:
		var u: Unit = pair[0]
		if is_instance_valid(u):
			u.restore(pair[1])
	ctx.board.restore(_board)
	ctx.board.resync(ctx.units)
	ctx.intel.restore(_intel)
	if ctx.state != null and not _record.is_empty():
		ctx.state.restore(_record)
	if ctx.root != null and ctx.root.is_inside_tree():
		for mark in ctx.root.get_tree().get_nodes_in_group("scorch"):
			if not _decals.has(mark):
				mark.queue_free()
