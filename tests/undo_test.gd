extends SceneTree
## Headless test of the command pattern with undo: CommandHistory + BattleSnapshot restore moves, shots (a blast that cratered the ground,
## killed a unit and hurt a prop), spotters and whole turns; the two separate functions - UNDO MOVE (free, no rules) and REWIND (charges,
## time window, none in hot seat); and the TurnManager loop (take-backs as commands, a turn that stays open while something can be taken back).
##   godot --headless --path . --script res://tests/undo_test.gd
## Exit code 1 when any check fails.

var fails := 0
var fake_ms := [0]


## A controller that follows a script: `plan` is called for every decision and returns an Action or null (end the turn).
class Scripted extends UnitController:
	var plan: Callable
	var hold: Callable
	var decisions := 0

	func decide(unit: Unit, ctx: BattleContext) -> Action:
		decisions += 1
		return plan.call(unit, ctx, decisions)

	func holds_turn(unit: Unit, ctx: BattleContext) -> bool:
		return hold.call(unit, ctx) if hold.is_valid() else false


func check(cond: bool, msg: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + msg)
	if not cond:
		fails += 1


func _initialize() -> void:
	_run()


func params_at(unit: Unit, weapon: WeaponStats, target: Vector3, charge: int, ammo: RoundStats) -> FireParams:
	var dir := Vector3(target.x - unit.global_position.x, 0.0, target.z - unit.global_position.z).normalized()
	var org := unit.muzzle_position(dir)
	var vmax := weapon.muzzle_velocity * weapon.charge_scale(charge) * (ammo.velocity_mult() if ammo != null else 1.0)
	var v := Ballistics.solve_velocity(org, target, vmax, weapon.high_arc)
	if v == Vector3.ZERO:
		return null
	return FireParams.make(weapon, atan2(v.x, v.z), atan2(v.y, Vector2(v.x, v.z).length()), v.length() / vmax, charge, ammo)


func place(ctx: BattleContext, unit: Unit, offset_cell: Vector2i) -> void:
	unit.snap_to(ctx.board.cell_to_world(GridBoard.offset_to_axial(offset_cell), unit.rest_height()))
	ctx.board.resync(ctx.units)


func same_spot(a: Unit, b: Vector3) -> bool:
	return a.global_position.distance_to(b) < 0.01


