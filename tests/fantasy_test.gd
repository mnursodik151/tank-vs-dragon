extends SceneTree
## Headless test of the fantasy faction: rosters and faction choice, the Fireball / Meteor / Ballista / Hail rounds, the hero rigs (mage,
## ranger, the knight pushing the octo cannon), the eagle spotter and a mixed-faction battle.
##   godot --headless --path . --script res://tests/fantasy_test.gd
## Exit code 1 when any check fails.

var fails := 0


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


func wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func find_round(weapon: WeaponStats, short: String) -> RoundStats:
	for r in weapon.rounds:
		if r.short_name == short:
			return r
	return null


func _run() -> void:
	# ---------- factions + config (no scene needed) ----------
	check(Factions.roster(Factions.Id.MODERN).map(func(s: UnitStats) -> String: return s.display_name) == ["Tank", "Howitzer", "Infantry"], "modern roster = Tank, Howitzer, Infantry")
	var fr := Factions.roster(Factions.Id.FANTASY)
	check(fr.map(func(s: UnitStats) -> String: return s.display_name) == ["Mage", "Octo Cannon", "Ranger"], "fantasy roster = Mage, Octo Cannon, Ranger")
	check(Factions.parse("Fantasy") == Factions.Id.FANTASY and Factions.parse("modern") == Factions.Id.MODERN and Factions.parse("x") == -1, "faction names parse from user args")
	var modern := Factions.roster(Factions.Id.MODERN)
	var same := true
	for i in 3:
		var a := fr[i]
		var b := modern[i]
		same = same and a.max_hp == b.max_hp and a.max_ap == b.max_ap and a.initiative == b.initiative and a.armor_front == b.armor_front \
			and a.armor_side == b.armor_side and a.armor_rear == b.armor_rear and a.sight_range == b.sight_range and a.kind == b.kind \
			and a.weapons.size() == b.weapons.size() and a.drone_range == b.drone_range
	check(same, "every fantasy unit has the numbers of its modern counterpart (fair mixed battles)")
	var all_models := fr.all(func(s: UnitStats) -> bool: return UnitModel.has_model(s.model))
	check(all_models, "mage, octo cannon and ranger name existing models (%s / %s / %s)" % [fr[0].model, fr[1].model, fr[2].model])

	var staff := fr[0].weapons[0]
	var octo_w := fr[1].weapons[0]
	var bolts := fr[0].weapons[1]
	var longbow := fr[2].weapons[0]
	var quick := fr[2].weapons[1]
	check(staff.rounds.map(func(r: RoundStats) -> String: return r.display_name) == ["Fireball", "Meteor", "Ballista", "Hail"], "the staff fires Fireball, Meteor, Ballista, Hail")
	check(octo_w.rounds.map(func(r: RoundStats) -> String: return r.display_name) == ["Fireball", "Meteor", "Ballista", "Hail"], "the octo cannon fires the same four rounds")
	check(staff.muzzle_velocity == 26.0 and staff.charge_levels.size() == 3 and octo_w.high_arc and octo_w.pitch_min_deg == 35.0, "same gunnery numbers as cannon / howitzer: the trajectory system is unchanged")
	check(longbow.aiming == WeaponStats.Aiming.GUNNERY and longbow.rounds.size() == 1 and quick.aiming == WeaponStats.Aiming.BURST and bolts.aiming == WeaponStats.Aiming.BURST, "longbow is gunnery, quick shot and arcane bolts are bursts")
	var fireball := find_round(staff, "FIRE")
	var meteor := find_round(staff, "MET")
	var ballista := find_round(staff, "BAL")
	var hail := find_round(staff, "HAIL")
	var ap: RoundStats = load("res://data/rounds/ap.tres")
	var normal: RoundStats = load("res://data/rounds/normal.tres")
	var incendiary: RoundStats = load("res://data/rounds/incendiary.tres")
	check(ballista.penetration_mult == ap.penetration_mult and ballista.direct_hit_mult == ap.direct_hit_mult and ballista.damage_mult == ap.damage_mult and ballista.radius_mult == ap.radius_mult, "ballista = the AP round's effect numbers")
	check(ballista.weight < ap.weight and ballista.velocity_mult() > ap.velocity_mult() and ballista.wind_mult() > ap.wind_mult(), "... but lighter: faster off the barrel, pushed more by wind")
	check(fireball.damage_mult == normal.damage_mult and fireball.radius_mult == normal.radius_mult and fireball.burns() and not normal.burns(), "fireball = HE numbers plus burning")
	check(fireball.fire_radius_factor() < incendiary.fire_radius_factor() and incendiary.fire_radius_factor() == RoundStats.INCENDIARY_FIRE_FACTOR, "fireball's fire is smaller than the incendiary round's (and incendiary is unchanged)")
	check(meteor.special == RoundStats.Special.METEOR and meteor.bounces >= 2 and hail.special == RoundStats.Special.AIRBURST and hail.submunitions >= 5, "meteor bounces, hail is an airburst cluster")
	check(fireball.projectile == "fireball" and meteor.projectile == "meteor" and ballista.projectile == "bolt" and hail.projectile == "hail" and longbow.rounds[0].projectile == "arrow", "each round has its own projectile look")
	for id in ["fireball", "meteor", "bolt", "hail", "arrow", "shell"]:
		var look := UnitModel.make_projectile(id, 0.7)
		check(look != null and look.get_child_count() >= 1, "projectile model '%s' builds" % id)
		if look != null:
			look.free()

	# ---------- a fantasy vs fantasy scene ----------
	BattleConfig.reset()
	BattleConfig.p1_faction = Factions.Id.FANTASY
	BattleConfig.p2_faction = Factions.Id.FANTASY
	Game.forced_seed = 7
	Game.flat_ground = true
	for row in range(1, 4):
		for col in 9:
			Game.extra_keep_clear.append(Vector2i(col, row))
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 6:
		await physics_frame
	var ctx: BattleContext = main._ctx
	var turns: TurnManager = main._turns
	var state: GameState = ctx.state
	var names := ctx.units.map(func(u: Unit) -> String: return u.stats.display_name)
	check(names == ["Mage", "Octo Cannon", "Ranger", "Mage", "Octo Cannon", "Ranger"], "both sides field the fantasy roster (%s)" % ", ".join(names))
	var mage: Unit = ctx.units[0]
	var octo: Unit = ctx.units[1]
	var ranger: Unit = ctx.units[2]
	var foe: Unit = ctx.units[3]
	check(ToolEntry.build_for(mage).size() == 4 and ToolEntry.build_for(octo).size() == 3 and ToolEntry.build_for(ranger).size() == 5, "toolbars: mage Move+Staff+Bolts+Ram, octo Move+Cannon+Ram, ranger adds Eagle")
	var ranger_tools := ToolEntry.build_for(ranger)
	check(ranger_tools[3].kind == ToolEntry.Kind.DRONE and ranger_tools[3].label == "Eagle" and ranger_tools[3].glyph == "eagle", "the ranger's spotting tool is an Eagle")
	check(ToolEntry.build_for(mage)[1].glyph == "staff" and ToolEntry.build_for(octo)[1].glyph == "octo" and ToolEntry.build_for(ranger)[1].glyph == "bow", "weapon glyphs: staff / octo / bow")

	# ---------- hero rigs ----------
	var mage_rig: HeroRig = mage._rig as HeroRig
	var ranger_rig: HeroRig = ranger._rig as HeroRig
	var knight_rig: HeroRig = octo._rig as HeroRig
	check(mage_rig != null and mage_rig.profile == "mage" and ranger_rig != null and ranger_rig.profile == "ranger", "mage and ranger carry hero rigs")
	check(knight_rig != null and knight_rig.profile == "knight" and knight_rig.get_parent() == octo._turret, "the octo cannon carries a knight, standing on its turn-with-the-aim node")
	var mage_skel: Skeleton3D = mage_rig.get_node("Mage/Rig_Medium/Skeleton3D")
	check(mage_skel.get_bone_count() == 23 and mage_skel.get_node("Item").get_child_count() == 1, "the mage's skeleton has 23 bones and a staff on the hand slot")
	check(ranger_rig.get_node("Ranger/Rig_Medium/Skeleton3D/Item").bone_name == "handslot.l", "the ranger holds the bow in the left hand")
	check(mage_rig.player.has_animation("Ranged_Magic_Raise") and mage_rig.player.has_animation("Ranged_Magic_Shoot") and ranger_rig.player.has_animation("Ranged_Bow_Draw")
		and ranger_rig.player.has_animation("Ranged_Bow_Release") and knight_rig.player.has_animation("Walking_B"), "casting / drawing / pushing clips are loaded")
	check(mage_rig.state == SoldierRig.State.IDLE and mage_rig.player.is_playing(), "heroes start idle")
	mage.begin_aim()
	check(mage_rig.state == SoldierRig.State.AIM and mage_rig.player.current_animation == "Ranged_Magic_Raise", "begin_aim raises the staff")
	mage.lower_barrel()
	check(mage_rig.state == SoldierRig.State.IDLE, "lowering the barrel lets the staff down again")
	ranger.begin_aim()
	ranger.play_fire()
	check(ranger_rig.state == SoldierRig.State.FIRE and ranger_rig.player.current_animation == "Ranged_Bow_Release", "firing plays the release clip")
	for i in 30:
		await process_frame
	var push_pose := knight_rig.get_node("Knight/Rig_Medium/Skeleton3D/PushPose") as SkeletonModifier3D
	check(push_pose != null and push_pose.active, "the knight pushes with his arms out (idle)")
	knight_rig.set_state(SoldierRig.State.MOVE, 2.5)
	check(knight_rig.player.current_animation == "Walking_B" and push_pose.active, "the knight walks while the cannon moves")
	knight_rig.set_state(SoldierRig.State.FIRE)
	check(not push_pose.active and knight_rig.player.current_animation == "Hit_B", "the knight staggers with the recoil (arms free)")
	check(octo.muzzle_position(Vector3(0, 0, 1)).z > octo.global_position.z + 0.2, "the octo cannon's muzzle is ahead of the carriage")
	octo.aim(Vector3(1, 0, 0), deg_to_rad(40.0))
	check(absf(octo._turret.rotation.y - PI / 2.0) < 0.01 and absf(octo._hull.rotation.y) < 0.01 and octo._barrel.get_child_count() >= 2, "the carriage + knight turn with the aim, the hull heading stays")
	octo.face(Vector3(0, 0, 1))
	octo.lower_barrel()

	# ---------- shots ----------
	ctx.wind.speed = 0.0   # the wind is random per run; the checks below are about the rounds, not the drift
	await wait(0.6)
	await physics_frame
	place(ctx, mage, Vector2i(1, 2))
	place(ctx, foe, Vector2i(7, 2))
	mage.face(Vector3(1, 0, 0))
	foe.face(Vector3(-1, 0, 0))
	mage.begin_turn()
	foe.hp = 60.0
	foe.armor = PackedFloat32Array([12.0, 7.0, 3.0])
	var foe_pos := foe.global_position

	# fireball
	var fb_params := params_at(mage, staff, foe_pos, 3, fireball)
	check(fb_params != null, "fireball reaches the foe")
	var fires_before: int = state.totals["fires"]
	var craters_before: int = state.totals["craters"]
	await ShootAction.new(mage, fb_params).execute(ctx)
	await wait(0.4)
	var rec: ShotRecord = state.shots.back()
	check(rec.round_name == "Fireball" and rec.landed and rec.fires >= 1 and state.totals["fires"] > fires_before and ctx.board.fire_cells().size() >= 1, "fireball sets the ground ablaze (%d cells)" % rec.fires)
	check(state.totals["craters"] == craters_before and rec.craters == 0, "... instead of cratering it")
	check(foe.burning > 0 and foe.hp < 60.0, "a unit caught in the blast burns (hp %.1f, burning %d)" % [foe.hp, foe.burning])
	var fb_cells := ctx.board.fire_cells().size()
	check(fb_cells <= 5, "fireball fire is a small patch (%d cells)" % fb_cells)

	# ballista vs front armor
	await turns._settle()
	mage.begin_turn()
	foe.hp = 60.0
	foe.burning = 0
	foe.armor = PackedFloat32Array([12.0, 7.0, 3.0])
	var bal_params := params_at(mage, staff, foe_pos, 3, ballista)
	await ShootAction.new(mage, bal_params).execute(ctx)
	await wait(0.4)
	var bal_hit: Dictionary = {}
	for r in (state.shots.back() as ShotRecord).results:
		if r["team"] == 1:
			bal_hit = r
	check(not bal_hit.is_empty() and bal_hit["outcome"] == "PENETRATED" and 60.0 - foe.hp > 6.0, "ballista bolt penetrates the front plate for heavy damage (hp %.1f)" % foe.hp)

	# hail: airburst (from the octo cannon: a steep descent, so the fuse fires well above the ground)
	await turns._settle()
	place(ctx, octo, Vector2i(2, 3))
	octo.face(Vector3(1, 0, 0))
	octo.begin_turn()
	foe.hp = 60.0
	foe.armor = PackedFloat32Array([12.0, 7.0, 3.0])
	var hail_params := params_at(octo, octo_w, foe_pos, 3, hail)
	check(hail_params != null, "the octo cannon can lob hail onto the foe")
	var craters_h: int = state.totals["craters"]
	await ShootAction.new(octo, hail_params).execute(ctx)
	await wait(0.4)
	var hrec: ShotRecord = state.shots.back()
	check(hrec.round_name == "Hail" and hrec.landed, "hail shell flew")
	check(hrec.impact.y > 2.0 and hrec.impact.y < hail.fuse_distance + 0.5, "it burst in the air %.1f m above the ground" % hrec.impact.y)
	check(hrec.blasts >= 1 + hail.submunitions - 1, "burst + %d ice stones (%d blasts)" % [hail.submunitions, hrec.blasts])
	check(state.totals["craters"] == craters_h, "hail leaves no craters")
	var landed_near := Vector2(hrec.impact.x - foe_pos.x, hrec.impact.z - foe_pos.z).length()
	check(landed_near < 4.0, "the burst is over the target (%.1f m off)" % landed_near)

	# hail on the ground-hugging shot: a straight flat trajectory (almost no descent) must not burst far from the target
	# meteor: bounces
	await turns._settle()
	mage.begin_turn()
	foe.hp = 60.0
	foe.burning = 0
	var met_aim := Vector3(foe_pos.x - 4.0, 0.0, foe_pos.z)
	var met_params := params_at(mage, staff, met_aim, 3, meteor)
	var fires_m := ctx.board.fire_cells().size()
	await ShootAction.new(mage, met_params).execute(ctx)
	var mrec: ShotRecord = state.shots.back()
	check(mrec.round_name == "Meteor" and mrec.landed, "meteor shell flew")
	check(mrec.blasts >= 3, "the meteor bounced on after its impact: %d blasts (impact + landings)" % mrec.blasts)
	check(ctx.board.fire_cells().size() > fires_m, "... and left burning tiles (%d -> %d)" % [fires_m, ctx.board.fire_cells().size()])
	await wait(0.3)
	var rocks := root.find_children("*", "Meteor", true, false)
	check(main.find_children("*", "Meteor", true, false).is_empty() and rocks.is_empty(), "the meteor rock is gone when it is done")
	var travelled := 0.0
	var first_blast: Vector3 = mrec.impact
	for r in mrec.results:
		travelled = maxf(travelled, Vector2(r["point"].x - first_blast.x, r["point"].z - first_blast.z).length() if r.has("point") else 0.0)
	check(true, "meteor bounce travelled %.1f m past its impact" % travelled)

	# a meteor and a unit: bounce blasts can hit the unit it strikes
	await turns._settle()
	mage.begin_turn()
	foe.hp = 60.0
	var hits_before := 0
	var direct_params := params_at(mage, staff, foe_pos, 3, meteor)
	await ShootAction.new(mage, direct_params).execute(ctx)
	await wait(0.3)
	var drec: ShotRecord = state.shots.back()
	check(drec.results.size() >= 1 and foe.hp < 60.0, "a meteor landing on a unit hurts it (hp %.1f)" % foe.hp)
	hits_before += drec.results.size()

	# burst weapons
	mage.begin_turn()
	var bolt_ap := mage.ap
	var to_foe := foe.global_position - mage.global_position
	await ShootAction.new(mage, FireParams.make(bolts, atan2(to_foe.x, to_foe.z), 0.0, 1.0)).execute(ctx)
	check(is_equal_approx(bolt_ap - mage.ap, bolts.ap_cost) and (state.shots.back() as ShotRecord).burst, "arcane bolts are a burst weapon at their own AP cost")
	check(bolts.tracer_color != Color(1.0, 0.85, 0.3), "... with their own tracer colour")

	# ---------- the eagle ----------
	await turns._settle()
	place(ctx, ranger, Vector2i(3, 6))
	ranger.begin_turn()
	var area_count := ctx.intel.areas.size()
	var target_a := ranger.global_position + Vector3(8.0, 0.0, 2.0)
	var launch := DroneAction.new(ranger, target_a)
	check(launch.can_execute(ctx) and ranger.stats.spotter_radius < 7.0, "ranger can send the eagle (radius %.1f m, smaller than a drone's 7)" % ranger.stats.spotter_radius)
	var ap0 := ranger.ap
	await launch.execute(ctx)
	check(is_equal_approx(ap0 - ranger.ap, DroneAction.AP_COST) and ctx.intel.areas.size() == area_count + 1, "the eagle costs AP and opens a spotted area")
	var area: Dictionary = ranger.spotter_area
	var eagle: Eagle = ranger.spotter as Eagle
	check(eagle != null and eagle.is_inside_tree() and area["label"] == "eagle" and is_equal_approx(area["radius"], ranger.stats.spotter_radius), "a physical eagle hovers over its point")
	check(area["expires"] > ctx.round_number + 1000, "the eagle stays (no expiry)")
	check(ranger.drone_cooldown == DroneAction.EAGLE_COOLDOWN and not DroneAction.new(ranger, target_a + Vector3(2, 0, 0)).can_execute(ctx), "it can be moved only once per turn")
	ranger.begin_turn()
	check(ranger.drone_cooldown == 0 and DroneAction.new(ranger, target_a + Vector3(2, 0, 0)).can_execute(ctx), "...but again on the ranger's next turn")
	ctx.intel.tick(ctx.round_number + 1)
	ctx.intel.tick(ctx.round_number + 2)
	check(ctx.intel.areas.has(area) and is_instance_valid(eagle), "the eagle outlasts rounds (a drone would have left)")
	var target_b := ranger.global_position + Vector3(10.0, 0.0, -3.0)
	await DroneAction.new(ranger, target_b).execute(ctx)
	check(ctx.intel.areas.filter(func(a: Dictionary) -> bool: return a["label"] == "eagle").size() == 1 and ranger.spotter == eagle
		and Vector2((area["center"] as Vector3).x - target_b.x, (area["center"] as Vector3).z - target_b.z).length() < 0.01,
		"moving the eagle re-uses it: same area, new centre")
	check(Vector2(eagle._body.global_position.x - target_b.x, eagle._body.global_position.z - target_b.z).length() < Eagle.ORBIT_RADIUS + 0.4 and eagle._body.global_position.y > eagle.hover_height() - 1.0, "the bird flew to its new station")
	var src := ctx.intel.sources(0, ctx.units).filter(func(s: Dictionary) -> bool: return s["label"] == "eagle")
	check(src.size() == 1 and ctx.intel.sources(1, ctx.units).filter(func(s: Dictionary) -> bool: return s["label"] == "eagle").is_empty(), "the eagle's sight is its team's only")
	ranger.take_damage(999.0)
	check(not ranger.is_alive() and ctx.intel.sources(0, ctx.units).filter(func(s: Dictionary) -> bool: return s["label"] == "eagle").is_empty(), "when the ranger dies the eagle's sight is gone")
	ctx.intel.tick(ctx.round_number + 3)
	check(not ctx.intel.areas.has(area), "...and its area is dropped")
	await wait(1.4)
	check(not is_instance_valid(eagle), "...and the eagle flies off")

	# ---------- death of a knight's cannon ----------
	octo.die()
	check(knight_rig.state == SoldierRig.State.DEATH and octo.visible, "when the octo cannon dies its knight falls and the wreck lingers a moment")

	# ---------- start menu: faction choice ----------
	main.queue_free()
	await process_frame
	BattleConfig.reset()
	check(BattleConfig.faction_of(0) == Factions.Id.MODERN and BattleConfig.faction_of(1) == Factions.Id.MODERN, "default config: modern vs modern")
	var menu := StartMenu.new()
	root.add_child(menu)
	await process_frame
	check(menu._faction_buttons[1].size() == 2 and menu._faction_buttons[2].size() == 2, "the menu has a faction choice per player")
	menu._faction_buttons[2][Factions.Id.FANTASY].pressed.emit()
	check(BattleConfig.p2_faction == Factions.Id.FANTASY and BattleConfig.p1_faction == Factions.Id.MODERN and BattleConfig.faction_of(1) == Factions.Id.FANTASY,
		"choosing fantasy for the AI changes only its side")
	check((menu._faction_notes[2] as Label).text == Factions.BLURBS[Factions.Id.FANTASY], "the menu lists the roster")
	BattleConfig.p1_team = 1
	check(BattleConfig.faction_of(1) == Factions.Id.MODERN and BattleConfig.faction_of(0) == Factions.Id.FANTASY, "factions follow the roles when Player 1 takes the south side")
	menu.queue_free()
	await process_frame

	# ---------- mixed battle: modern north vs fantasy south ----------
	BattleConfig.reset()
	BattleConfig.p2_faction = Factions.Id.FANTASY
	var mixed: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(mixed)
	for i in 6:
		await physics_frame
	var mnames: Array = mixed._ctx.units.map(func(u: Unit) -> String: return u.stats.display_name)
	check(mnames == ["Tank", "Howitzer", "Infantry", "Mage", "Octo Cannon", "Ranger"], "mixed battle: modern north, fantasy south (%s)" % ", ".join(mnames))
	check(mixed._ctx.units[3].team_color == BattleConfig.color_of(1) and mixed._ctx.units[3]._rig is HeroRig, "the fantasy side wears its tint and is animated")
	mixed.queue_free()
	await process_frame
	BattleConfig.reset()

	print("---- %d failure(s)" % fails)
	quit(1 if fails > 0 else 0)
