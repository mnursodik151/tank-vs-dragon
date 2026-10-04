class_name CommandHistory
extends RefCounted
## The command pattern's invoker side: the actions executed during the current unit's turn, each paired with a BattleSnapshot taken just
## before it ran, so they can be taken back. TurnManager calls `begin_turn` / `record`; a controller asks for one of the two take-back
## commands (UndoMoveAction, RewindAction), whose execution lands in `undo_move` / `rewind`.
##
## Two separate functions with separate rules:
##   * UNDO MOVE - takes back the most recent action when it is a move (Action.Reversibility.FREE). It is free and has no rules at all:
##     no charges, no time window, always available in every game mode.
##   * REWIND - takes back the whole turn. Rewinding a turn of moves only is the same as undoing them and just as free; as soon as
##     it takes back a COSTLY action (a shot, ram or spotter: ammunition, physics, a look at the fog) it needs a rewind charge
##     (`rules.rewind_charges` per battle, from the side's BattleRules, which upgrades can raise) and, when `rules.rewind_window_sec`
##     is set, the oldest costly action must be younger than that many real seconds. NONE actions can never be taken back.
## History never spans turns: it is emptied when a unit's turn begins and ends.

signal changed

class Entry extends RefCounted:
	var action: Action
	var snapshot: BattleSnapshot
	var time_ms := 0

var entries: Array[Entry] = []
var rewinds_used := {}                         ## team -> charges spent this battle
var clock: Callable = Time.get_ticks_msec      ## test hook: milliseconds

var _team := -1


func begin_turn(unit: Unit) -> void:
	entries.clear()
	_team = unit.team
	changed.emit()


func end_turn() -> void:
	entries.clear()
	changed.emit()


## Called by TurnManager just BEFORE `action` executes: remembers the battle as it is now.
func record(action: Action, ctx: BattleContext) -> void:
	var e := Entry.new()
	e.action = action
	e.snapshot = BattleSnapshot.take(ctx)
	e.time_ms = clock.call()
	entries.append(e)
	changed.emit()


func is_empty() -> bool:
	return entries.is_empty()


# --- undo move: free, no rules --------------------------------------------------

## Empty when the last action is a move that can be taken back, otherwise the reason.
func refusal_move() -> String:
	if entries.is_empty():
		return "Nothing to undo"
	if entries[entries.size() - 1].action.reversibility() != Action.Reversibility.FREE:
		return "Only a move can be undone"
	return ""


func can_undo_move() -> bool:
	return refusal_move() == ""


## Takes back the most recent action if it is a move. Returns false (and changes nothing) otherwise.
func undo_move(ctx: BattleContext) -> bool:
	if not can_undo_move():
		return false
	_restore_to(entries.size() - 1, ctx)
	if ctx.state != null:
		ctx.state.note_undo(false)
	return true


# --- rewind: the whole turn, limited ---------------------------------------------

func rewinds_left(ctx: BattleContext) -> int:
	return maxi(0, ctx.rules_for(_team).rewind_charges - int(rewinds_used.get(_team, 0)))


## True when taking the whole turn back would include an action that is not a plain move (so it costs a rewind charge).
func rewind_costs(_ctx: BattleContext = null) -> bool:
	return entries.any(func(e: Entry) -> bool: return e.action.reversibility() == Action.Reversibility.COSTLY)


## Seconds a rewind can still reach `entry` (INF without a window).
func window_left(ctx: BattleContext, entry: Entry) -> float:
	var window := ctx.rules_for(_team).rewind_window_sec
	if window <= 0.0:
		return INF
	return window - float(int(clock.call()) - entry.time_ms) / 1000.0


## Empty when the turn can be rewound now, otherwise the reason ("Nothing to rewind", "No rewinds left", "Too late...").
func refusal_rewind(ctx: BattleContext) -> String:
	if entries.is_empty():
		return "Nothing to rewind"
	var costly := false
	for e in entries:
		match e.action.reversibility():
			Action.Reversibility.NONE:
				return "%s cannot be taken back" % e.action.describe()
			Action.Reversibility.COSTLY:
				costly = true
				if window_left(ctx, e) <= 0.0:
					return "Too late to rewind (%.0f s window)" % ctx.rules_for(_team).rewind_window_sec
	if costly and rewinds_left(ctx) <= 0:
		return "No rewinds left"
	return ""


func can_rewind(ctx: BattleContext) -> bool:
	return refusal_rewind(ctx) == ""


## Takes back every action of the turn: the unit is where it began the turn, AP refilled, the world as it was.
## One rewind charge in all, none when every action was a move. Returns false (and changes nothing) when not allowed.
func rewind(ctx: BattleContext) -> bool:
	if not can_rewind(ctx):
		return false
	if rewind_costs():
		rewinds_used[_team] = int(rewinds_used.get(_team, 0)) + 1
	_restore_to(0, ctx)
	if ctx.state != null:
		ctx.state.note_undo(true)
	return true


## Anything the player could still take back (keeps a turn open when the AP are gone).
func can_undo_any(ctx: BattleContext) -> bool:
	return can_undo_move() or can_rewind(ctx)


## Restores the snapshot taken before entry `index` and forgets that entry and every later one.
func _restore_to(index: int, ctx: BattleContext) -> void:
	entries[index].snapshot.restore(ctx)
	entries.resize(index)
	changed.emit()


## One-line summary for the toolbar, e.g. "[Z] Undo move   [X] Rewind turn (1 left)".
func hint(ctx: BattleContext) -> String:
	if entries.is_empty():
		return ""
	var parts: PackedStringArray = []
	if can_undo_move():
		parts.append("[Z] Undo move")
	var costly := rewind_costs()
	if costly or entries.size() > 1:
		if costly and ctx.rules_for(_team).rewind_charges > 0:
			parts.append("[X] Rewind turn (%d left)" % rewinds_left(ctx))
		elif not costly:
			parts.append("[X] Rewind turn")
	return "   ".join(parts)
