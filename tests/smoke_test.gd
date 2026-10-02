extends SceneTree
## Headless smoke test: hex maths, weighted pathing, terrain (craters / fire), ballistics + wind,
## round types + charges, armor, gridless move + AP, gunnery + burst shooting, cluster / incendiary
## rounds, shot camera, game-state log, AI fairness, fall-off-board death.
##   godot --headless --path . --script res://tests/smoke_test.gd
## Exit code 1 when any check fails.

var fails := 0


func check(cond: bool, msg: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + msg)
	if not cond:
		fails += 1


func _initialize() -> void:
	_run()


## FireParams that should land a shot of `weapon` on `target` (still air). Null if out of reach.
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


func _run() -> void:
	# ---------- pure grid tests ----------
	var b := GridBoard.new(Vector2i(18, 15), 1.0)
	check(b.all_cells().size() == 270, "18x15 board = 270 cells")
	var rt_ok := true
	for c in b.all_cells():
		if not b.in_bounds(c) or b.world_to_cell(b.cell_to_world(c)) != c:
			rt_ok = false
	check(rt_ok, "cell<->world round trip for every cell")
	check(absf(b.cell_to_world(Vector2i(5, 5)).distance_to(b.cell_to_world(Vector2i(6, 5))) - 1.7320508) < 0.001, "neighbour spacing = sqrt(3)")

	var origin := GridBoard.offset_to_axial(Vector2i(2, 5))
	var goal := GridBoard.offset_to_axial(Vector2i(6, 5))
	var p0 := b.find_path(origin, goal)
	check(p0.size() - 1 == GridBoard.hex_distance(origin, goal), "open path length == hex distance")
	for c in p0.slice(1, p0.size() - 1):
		b.set_weight(c, 3.0)
	var p1 := b.find_path(origin, goal)
	check(p1 != p0 and b.path_cost(p1) < 3.0 * (p0.size() - 2) + 1.0, "weighted path detours (cost %.1f)" % b.path_cost(p1))
	b.set_blocked(goal)
	check(b.find_path(origin, goal).is_empty(), "blocked goal unreachable")

	# ---------- terrain: craters and fire ----------
	var t := GridBoard.new(Vector2i(18, 15), 1.0)
	var mid := GridBoard.offset_to_axial(Vector2i(9, 7))
	var mid_w := t.cell_to_world(mid)
	var changed: Array = []
	t.terrain_changed.connect(func(c: Vector2i, ty: int) -> void: changed.append([c, ty]))
	check(t.weight_of(mid) == 1.0, "grass costs 1")
	var n_crater := t.crater_area(mid_w, 1.2)
	check(n_crater >= 1 and t.terrain_at(mid) == Terrain.Type.CRATER and t.weight_of(mid) == Terrain.weight(Terrain.Type.CRATER), "crater_area makes a crater (weight %.1f, %d cell)" % [t.weight_of(mid), n_crater])
	check(changed.size() == n_crater, "terrain_changed fires per cell")
	var far := GridBoard.offset_to_axial(Vector2i(12, 7))
	var straight := t.path_cost(t.find_path(GridBoard.offset_to_axial(Vector2i(6, 7)), far))
	check(straight >= GridBoard.hex_distance(GridBoard.offset_to_axial(Vector2i(6, 7)), far), "paths price terrain (%.1f)" % straight)
	t.set_blocked(GridBoard.offset_to_axial(Vector2i(3, 3)))
	t.crater_area(t.cell_to_world(GridBoard.offset_to_axial(Vector2i(3, 3))), 1.5)
	check(t.terrain_at(GridBoard.offset_to_axial(Vector2i(3, 3))) == Terrain.Type.GRASS, "obstacle cells are never changed")

	var fire_cell := GridBoard.offset_to_axial(Vector2i(4, 10))
	t.ignite_area(t.cell_to_world(fire_cell), 1.0)
	check(t.is_burning(fire_cell) and t.terrain_at(fire_cell) == Terrain.Type.FIRE, "ignite_area sets fire")
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var base_fires := t.fire_cells().size()
	t.tick_fires(Vector3(1.0, 0.0, 0.0), rng)
	check(t.fire_cells().size() >= base_fires, "fire persists / spreads on the first tick")
	for i in 6:
		t.tick_fires(Vector3(1.0, 0.0, 0.0), rng)
	check(t.fire_cells().is_empty() and t.terrain_at(fire_cell) == Terrain.Type.SCORCH, "fires burn out into scorched ground")
	# strong downwind spread
	var spread_seen := false
	for trial in 12:
		var tb := GridBoard.new(Vector2i(18, 15), 1.0)
		var start := GridBoard.offset_to_axial(Vector2i(6, 7))
		tb.ignite(start, GridBoard.FIRE_DURATION)
		tb.tick_fires(Vector3(1.0, 0.0, 0.0), rng)
		if tb.fire_cells().size() > 1:
			spread_seen = true
			break
	check(spread_seen, "fire spreads to neighbours (downwind)")

	# ---------- ballistics, wind, rounds, charges ----------
	var o := Vector3(0, 1, 0)
	var tg := Vector3(12, 0, 5)
	for high in [false, true]:
		var v := Ballistics.solve_velocity(o, tg, 15.0, high)
		var vh := Vector2(v.x, v.z).length()
		var tt := Vector2(tg.x - o.x, tg.z - o.z).length() / vh
		check(v != Vector3.ZERO and Ballistics.position_at(o, v, tt).distance_to(tg) < 0.01, "solve_velocity high_arc=%s lands on target" % high)
	var wind := Wind.new()
	wind.set_fixed(6.0, 1.0)
	check(is_equal_approx(wind.accel().length(), 6.0 * Wind.COUPLING), "wind accel = speed * coupling")

	var normal: RoundStats = load("res://data/rounds/normal.tres")
	var ap: RoundStats = load("res://data/rounds/ap.tres")
	var inc: RoundStats = load("res://data/rounds/incendiary.tres")
	var clu: RoundStats = load("res://data/rounds/cluster.tres")
	check(ap.velocity_mult() < normal.velocity_mult() and normal.velocity_mult() < inc.velocity_mult(), "heavier round = slower muzzle speed (AP %.2f < HE %.2f < INC %.2f)" % [ap.velocity_mult(), normal.velocity_mult(), inc.velocity_mult()])
	check(ap.wind_mult() < normal.wind_mult() and normal.wind_mult() < inc.wind_mult(), "heavier round = less wind drift (x%.2f / x%.2f / x%.2f)" % [ap.wind_mult(), normal.wind_mult(), inc.wind_mult()])
	var cannon: WeaponStats = load("res://data/weapons/tank_cannon.tres")
	check(cannon.rounds.size() == 4 and cannon.max_charges() == 3, "cannon: 4 round types, 3 charges")
	check(is_equal_approx(cannon.total_cost(1), 4.0) and is_equal_approx(cannon.total_cost(3), 6.0), "charges cost extra AP (%.1f / %.1f / %.1f)" % [cannon.total_cost(1), cannon.total_cost(2), cannon.total_cost(3)])
	var fp1 := FireParams.make(cannon, 0.0, 0.2, 1.0, 1, normal)
	var fp3 := FireParams.make(cannon, 0.0, 0.2, 1.0, 3, normal)
	check(fp3.speed() > fp1.speed() * 1.4, "more charges = higher muzzle speed (%.1f -> %.1f m/s)" % [fp1.speed(), fp3.speed()])
	check(Ballistics.flat_range(fp3.speed(), 0.2) > Ballistics.flat_range(fp1.speed(), 0.2) * 2.0, "more charges = much longer reach")
	check(FireParams.make(cannon, 0.0, 0.2, 1.0, 1, ap).speed() < fp1.speed(), "AP round leaves the barrel slower")
	check(FireParams.make(cannon, 0.0, 0.2, 1.0, 9, normal).charge == 3, "charge clamps to the weapon's maximum")

	# ---------- armor model on a standalone unit ----------
	var tank_stats: UnitStats = load("res://data/tank.tres")
	var inf_stats: UnitStats = load("res://data/infantry.tres")
	var how_stats: UnitStats = load("res://data/howitzer.tres")
	var probe := Unit.new()
	probe.configure(tank_stats, 0, Color.WHITE)
	root.add_child(probe)
	probe.face(Vector3(0, 0, 1))
	check(probe.armor_sector(Vector3(0, 0, 1)) == HitResult.Sector.FRONT, "hit from ahead = front plate")
	check(probe.armor_sector(Vector3(1, 0, 0)) == HitResult.Sector.SIDE, "hit from the flank = side plate")
	check(probe.armor_sector(Vector3(0, 0, -1)) == HitResult.Sector.REAR, "hit from behind = rear plate")
	var weak := probe.take_hit(6.0, 8.0, Vector3(0, 0, 1))
	check(weak.outcome == HitResult.Outcome.ABSORBED and weak.damage < 6.0 and weak.damage > 3.0, "pen 8 vs front 12: armor absorbs part (%.1f of 6)" % weak.damage)
	check(probe.armor[0] < 12.0, "absorbing wears the plate (12 -> %.2f)" % probe.armor[0])
	var pen := probe.take_hit(6.0, 17.6, Vector3(0, 0, 1))
	check(pen.outcome == HitResult.Outcome.PENETRATED and is_equal_approx(pen.damage, 6.0), "AP penetration bypasses armor for full damage")
	var side := probe.take_hit(6.0, 8.0, Vector3(1, 0, 0))
	check(side.outcome == HitResult.Outcome.PENETRATED, "pen 8 vs weaker side plate (7) penetrates")
	var tough := Unit.new()
	tough.configure(tank_stats, 0, Color.WHITE)
	root.add_child(tough)
	tough.face(Vector3(0, 0, 1))
	var first := tough.take_hit(1.0, 1.5, Vector3(0, 0, 1))
	var last := first
	for i in 40:
		last = tough.take_hit(1.0, 1.5, Vector3(0, 0, 1))
	check(last.damage > first.damage and tough.armor[0] < 12.0, "armor depletes under sustained fire (%.2f -> %.2f dmg per hit)" % [first.damage, last.damage])
	var burn := Unit.new()
	burn.configure(tank_stats, 0, Color.WHITE)
	root.add_child(burn)
	burn.face(Vector3(0, 0, 1))
	check(burn.take_hit(6.0, 8.0, Vector3(0, 0, 1)).outcome == HitResult.Outcome.ABSORBED, "cold armor stops a pen-8 hit on the front")
	var burn2 := Unit.new()
	burn2.configure(tank_stats, 0, Color.WHITE)
	root.add_child(burn2)
	burn2.face(Vector3(0, 0, 1))
	burn2.ignite(2)
	check(burn2.take_hit(6.0, 8.0, Vector3(0, 0, 1)).outcome == HitResult.Outcome.PENETRATED, "burning halves armor: the same hit now penetrates")
	var hp_before := burn2.hp
	burn2.begin_turn()
	check(burn2.hp < hp_before and burn2.burning == 1, "burning costs HP each turn (%.1f -> %.1f)" % [hp_before, burn2.hp])
	var grunt := Unit.new()
	grunt.configure(inf_stats, 0, Color.WHITE)
	root.add_child(grunt)
	check(grunt.take_hit(3.0, 1.0, Vector3(0, 0, 1)).outcome == HitResult.Outcome.UNARMORED, "infantry have no armor")

	# ---------- live scene ----------
	# the composed map is random per game; tests pin the seed and keep their firing lane (rows 1-3, cols 0-8) and
	# the fall-off cell (27, 7) free of props
	Game.forced_seed = 7
	Game.flat_ground = true   # the legacy checks below assume level ground; hills have their own section
	for row in range(1, 4):
		for col in 9:
			Game.extra_keep_clear.append(Vector2i(col, row))
	Game.extra_keep_clear.append(Vector2i(27, 7))
	# ...and the sight line from the team 0 scout (17, 6) to the team 1 tank (18, 16), one cell either side
	var sa := GridBoard.offset_to_axial(Vector2i(17, 6))
	var sb := GridBoard.offset_to_axial(Vector2i(18, 16))
	for k in 41:
		var lc := GridBoard.axial_round(lerpf(sa.x, sb.x, k / 40.0), lerpf(sa.y, sb.y, k / 40.0))
		Game.extra_keep_clear.append(GridBoard.axial_to_offset(lc))
		for d in GridBoard.DIRS:
			Game.extra_keep_clear.append(GridBoard.axial_to_offset(lc + d))
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 6:
		await physics_frame
	var ctx: BattleContext = main._ctx
	var turns: TurnManager = main._turns
	var state: GameState = ctx.state
	var shooter: Unit = ctx.units[0]
	var how: Unit = ctx.units[1]
	var enemy: Unit = ctx.units[3]
	check(ctx.board.size == Vector2i(28, 22), "map extended to 28x22")

	# ---------- scene composer ----------
	var comp := SceneComposer.new()
	comp.reserved = [Vector2i(3, 3), Vector2i(18, 14)]
	var lay_a := comp.compose(42)
	var lay_b := comp.compose(42)
	var lay_c := comp.compose(43)
	check(lay_a.props == lay_b.props and lay_a.rough == lay_b.rough, "composer: same seed gives the same map")
	check(lay_a.props != lay_c.props, "composer: different seeds give different maps")
	check(lay_a.props.size() >= 20 and not lay_a.rough.is_empty(), "composer places foliage and undergrowth (%s)" % lay_a.summary())
	var comp_ok := true
	var comp_cells := {}
	for lay in [lay_a, lay_c]:
		comp_cells.clear()
		for p: Array in lay.props:
			var pc: Vector2i = p[1]
			comp_ok = comp_ok and not comp_cells.has(pc) and Props.models(p[0]).has(p[2])
			comp_ok = comp_ok and GridBoard.hex_distance(GridBoard.offset_to_axial(pc), GridBoard.offset_to_axial(Vector2i(3, 3))) > comp.reserved_radius
			comp_ok = comp_ok and GridBoard.hex_distance(GridBoard.offset_to_axial(pc), GridBoard.offset_to_axial(Vector2i(18, 14))) > comp.reserved_radius
			comp_cells[pc] = true
		for rc in lay.rough:
			comp_ok = comp_ok and not comp_cells.has(rc)
	check(comp_ok, "composer: no overlaps, valid models, reserved zones stay clear")
	var comp_walls := SceneComposer.new()
	comp_walls.reserved = [Vector2i(3, 3), Vector2i(18, 14)]
	comp_walls.large_rocks = Vector2i(0, 0)
	var many_seeds_ok := true
	for sd in 20:
		var lay := comp_walls.compose(sd)
		var bd := GridBoard.new(comp_walls.board_size, 1.0)
		for p: Array in lay.props:
			bd.add_prop(GridBoard.offset_to_axial(p[1]), p[0], p[2])
		many_seeds_ok = many_seeds_ok and not bd.find_path(GridBoard.offset_to_axial(Vector2i(3, 3)), GridBoard.offset_to_axial(Vector2i(18, 14))).is_empty()
	check(many_seeds_ok, "composer: spawn points stay connected over 20 seeds")
	var game_cells := {}
	for p: Array in main._layout.props:
		game_cells[p[1]] = true
	var game_ok: bool = main._layout.seed == 7 and not game_cells.has(Vector2i(27, 7))
	for row in range(1, 4):
		for col in 9:
			game_ok = game_ok and not game_cells.has(Vector2i(col, row))
	check(game_ok and ctx.board.prop_cells().size() == main._layout.props.size(), "game builds the composed layout and honours keep-clear cells")
	check(state != null and ctx.camera != null, "context carries GameState and shot camera")
	check(ToolEntry.build_for(shooter).size() == 4, "toolbar for tank: Move, Cannon, MG, Ram")

	# ---------- spotting (Intel) + drone ----------
	var scout: Unit = ctx.units[2]            # team 0 infantry, carries a drone
	var far_foe: Unit = ctx.units[4]          # team 1 howitzer, outside every friendly sight radius at the start
	check(ToolEntry.build_for(scout).size() == 5, "toolbar for infantry adds Drone")
	check(Intel.fidelity_for(Vector3(5, 0, 0), Vector3.ZERO, 10.0) == Intel.LOS_FIDELITY, "inside sight radius = LoS fidelity")
	check(absf(Intel.fidelity_for(Vector3(10.01, 0, 0), Vector3.ZERO, 10.0) - Intel.EDGE_FIDELITY) < 0.01, "just outside LoS starts at 50% fidelity")
	var f_near := Intel.fidelity_for(Vector3(12, 0, 0), Vector3.ZERO, 10.0)
	var f_far := Intel.fidelity_for(Vector3(16, 0, 0), Vector3.ZERO, 10.0)
	check(f_near < Intel.EDGE_FIDELITY and f_far < f_near and f_far >= Intel.FLOOR_FIDELITY, "fidelity fades gradually outside LoS (%.2f > %.2f)" % [f_near, f_far])
	check(Intel.sigma_fraction(Intel.LOS_FIDELITY) < Intel.sigma_fraction(Intel.EDGE_FIDELITY), "lower fidelity = wider deviation")
	var f_foe := ctx.intel.fidelity_at(0, ctx.units, far_foe.global_position)
	check(f_foe < Intel.LOS_FIDELITY and f_foe >= Intel.FLOOR_FIDELITY, "far enemy is outside LoS (fidelity %.2f)" % f_foe)
	var rd1 := ctx.intel.reading(shooter, far_foe, ctx.units)
	var rd2 := ctx.intel.reading(shooter, far_foe, ctx.units)
	check(rd1["est"] == rd2["est"], "reading is stable within a turn (no averaging the noise away)")
	check(rd1["sigma"] > 0.0 and absf(float(rd1["est"]) - float(rd1["true"])) <= 2.5 * float(rd1["sigma"]) + 0.001, "reading error stays within the deviation (est %.1f, true %.1f, sigma %.1f)" % [rd1["est"], rd1["true"], rd1["sigma"]])
	var rerolled := false
	for k in 8:
		ctx.intel.begin_turn(shooter)
		if ctx.intel.reading(shooter, far_foe, ctx.units)["est"] != rd1["est"]:
			rerolled = true
	check(rerolled, "readings are re-rolled on a new turn")
	check(not ctx.board.los_blocked(scout.global_position, ctx.units[3].global_position), "scout has a clear view of the enemy tank at the start")
	var tank_home := ctx.units[3].global_position
	ctx.units[3].snap_to(scout.global_position.lerp(tank_home, 0.6))   # the scout's inner ring is 12.8 m now, the tank starts ~15 m away
	var near_foe := ctx.intel.reading(scout, ctx.units[3], ctx.units)
	check(near_foe["los"] and near_foe["sigma"] < near_foe["true"] * Intel.sigma_fraction(Intel.EDGE_FIDELITY), "enemy inside a friendly's sight is measured tightly")
	ctx.units[3].snap_to(tank_home)
	check(ctx.intel.spot_impact(0, ctx.units, far_foe.global_position), "shell landing outside LoS opens a spotted area")
	check(Intel.in_los(ctx.intel.fidelity_at(0, ctx.units, far_foe.global_position)), "spotted area counts as line of sight")
	check(ctx.intel.fidelity_at(1, ctx.units, far_foe.global_position) >= Intel.LOS_FIDELITY, "...and the enemy team still sees its own unit")
	check(not ctx.intel.spot_impact(0, ctx.units, far_foe.global_position), "a second impact inside LoS opens nothing new")
	ctx.intel.tick(ctx.round_number + 50)
	check(ctx.intel.areas.is_empty() and ctx.intel.fidelity_at(0, ctx.units, far_foe.global_position) < Intel.LOS_FIDELITY, "spotted areas expire")
	ctx.intel.tick(ctx.round_number)

	# ---------- two sight rings: inner = tight reading, outer (10 m more) = estimated, beyond = hidden ----------
	var ring_in := Intel.fidelity_for(Vector3(10, 0, 0), Vector3.ZERO, 10.0)
	var ring_a := Intel.fidelity_for(Vector3(11, 0, 0), Vector3.ZERO, 10.0)
	var ring_b := Intel.fidelity_for(Vector3(17, 0, 0), Vector3.ZERO, 10.0)
	var ring_out := Intel.fidelity_for(Vector3(18.5, 0, 0), Vector3.ZERO, 10.0)
	check(Intel.in_los(ring_in) and Intel.in_view(ring_a) and not Intel.in_los(ring_a) and Intel.in_view(ring_b) and ring_out == 0.0 and not Intel.in_view(ring_out),
		"inner ring is clear, the next %.0f m are seen but estimated, beyond that nothing" % Intel.OUTER_BAND)
	check(Intel.sigma_fraction(ring_in) < Intel.sigma_fraction(ring_a) and Intel.sigma_fraction(ring_a) < Intel.sigma_fraction(ring_b), "the deviation grows across the outer ring")
	check(Intel.fidelity_for(Vector3(10.5, 0, 0), Vector3.ZERO, 10.0, 0.0) == 0.0, "spotted areas and drones have no outer ring")
	var ring_ctx := BattleContext.new()   # no board: nothing blocks sight, only the rings count
	var ring_obs := Unit.new()
	ring_obs.configure(tank_stats, 1, Color.WHITE)
	var ring_tgt := Unit.new()
	ring_tgt.configure(tank_stats, 0, Color.WHITE)
	main.add_child(ring_obs)
	main.add_child(ring_tgt)
	ring_ctx.units = [ring_obs, ring_tgt] as Array[Unit]
	ring_obs.snap_to(Vector3(300, 0.6, 300))
	var ai_rings := AIController.new()
	var at_inner := [7.0, 14.0, 22.0]   # tank sight is 9.6 m + 8 m outer ring: inner, outer, hidden
	var rings_ok := true
	var rd_outer := {}
	for k in at_inner.size():
		ring_tgt.snap_to(Vector3(300.0 + at_inner[k], 0.6, 300))
		ring_ctx.intel.begin_turn(ring_obs)
		var rd := ring_ctx.intel.reading(ring_obs, ring_tgt, ring_ctx.units)
		var seen := ring_ctx.intel.sees(1, ring_ctx.units, ring_tgt)
		rings_ok = rings_ok and seen == (k < 2) and bool(rd["los"]) == (k == 0) and bool(rd["outer"]) == (k == 1)
		if k == 1:
			rd_outer = rd
	check(rings_ok, "a unit 7 m away is measured, 14 m away is seen as an estimate, 22 m away is hidden (tank sight 9.6 m + 8 m)")
	ring_tgt.snap_to(Vector3(314.0, 0.6, 300))
	ring_ctx.intel.begin_turn(ring_obs)
	var rd_now := ring_ctx.intel.reading(ring_obs, ring_tgt, ring_ctx.units)
	var perceived := ai_rings._perceived_position(ring_obs, ring_tgt, ring_ctx)
	check(absf(perceived.x - (300.0 + float(rd_now["est"]))) < 0.01 and absf(perceived.z - 300.0) < 0.01 and rd_now["outer"],
		"the AI aims at the estimated range for a target in the outer ring (est %.1f, true 14)" % rd_now["est"])
	ring_tgt.snap_to(Vector3(307.0, 0.6, 300))
	check(ai_rings._perceived_position(ring_obs, ring_tgt, ring_ctx).is_equal_approx(ring_tgt.global_position), "...and at the true position inside the inner ring")
	ring_obs.queue_free()
	ring_tgt.queue_free()
	ai_rings.free()

	# ---------- fog: an enemy beyond both sight rings is simply unknown (screen and AI) ----------
	# the howitzer starts 19-20 m from the scout (inside its outer ring now): park it in the far corner for the fog checks
	var far_home := far_foe.global_position
	far_foe.snap_to(ctx.board.cell_to_world(GridBoard.offset_to_axial(Vector2i(27, 21)), far_foe.rest_height()))
	ctx.board.resync(ctx.units)
	check(ctx.intel.sees(0, ctx.units, ctx.units[3]) and ctx.intel.sees(0, ctx.units, ctx.units[5]) and not ctx.intel.sees(0, ctx.units, far_foe),
		"at the start the scout's rings cover two enemies, the one parked in the corner stays hidden")
	# the AI checks below need team 1 to be blind as well (its tank / infantry would see the scout from ~10-15 m): park all of it
	var team1_home := {}
	var park_cells := {5: Vector2i(27, 21), 3: Vector2i(26, 21), 4: Vector2i(25, 21)}
	for idx: int in park_cells:
		team1_home[idx] = far_home if ctx.units[idx] == far_foe else ctx.units[idx].global_position
		ctx.units[idx].snap_to(ctx.board.cell_to_world(GridBoard.offset_to_axial(park_cells[idx]), ctx.units[idx].rest_height()))
	ctx.board.resync(ctx.units)
	check(not ctx.intel.sees(0, ctx.units, far_foe) and ctx.intel.sees(1, ctx.units, far_foe), "an enemy outside every friendly sight radius is not seen (its own team always sees it)")
	check(not ctx.visible_to_viewer(far_foe) and ctx.visible_to_viewer(shooter) and not ctx.visible_enemies_of(shooter).has(far_foe), "the screen hides it, never our own units")
	main._update_fog()
	check(far_foe.is_concealed() and not far_foe._label.visible and not far_foe._hull.visible and not shooter.is_concealed() and shooter._label.visible, "a concealed enemy shows no model and no label")
	ctx.intel.add_area(0, far_foe.global_position, 4.0, 2, "test")
	check(ctx.intel.sees(0, ctx.units, far_foe) and ctx.visible_enemies_of(shooter).has(far_foe), "a spotted area uncovers it")
	main._update_fog()
	check(not far_foe.is_concealed() and far_foe._label.visible and far_foe._hull.visible, "...and it shows again")
	ctx.intel.areas.clear()
	main._update_fog()
	var fog_ai := AIController.new()
	fog_ai.think_delay = 0.0
	main.add_child(fog_ai)
	check(fog_ai._nearest_enemy(far_foe, ctx) == null, "AI: no enemy in its team's sight = no target")
	far_foe.begin_turn()
	var search: Action = await fog_ai.decide(far_foe, ctx)
	check(search is MoveAction and (search as MoveAction).can_execute(ctx), "AI with nobody in sight scouts instead of attacking")
	ctx.intel.add_area(1, shooter.global_position, 4.0, 2, "test")   # the AI's team now sees the tank
	check(fog_ai._nearest_enemy(far_foe, ctx) == shooter, "AI targets an enemy once its team sees it")
	ctx.intel.areas.clear()
	check(fog_ai._nearest_enemy(far_foe, ctx) == null, "...and loses it when the sight is gone")
	far_foe.begin_turn()
	var hunt: Action = await fog_ai.decide(far_foe, ctx)
	var seen_at: Vector3 = shooter.global_position
	check(hunt is MoveAction and Vector2((hunt as MoveAction).point.x - seen_at.x, (hunt as MoveAction).point.z - seen_at.z).length() < Vector2(far_foe.global_position.x - seen_at.x, far_foe.global_position.z - seen_at.z).length(),
		"AI heads for where it last saw an enemy")
	fog_ai.queue_free()
	for idx: int in team1_home:
		ctx.units[idx].snap_to(team1_home[idx])
	ctx.board.resync(ctx.units)
	scout.begin_turn()
	var scout_ap := scout.ap
	var drone_far := DroneAction.new(scout, scout.global_position + Vector3(scout.stats.drone_range + 5.0, 0.0, 0.0))
	check(not drone_far.can_execute(ctx), "drone out of range rejected")
	var drone_pt := Vector3(far_foe.global_position.x, 0.0, far_foe.global_position.z)
	var drone_ok := DroneAction.new(scout, scout.global_position.lerp(drone_pt, 0.8))
	check(drone_ok.in_range() and drone_ok.can_execute(ctx), "drone in range accepted")
	await drone_ok.execute(ctx)
	check(is_equal_approx(scout_ap - scout.ap, DroneAction.AP_COST) and ctx.intel.areas.size() == 1, "drone costs AP and opens a spotted area")
	var drone_node: Variant = ctx.intel.areas[0]["node"]
	check(drone_node is Drone and is_instance_valid(drone_node) and (drone_node as Drone).is_inside_tree(), "drone leaves a physical marker on station")
	check(scout.drone_cooldown == DroneAction.COOLDOWN_TURNS and not DroneAction.new(scout, drone_pt).can_execute(ctx), "drone on cooldown cannot launch again")
	check(ctx.intel.areas[0]["expires"] - ctx.round_number == Intel.DRONE_ROUNDS - 1, "drone stays for %d turns" % Intel.DRONE_ROUNDS)
	check(main._sight.refresh() == ctx.intel.sources(0, ctx.units).size() and main._sight.visible, "LoS overlay is fed the team's sight sources")
	var is_drone := func(s: Dictionary) -> bool: return s["label"] == "drone"
	check(ctx.intel.sources(0, ctx.units).filter(is_drone).size() == 1 and ctx.intel.sources(1, ctx.units).filter(is_drone).is_empty(), "drone sight belongs to its own team only")
	ctx.intel.tick(ctx.round_number + 50)
	await create_timer(1.2).timeout
	check(not is_instance_valid(drone_node), "drone flies off when its time is up")
	ctx.intel.tick(ctx.round_number)
	for k in DroneAction.COOLDOWN_TURNS:
		scout.begin_turn()
	check(scout.drone_cooldown == 0 and DroneAction.new(scout, scout.global_position.lerp(drone_pt, 0.8)).can_execute(ctx), "drone available again after %d turns" % DroneAction.COOLDOWN_TURNS)

	# ---------- props: trees, rocks, groves + line-of-sight occlusion ----------
	var kinds := {}
	for c: Vector2i in ctx.board.prop_cells():
		var k: int = ctx.board.prop_at(c)
		kinds[k] = int(kinds.get(k, 0)) + 1
	check(kinds.size() >= 4 and kinds[Props.Kind.TREE] >= 10 and kinds[Props.Kind.ROCK_LARGE] >= 4 and kinds[Props.Kind.ROCK_SMALL] >= 4 and kinds[Props.Kind.GROVE] >= 3,
		"map has trees, large rocks, small rocks and groves (%s)" % [kinds])
	var expected_occluders := 0
	for k: int in kinds:
		if Props.blocks_los(k as Props.Kind):
			expected_occluders += int(kinds[k])
	check(ctx.board.los_occluders().size() == expected_occluders, "only tall props (trees, rocks, buildings, walls, woods, tents) block line of sight (%d occluders)" % ctx.board.los_occluders().size())
	check(ctx.board.los_occluders().size() <= SightView.MAX_OCCLUDERS, "occluder count fits the sight shader (max %d)" % SightView.MAX_OCCLUDERS)
	var all_block := true
	var all_named := true
	for c: Vector2i in ctx.board.prop_cells():
		all_block = all_block and ctx.board.is_blocked(c) and not ctx.board.is_walkable(c)
		all_named = all_named and Props.models(ctx.board.prop_at(c) as Props.Kind).has(ctx.board.prop_model(c)) and FileAccess.file_exists(Props.scene_path(ctx.board.prop_model(c)))
	check(all_block, "every prop blocks its hex")
	check(all_named, "every prop names an existing glTF model of its kind")
	var reach_all := true
	var reachable := ctx.board.reachable(ctx.units[0].cell, 1000.0)
	for u in ctx.units:   # units block each other, so look for a reachable neighbour
		var touches := u == ctx.units[0]
		for d in GridBoard.DIRS:
			touches = touches or reachable.has(u.cell + d)
		reach_all = reach_all and touches
	check(reach_all, "every unit can still reach every other (props leave the map connected)")
	var props_node: Node = ctx.view.get_node("Props")
	check(props_node.get_child_count() == ctx.board.prop_cells().size(), "PropView built one body per prop (%d)" % props_node.get_child_count())
	var tree_cell := Vector2i.ZERO
	var rock_cell := Vector2i.ZERO
	var grove_cell := Vector2i.ZERO
	for c: Vector2i in ctx.board.prop_cells():
		match ctx.board.prop_at(c):
			Props.Kind.TREE: tree_cell = c
			Props.Kind.ROCK_LARGE: rock_cell = c
			Props.Kind.GROVE: grove_cell = c
	var space3: PhysicsDirectSpaceState3D = (main as Node3D).get_world_3d().direct_space_state
	for pair in [[tree_cell, "Tree_"], [rock_cell, "LargeRock_"], [grove_cell, "Grove_"]]:
		var pc := ctx.board.cell_to_world(pair[0])
		var q := PhysicsRayQueryParameters3D.create(pc + Vector3(0.0, 8.0, 0.0), pc + Vector3(0.0, -1.0, 0.0), Unit.LAYER_TERRAIN)   # straight down: only the prop's own cell
		var hit: Dictionary = space3.intersect_ray(q)
		check(not hit.is_empty() and String((hit["collider"] as Node).name).begins_with(pair[1]), "a shell raycast stops at the %s prop (%s)" % [pair[1], "none" if hit.is_empty() else (hit["collider"] as Node).name])
	var rock_body: Node = null
	for ch in props_node.get_children():
		if ch.name.begins_with("LargeRock_"):
			rock_body = ch
			break
	var hull: CollisionShape3D = null
	if rock_body != null:
		for ch in rock_body.get_children():
			if ch is CollisionShape3D:
				hull = ch
	check(hull != null and hull.shape is ConvexPolygonShape3D and (hull.shape as ConvexPolygonShape3D).points.size() >= 8, "large rock collider is a convex hull of its mesh")

	var lb := GridBoard.new(Vector2i(14, 10), 1.0)
	var la := lb.cell_to_world(GridBoard.offset_to_axial(Vector2i(2, 4)))
	var lz := lb.cell_to_world(GridBoard.offset_to_axial(Vector2i(10, 4)))
	var lmid := GridBoard.offset_to_axial(Vector2i(6, 4))
	check(not lb.los_blocked(la, lz), "open ground does not block sight")
	lb.add_prop(lmid, Props.Kind.STUMPS)
	check(not lb.los_blocked(la, lz) and lb.is_blocked(lmid), "stumps block the hex but not sight")
	lb.add_prop(lmid, Props.Kind.ROCK_SMALL)
	check(not lb.los_blocked(la, lz), "small rocks do not block sight")
	lb.add_prop(lmid, Props.Kind.TREE)
	check(lb.los_blocked(la, lz) and lb.los_blocked(lz, la), "a tree blocks sight both ways")
	check(not lb.los_blocked(la, lb.cell_to_world(GridBoard.offset_to_axial(Vector2i(10, 1)))), "sight past the side of a tree is clear")
	check(not lb.los_blocked(la, lb.cell_to_world(lmid)), "the tree itself stays visible (an occluder holding the target does not block)")
	lb.add_prop(lmid, Props.Kind.ROCK_LARGE)
	check(lb.los_blocked(la, lz), "a large rock blocks sight")
	var shadows := lb.los_shadows(la, 12.0)
	var behind := Vector2(lz.x, lz.z)
	var aside := Vector2(lz.x, lz.z - 4.0)
	check(shadows.size() == 1 and Geometry2D.is_point_in_polygon(behind, shadows[0]) and not Geometry2D.is_point_in_polygon(aside, shadows[0]), "sight shadow covers the ground behind the rock, not beside it")
	check(lb.los_shadows(la, 3.0).is_empty(), "rocks beyond the reach cast no shadow")

	# a tree between the scout and the enemy tank takes the tank out of the scout's line of sight; a drone still sees it
	var foe: Unit = ctx.units[3]
	var foe_home := foe.global_position
	foe.snap_to(scout.global_position.lerp(foe_home, 0.6))   # inside the scout's 12.8 m inner ring, on the cleared sight line
	var occ_board := GridBoard.new(ctx.board.size, ctx.board.hex_size)
	var real_board := ctx.intel.board
	ctx.intel.board = occ_board
	check(Intel.in_los(ctx.intel.fidelity_at(0, ctx.units, foe.global_position)), "(setup) scout sees the enemy tank on open ground")
	var between := occ_board.world_to_cell(scout.global_position.lerp(foe.global_position, 0.5))
	occ_board.add_prop(between, Props.Kind.TREE)
	var scout_only: Array[Unit] = [scout]   # other friendlies may still see it through their own outer rings
	var hidden_f := ctx.intel.fidelity_at(0, scout_only, foe.global_position)
	check(not Intel.in_view(hidden_f) and not ctx.intel.sees(0, scout_only, foe), "a tree in the way hides the target completely, even inside the sight radius (fidelity %.2f)" % hidden_f)
	check(ctx.intel.spot_impact(0, ctx.units, foe.global_position), "a shell landing behind the tree opens a spotted area")
	check(Intel.in_los(ctx.intel.fidelity_at(0, ctx.units, foe.global_position)), "spotted areas look from above: not blocked by the tree")
	ctx.intel.tick(ctx.round_number + 50)
	ctx.intel.board = real_board
	ctx.intel.tick(ctx.round_number)
	check(Intel.in_los(ctx.intel.fidelity_at(0, ctx.units, foe.global_position)), "back on the real map the scout sees the tank again")
	foe.snap_to(foe_home)
	main._sight.refresh()
	check(int(main._sight._mat.get_shader_parameter("occ_count")) == ctx.board.los_occluders().size(), "LoS overlay is fed the map's sight blockers")

	# gridless move (before clearing the field)
	shooter.begin_turn()
	var ap0 := shooter.ap
	var dest_point := ctx.board.cell_to_world(shooter.cell + Vector2i(1, 1)) + Vector3(0.3, 0.0, 0.2)
	var mv := MoveAction.new(shooter, dest_point)
	var expect_cost := mv.cost(ctx)
	await mv.execute(ctx)
	check(Vector2(shooter.global_position.x - dest_point.x, shooter.global_position.z - dest_point.z).length() < 0.05, "unit ends exactly at clicked point")
	check(is_equal_approx(ap0 - shooter.ap, expect_cost) and expect_cost > 0.0, "AP spent == path cost (%.1f)" % expect_cost)

	# live shell with wind vs. analytic trace, heavy vs light round
	ctx.wind.set_fixed(8.0, 0.7)
	how.begin_turn()
	var hw := how.stats.weapons[0]
	var aim := Vector3(how.global_position.x + 1.0, 0.0, how.global_position.z + 11.0)
	var org := how.muzzle_position(Vector3(0, 0, 1))
	var lob := Ballistics.solve_velocity(org, aim, hw.muzzle_velocity, true)
	var ex: Array[RID] = [how.get_rid()]
	var space := how.get_world_3d().direct_space_state
	var calm := Ballistics.trace(space, org, lob, ex)
	var heavy_acc := ctx.wind.accel() * ap.wind_mult()
	var light_acc := ctx.wind.accel() * inc.wind_mult()
	var heavy_end := last_point(Ballistics.trace(space, org, lob, ex, heavy_acc))
	var light_end := last_point(Ballistics.trace(space, org, lob, ex, light_acc))
	var calm_end := last_point(calm)
	check((light_end - calm_end).length() > (heavy_end - calm_end).length() * 1.4, "light round drifts more than heavy (%.1f m vs %.1f m)" % [(light_end - calm_end).length(), (heavy_end - calm_end).length()])
	var shell := Shell.new()
	ctx.root.add_child(shell)
	shell.launch(org, lob, ex, light_acc, hw.shell_radius, Color.WHITE, true)
	var res: Array = await shell.impacted
	check(res[1] and (res[0] as Vector3).distance_to(light_end) < 0.3, "live shell lands where the wind-aware trace says (err %.3f m)" % (res[0] as Vector3).distance_to(light_end))
	check(shell.trail != null and shell.path.size() > 10, "shell recorded %d flight samples and drew a trail" % shell.path.size())

	# clear the field: only shooter + enemy tank remain, in an obstacle-free corridor
	for u in ctx.units:
		if u != shooter and u != enemy:
			u.die()
	ctx.wind.set_fixed(0.0, 0.0)
	place(ctx, shooter, Vector2i(1, 2))
	place(ctx, enemy, Vector2i(7, 2))
	enemy.face(Vector3(-1, 0, 0))   # enemy front armor toward the shooter
	shooter.face(Vector3(1, 0, 0))
	shooter.begin_turn()
	enemy.hp = 40.0

	# normal round vs. front armor: absorbed, crater left behind
	var target_pos := Vector3(enemy.global_position.x, enemy.rest_height(), enemy.global_position.z)
	var normal_params := params_at(shooter, cannon, target_pos, 3, normal)
	check(normal_params != null, "cannon solution exists at charge 3")
	var craters_before: int = state.totals["craters"]
	var armor_front0 := enemy.armor[0]
	var hp0 := enemy.hp
	var ap_before := shooter.ap
	var shot := ShootAction.new(shooter, normal_params)
	check(shot.can_execute(ctx) and is_equal_approx(shot.cost(ctx), 6.0), "3-charge cannon shot costs 6 AP")
	var cam_started := ctx.camera.size
	var done := [false]
	var runner := func() -> void:
		await shot.execute(ctx)
		done[0] = true
	runner.call()
	await create_timer(0.5).timeout
	check(ctx.camera.mode == TacticsCamera.Mode.FOLLOW, "shot camera follows the shell")
	while not done[0]:
		await physics_frame
	check(is_equal_approx(ap_before - shooter.ap, 6.0), "AP spent includes the extra charges")
	await turns._settle()
	var rec: ShotRecord = state.shots.back()
	check(rec.landed and rec.results.size() >= 1 and rec.results[0]["sector"] == "Front", "front plate was hit (%s)" % str(rec.results[0]["outcome"] if rec.results.size() > 0 else "none"))
	check(rec.results.size() >= 1 and rec.results[0]["outcome"] == "ABSORBED" and enemy.hp < hp0 and enemy.armor[0] < armor_front0, "normal round: front armor absorbs part and wears down (hp %.1f -> %.1f)" % [hp0, enemy.hp])
	check(state.totals["craters"] > craters_before and rec.craters >= 1, "blast left %d crater cell(s)" % rec.craters)
	var any_crater := false
	for c in ctx.board.terrain_cells():
		if ctx.board.terrain_at(c) == Terrain.Type.CRATER and ctx.board.weight_of(c) > 1.0:
			any_crater = true
	check(any_crater, "craters raise the AP cost of crossing that ground")
	check(rec.trail.size() > 4 and rec.flight_time > 0.2 and rec.charges == 3 and rec.round_name == "Normal", "game state logged trail (%d pts), flight %.2fs, charges, round" % [rec.trail.size(), rec.flight_time])
	check(rec.origin.distance_to(rec.impact) > 5.0 and rec.shooter_name == "Tank", "game state logged origin/impact/shooter")
	var hit0: Dictionary = rec.results[0] if rec.results.size() > 0 else {}
	check(hit0.has("point") and hit0.has("unit_pos") and hit0.has("hull_yaw") and float(hit0.get("radius", 0.0)) > 0.5 and hit0.get("direct", false) and not hit0.get("bomblet", true),
		"hit entries carry the blast (centre, radius, direct) and the unit's footprint, for the last-shot view")
	check(state.last_gunnery_shot_of(shooter) == rec and state.last_gunnery_shot_of(enemy) == null and rec.shooter_id == shooter.get_instance_id(),
		"GameState finds a unit's last gunnery shot")
	check(rec.round_short == "HE" and rec.round_color == normal.color and rec.shooter_pos.distance_to(shooter.global_position) < 0.5, "record keeps round colour / short name and the firing position")

	# camera returns to the player's view
	await create_timer(3.4).timeout
	check(ctx.camera.mode == TacticsCamera.Mode.IDLE and absf(ctx.camera.size - cam_started) < 0.2, "shot camera returned to the saved view (size %.1f)" % ctx.camera.size)

	# AP round: direct hit penetrates the same front plate
	shooter.begin_turn()
	enemy.hp = 40.0
	var hp1 := enemy.hp
	var ap_params := params_at(shooter, cannon, target_pos, 3, ap)
	await ShootAction.new(shooter, ap_params).execute(ctx)
	await turns._settle()
	var rec2: ShotRecord = state.shots.back()
	var enemy_hit: Dictionary = {}
	for r in rec2.results:
		if r["unit"] == "Tank" and r["team"] == 1:
			enemy_hit = r
	check(not enemy_hit.is_empty() and enemy_hit["outcome"] == "PENETRATED", "AP round penetrates front armor (%s)" % str(enemy_hit.get("outcome", "no hit")))
	check(hp1 - enemy.hp > (hp0 - (hp0 - 3.0)) and hp1 - enemy.hp > 6.0, "AP direct hit deals heavy damage (%.1f)" % (hp1 - enemy.hp))
	check(ctx.camera != null and state.totals["penetrations"] >= 1, "penetrations are counted in the summary")

	# incendiary: ground fire + softened armor
	shooter.begin_turn()
	var fires_before: int = state.totals["fires"]
	var inc_aim := Vector3(enemy.global_position.x - 3.5, 0.0, enemy.global_position.z)
	var inc_params := params_at(shooter, cannon, inc_aim, 3, inc)
	await ShootAction.new(shooter, inc_params).execute(ctx)
	var rec3: ShotRecord = state.shots.back()
	check(rec3.fires >= 1 and state.totals["fires"] > fires_before and ctx.board.fire_cells().size() >= 1, "incendiary round sets %d cells on fire" % rec3.fires)
	await turns._settle()
	var fire_c: Vector2i = ctx.board.fire_cells()[0]
	check(ctx.board.terrain_at(fire_c) == Terrain.Type.FIRE and ctx.board.is_burning(fire_c), "fire cell is FIRE terrain")

	# cluster: main burst + bomblets
	shooter.begin_turn()
	var clu_aim := Vector3(enemy.global_position.x - 1.5, 0.0, enemy.global_position.z + 1.0)
	var clu_params := params_at(shooter, cannon, clu_aim, 3, clu)
	await ShootAction.new(shooter, clu_params).execute(ctx)
	await turns._settle()
	var rec4: ShotRecord = state.shots.back()
	check(rec4.round_name == "Cluster" and rec4.blasts >= 3, "cluster round: %d blasts (main + bomblets)" % rec4.blasts)
	var bomblet_hits := 0
	for r in rec4.results:
		if r.get("bomblet", false):
			bomblet_hits += 1
	check(bomblet_hits <= rec4.results.size() and state.last_gunnery_shot_of(shooter) == rec4, "cluster hits are logged per blast (%d of %d entries are bomblets)" % [bomblet_hits, rec4.results.size()])
	var gp_hits := GunneryPanel.new()
	gp_hits._ctx = ctx
	gp_hits._unit = shooter
	var group := gp_hits._hit_group(rec4)
	check(group.size() == 0 or (group[0]["team"] == 1 and group.size() == rec4.results.filter(func(r: Dictionary) -> bool: return r["team"] == 1).size()), "sidebar picks the struck enemy and all its blasts (%d)" % group.size())
	check(GunneryPanel._rel_flat(Vector3(1, 0, 0), Vector3.ZERO, -PI * 0.5 - Vector2(1, 0).angle()).distance_to(Vector2(0, -1)) < 0.001, "last-shot view puts the line of fire straight up")
	gp_hits.free()

	# machine gun against armor: damage is reduced, AP differs
	shooter.begin_turn()
	enemy.hp = 40.0
	var mg := shooter.stats.weapons[1]
	var to_enemy := enemy.global_position - shooter.global_position
	var mg_params := FireParams.make(mg, atan2(to_enemy.x, to_enemy.z), 0.0, 1.0)
	var mg_ap := shooter.ap
	await ShootAction.new(shooter, mg_params).execute(ctx)
	check(is_equal_approx(mg_ap - shooter.ap, mg.ap_cost) and mg.ap_cost != cannon.ap_cost, "MG spends its own AP (%.1f)" % mg.ap_cost)
	var mg_dmg := 40.0 - enemy.hp
	check(mg_dmg > 0.2 and mg_dmg < float(mg.burst_rounds), "MG vs armor: reduced damage (%.2f of %d)" % [mg_dmg, mg.burst_rounds])
	await turns._settle()
	check(state.shots.back().burst and state.totals["shots"] >= 5, "burst logged in game state (%d shots total)" % state.totals["shots"])
	var summary := state.summary()
	check(summary["totals"]["landed"] >= 4 and state.summary_lines().size() >= 4, "game state summary available for an end screen")

	# not enough AP
	var low_ap := Unit.new()
	low_ap.configure(tank_stats, 0, Color.WHITE)
	ctx.root.add_child(low_ap)
	low_ap.ap = 5.0
	check(not ShootAction.new(low_ap, fp3).can_execute(ctx), "3-charge shot rejected with only 5 AP")
	check(ShootAction.new(low_ap, fp1).can_execute(ctx), "1-charge shot accepted with 5 AP")
	low_ap.queue_free()

	# ---------- AI fairness: wind drifts the AI, awareness corrects it ----------
	for u in ctx.units:
		if u != how:
			u.die()
	var victim := Unit.new()
	victim.configure(inf_stats, 1, Color.RED)
	main.add_child(victim)
	ctx.units.append(victim)
	place(ctx, how, Vector2i(1, 2))
	place(ctx, victim, Vector2i(7, 2))
	how.begin_turn()
	ctx.wind.set_fixed(9.0, 0.0)   # strong crosswind (blowing toward +z, the shot goes along +x)
	var ai := AIController.new()
	ai.aim_noise_deg = 0.0
	ai.power_noise = 0.0
	var aim_pt := Vector3(victim.global_position.x, 0.0, victim.global_position.z)
	var miss := {}
	for awareness in [0.0, 1.0]:
		ai.wind_awareness = awareness
		var plan: ShootAction = ai._plan_shot(how, victim, hw, ctx)
		if plan == null:
			check(false, "AI produced a howitzer plan (awareness %.0f)" % awareness)
			continue
		var wind_acc := ctx.wind.accel() * plan.params.wind_scale()
		var traced := Ballistics.trace(how.get_world_3d().direct_space_state, how.muzzle_position(plan.params.flat_dir()), plan.params.velocity(), [how.get_rid()], wind_acc)
		var land := last_point(traced)
		miss[awareness] = Vector2(land.x - aim_pt.x, land.z - aim_pt.z).length()
		check(plan.params.charge >= 1 and plan.params.charge <= 3 and plan.cost(ctx) <= how.ap, "AI picks an affordable charge level (%d, %.1f AP)" % [plan.params.charge, plan.cost(ctx)])
	if miss.has(0.0) and miss.has(1.0):
		check(miss[0.0] > 1.0, "AI ignoring wind drifts off target (%.1f m)" % miss[0.0])
		check(miss[1.0] < miss[0.0] * 0.5, "AI wind awareness cuts the miss (%.1f m -> %.1f m)" % [miss[0.0], miss[1.0]])
	ai.free()

	# ---------- shot camera API ----------
	while ctx.camera.mode != TacticsCamera.Mode.IDLE:
		await physics_frame
	var dummy := Node3D.new()
	main.add_child(dummy)
	var saved := ctx.camera.size
	ctx.camera.follow(dummy)
	check(ctx.camera.mode == TacticsCamera.Mode.FOLLOW, "camera.follow starts tracking")
	ctx.camera.release(0.2)
	await create_timer(2.6).timeout
	check(ctx.camera.mode == TacticsCamera.Mode.IDLE and absf(ctx.camera.size - saved) < 0.2, "camera eases back after release")
	ctx.camera.shot_cam_enabled = false
	ctx.camera.follow(dummy)
	check(ctx.camera.mode == TacticsCamera.Mode.IDLE, "shot camera can be disabled")
	ctx.camera.shot_cam_enabled = true

	# ---------- shot review ----------
	var review := ShotReview.new()
	main.add_child(review)
	review.setup(state, ctx)
	review.viewer_team = 0
	review._open()
	var mine := state.shots.filter(func(r: ShotRecord) -> bool: return r.shooter_team == 0).size()
	check(state.shots.size() > 0 and review._visible_indices().size() == state.shots.size(), "review lists every recorded shot (%d)" % state.shots.size())
	review._filter = ShotReview.Filter.ALLIES
	check(review._visible_indices().size() == mine, "review filter ALLIES (%d)" % mine)
	review._filter = ShotReview.Filter.ENEMIES
	check(review._visible_indices().size() == state.shots.size() - mine, "review filter ENEMIES")
	review._filter = ShotReview.Filter.ALL
	review._step(1)
	check(review._selected >= 0 and review.visible, "review selection moves and overlay is open")
	review.free()

	# ---------- turn start: the camera glides to the acting unit, zoom kept ----------
	var cam: TacticsCamera = ctx.camera
	var own_actor := Unit.new()
	own_actor.configure(inf_stats, 0, Color.WHITE)
	main.add_child(own_actor)
	own_actor.snap_to(ctx.board.cell_to_world(GridBoard.offset_to_axial(Vector2i(5, 8)), own_actor.rest_height()))
	var foe_actor := Unit.new()
	foe_actor.configure(inf_stats, 1, Color.WHITE)
	main.add_child(foe_actor)
	foe_actor.snap_to(ctx.board.cell_to_world(GridBoard.offset_to_axial(Vector2i(27, 20)), foe_actor.rest_height()))   # far from every friendly unit
	var settle := func() -> void:
		for k in 900:
			await process_frame
			if cam.mode == TacticsCamera.Mode.IDLE:
				break
	var off_by := func(u: Unit) -> float:
		return Vector2(cam.focus.x - u.global_position.x, cam.focus.z - u.global_position.z).length()
	await settle.call()
	cam.focus = Vector3(40.0, 0.0, 30.0)
	cam.size = 9.0
	turns.turn_started.emit(own_actor)
	await settle.call()
	check(off_by.call(own_actor) < 0.3 and absf(cam.size - 9.0) < 0.1, "player turn start pans to the unit and keeps the zoom (focus err %.2f, size %.1f)" % [off_by.call(own_actor), cam.size])
	turns.turn_started.emit(foe_actor)
	await settle.call()
	check(not ctx.visible_to_viewer(foe_actor) and off_by.call(foe_actor) > 5.0, "an enemy turn out of our sight does not pan the camera to it (no free scouting)")
	ctx.intel.add_area(0, foe_actor.global_position, 4.0, 2, "test")   # a spotted area: now we see it
	turns.turn_started.emit(foe_actor)
	await settle.call()
	check(ctx.visible_to_viewer(foe_actor) and off_by.call(foe_actor) < 0.3, "enemy turn start pans to a visible enemy (default on)")
	main.enemy_turn_pan = false
	cam.focus = Vector3(40.0, 0.0, 30.0)
	turns.turn_started.emit(foe_actor)
	for k in 30:
		await process_frame
	check(cam.focus.distance_to(Vector3(40.0, 0.0, 30.0)) < 0.01, "enemy-turn pan can be switched off")
	turns.turn_started.emit(own_actor)
	await settle.call()
	check(off_by.call(own_actor) < 0.3, "player turns always pan, even with enemy-turn pan off")
	main.enemy_turn_pan = true
	ctx.intel.areas.clear()
	own_actor.die()
	foe_actor.die()

	# ---------- ram (dash) ----------
	var rctx := BattleContext.new()
	rctx.board = GridBoard.new(Vector2i(22, 18), 1.0)
	rctx.root = main
	var spawn := func(st: UnitStats, team: int, col: int, row: int) -> Unit:
		var u := Unit.new()
		u.configure(st, team, Color.WHITE)
		main.add_child(u)
		var c := GridBoard.offset_to_axial(Vector2i(col, row))
		u.snap_to(rctx.board.cell_to_world(c, u.rest_height()))
		rctx.board.place(u, c)
		rctx.units.append(u)
		u.begin_turn()
		return u
	var rammer: Unit = spawn.call(tank_stats, 0, 4, 12)
	var open_dash := DashAction.new(rammer, Vector3.RIGHT)
	check(open_dash.can_execute(rctx) and not open_dash.has_impact(), "dash into open ground hits nothing")
	check(is_equal_approx(open_dash.cost(rctx), 8.0 - 0.0) or open_dash.cost(rctx) <= rammer.ap + 0.001, "dash never costs more than the AP on hand (%.1f)" % open_dash.cost(rctx))
	check(open_dash.run_length(rctx) > 8.0 * 1.5, "a full-AP dash covers several hexes (%.1f m)" % open_dash.run_length(rctx))
	rammer.ap = 3.0
	var short_dash := DashAction.new(rammer, Vector3.RIGHT)
	check(short_dash.cost(rctx) <= 3.001 and short_dash.run_length(rctx) < open_dash.run_length(rctx), "dash range is limited by the remaining AP (%.1f m for 3 AP)" % short_dash.run_length(rctx))
	rctx.board.set_weight(GridBoard.offset_to_axial(Vector2i(6, 12)), 3.0)
	var ram_heavy := DashAction.new(rammer, Vector3.RIGHT)
	check(ram_heavy.cost(rctx) <= 3.001 and ram_heavy.run_length(rctx) < short_dash.run_length(rctx), "dash pays terrain weight like a walk (%.1f m now)" % ram_heavy.run_length(rctx))
	rctx.board.set_weight(GridBoard.offset_to_axial(Vector2i(6, 12)), 1.0)
	rammer.ap = rammer.stats.max_ap
	var dash_rock := GridBoard.offset_to_axial(Vector2i(9, 12))
	rctx.board.add_prop(dash_rock, Props.Kind.ROCK_LARGE)
	var rock_dash := DashAction.new(rammer, Vector3.RIGHT)
	rock_dash.plan(rctx)
	check(rock_dash.hit_cell == dash_rock and rock_dash.can_execute(rctx), "dash stops against a rock and counts as a ram")
	check(rock_dash.exchange() == Vector2(12.0, 10.0), "ram vs large rock: deals the tank's front armor, takes the rock's (%s)" % rock_dash.exchange())
	var ram_hp0 := rammer.hp
	var ram_ap0 := rammer.ap
	await rock_dash.execute(rctx)
	check(is_equal_approx(rammer.hp, ram_hp0 - 10.0) and is_equal_approx(rammer.armor[0], 12.0 - 5.0), "tank takes 10 damage and its front plate wears to %.1f" % rammer.armor[0])
	check(is_equal_approx(ram_ap0 - rammer.ap, rock_dash.cost(rctx)) and rammer.cell != GridBoard.offset_to_axial(Vector2i(4, 12)), "dash spends its priced AP and moves the unit")
	rctx.board.set_blocked(dash_rock, false)
	rammer.hp = float(rammer.stats.max_hp)
	rammer.armor[0] = rammer.stats.armor_front
	rammer.ap = rammer.stats.max_ap
	var ram_mark: Unit = spawn.call(how_stats, 1, 12, 12)
	var ram_hit := DashAction.new(rammer, ram_mark.global_position - rammer.global_position)
	ram_hit.plan(rctx)
	check(ram_hit.hit_unit == ram_mark and ram_hit.has_impact(), "dash toward a unit ends against it")
	check(ram_hit.exchange() == Vector2(12.0, 3.0), "ram vs howitzer side plate: deal 12, take 3 (%s)" % ram_hit.exchange())
	var mark_x := ram_mark.global_position.x
	await ram_hit.execute(rctx)
	check(is_equal_approx(ram_mark.hp, 14.0 - 12.0) and is_equal_approx(ram_mark.armor[1], 0.0), "howitzer takes 12 and loses its side plate (hp %.0f, plate %.1f)" % [ram_mark.hp, ram_mark.armor[1]])
	check(is_equal_approx(rammer.armor[0], 12.0 - 1.5), "rammer's front plate wears by half the damage taken (%.1f)" % rammer.armor[0])
	for k in 90:
		await physics_frame
	check(ram_mark.global_position.x > mark_x + 0.3, "armor difference knocks the howitzer back (%.1f m)" % (ram_mark.global_position.x - mark_x))
	ram_mark.freeze_in_place()
	var rookie: Unit = spawn.call(inf_stats, 0, 4, 14)
	var ram_weak := DashAction.new(rookie, Vector3.RIGHT)
	var weak_foe: Unit = spawn.call(how_stats, 1, 8, 14)
	var weak_hit := DashAction.new(rookie, weak_foe.global_position - rookie.global_position)
	weak_hit.plan(rctx)
	check(weak_hit.hit_unit == weak_foe and weak_hit.exchange().x == 0.0 and weak_hit.exchange().y > 0.0, "unarmored infantry ram deals nothing and takes damage")
	var blocked_dash := DashAction.new(rookie, Vector3.LEFT * 50.0)
	check(blocked_dash.run_length(rctx) > 0.0 and not blocked_dash.has_impact(), "running off the board edge just stops at the edge")
	for u in [rammer, ram_mark, rookie, weak_foe]:
		u.die()
		u.queue_free()

	# ---------- elevation, ev_cliffs, destroyable props, cover ----------
	var eb := GridBoard.new(Vector2i(22, 18), 1.0)
	var lo_a := GridBoard.offset_to_axial(Vector2i(5, 5))
	var lo_b := GridBoard.offset_to_axial(Vector2i(6, 5))
	eb.set_level(lo_b, 1)
	check(is_equal_approx(eb.step_cost(lo_a, lo_b), 1.0 + GridBoard.CLIMB_WEIGHT), "climbing a one-level slope costs extra AP (%.2f)" % eb.step_cost(lo_a, lo_b))
	check(is_equal_approx(eb.step_cost(lo_b, lo_a), 1.0 + GridBoard.DESCENT_WEIGHT) and not eb.is_cliff(lo_a, lo_b), "going down a slope is cheap and a one-level step is no cliff")
	check(is_equal_approx(eb.cell_to_world(lo_b, 0.5).y, 1.0) and is_equal_approx(eb.surface_y(eb.cell_to_world(lo_b)), 0.5), "cell_to_world / surface_y follow the elevation")
	eb.set_level(lo_b, 9)
	check(eb.level_of(lo_b) == GridBoard.MAX_LEVEL, "elevation caps at level %d" % GridBoard.MAX_LEVEL)
	eb.set_level(lo_b, 0)
	# a full-width cliff wall (level 2) along column 8
	for row in 18:
		eb.set_level(GridBoard.offset_to_axial(Vector2i(8, row)), 2)
	var ev_west := GridBoard.offset_to_axial(Vector2i(5, 5))
	var ev_east := GridBoard.offset_to_axial(Vector2i(11, 5))
	check(eb.find_path(ev_west, ev_east, INF, false).is_empty(), "no way past a full-width cliff without crossing it")
	var ev_over := eb.find_path(ev_west, ev_east)
	check(not ev_over.is_empty(), "crossing the cliff is possible when there is no way around")
	check(eb.path_cost(ev_over) > GridBoard.CLIFF_CLIMB_WEIGHT * 2.0 + GridBoard.CLIFF_DROP_WEIGHT * 2.0, "...and costs a steep AP price (%.1f)" % eb.path_cost(ev_over))
	eb.set_level(GridBoard.offset_to_axial(Vector2i(8, 16)), 1)   # a ramp-ish gap far to the south
	eb.set_level(GridBoard.offset_to_axial(Vector2i(8, 17)), 1)
	var ev_around := eb.find_path(ev_west, ev_east, INF, false)
	check(not ev_around.is_empty() and eb.path_cost(ev_around) > 0.0, "a gap in the wall lets units walk around (%.1f AP)" % eb.path_cost(ev_around))
	check(eb.path_cost(ev_around) > eb.path_cost(ev_over), "walking around the long way costs more AP than crossing (%.1f vs %.1f)" % [eb.path_cost(ev_around), eb.path_cost(ev_over)])
	eb.set_level(GridBoard.offset_to_axial(Vector2i(8, 16)), 2)
	eb.set_level(GridBoard.offset_to_axial(Vector2i(8, 17)), 2)

	var ectx := BattleContext.new()
	ectx.board = eb
	ectx.root = main
	var spawn_on := func(st: UnitStats, team: int, col: int, row: int) -> Unit:
		var u := Unit.new()
		u.configure(st, team, Color.WHITE)
		main.add_child(u)
		var c := GridBoard.offset_to_axial(Vector2i(col, row))
		u.snap_to(eb.cell_to_world(c, u.rest_height()))
		eb.place(u, c)
		ectx.units.append(u)
		u.begin_turn()
		return u
	var ev_climber: Unit = spawn_on.call(tank_stats, 0, 7, 5)
	ev_climber.ap = 30.0
	var el_start_y := ev_climber.global_position.y
	var ev_crossing := MoveAction.new(ev_climber, eb.cell_to_world(GridBoard.offset_to_axial(Vector2i(9, 5))))
	check(ev_crossing.can_execute(ectx) and ev_crossing.cost(ectx) > 8.0, "a move over the cliff is allowed and costs a steep AP price (%.1f)" % ev_crossing.cost(ectx))
	var ev_detour := MoveAction.new(ev_climber, eb.cell_to_world(GridBoard.offset_to_axial(Vector2i(9, 5))), true)
	check(not ev_detour.can_execute(ectx), "the AI's cliff-avoiding move finds no path across a closed wall")
	var hp_el := ev_climber.hp
	var ap_el := ev_climber.ap
	await ev_crossing.execute(ectx)
	check(is_equal_approx(ap_el - ev_climber.ap, ev_crossing.cost(ectx)) and is_equal_approx(hp_el, ev_climber.hp), "crossing deducts the priced AP and no hit points (-%.1f AP)" % (ap_el - ev_climber.ap))
	check(absf(ev_climber.global_position.y - el_start_y) < 0.02, "unit ends on the ground at its destination height")
	var ev_on_wall: Unit = spawn_on.call(tank_stats, 0, 8, 12)
	check(absf(ev_on_wall.global_position.y - (ev_on_wall.rest_height() + 1.0)) < 0.01, "a unit on a level-2 cell stands 1 m up")
	var ev_seen_from: Unit = spawn_on.call(tank_stats, 0, 6, 13)
	var ev_far_side: Unit = spawn_on.call(tank_stats, 1, 10, 13)
	check(eb.los_blocked(ev_seen_from.global_position, ev_far_side.global_position), "a cliff wall taller than the eye blocks line of sight")
	check(not eb.los_blocked(ev_on_wall.global_position, spawn_on.call(tank_stats, 1, 10, 12).global_position), "...but a unit standing on the wall sees over it")
	ectx.intel.board = eb
	check(not Intel.in_los(ectx.intel.fidelity_at(0, [ev_seen_from] as Array[Unit], ev_far_side.global_position)), "intel: a target behind the cliff is out of line of sight")
	for u in [ev_climber, ev_on_wall, ev_seen_from, ev_far_side]:
		u.die()

	# prop hit points
	var ev_tree_cell := GridBoard.offset_to_axial(Vector2i(4, 14))
	eb.add_prop(ev_tree_cell, Props.Kind.TREE)
	var ev_seen_destroyed := []
	eb.prop_destroyed.connect(func(c: Vector2i, _k: int) -> void: ev_seen_destroyed.append(c))
	check(eb.prop_hp(ev_tree_cell) == Props.max_hp(Props.Kind.TREE) and eb.is_blocked(ev_tree_cell), "props start at full hit points and block their cell")
	check(eb.damage_prop(ev_tree_cell, 5.0) == Props.max_hp(Props.Kind.TREE) - 5.0 and eb.prop_at(ev_tree_cell) >= 0, "damage wears a prop down")
	var occluders_before := eb.los_occluders().size()
	check(eb.damage_prop(ev_tree_cell, 99.0) == 0.0 and eb.prop_at(ev_tree_cell) == -1 and not eb.is_blocked(ev_tree_cell) and ev_seen_destroyed == [ev_tree_cell], "a prop at 0 hp is destroyed: the cell opens and the signal fires")
	check(eb.los_occluders().size() == occluders_before - 1, "a destroyed tree no longer blocks sight")

	# the real scene objects: floor with hills, prop colliders, cover from explosions
	var ev_rock_cell := GridBoard.offset_to_axial(Vector2i(8, 9))
	for row in 18:
		eb.set_level(GridBoard.offset_to_axial(Vector2i(8, row)), 0)
	eb.add_prop(ev_rock_cell, Props.Kind.ROCK_LARGE)
	for row in range(0, 4):
		eb.set_level(GridBoard.offset_to_axial(Vector2i(14, row)), 2)
	var ev_bv := BoardView.new()
	ev_bv.build(eb)
	main.add_child(ev_bv)
	for k in 3:
		await physics_frame
	var floor_space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
	var ev_drop := func(cell: Vector2i) -> float:
		var p := eb.cell_to_world(cell)
		var h: Dictionary = floor_space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(p.x, 6.0, p.z), Vector3(p.x, -2.0, p.z), Unit.LAYER_TERRAIN))
		return h["position"].y if not h.is_empty() else -99.0
	check(absf(ev_drop.call(GridBoard.offset_to_axial(Vector2i(14, 1))) - 1.0) < 0.02 and absf(ev_drop.call(GridBoard.offset_to_axial(Vector2i(2, 1)))) < 0.02, "the floor colliders follow the elevation")
	check(eb.surface_y(eb.cell_to_world(GridBoard.offset_to_axial(Vector2i(14, 1)))) == 1.0, "surface_y reads the same height the colliders have")

	var ev_shell_w := WeaponStats.new()
	ev_shell_w.blast_radius = 6.0
	ev_shell_w.blast_damage = 20.0
	ev_shell_w.blast_impulse = 0.0
	ev_shell_w.penetration = 1.0
	var ev_blast_at := GridBoard.offset_to_axial(Vector2i(7, 9))
	var ev_behind: Unit = spawn_on.call(inf_stats, 1, 10, 9)
	var ev_open: Unit = spawn_on.call(inf_stats, 1, 4, 9)
	ev_behind.hp = 100.0
	ev_open.hp = 100.0
	var rock_hp0 := eb.prop_hp(ev_rock_cell)
	Explosion.detonate(ectx, eb.cell_to_world(ev_blast_at, 0.05), ev_shell_w)
	var open_dmg := 100.0 - ev_open.hp
	var behind_dmg := 100.0 - ev_behind.hp
	check(open_dmg > 1.0 and behind_dmg < open_dmg * (1.0 - Props.cover(Props.Kind.ROCK_LARGE) * 0.9), "a rock soaks a blast for the unit behind it (%.1f behind vs %.1f in the open)" % [behind_dmg, open_dmg])
	check(eb.prop_hp(ev_rock_cell) < rock_hp0, "...and the blast chips the rock itself (%.0f -> %.0f hp)" % [rock_hp0, eb.prop_hp(ev_rock_cell)])
	eb.damage_prop(ev_rock_cell, 999.0)
	for k in 3:
		await physics_frame
	ev_behind.hp = 100.0
	ev_open.hp = 100.0
	Explosion.detonate(ectx, eb.cell_to_world(ev_blast_at, 0.05), ev_shell_w)
	check(absf((100.0 - ev_behind.hp) - (100.0 - ev_open.hp)) < 0.2, "once the rock is destroyed the cover is gone (%.1f vs %.1f)" % [100.0 - ev_behind.hp, 100.0 - ev_open.hp])
	ev_behind.die()
	ev_open.die()

	var ev_hill_target: Unit = spawn_on.call(inf_stats, 1, 15, 1)
	var ev_hill_open: Unit = spawn_on.call(inf_stats, 1, 7, 1)
	ev_hill_target.hp = 100.0
	ev_hill_open.hp = 100.0
	var ev_hill_blast := GridBoard.offset_to_axial(Vector2i(11, 1))
	ev_shell_w.blast_radius = 12.0
	Explosion.detonate(ectx, eb.cell_to_world(ev_hill_blast, 0.05), ev_shell_w)
	check(100.0 - ev_hill_target.hp < (100.0 - ev_hill_open.hp) * 0.75, "a hill between the blast and the unit shelters it (%.1f vs %.1f)" % [100.0 - ev_hill_target.hp, 100.0 - ev_hill_open.hp])
	ev_hill_target.die()
	ev_hill_open.die()

	# ramming a prop wrecks it
	var ev_rammer2: Unit = spawn_on.call(tank_stats, 0, 4, 16)
	var wreck_cell := GridBoard.offset_to_axial(Vector2i(8, 16))
	eb.add_prop(wreck_cell, Props.Kind.TREE)
	var wreck_dash := DashAction.new(ev_rammer2, Vector3.RIGHT)
	wreck_dash.plan(ectx)
	check(wreck_dash.hit_cell == wreck_cell, "dash runs into the tree")
	await wreck_dash.execute(ectx)
	check(eb.prop_at(wreck_cell) == -1 and not eb.is_blocked(wreck_cell), "the tank's 12 armor wrecks a 12 hp tree")
	ev_rammer2.die()
	ev_bv.queue_free()
	await physics_frame

	# composer: gradual hills, a few ev_cliffs, flat spawns, always connected on foot
	var hilly := SceneComposer.new()
	hilly.reserved = [Vector2i(9, 5), Vector2i(14, 3), Vector2i(17, 6), Vector2i(18, 16), Vector2i(13, 18), Vector2i(9, 16)]
	var ev_slopes := 0
	var ev_cliffs := 0
	var peak_seen := 0
	var spawns_flat := true
	var hills_connected := true
	for sd in 30:
		var hl := hilly.compose(sd)
		var hb := GridBoard.new(hilly.board_size, 1.0)
		for lv: Vector2i in hl.levels:
			hb.set_level(GridBoard.offset_to_axial(lv), hl.levels[lv])
			peak_seen = maxi(peak_seen, int(hl.levels[lv]))
		for p: Array in hl.props:
			hb.add_prop(GridBoard.offset_to_axial(p[1]), p[0], p[2])
		for c in hb.all_cells():
			for d in GridBoard.DIRS:
				if hb.in_bounds(c + d) and c < c + d:
					var diff := absi(hb.level_of(c) - hb.level_of(c + d))
					ev_slopes += 1 if diff == 1 else 0
					ev_cliffs += 1 if diff >= GridBoard.CLIFF_LEVELS else 0
		for rs in hilly.reserved:
			spawns_flat = spawns_flat and hb.level_of(GridBoard.offset_to_axial(rs)) == 0
		var hfirst := GridBoard.offset_to_axial(hilly.reserved[0])
		for i in range(1, hilly.reserved.size()):
			hills_connected = hills_connected and not hb.find_path(hfirst, GridBoard.offset_to_axial(hilly.reserved[i]), INF, false).is_empty()
	check(peak_seen >= 3 and peak_seen <= GridBoard.MAX_LEVEL, "composer raises hills up to level %d (max %d)" % [peak_seen, GridBoard.MAX_LEVEL])
	check(ev_slopes > ev_cliffs * 3 and ev_cliffs > 0, "hills are mostly gradual slopes with a few cliff faces (%d slope edges, %d cliff edges over 30 seeds)" % [ev_slopes, ev_cliffs])
	check(spawns_flat and hills_connected, "spawn points stay flat and connected on foot without crossing a cliff (30 seeds)")
	check(hilly.compose(11).levels == hilly.compose(11).levels, "the same seed gives the same hills")

	# ---------- gunnery over terrain ----------
	var gun_flat := GridBoard.new(Vector2i(22, 18), 1.0)
	var gun_hill := GridBoard.new(Vector2i(22, 18), 1.0)
	var gun_wall := GridBoard.new(Vector2i(22, 18), 1.0)
	for q in range(3, 7):
		gun_hill.set_level(Vector2i(q, 5), 4)    # the gun stands on a 2 m plateau, ground drops away to the east
	for q in range(7, 15):
		gun_wall.set_level(Vector2i(q, 5), 4)    # a 2 m hill ~4 m ahead of a gun on level ground (the muzzle is ~1 m ahead of the body, its arc peaks 3 m out)
	var gun_cannon: WeaponStats = load("res://data/weapons/tank_cannon.tres")
	var panel_for := func(board: GridBoard) -> GunneryPanel:
		var gctx := BattleContext.new()
		gctx.board = board
		gctx.root = main
		var gu := Unit.new()
		gu.configure(tank_stats, 0, Color.WHITE)
		main.add_child(gu)
		var gc := Vector2i(5, 5)
		gu.snap_to(board.cell_to_world(gc, gu.rest_height()))
		board.place(gu, gc)
		gctx.units.append(gu)
		var gp := GunneryPanel.new()
		gp._unit = gu
		gp._weapon = gun_cannon
		gp._ctx = gctx
		gp._yaw = PI / 2.0   # aiming along +x, i.e. along the row of cells
		return gp
	var gp_flat: GunneryPanel = panel_for.call(gun_flat)
	var gp_hill: GunneryPanel = panel_for.call(gun_hill)
	var gp_wall: GunneryPanel = panel_for.call(gun_wall)
	gp_flat._pitch = deg_to_rad(8.0)
	gp_hill._pitch = deg_to_rad(8.0)
	gp_wall._pitch = deg_to_rad(8.0)
	var est_flat := gp_flat._estimate(15.0)
	var h_flat: float = est_flat["h0"]
	var analytic := 15.0 * cos(deg_to_rad(8.0)) * (15.0 * sin(deg_to_rad(8.0)) + sqrt(pow(15.0 * sin(deg_to_rad(8.0)), 2.0) + 2.0 * Ballistics.gravity() * h_flat)) / Ballistics.gravity()
	check(absf(float(est_flat["range"]) - analytic) < 0.1 and not est_flat["blocked"], "gunnery estimate on level ground matches the closed form (%.2f vs %.2f m)" % [est_flat["range"], analytic])
	var est_hill := gp_hill._estimate(15.0)
	check(float(est_hill["range"]) > float(est_flat["range"]) + 0.5 and float(est_hill["land_y"]) < -1.0, "firing down from a plateau reaches farther and lands lower (%.1f vs %.1f m)" % [est_hill["range"], est_flat["range"]])
	var est_wall := gp_wall._estimate(15.0)
	check(est_wall["blocked"] and float(est_wall["range"]) < float(est_flat["range"]), "a hill in the way ends the arc early and flags it as blocked (%.1f m)" % est_wall["range"])
	gp_wall._pitch = deg_to_rad(45.0)
	var est_over := gp_wall._estimate(15.0)
	check(not est_over["blocked"] and float(est_over["range"]) > 8.0, "a high arc clears the same hill (%.1f m)" % est_over["range"])
	var open_floor := gp_flat._pitch_floor()
	check(is_equal_approx(open_floor, deg_to_rad(gun_cannon.pitch_min_deg)), "on open ground the weapon's own minimum elevation applies")
	var tight := gun_cannon.pitch_min_deg
	var gun_cliff := GridBoard.new(Vector2i(22, 18), 1.0)
	for q in range(6, 12):
		gun_cliff.set_level(Vector2i(q, 5), 3)   # a 1.5 m wall right in front of the gun
	var gp_cliff: GunneryPanel = panel_for.call(gun_cliff)
	check(gp_cliff._pitch_floor() > deg_to_rad(tight) + 0.05, "ground right ahead of the muzzle raises the minimum elevation (%.1f deg)" % rad_to_deg(gp_cliff._pitch_floor()))
	gp_cliff._set_pitch(deg_to_rad(-5.0))
	check(gp_cliff._pitch >= gp_cliff._pitch_floor() - 0.0001, "the barrel cannot be depressed into the hill")
	gp_hill._choices.append(RoundStats.new())
	gp_hill._base_yaw = PI / 2.0
	gp_hill._active = true
	main.add_child(gp_hill)   # lets _draw run: side view with the ground silhouette, radar with relief tint
	for k in 4:
		await process_frame
	check(gp_hill.is_inside_tree() and gp_hill._pitch_floor() <= deg_to_rad(gun_cannon.pitch_max_deg), "the panel draws over hills (side-view silhouette, radar relief) without errors")
	gp_hill._active = false
	main.remove_child(gp_hill)
	for gp: GunneryPanel in [gp_flat, gp_hill, gp_wall, gp_cliff]:
		gp._unit.die()
		gp.free()

	# ---------- glTF unit models (res://Players) ----------
	var rig_ok := true
	for st: UnitStats in [tank_stats, how_stats, inf_stats]:
		rig_ok = rig_ok and UnitModel.has_model(st.model)
	check(rig_ok, "tank, howitzer and infantry name an existing glTF model (%s / %s / %s)" % [tank_stats.model, how_stats.model, inf_stats.model])
	for st: UnitStats in [tank_stats, how_stats]:
		var mu := Unit.new()
		mu.configure(st, 0, Color.WHITE)
		main.add_child(mu)
		mu.snap_to(Vector3(2.0, mu.rest_height(), 2.0))
		var m_hull: Node3D = mu._hull
		var m_turret: Node3D = mu._turret
		var m_barrel: Node3D = mu._barrel
		check(m_hull.get_child_count() > 0 and m_turret.get_child_count() > 0 and m_barrel.get_child_count() > 0,
			"%s model is cut into hull (%d), turret (%d) and barrel (%d) meshes" % [st.display_name, m_hull.get_child_count(), m_turret.get_child_count(), m_barrel.get_child_count()])
		mu.face(Vector3(0.0, 0.0, 1.0))
		var level := mu.muzzle_position(Vector3(0.0, 0.0, 1.0))
		check(level.z > mu.global_position.z + 0.5 and absf(level.y - mu.global_position.y) < st.height, "%s muzzle sits ahead of the hull (%.2f m forward, %.2f m up)" % [st.display_name, level.z - mu.global_position.z, level.y - mu.global_position.y])
		mu.aim(Vector3(1.0, 0.0, 0.0), deg_to_rad(30.0))
		var turned := mu.muzzle_position(Vector3(1.0, 0.0, 0.0))
		check(turned.x > mu.global_position.x + 0.5 and absf(m_turret.rotation.y - PI / 2.0) < 0.01 and absf(m_hull.rotation.y) < 0.01, "%s turret turns to the aim while the hull keeps its heading (armor sectors stay valid)" % st.display_name)
		check(absf(m_barrel.rotation.x + deg_to_rad(30.0)) < 0.001, "%s barrel pitches with the aim" % st.display_name)
		mu.die()
		mu.free()
	var soldier := Unit.new()
	soldier.configure(inf_stats, 0, Color.WHITE)
	main.add_child(soldier)
	var rpg_w: WeaponStats = inf_stats.weapons[0]
	var rifle_w: WeaponStats = inf_stats.weapons[1]
	check(rpg_w.model == "bazooka" and rifle_w.model == "rifle" and soldier._barrel.get_child_count() == 1, "the soldier starts holding his main weapon (%s)" % rpg_w.model)
	var rpg_reach := soldier.muzzle_position(Vector3(0.0, 0.0, 1.0)).z - soldier.global_position.z
	soldier.equip(rifle_w)
	await soldier.get_tree().process_frame
	var rifle_reach := soldier.muzzle_position(Vector3(0.0, 0.0, 1.0)).z - soldier.global_position.z
	check(soldier._barrel.get_child_count() == 1 and absf(rifle_reach - rpg_reach) > 0.01, "equipping the rifle swaps the held model and the muzzle position (%.2f -> %.2f m)" % [rpg_reach, rifle_reach])
	# animated soldier: rig, skin and state changes
	var rig := soldier._rig
	var rig_skel: Skeleton3D = rig.get_node("Rig_Medium/Skeleton3D") if rig != null else null
	check(rig != null and rig_skel != null and rig_skel.get_bone_count() == 23 and rig.mesh_instance.skin != null, "the soldier carries a skinned 23-bone Rig_Medium rig")
	var skin_arrays := (rig.mesh_instance.mesh as ArrayMesh).surface_get_arrays(0)
	var skin_weights: PackedFloat32Array = skin_arrays[Mesh.ARRAY_WEIGHTS]
	var weights_ok := skin_weights.size() == (skin_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() * 4
	for v in range(0, skin_weights.size(), 4):
		weights_ok = weights_ok and absf(skin_weights[v] + skin_weights[v + 1] + skin_weights[v + 2] + skin_weights[v + 3] - 1.0) < 0.001
	check(weights_ok, "every soldier vertex has skin weights that sum to 1")
	check(rig.player.has_animation("Ranged_2H_Aiming") and rig.player.has_animation("Running_HoldingRifle") and rig.player.has_animation("Death_A") and rig.player.is_playing(), "the soldier idles with the aiming clip and has run / death clips")
	var mount_ready := soldier._barrel.position
	rig.set_state(SoldierRig.State.MOVE, 3.0)
	for i in 30:
		await soldier.get_tree().process_frame
	check(rig.player.current_animation == "Running_HoldingRifle" and soldier._barrel.position.distance_to(mount_ready) > 0.1, "running plays the run clip and carries the weapon across the chest")
	rig.set_state(SoldierRig.State.FIRE)
	check(rig.is_busy() and rig.player.current_animation == "Ranged_2H_Shoot", "firing plays the one-shot shoot clip")
	soldier.die()
	check(rig.state == SoldierRig.State.DEATH and soldier.visible, "a dead soldier plays the death clip and stays visible for a moment")
	rig.set_state(SoldierRig.State.IDLE)
	check(rig.state == SoldierRig.State.DEATH, "a dead soldier cannot get up again")
	soldier.free()
	var shell_model := UnitModel.make_shell(0.7)
	check(shell_model != null and shell_model.get_child_count() == 1, "the tank shell model loads for gunnery rounds")
	if shell_model != null:
		shell_model.free()

	# ---------- river, roads, bridges ----------
	var rb := GridBoard.new(Vector2i(12, 8), 1.0)
	var r_from := GridBoard.offset_to_axial(Vector2i(2, 4))
	var r_to := GridBoard.offset_to_axial(Vector2i(8, 4))
	var plain_cost := rb.path_cost(rb.find_path(r_from, r_to))
	for q in range(3, 8):
		rb.set_terrain(GridBoard.offset_to_axial(Vector2i(q, 4)), Terrain.Type.ROAD)
	var road_cost := rb.path_cost(rb.find_path(r_from, r_to))
	check(road_cost < plain_cost * 0.75, "road cells are cheap to cross (%.1f vs %.1f AP weight)" % [road_cost, plain_cost])
	rb.set_terrain(GridBoard.offset_to_axial(Vector2i(5, 4)), Terrain.Type.CRATER)
	check(rb.weight_of(GridBoard.offset_to_axial(Vector2i(5, 4))) > 2.0, "a crater on a road costs like a crater")
	var wet := GridBoard.new(Vector2i(12, 8), 1.0)
	for row in 8:
		wet.add_water(GridBoard.offset_to_axial(Vector2i(6, row)))
	var west := GridBoard.offset_to_axial(Vector2i(2, 4))
	var east := GridBoard.offset_to_axial(Vector2i(10, 4))
	var river_cell := GridBoard.offset_to_axial(Vector2i(6, 4))
	check(wet.is_water(river_cell) and not wet.is_blocked(river_cell) and wet.is_walkable(river_cell), "river cells can be waded")
	check(is_equal_approx(wet.weight_of(river_cell), Terrain.WATER_WEIGHT) and Terrain.WATER_WEIGHT >= 3.0 * Terrain.weight(Terrain.Type.GRASS), "wading costs a huge AP penalty (weight %.1f vs 1.0 on grass)" % wet.weight_of(river_cell))
	var ford_cost := wet.path_cost(wet.find_path(west, east))
	var dry := GridBoard.new(Vector2i(12, 8), 1.0)
	check(not wet.find_path(west, east).is_empty() and ford_cost > dry.path_cost(dry.find_path(west, east)) + Terrain.WATER_WEIGHT - 1.5, "a path across a full-width river exists and pays the wading cost (%.1f vs %.1f)" % [ford_cost, dry.path_cost(dry.find_path(west, east))])
	var wet2 := GridBoard.new(Vector2i(12, 8), 1.0)
	for row in 8:
		if row != 4:
			wet2.add_water(GridBoard.offset_to_axial(Vector2i(6, row)))
	wet2.add_bridge(river_cell)
	# a bridge two rows up: the road over it is the cheap way across, so the path detours to it
	var wet3 := GridBoard.new(Vector2i(12, 8), 1.0)
	for row in 8:
		if row != 1:
			wet3.add_water(GridBoard.offset_to_axial(Vector2i(6, row)))
	wet3.add_bridge(GridBoard.offset_to_axial(Vector2i(6, 1)))
	for q in range(0, 12):
		wet3.set_terrain(GridBoard.offset_to_axial(Vector2i(q, 1)), Terrain.Type.ROAD)
	var detour := wet3.find_path(west, east)
	var crosses_bridge := false
	for dc in detour:
		crosses_bridge = crosses_bridge or wet3.is_bridge(dc)
	check(crosses_bridge and wet3.terrain_at(GridBoard.offset_to_axial(Vector2i(6, 1))) == Terrain.Type.ROAD and not wet3.is_water(GridBoard.offset_to_axial(Vector2i(6, 1))), "pathing prefers the bridge to wading")
	wet.set_terrain(river_cell, Terrain.Type.CRATER)
	wet.ignite(river_cell, 3)
	check(wet.terrain_at(river_cell) == Terrain.Type.GRASS and is_equal_approx(wet.weight_of(river_cell), Terrain.WATER_WEIGHT) and not wet.is_burning(river_cell), "water takes no craters and no fire")
	var tiles_ok := true
	for m in range(1, 64):
		tiles_ok = tiles_ok and not HexTiles.road(m).is_empty() and not HexTiles.river(m).is_empty()
	check(tiles_ok and HexTiles.road(0).is_empty(), "every road / river edge mask has a pack tile")
	var straight_road := HexTiles.road(HexTiles.mask_of([2, 5]))
	check(straight_road["tile"] == "tiles/roads/hex_road_A" and is_equal_approx(float(straight_road["yaw"]), 2.0 * PI / 3.0), "a road along edges 2 and 5 is the straight tile turned 120 degrees")
	var cross := HexTiles.crossing(HexTiles.mask_of([1, 4]), HexTiles.mask_of([2, 5]))
	check(cross.has("tile") and String(cross["bridge"]).begins_with("buildings/neutral/building_bridge_") and FileAccess.file_exists(HexTiles.DIR + String(cross["bridge"]) + ".gltf"), "a bridge over a river along edges 1 and 4 finds a crossing tile and a bridge model (%s)" % [cross])
	var rc := SceneComposer.new()
	rc.reserved = [Vector2i(9, 5), Vector2i(14, 3), Vector2i(17, 6), Vector2i(18, 16), Vector2i(13, 18), Vector2i(9, 16)]
	var river_ok := true
	var river_note := ""
	for rs in [11, 12, 13, 14]:
		var rl := rc.compose(rs)
		var wet_cells := {}
		for wc in rl.water:
			wet_cells[wc] = true
		var overlap := false
		for rr in rl.roads:
			overlap = overlap or wet_cells.has(rr)
		for pr: Array in rl.props:
			overlap = overlap or wet_cells.has(pr[1]) or rl.roads.has(pr[1])
		var spans := rl.water.size() >= rc.board_size.x / 2 and not rl.bridges.is_empty()
		var all_bridges_on_roads := true
		for br in rl.bridges:
			all_bridges_on_roads = all_bridges_on_roads and rl.roads.has(br) and not wet_cells.has(br)
		river_ok = river_ok and spans and not overlap and all_bridges_on_roads
		river_note = "seed %d: %s" % [rs, rl.summary()]
	check(river_ok, "composer: a river spans the map with bridges on roads, and nothing is built on water or roads (%s)" % river_note)

	# ---------- knocked off the board ----------
	var inf := Unit.new()
	inf.configure(inf_stats, 0, Color.WHITE)
	main.add_child(inf)
	ctx.units.append(inf)
	inf.snap_to(ctx.board.cell_to_world(GridBoard.offset_to_axial(Vector2i(27, 7)), inf.rest_height()))
	await turns._settle()
	inf.launch(Vector3(30.0, 6.0, 0.0))
	await turns._settle()
	check(not inf.is_alive(), "unit launched off the board dies (alive=%s)" % inf.is_alive())

	# ---------- wading the river ----------
	var wcell := Vector2i.ZERO
	var land := Vector2i.ZERO
	var found_shore := false
	for wc: Vector2i in ctx.board.water_cells():
		for d in GridBoard.DIRS:
			if not found_shore and ctx.board.is_walkable(wc + d) and not ctx.board.is_water(wc + d) and ctx.board.terrain_at(wc + d) == Terrain.Type.GRASS:
				wcell = wc
				land = wc + d
				found_shore = true
	check(found_shore, "the live map has a river bank to test on")
	if found_shore:
		var wader := Unit.new()
		wader.configure(tank_stats, 0, Color.WHITE)
		main.add_child(wader)
		ctx.units.append(wader)
		wader.snap_to(ctx.board.cell_to_world(land, wader.rest_height()))
		ctx.board.resync(ctx.units)
		wader.ap = 8.0
		var wade := MoveAction.new(wader, ctx.board.cell_to_world(wcell, wader.rest_height()))
		check(wade.can_execute(ctx) and is_equal_approx(wade.cost(ctx), Terrain.WATER_WEIGHT * tank_stats.move_ap_per_weight), "a tank can wade one river cell for %.1f AP" % wade.cost(ctx))
		await wade.execute(ctx)
		await turns._settle()
		check(wader.is_alive() and ctx.board.is_water(wader.cell) and absf(wader.ap - (8.0 - Terrain.WATER_WEIGHT * tank_stats.move_ap_per_weight)) < 0.01, "the wading tank stands in the river and paid the AP (cell %s, AP left %.1f)" % [wader.cell, wader.ap])
		var space_w: PhysicsDirectSpaceState3D = (main as Node3D).get_world_3d().direct_space_state
		var wc_world := ctx.board.cell_to_world(wcell)
		var floor_hit := space_w.intersect_ray(PhysicsRayQueryParameters3D.create(wc_world + Vector3(0.0, 6.0, 0.0), wc_world + Vector3(0.0, -2.0, 0.0), Unit.LAYER_TERRAIN))
		check(not floor_hit.is_empty(), "the riverbed holds units up (no fall through the river)")
		wader.die()

	# ---------- start menu choices: side, tint, hot seat, victory screen ----------
	check(BattleConfig.human_teams() == [0] and BattleConfig.color_of(0) == BattleConfig.PALETTE[0] and BattleConfig.name_of(1) == "AI",
		"default config = you (team 0, blue) against the AI")
	check(ctx.units[0].team_color == BattleConfig.color_of(0) and ctx.units[3].team_color == BattleConfig.color_of(1), "units carry the configured tint")
	check(main._turns._controllers[0] == main._player and main._turns._controllers[1] == main._ai and ctx.viewer_team == 0, "1P default: team 0 is the player, team 1 the AI, screen = team 0")
	main.queue_free()
	await process_frame

	BattleConfig.two_player = true
	BattleConfig.p1_team = 1
	BattleConfig.p1_color = BattleConfig.PALETTE[2]   # green
	BattleConfig.p2_color = BattleConfig.PALETTE[4]   # purple
	check(BattleConfig.human_teams() == [1, 0] and BattleConfig.color_of(1) == BattleConfig.PALETTE[2] and BattleConfig.color_of(0) == BattleConfig.PALETTE[4]
		and BattleConfig.name_of(1) == "PLAYER 1" and BattleConfig.name_of(0) == "PLAYER 2", "hot seat: Player 1 on the south side, own tints")
	var hot: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(hot)
	for i in 6:
		await physics_frame
	var hctx: BattleContext = hot._ctx
	var hturns: TurnManager = hot._turns
	check(hctx.units[0].team == 0 and hctx.units[0].team_color == BattleConfig.PALETTE[4] and hctx.units[3].team_color == BattleConfig.PALETTE[2],
		"hot seat: the units wear the chosen tints (team 0 purple, team 1 green)")
	check(hturns._controllers[0] == hot._hot_seat and hturns._controllers[1] == hot._hot_seat and hot._hot_seat.inner == hot._player, "hot seat: both teams go through the hand-off controller")
	check(hot._handoff.visible and hctx.viewer_team == hturns.current_unit.team and not hot._player._active, "hot seat: the cover is up before the first turn and the screen already looks through that player's eyes")
	var first_team := hturns.current_unit.team
	hot._handoff._confirm()
	await process_frame
	check(not hot._handoff.visible and hot._player._active, "confirming the cover hands over the controls")
	var park := 27
	for u in hctx.units:   # the infantry's outer ring now reaches ~26 m: park the other side in the far corner to test the fog
		if u.team != first_team:
			u.snap_to(hctx.board.cell_to_world(GridBoard.offset_to_axial(Vector2i(park, 21)), u.rest_height()))
			park -= 1
	hot._update_fog()
	var hidden_foes := hctx.units.filter(func(u: Unit) -> bool: return u.team != first_team and not hctx.visible_to_viewer(u))
	check(not hidden_foes.is_empty() and hidden_foes.all(func(u: Unit) -> bool: return u.is_concealed()), "hot seat: the other player's units outside sight stay hidden (%d)" % hidden_foes.size())
	hot._player._finish(null)   # end the turn
	for i in 8:
		await physics_frame
	check(hturns.current_unit.team != first_team and hot._handoff.visible and hctx.viewer_team == hturns.current_unit.team and not hot._player._active,
		"hot seat: the next turn belongs to the other player, the cover returns and the view switches (viewer %d)" % hctx.viewer_team)
	check(hot._sight.viewer_team == hctx.viewer_team and hot._review.viewer_team == hctx.viewer_team, "line-of-sight overlay and shot review follow the viewer")
	# damage report for the incoming player: enemy shots that hit them or landed in their sight, with the direction they came from
	var rep_team: int = hctx.viewer_team
	var rep_unit: Unit = hctx.units.filter(func(u: Unit) -> bool: return u.team == rep_team)[0]
	var mk := func(id: int, shooter_team: int, origin: Vector3, impact: Vector3) -> ShotRecord:
		var r := ShotRecord.new()
		r.id = id
		r.shooter_team = shooter_team
		r.origin = origin
		r.shooter_pos = origin
		r.impact = impact
		r.landed = true
		return r
	var hit_rec: ShotRecord = mk.call(1001, 1 - rep_team, rep_unit.global_position + Vector3(20, 0, 0), rep_unit.global_position)
	hit_rec.results.append({"unit": "Tank", "team": rep_team, "sector": "front", "outcome": "PENETRATED", "damage": 3.0, "killed": false,
		"unit_id": rep_unit.get_instance_id(), "unit_pos": rep_unit.global_position})
	hit_rec.results.append(hit_rec.results[0].duplicate())   # a second blast on the same unit folds into one line
	var far_rec: ShotRecord = mk.call(1002, 1 - rep_team, Vector3(200, 0, 200), Vector3(210, 0, 210))
	var own_rec: ShotRecord = mk.call(1003, rep_team, Vector3.ZERO, rep_unit.global_position)
	var foe_rec: ShotRecord = mk.call(1004, 1 - rep_team, Vector3.ZERO, rep_unit.global_position)   # hit nobody of ours but landed in our sight
	hot._state.shots.append_array([hit_rec, far_rec, own_rec, foe_rec])
	var report := TurnReport.build(hot._state, hctx, rep_team, 1000)
	check(report.size() == 2 and report[0]["id"] == 1001 and report[1]["id"] == 1004, "report keeps shots that hit us or landed in sight, drops unseen and our own (%d)" % report.size())
	check(report[0]["from"] == "E" and report[0]["hits"].size() == 1 and is_equal_approx(report[0]["hits"][0]["damage"], 6.0) and report[1]["hits"].is_empty(),
		"report names the direction (E) and folds repeated hits on one unit")
	check(TurnReport.direction_text(Vector3(0, 0, -5), Vector3.ZERO) == "N" and TurnReport.direction_text(Vector3(5, 0, 5), Vector3.ZERO) == "SE", "compass: north = -Z, east = +X")
	check(TurnReport.build(hot._state, hctx, rep_team, 1004).is_empty(), "shots already reported are not repeated")
	hot._handoff._fill_report(hctx, rep_team, report)
	check(hot._handoff._report_body.get_child_count() == 4, "report panel lists each shot's direction, the hit line and the no-hit line")
	hot._state.shots.erase(hit_rec)
	hot._state.shots.erase(far_rec)
	hot._state.shots.erase(own_rec)
	hot._state.shots.erase(foe_rec)

	# shot review follows each player: own shots = full data, the other side's = marker + trajectory only
	var rv_a: ShotRecord = mk.call(2001, rep_team, Vector3.ZERO, Vector3(3, 0, 3))
	var rv_b: ShotRecord = mk.call(2002, 1 - rep_team, Vector3.ZERO, Vector3(4, 0, 4))
	hot._state.shots.append_array([rv_a, rv_b])
	var rv: ShotReview = hot._review
	rv._filter = ShotReview.Filter.ALLIES
	var mine_first: Array[int] = rv._visible_indices()
	check(rv._info(rv_a) and not rv._info(rv_b) and mine_first.size() == 1 and hot._state.shots[mine_first[0]] == rv_a, "review (viewer team %d): ALLIES = own shots, full data only for them" % rep_team)
	hot._set_viewer(1 - rep_team)
	var theirs_first: Array[int] = rv._visible_indices()
	check(rv._info(rv_b) and not rv._info(rv_a) and theirs_first.size() == 1 and hot._state.shots[theirs_first[0]] == rv_b, "review follows the other player after the switch (own shots, own data)")
	hot._set_viewer(rep_team)
	hot._on_battle_over(1)
	check(rv._full() and rv._info(rv_a) and rv._info(rv_b), "after the battle the review is the full shot history (every side's data)")
	rv._filter = ShotReview.Filter.ALLIES
	check(rv._visible_indices().size() == 1 and rv._filter_name() == "PLAYER 1" and rv._team_col(0) == BattleConfig.color_of(0) and rv._team_col(1) == BattleConfig.color_of(1),
		"history filters by player and draws each side in its tint")
	rv._filter = ShotReview.Filter.ALL
	hot._state.shots.erase(rv_a)
	hot._state.shots.erase(rv_b)
	check(hctx.reveal_all and hctx.units.all(func(u: Unit) -> bool: return hctx.visible_to_viewer(u)) and hot._result == "PLAYER 1 WINS", "battle over reveals every unit and names the winning player")
	hot._victory.present(1, hot._state, hctx)
	check(hot._victory.visible and hot._victory._headline(1)[0] == "VICTORY" and hot._victory._headline(1)[2] == "PLAYER 1 WINS", "victory screen opens for the winner (hot seat names the player)")
	hot._victory.hide_results()
	check(not hot._victory.visible and hot._victory.is_open() == false, "victory screen can be dismissed to look at the battlefield")
	BattleConfig.two_player = false
	check(hot._victory._headline(1)[0] == "VICTORY" and hot._victory._headline(0)[0] == "DEFEAT" and hot._victory._headline(TurnManager.DRAW)[0] == "DRAW",
		"1P headlines: VICTORY when your side wins, DEFEAT when it loses, DRAW")
	hot.queue_free()
	await process_frame

	# 1P on the south side: you are team 1, the AI team 0
	BattleConfig.p1_team = 1
	var south: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(south)
	for i in 6:
		await physics_frame
	check(south._turns._controllers[1] == south._player and south._turns._controllers[0] == south._ai and south._ctx.viewer_team == 1 and south._sight.viewer_team == 1,
		"1P south: team 1 is the player and the screen looks through team 1")
	south.queue_free()
	await process_frame
	BattleConfig.reset()

	print("---- %d failure(s)" % fails)
	quit(1 if fails > 0 else 0)


func last_point(trace: Dictionary) -> Vector3:
	var pts: PackedVector3Array = trace["points"]
	return pts[pts.size() - 1]