func _run() -> void:
	# ---------- a live battle to work in ----------
	BattleConfig.reset()
	RunState.reset()
	Game.forced_seed = 7
	Game.flat_ground = true
	for row in range(1, 4):
		for col in 16:
			Game.extra_keep_clear.append(Vector2i(col, row))
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 6:
		await physics_frame
	var ctx: BattleContext = main._ctx
	var turns: TurnManager = main._turns
	var hist: CommandHistory = ctx.history
	ctx.wind.set_fixed(0.0, 0.0)
	var tank: Unit = ctx.units[0]
	var inf: Unit = ctx.units[2]
	var foe_tank: Unit = ctx.units[3]
	var foe_how: Unit = ctx.units[4]
	var foe: Unit = ctx.units[5]
	place(ctx, foe_tank, Vector2i(20, 12))
	place(ctx, foe_how, Vector2i(22, 12))
	place(ctx, ctx.units[1], Vector2i(2, 12))
	place(ctx, inf, Vector2i(2, 9))
	place(ctx, tank, Vector2i(3, 2))
	place(ctx, foe, Vector2i(10, 2))
	await turns._settle()

	check(ctx.rules_for(0).rewind_charges == 1 and ctx.rules_for(0).rewind_window_sec == 0.0 and ctx.rules_for(1).rewind_charges == 0, "rules: the player's side has one rewind and no time window, the AI side none")
	check(Action.new(tank).reversibility() == Action.Reversibility.COSTLY and MoveAction.new(tank, Vector3.ZERO).reversibility() == Action.Reversibility.FREE
		and DashAction.new(tank, Vector3.RIGHT).reversibility() == Action.Reversibility.COSTLY and DroneAction.new(inf, Vector3.ZERO).reversibility() == Action.Reversibility.COSTLY
		and UndoMoveAction.new(tank).reversibility() == Action.Reversibility.NONE and not UndoMoveAction.new(tank).records_history() and not RewindAction.new(tank).records_history()
		and MoveAction.new(tank, Vector3.ZERO).records_history(),
		"reversibility: a move is FREE, shots / rams / spotters COSTLY, the take-back commands themselves are never recorded")

	# ---------- undoing a move ----------
	tank.begin_turn()
	hist.begin_turn(tank)
	var start := tank.global_position
	var ap0 := tank.ap
	var cell0 := tank.cell
	check(not hist.can_undo_move() and hist.refusal_move() == "Nothing to undo" and not hist.can_rewind(ctx) and hist.refusal_rewind(ctx) == "Nothing to rewind" and hist.hint(ctx) == "", "nothing to undo or rewind at the start of a turn")
	var mv := MoveAction.new(tank, start + Vector3(3.0, 0.0, 1.5))
	hist.record(mv, ctx)
	await mv.execute(ctx)
	await turns._settle()
	check(tank.ap < ap0 and not same_spot(tank, start) and hist.entries.size() == 1 and hist.can_undo_move(), "a move spends AP and shows up in the history")
	check(hist.hint(ctx) == "[Z] Undo move", "the toolbar hint offers the move undo (%s)" % hist.hint(ctx))
	var undo := UndoMoveAction.new(tank)
	check(undo.can_execute(ctx) and undo.cost(ctx) == 0.0 and RewindAction.new(tank).can_execute(ctx), "UndoMoveAction is legal and costs no AP (a rewind of a move is free too)")
	await undo.execute(ctx)
	await turns._settle()
	check(same_spot(tank, start) and is_equal_approx(tank.ap, ap0) and tank.cell == cell0 and ctx.board.unit_at(cell0) == tank and hist.entries.is_empty(), "undoing the move puts the unit back, refunds the AP and re-seats it on the board")
	check(hist.rewinds_left(ctx) == 1, "a free move undo costs no rewind charge")
	var mv1 := MoveAction.new(tank, start + Vector3(2.0, 0.0, 0.0))
	hist.record(mv1, ctx)
	await mv1.execute(ctx)
	var mid := tank.global_position
	var mv2 := MoveAction.new(tank, mid + Vector3(2.0, 0.0, 1.0))
	hist.record(mv2, ctx)
	await mv2.execute(ctx)
	await turns._settle()
	check(hist.undo_move(ctx) and same_spot(tank, mid) and hist.entries.size() == 1, "undo move goes one move at a time (back to the first move's end)")
	check(hist.undo_move(ctx) and same_spot(tank, start) and hist.entries.is_empty() and is_equal_approx(tank.ap, ap0), "... and then to the start, as often as you like")
	check(not hist.undo_move(ctx), "an empty history refuses")

	# ---------- undoing a shot: damage, a kill, craters, scorch, the record ----------
	foe.hp = 1.0
	var cannon: WeaponStats = tank.stats.weapons[0]
	var he: RoundStats = cannon.rounds[0]
	var prop_view: PropView = main._view.get_node_or_null("Props") as PropView
	var prop_cell: Vector2i = Vector2i.ZERO
	for c: Vector2i in ctx.board.prop_cells():
		prop_cell = c
		break
	var bodies_before := prop_view._bodies.size() if prop_view != null else -1
	var props_before := ctx.board.prop_cells().size()
	var prop_hp := ctx.board.prop_hp(prop_cell)
	var terrain_before := ctx.board.terrain_cells().size()
	var decals_before := get_nodes_in_group("scorch").size()
	var ap_shot0 := tank.ap
	var foe_start := foe.global_position
	var shot := params_at(tank, cannon, foe.global_position, 3, he)
	check(shot != null, "a firing solution exists")
	var act := ShootAction.new(tank, shot)
	hist.record(act, ctx)
	await act.execute(ctx)
	await turns._settle()
	check(not foe.is_alive() and ctx.state.shots.size() == 1 and ctx.state.totals["shots"] == 1 and ctx.state.totals["craters"] > 0 and tank.ap < ap_shot0, "the shot killed the unit, cratered the ground and was logged")
	check(ctx.board.terrain_cells().size() > terrain_before and get_nodes_in_group("scorch").size() > decals_before, "the ground shows craters and a scorch mark")
	check(not hist.can_undo_move() and UndoMoveAction.new(tank).refusal(ctx) == "Only a move can be undone" and not hist.hint(ctx).contains("[Z]"), "undo move refuses a shot: only moves can be undone for free")
	check(hist.can_rewind(ctx) and hist.refusal_rewind(ctx) == "" and hist.hint(ctx) == "[X] Rewind turn (1 left)", "a shot can be taken back by rewinding while a rewind charge is left (%s)" % hist.hint(ctx))
	# a prop destroyed by the same action (set up by hand so the check does not depend on where the blast fell)
	check(ctx.board.prop_hp(prop_cell) == prop_hp, "(the prop is unharmed so far)")
	var rewound := hist.rewind(ctx)
	await turns._settle()
	check(rewound and foe.is_alive() and is_equal_approx(foe.hp, 1.0) and same_spot(foe, foe_start) and foe.collision_layer == Unit.LAYER_UNITS and foe.visible, "rewinding the shot revives the killed unit where it stood, with its hit points and its collision")
	check(is_equal_approx(tank.ap, ap_shot0) and ctx.state.shots.is_empty() and ctx.state.totals["shots"] == 0 and ctx.state.totals["craters"] == 0 and ctx.state.totals["landed"] == 0,
		"... refunds the AP and wipes the shot from the battle record and its totals")
	check(ctx.board.terrain_cells().size() == terrain_before and ctx.board.terrain_at(ctx.board.world_to_cell(foe_start)) == Terrain.Type.GRASS, "... and the craters are gone again")
	await process_frame
	check(get_nodes_in_group("scorch").filter(func(n: Node) -> bool: return not n.is_queued_for_deletion()).size() == decals_before, "... and so is the scorch mark")
	check(ctx.board.unit_at(foe.cell) == foe and not ctx.alive_units().is_empty() and ctx.alive_units().has(foe), "the revived unit is back on the board and in the turn order")
	check(hist.rewinds_left(ctx) == 0, "the rewind used up the charge (%d left)" % hist.rewinds_left(ctx))
	check(ctx.state.totals["undos"] == 4, "... and every undo (3 free moves + this rewind) was counted in the battle totals (%s)" % str(ctx.state.totals.get("undos")))
	check(props_before == ctx.board.prop_cells().size() and prop_view != null and prop_view._bodies.size() == bodies_before, "... and no prop was lost or duplicated (%d props, %d bodies vs %d)" % [ctx.board.prop_cells().size(), prop_view._bodies.size() if prop_view != null else -1, bodies_before])

	# ---------- the limits ----------
	var foe_state := foe.capture()
	var act2 := ShootAction.new(tank, params_at(tank, cannon, foe.global_position, 3, he))
	hist.record(act2, ctx)
	await act2.execute(ctx)
	await turns._settle()
	check(not hist.can_rewind(ctx) and hist.refusal_rewind(ctx) == "No rewinds left" and not RewindAction.new(tank).can_execute(ctx), "out of rewind charges, the second shot cannot be taken back (%s)" % hist.refusal_rewind(ctx))
	var shots_now := ctx.state.shots.size()
	check(not hist.rewind(ctx) and not hist.undo_move(ctx) and ctx.state.shots.size() == shots_now and not foe.is_alive(), "a refused take-back changes nothing")
	# a free move recorded after the shot is still undoable, the shot below it is not
	var mv3 := MoveAction.new(tank, tank.global_position + Vector3(1.0, 0.0, 1.0))
	if tank.ap >= mv3.cost(ctx):
		hist.record(mv3, ctx)
		await mv3.execute(ctx)
		check(hist.undo_move(ctx) and hist.entries.size() == 1 and not hist.can_undo_move() and not hist.can_rewind(ctx), "a move after the shot can still be undone with no charge left, the shot beneath it stays")
	hist.end_turn()
	check(hist.entries.is_empty() and not hist.can_undo_any(ctx), "the history is emptied when the turn ends (nothing of an old turn can be taken back)")
	# put the world back for the next scenarios
	foe.restore(foe_state)   # (the killed unit is stood up by hand: no charges left to do it with)
	foe.hp = 8.0
	ctx.board.resync(ctx.units)
	ctx.state.reset()
	ctx.rules_for(0).rewind_charges = 2
	hist.rewinds_used.clear()

	# ---------- rewinding the whole turn ----------
	foe.hp = 8.0
	tank.begin_turn()
	hist.begin_turn(tank)
	var t_start := tank.global_position
	var t_ap := tank.ap
	var tm1 := MoveAction.new(tank, t_start + Vector3(2.0, 0.0, 0.0))
	hist.record(tm1, ctx)
	await tm1.execute(ctx)
	var tshot := ShootAction.new(tank, params_at(tank, cannon, foe.global_position, 1, he))
	hist.record(tshot, ctx)
	await tshot.execute(ctx)
	await turns._settle()
	var hp_hit := foe.hp
	check(hist.entries.size() == 2 and hist.can_rewind(ctx) and hist.hint(ctx).contains("[X] Rewind turn"), "a turn of a move and a shot can be rewound as a whole")
	var whole := RewindAction.new(tank)
	check(whole.can_execute(ctx), "the rewind command is legal")
	await whole.execute(ctx)
	await turns._settle()
	check(same_spot(tank, t_start) and is_equal_approx(tank.ap, t_ap) and hist.entries.is_empty() and is_equal_approx(foe.hp, 8.0) and ctx.state.shots.is_empty(), "the whole turn is gone: unit back at the start, AP full, damage healed, record clean")
	check(hist.rewinds_left(ctx) == 1 and ctx.state.totals["undos"] == 1 and ctx.state.totals["rewound_turns"] == 1, "a whole-turn rewind costs ONE charge however many actions it took back")
	# only free actions: no charge at all
	var fm1 := MoveAction.new(tank, t_start + Vector3(2.0, 0.0, 0.0))
	hist.record(fm1, ctx)
	await fm1.execute(ctx)
	check(hist.hint(ctx) == "[Z] Undo move" and hist.rewind(ctx) and hist.rewinds_left(ctx) == 1, "rewinding a turn of moves only costs no charge")

	# ---------- the time window ----------
	ctx.rules_for(0).rewind_window_sec = 10.0
	hist.clock = func() -> int: return fake_ms[0]
	fake_ms[0] = 0
	hist.begin_turn(tank)
	tank.begin_turn()
	var wshot := ShootAction.new(tank, params_at(tank, cannon, foe.global_position, 1, he))
	hist.record(wshot, ctx)
	await wshot.execute(ctx)
	await turns._settle()
	fake_ms[0] = 4000
	check(hist.can_rewind(ctx) and is_equal_approx(hist.window_left(ctx, hist.entries[0]), 6.0), "inside the window the shot can be rewound (%.0f s left)" % hist.window_left(ctx, hist.entries[0]))
	fake_ms[0] = 11000
	check(not hist.can_rewind(ctx) and hist.refusal_rewind(ctx).begins_with("Too late"), "after the window it is too late (%s)" % hist.refusal_rewind(ctx))
	var late_move := MoveAction.new(tank, tank.global_position + Vector3(1.0, 0.0, 0.0))
	hist.record(late_move, ctx)
	await late_move.execute(ctx)
	check(hist.undo_move(ctx), "a move undo is never subject to the window")
	hist.clock = Time.get_ticks_msec
	ctx.rules_for(0).rewind_window_sec = 0.0
	hist.end_turn()

	# ---------- rules can switch it off, hot seat has no rewinds ----------
	hist.begin_turn(tank)
	tank.begin_turn()
	var off_mv := MoveAction.new(tank, tank.global_position + Vector3(1.0, 0.0, 0.0))
	hist.record(off_mv, ctx)
	await off_mv.execute(ctx)
	ctx.rules_for(0).rewind_charges = 0
	ctx.rules_for(0).rewind_window_sec = 0.001
	fake_ms[0] += 60000
	hist.clock = func() -> int: return fake_ms[0]
	check(hist.can_undo_move() and hist.can_rewind(ctx) and hist.can_undo_any(ctx), "no rewind charges and a tiny window: undoing (or rewinding) moves still works - it has no rules")
	hist.clock = Time.get_ticks_msec
	ctx.rules_for(0).rewind_window_sec = 0.0
	var hs_shot := ShootAction.new(tank, params_at(tank, cannon, foe.global_position, 1, he))
	hist.record(hs_shot, ctx)
	await hs_shot.execute(ctx)
	await turns._settle()
	check(not hist.can_undo_move() and not hist.can_rewind(ctx), "no rewind charges: a turn with a shot in it stays committed")
	ctx.rules_for(0).rewind_charges = 1
	hist.end_turn()
	foe.hp = 8.0

	# ---------- a spotter ----------
	inf.begin_turn()
	hist.begin_turn(inf)
	ctx.rules_for(0).rewind_charges = 1
	hist.rewinds_used.clear()
	var inf_ap := inf.ap
	var pt := inf.global_position + Vector3(8.0, 0.0, 0.0)
	var areas_before := ctx.intel.areas.size()   # (earlier shots that landed unseen left "impact" areas)
	var spot := DroneAction.new(inf, pt)
	check(spot.can_execute(ctx), "the infantry can send its drone")
	hist.record(spot, ctx)
	await spot.execute(ctx)
	var areas_after := ctx.intel.areas.size()
	var drone_node: Node = inf.spotter
	check(areas_after == areas_before + 1 and inf.drone_cooldown == 3 and drone_node != null, "the drone is out: a spotted area, cooldown, a marker")
	check(not hist.can_undo_move() and hist.rewind(ctx), "a spotter action cannot be move-undone but can be rewound")
	await process_frame
	check(ctx.intel.areas.size() == areas_before and inf.drone_cooldown == 0 and inf.spotter == null and is_equal_approx(inf.ap, inf_ap) and (not is_instance_valid(drone_node) or drone_node.is_queued_for_deletion()),
		"... the area, the cooldown, the marker and the AP are all taken back")
	hist.end_turn()

	# ---------- a prop destroyed and a unit burning ----------
	var snap := BattleSnapshot.take(ctx)
	var kind := ctx.board.prop_at(prop_cell)
	var hp_before_prop := ctx.board.prop_hp(prop_cell)
	if kind >= 0:
		ctx.board.damage_prop(prop_cell, 9999.0)
		await process_frame
		check(ctx.board.prop_at(prop_cell) < 0 and not ctx.board.is_blocked(prop_cell), "(prop destroyed for the test)")
	var fire_cell := ctx.board.world_to_cell(foe.global_position)
	ctx.board.ignite(fire_cell, 3)
	foe.ignite(2)
	tank.take_damage(2.0)
	var tank_hp := tank.hp
	snap.restore(ctx)
	await process_frame
	check(ctx.board.prop_at(prop_cell) == kind and is_equal_approx(ctx.board.prop_hp(prop_cell), hp_before_prop) and ctx.board.is_blocked(prop_cell), "a snapshot brings a destroyed prop back (blocked again, same hit points)")
	check(prop_view == null or prop_view._bodies.has(prop_cell), "... and its model / collider is rebuilt")
	check(not ctx.board.is_burning(fire_cell) and ctx.board.terrain_at(fire_cell) != Terrain.Type.FIRE and foe.burning == 0 and tank.hp == tank_hp + 2.0, "... fires go out, burning stops, damage is healed")

	# ---------- through the turn loop ----------
	main.set_process(false)
	main._turns.queue_free()
	var tm := TurnManager.new()
	root.add_child(tm)
	var log := []
	var first_unit := []
	var plan_a := func(unit: Unit, c: BattleContext, n: int) -> Action:
		if first_unit.is_empty():
			first_unit.append(unit)
			log.append(unit.global_position)
			log.append(unit.ap)
		match n:
			1:
				var dest := unit.global_position
				for d in GridBoard.DIRS:
					if c.board.is_walkable(unit.cell + d):
						dest = c.board.cell_to_world(unit.cell + d)
						break
				var step := MoveAction.new(unit, dest)
				unit.ap = step.cost(c)   # exactly one step's worth: the move leaves no AP
				log.append(unit.ap)
				return step
			2:
				return UndoMoveAction.new(unit)
			_:
				return null
	var plan_idle := func(_u: Unit, _c: BattleContext, _n: int) -> Action: return null
	var c0 := Scripted.new()
	c0.plan = plan_a
	var c1 := Scripted.new()
	c1.plan = plan_idle
	c0.hold = func(u: Unit, cc: BattleContext) -> bool: return main._player.holds_turn(u, cc)
	root.add_child(c0)
	root.add_child(c1)
	var executed := []
	var decisions_at_end := []
	tm.turn_ended.connect(func(u: Unit) -> void:
		if first_unit.size() > 0 and u == first_unit[0] and decisions_at_end.is_empty():
			decisions_at_end.append(c0.decisions))
	tm.action_executed.connect(func(a: Action) -> void: executed.append(a))
	var ended := []
	tm.turn_ended.connect(func(u: Unit) -> void: ended.append(u))
	for u in ctx.units:
		if u.is_alive():
			u.freeze_in_place()
	ctx.board.resync(ctx.units)
	for u in ctx.units:
		u.drone_cooldown = 0
		u.burning = 0
	# keep the battle running for one round: both sides alive
	tm.start(ctx, {0: c0, 1: c1})
	while first_unit.is_empty() or not ended.has(first_unit[0]):
		await physics_frame
	var u0: Unit = first_unit[0]
	check(executed.size() == 2 and executed[0] is MoveAction and executed[1] is UndoMoveAction, "the loop ran the move and the undo as ordinary commands")
	check(decisions_at_end == [3], "with the AP gone the turn stayed open for the player: move, undo, then the explicit end (%s decisions)" % str(decisions_at_end))
	check(same_spot(u0, log[0]) and is_equal_approx(u0.ap, log[2]), "the undo inside the loop put the unit back where its turn began and refunded the AP (%s)" % u0.stats.display_name)
	tm.queue_free()
	await process_frame

	# a controller that does not hold the turn loses it as soon as the AP are spent
	var tm_b := TurnManager.new()
	root.add_child(tm_b)
	var c0b := Scripted.new()
	var steps_b := []
	c0b.plan = func(unit: Unit, c: BattleContext, n: int) -> Action:
		steps_b.append(n)
		if n == 1:
			var dest := unit.global_position
			for d in GridBoard.DIRS:
				if c.board.is_walkable(unit.cell + d):
					dest = c.board.cell_to_world(unit.cell + d)
					break
			var step := MoveAction.new(unit, dest)
			unit.ap = step.cost(c)
			return step
		return null
	root.add_child(c0b)
	var ended_b := []
	tm_b.turn_ended.connect(func(u: Unit) -> void: ended_b.append(u))
	var steps_at_end := []
	tm_b.turn_ended.connect(func(u: Unit) -> void:
		if u.team == 0 and steps_at_end.is_empty():
			steps_at_end.append(steps_b.duplicate()))
	var team0_done := func() -> bool: return not steps_at_end.is_empty()
	for u in ctx.units:
		u.drone_cooldown = 0
	ctx.board.resync(ctx.units)
	tm_b.start(ctx, {0: c0b, 1: c1})
	while not team0_done.call():
		await physics_frame
	check(steps_at_end == [[1]], "by default a turn ends the moment the AP are spent (the controller was asked once: %s)" % str(steps_at_end))
	tm_b.queue_free()

	main.queue_free()
	await process_frame

	# ---------- the real player controller: keys Z / X / Space in a live game ----------
	var live: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(live)
	var pl: PlayerController = live._player
	var lctx: BattleContext = live._ctx
	var waited := 0.0
	while not (pl._active and live._turns.current_unit != null and live._turns.current_unit.team == 0) and waited < 20.0:
		await physics_frame
		waited += 1.0 / 60.0
	var hero: Unit = live._turns.current_unit
	check(pl._active and hero.team == 0, "the player's first turn is waiting for input (%s)" % hero.stats.display_name)
	var key := func(code: Key) -> InputEventKey:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.pressed = true
		return ev
	var h_start := hero.global_position
	var h_dir := Vector3.ZERO
	for d in GridBoard.DIRS:
		if lctx.board.is_walkable(hero.cell + d):
			h_dir = lctx.board.cell_to_world(hero.cell + d)
			break
	var h_move := MoveAction.new(hero, h_dir)
	hero.ap = h_move.cost(lctx)    # one step's worth of AP: after it the unit has nothing left
	var h_ap := hero.ap
	pl._finish(h_move)
	waited = 0.0
	while not pl._active and waited < 10.0:
		await physics_frame
		waited += 1.0 / 60.0
	check(pl._active and hero.ap < 0.001 and lctx.history.entries.size() == 1 and live._turns.current_unit == hero, "out of AP the turn is NOT over: the player is asked again so they can undo")
	await process_frame
	check(pl._toolbar._undo.text == "[Z] Undo move", "the toolbar says what can be undone (%s)" % pl._toolbar._undo.text)
	check(pl._toolbar._popup_label.text.contains("SPACE") and pl._end_turn_hinted, "out of AP a gentle popup says SPACE ends the turn (%s)" % pl._toolbar._popup_label.text)
	pl._unhandled_input(key.call(KEY_X))   # whole-turn rewind of a single free move: allowed, free
	waited = 0.0
	while not pl._active and waited < 10.0:
		await physics_frame
		waited += 1.0 / 60.0
	check(same_spot(hero, h_start) and is_equal_approx(hero.ap, h_ap) and lctx.history.entries.is_empty() and lctx.history.rewinds_left(lctx) == 1, "X rewinds the turn: the unit is back, AP refunded, no charge spent")
	pl._unhandled_input(key.call(KEY_Z))
	await process_frame
	await process_frame   # (process_frame fires before the nodes' own _process: wait one more for the hint to refresh)
	check(pl._active and lctx.history.entries.is_empty() and pl._toolbar._undo.text == "", "with nothing to undo Z does nothing (the hint is empty)")
	pl._unhandled_input(key.call(KEY_SPACE))
	waited = 0.0
	while live._turns.current_unit == hero and waited < 10.0:
		await physics_frame
		waited += 1.0 / 60.0
	check(live._turns.current_unit != hero or not hero.is_alive(), "Space still ends the turn")
	live.queue_free()
	await process_frame
	BattleConfig.reset()
	print("---- %d failure(s)" % fails)
	quit(1 if fails > 0 else 0)
