extends SceneTree
## Headless test of the modular parameter system: the StatCatalog (every exported number is a stat), StatModifier maths, UnitBlueprint /
## UnitProfile (the six units mapped into the template), that upgrades reach the game code (units, weapons, rounds, actions, rules) and
## that the authored data is never touched.
##   godot --headless --path . --script res://tests/params_test.gd
## Exit code 1 when any check fails.

var fails := 0


func check(cond: bool, msg: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + msg)
	if not cond:
		fails += 1


func _initialize() -> void:
	_run()


func mod(stat: StringName, op: StatModifier.Op, value: float, target: StringName = &"", tag: StringName = &"") -> StatModifier:
	return StatModifier.make(stat, op, value, &"test", target, tag)


func bp(name: String) -> UnitBlueprint:
	return load("res://data/blueprints/%s.tres" % name) as UnitBlueprint


func _run() -> void:
	# ---------- the catalog covers every exported number ----------
	var covered := true
	var missing := PackedStringArray()
	var total := 0
	for scope: StringName in StatCatalog.scopes():
		var script: Script = StatCatalog.scopes()[scope]
		var inst: Object = script.new()
		for p: Dictionary in inst.get_property_list():
			if not (int(p["usage"]) & PROPERTY_USAGE_EDITOR) or not (int(p["usage"]) & PROPERTY_USAGE_STORAGE) or String(p["name"]).begins_with("resource_"):
				continue
			var t: int = p["type"]
			if (t == TYPE_FLOAT or t == TYPE_INT or t == TYPE_BOOL or t == TYPE_PACKED_FLOAT32_ARRAY) and int(p["hint"]) != PROPERTY_HINT_ENUM:
				var id := StringName("%s.%s" % [scope, p["name"]])
				total += 1
				if not StatCatalog.has(id):
					covered = false
					missing.append(String(id))
	check(covered, "every exported number of UnitStats / WeaponStats / RoundStats / RamSpec / SpotterSpec / BattleRules is a catalogued stat (%d stats; missing: %s)" % [total, ", ".join(missing)])
	var ids_real := true
	for id in StatCatalog.ids():
		var si := StatCatalog.info(id)
		var inst: Object = (StatCatalog.scopes()[si.scope] as Script).new()
		ids_real = ids_real and inst.get(si.prop) != null
	check(ids_real, "every catalogued stat names a real variable")
	var mv := StatCatalog.info(&"weapon.muzzle_velocity")
	check(mv != null and mv.label == "Muzzle Velocity" and mv.group == "Ballistics" and mv.minimum == 0.0, "stat metadata: label, @export_group as group, default floor 0")
	check(StatCatalog.info(&"unit.ap_carry").maximum == 1.0 and StatCatalog.info(&"unit.max_hp").is_int() and StatCatalog.info(&"weapon.high_arc").is_bool() and StatCatalog.info(&"weapon.charge_levels").is_array(),
		"limits come from @export_range, types are told apart (int / bool / array)")
	check(StatCatalog.info(&"weapon.pitch_min_deg").minimum == -INF and not StatCatalog.has(&"unit.model") and not StatCatalog.has(&"unit.kind") and not StatCatalog.has(&"spotter.spotter_kind"),
		"angles may go negative; strings and enums are settings, not stats")
	check(StatCatalog.ids(&"round").size() > 15 and StatCatalog.ids(&"unit").size() > 25, "the catalog lists %d unit and %d round stats" % [StatCatalog.ids(&"unit").size(), StatCatalog.ids(&"round").size()])

	# ---------- the six units mapped into the template ----------
	var names := ["tank", "howitzer", "infantry", "mage", "octo_cannon", "ranger"]
	var shape_ok := true
	for n in names:
		var b := bp(n)
		shape_ok = shape_ok and b != null and b.stats != null and b.ident() == StringName(n) and b.has_action(ActionSpec.Kind.MOVE) and b.has_action(ActionSpec.Kind.SHOOT) \
			and b.has_action(ActionSpec.Kind.RAM) and b.meta.has("faction") and b.meta.has("role")
	check(shape_ok, "all six blueprints load: stats + Move / Shoot / Ram actions + metadata")
	check(bp("infantry").has_action(ActionSpec.Kind.SPOTTER) and bp("ranger").has_action(ActionSpec.Kind.SPOTTER) and not bp("tank").has_action(ActionSpec.Kind.SPOTTER) and not bp("howitzer").has_action(ActionSpec.Kind.SPOTTER),
		"only infantry (drone) and ranger (eagle) can spot")
	var drone := bp("infantry").spec(ActionSpec.Kind.SPOTTER) as SpotterSpec
	var eagle := bp("ranger").spec(ActionSpec.Kind.SPOTTER) as SpotterSpec
	check(drone.reach == 22.0 and drone.radius == 7.0 and drone.ap_cost == 2.0 and drone.cooldown_turns == 3 and drone.duration_rounds == 2 and not drone.is_eagle(), "the infantry drone keeps the old numbers (22 m, 7 m radius, 2 AP, cooldown 3, 2 rounds)")
	check(eagle.is_eagle() and eagle.radius == 4.5 and eagle.cooldown_turns == 1 and eagle.spotter_name() == "Eagle", "the ranger's eagle: 4.5 m radius, once per turn")
	var ram := bp("tank").spec(ActionSpec.Kind.RAM) as RamSpec
	check(ram.speed_mult == 2.0 and ram.armor_wear == 0.5 and ram.knock_per_armor == 0.6 and ram.knock_mass_exponent == 0.3 and ram.max_run == 60.0 and ram.damage_mult == 1.0, "ram numbers equal the old constants")
	var tank_p := UnitProfile.create(bp("tank"))
	var unchanged := true
	for row in tank_p.describe_params():
		unchanged = unchanged and not row["modified"]
	check(unchanged and tank_p.modifiers.is_empty(), "a profile without upgrades reproduces the authored numbers exactly")
	check(tank_p.stat(&"unit.max_hp") == 20 and tank_p.stat(&"unit.armor_front") == 12.0 and tank_p.stat(&"weapon.muzzle_velocity") == 26.0 and tank_p.stat(&"round.weight") == 1.0 and tank_p.stat(&"ram.speed_mult") == 2.0,
		"stat() answers for unit, main weapon, first round and action scopes")

	# ---------- clones: the authored data is never touched ----------
	var authored: UnitStats = load("res://data/tank.tres")
	var hp_before := authored.max_hp
	var cannon_v_before := authored.weapons[0].muzzle_velocity
	var weight_before := authored.weapons[0].rounds[1].weight
	var p := UnitProfile.create(bp("tank"))
	var cannon_clone: WeaponStats = p.stats.weapons[0]
	p.add_modifiers([mod(&"unit.max_hp", StatModifier.Op.ADD, 5), mod(&"weapon.muzzle_velocity", StatModifier.Op.PERCENT, 0.5), mod(&"round.weight", StatModifier.Op.ADD, 1.0)])
	check(authored.max_hp == hp_before and authored.weapons[0].muzzle_velocity == cannon_v_before and authored.weapons[0].rounds[1].weight == weight_before, "upgrading a profile leaves the .tres resources alone")
	check(p.stats != authored and p.stats.weapons[0] != authored.weapons[0] and p.stats.weapons[0].rounds[0] != authored.weapons[0].rounds[0] and p.stats.weapons[0].origin == authored.weapons[0], "a profile owns deep clones (unit, weapon, round) that remember their origin")
	check(p.stats.weapons[0] == cannon_clone, "a rebuild updates the clones in place (references to a weapon stay valid)")
	var other := UnitProfile.create(bp("tank"))
	check(other.stats.max_hp == 20 and p.stats.max_hp == 25, "two units of one type do not share upgrades")
	check(p.base_stat(&"unit.max_hp") == 20 and p.stat(&"unit.max_hp") == 25 and p.stat(&"weapon.muzzle_velocity") == 39.0, "base_stat() vs stat(): max_hp 20 -> 25, muzzle velocity 26 -> 39")

	# ---------- modifier maths ----------
	var q := UnitProfile.create(bp("tank"))
	q.add_modifiers([mod(&"unit.max_ap", StatModifier.Op.ADD, 2), mod(&"unit.max_ap", StatModifier.Op.ADD, 1), mod(&"unit.max_ap", StatModifier.Op.PERCENT, 0.1), mod(&"unit.max_ap", StatModifier.Op.PERCENT, 0.1),
		mod(&"unit.max_ap", StatModifier.Op.SCALE, 2.0)])
	check(is_equal_approx(q.stat(&"unit.max_ap"), (8.0 + 3.0) * 1.2 * 2.0), "ADD sums, PERCENT sums then applies once, SCALE multiplies: (8+3) x 1.2 x 2 = %.1f" % q.stat(&"unit.max_ap"))
	q.clear_modifiers()
	q.add_modifiers([mod(&"unit.max_ap", StatModifier.Op.ADD, 5), mod(&"unit.max_ap", StatModifier.Op.SET, 4)])
	check(q.stat(&"unit.max_ap") == 9.0, "SET replaces the base, flat bonuses still apply on top (4 + 5)")
	q.clear_modifiers()
	q.add_modifiers([mod(&"unit.max_ap", StatModifier.Op.ADD, -100), mod(&"unit.max_hp", StatModifier.Op.PERCENT, 0.126)])
	check(q.stat(&"unit.max_ap") == 0.0 and q.stat(&"unit.max_hp") == 23, "results are clamped to the stat's limits (no negative AP) and integers are rounded (20 x 1.126 -> 23)")
	q.clear_modifiers()
	q.add_modifiers([mod(&"unit.ap_carry", StatModifier.Op.ADD, 5.0)])
	check(q.stat(&"unit.ap_carry") == 1.0, "@export_range caps a stat (ap_carry <= 1)")
	q.clear_modifiers()
	q.add_modifiers([mod(&"weapon.high_arc", StatModifier.Op.SET, 1.0), mod(&"weapon.charge_levels", StatModifier.Op.SCALE, 0.5)])
	var lv: PackedFloat32Array = q.stat(&"weapon.charge_levels")
	check(q.stat(&"weapon.high_arc") == true and is_equal_approx(lv[0], 0.3) and is_equal_approx(lv[2], 0.5) and (q.base_stat(&"weapon.charge_levels") as PackedFloat32Array)[2] == 1.0
		and (load("res://data/weapons/tank_cannon.tres") as WeaponStats).charge_levels[2] == 1.0, "a bool stat takes SET, an array stat takes every op per element (authored array untouched)")
	q.clear_modifiers()
	var hp_up := StatModifier.make(&"unit.max_hp", StatModifier.Op.ADD, 4, &"toughness")
	q.add_modifiers([hp_up, StatModifier.make(&"unit.armor_front", StatModifier.Op.ADD, 2, &"toughness"), StatModifier.make(&"unit.max_ap", StatModifier.Op.ADD, 1, &"other")])
	q.remove_source(&"toughness")
	check(q.stat(&"unit.max_hp") == 20 and q.stat(&"unit.armor_front") == 12.0 and q.stat(&"unit.max_ap") == 9.0 and q.modifiers.size() == 1, "remove_source() takes every modifier of one source away and leaves the rest")
	q.clear_modifiers()

	# ---------- targeting: instance id and tag filters ----------
	var tgt := UnitProfile.create(bp("tank"))
	tgt.add_modifiers([mod(&"weapon.blast_damage", StatModifier.Op.ADD, 4, &"tank_cannon"), mod(&"weapon.spread_deg", StatModifier.Op.SCALE, 0.5, &"", &"burst"), mod(&"round.damage_mult", StatModifier.Op.SCALE, 2.0, &"", &"incendiary")])
	var main_gun: WeaponStats = tgt.stats.weapons[0]
	var mg: WeaponStats = tgt.stats.weapons[1]
	check(main_gun.ident() == &"tank_cannon" and mg.ident() == &"machine_gun", "weapons are identified by their file stem")
	check(main_gun.blast_damage == 10.0 and mg.blast_damage == bp("tank").stats.weapons[1].blast_damage, "target filter: +4 damage reaches the cannon only")
	check(is_equal_approx(mg.spread_deg, bp("tank").stats.weapons[1].spread_deg * 0.5) and main_gun.spread_deg == bp("tank").stats.weapons[0].spread_deg, "tag filter: 'burst' reaches the machine gun, not the cannon")
	var hit := 0
	var untouched := 0
	for r in main_gun.rounds:
		if r.special == RoundStats.Special.INCENDIARY:
			hit += 1 if is_equal_approx(r.damage_mult, 2.0 * r.origin.damage_mult) else 0
		elif r.damage_mult == r.origin.damage_mult:
			untouched += 1
	check(hit == 1 and untouched == main_gun.rounds.size() - 1, "tag filter on rounds: only the incendiary round doubles its damage")
	check(tgt.modifiers_for(&"weapon.blast_damage", main_gun).size() == 1 and tgt.modifiers_for(&"weapon.blast_damage", mg).is_empty(), "modifiers_for() lists what reaches one instance")

	# ---------- the numbers reach the game code ----------
	var body := UnitProfile.create(bp("tank"), [mod(&"unit.max_ap", StatModifier.Op.ADD, 2), mod(&"unit.ap_carry", StatModifier.Op.SET, 0.5), mod(&"unit.damage_taken_mult", StatModifier.Op.SET, 0.5),
		mod(&"unit.knockback_taken", StatModifier.Op.SET, 0.0), mod(&"unit.mass", StatModifier.Op.ADD, 2.0), mod(&"unit.friction", StatModifier.Op.SET, 0.9), mod(&"unit.burn_damage", StatModifier.Op.SET, 3.0)])
	var u := Unit.new()
	u.configure(body, 0, Color.WHITE)
	root.add_child(u)
	u.begin_turn()
	check(u.ap == 10.0 and u.mass == 8.0 and is_equal_approx(u.physics_material_override.friction, 0.9) and u.hp == 20.0, "Unit follows its profile: AP 10 per turn, mass 8, friction 0.9")
	u.spend_ap(4.0)
	u.begin_turn()
	check(is_equal_approx(u.ap, 10.0 + 3.0), "ap_carry 0.5: 6 AP unspent carry 3 into the next turn (10 + 3)")
	u.spend_ap(u.ap)
	u.begin_turn()
	u.ap = 40.0
	u.begin_turn()
	check(is_equal_approx(u.ap, 10.0 + body.stats.ap_carry_cap), "... but never more than ap_carry_cap (%.0f)" % body.stats.ap_carry_cap)
	var res := u.take_hit(10.0, 100.0, Vector3(0, 0, 1))
	check(is_equal_approx(res.damage, 5.0) and is_equal_approx(u.hp, 15.0), "damage_taken_mult 0.5 halves what gets through")
	u.launch(Vector3(10.0, 0.0, 0.0))
	check(u.linear_velocity.length() < 0.001, "knockback_taken 0 makes the unit immovable")
	u.freeze_in_place()
	u.burning = 2
	var hp_pre := u.hp
	u.begin_turn()
	check(is_equal_approx(hp_pre - u.hp, 3.0 * 0.5), "burn_damage 3 (x damage_taken_mult 0.5) per burning turn")
	var plain := Unit.new()
	plain.configure(bp("tank"), 0, Color.WHITE)
	root.add_child(plain)
	plain.ignite(2)
	var fiery := Unit.new()
	fiery.configure(UnitProfile.create(bp("tank"), [mod(&"unit.burn_duration_mult", StatModifier.Op.SET, 2.0), mod(&"unit.front_arc_deg", StatModifier.Op.SET, 10.0)]), 0, Color.WHITE)
	root.add_child(fiery)
	fiery.ignite(2)
	check(plain.burning == 2 and fiery.burning == 4, "burn_duration_mult scales how long a fire hit lasts")
	var oblique := Vector3(sin(deg_to_rad(30.0)), 0.0, cos(deg_to_rad(30.0)))
	check(plain.armor_sector(oblique) == HitResult.Sector.FRONT and fiery.armor_sector(oblique) == HitResult.Sector.SIDE, "front_arc_deg 10 turns a 30 degree hit into a side hit")
	var live_before := u.stats
	body.add_modifier(mod(&"unit.max_hp", StatModifier.Op.ADD, 10))
	check(u.stats == live_before and u.stats.max_hp == 30, "an upgrade added to a live profile reaches the unit (same stats object)")
	for n: Node in [u, plain, fiery]:
		n.free()

	# ---------- weapon and round numbers reach the shot maths ----------
	var gun := UnitProfile.create(bp("tank"), [mod(&"weapon.muzzle_velocity", StatModifier.Op.PERCENT, 0.25, &"tank_cannon"), mod(&"round.weight", StatModifier.Op.SCALE, 2.0, &"", &"incendiary")])
	var gw: WeaponStats = gun.stats.weapons[0]
	var inc_round: RoundStats
	for r in gw.rounds:
		if r.special == RoundStats.Special.INCENDIARY:
			inc_round = r
	var shot := FireParams.make(gw, 0.0, 0.2, 1.0, 3, inc_round)
	var base_w: WeaponStats = bp("tank").stats.weapons[0]
	var base_inc: RoundStats
	for r in base_w.rounds:
		if r.special == RoundStats.Special.INCENDIARY:
			base_inc = r
	var base_shot := FireParams.make(base_w, 0.0, 0.2, 1.0, 3, base_inc)
	check(is_equal_approx(shot.speed(), base_shot.speed() * 1.25 * sqrt(base_inc.weight / (base_inc.weight * 2.0))) and is_equal_approx(shot.wind_scale(), base_shot.wind_scale() * 0.5),
		"muzzle velocity +25 %% and a round twice as heavy: speed %.1f vs %.1f m/s, wind drift halves" % [shot.speed(), base_shot.speed()])
	var gun_unit := Unit.new()
	gun_unit.configure(gun, 0, Color.WHITE)
	root.add_child(gun_unit)
	gun_unit.begin_turn()
	check(ShootAction.new(gun_unit, shot).can_execute(BattleContext.new()), "a ShootAction with the unit's cloned weapon and round is legal")
	check(gun_unit.stats.owns_weapon(gw) and gun_unit.stats.owns_weapon(base_w), "a unit owns its cloned weapon and the authored one it came from")
	gun_unit.free()

	# ---------- action parameters ----------
	var ramp := UnitProfile.create(bp("tank"), [mod(&"ram.damage_mult", StatModifier.Op.SET, 2.0), mod(&"ram.speed_mult", StatModifier.Op.ADD, 1.0), mod(&"ram.max_run", StatModifier.Op.SET, 3.0), mod(&"ram.ap_cost_mult", StatModifier.Op.SET, 0.5)])
	check(ramp.ram().damage_mult == 2.0 and ramp.ram().speed_mult == 3.0 and ramp.ram().max_run == 3.0 and bp("tank").spec(ActionSpec.Kind.RAM).get("max_run") == 60.0, "ram.* stats change the unit's RamSpec clone, not the blueprint's")
	var spot := UnitProfile.create(bp("infantry"), [mod(&"spotter.reach", StatModifier.Op.ADD, 8.0), mod(&"spotter.cooldown_turns", StatModifier.Op.ADD, -2.0), mod(&"spotter.radius", StatModifier.Op.PERCENT, 0.5)])
	check(spot.spotter().reach == 30.0 and spot.spotter().cooldown_turns == 1 and is_equal_approx(spot.spotter().radius, 10.5), "spotter.* stats: reach 22 -> 30, cooldown 3 -> 1, radius 7 -> 10.5")
	var scout := Unit.new()
	scout.configure(spot, 0, Color.WHITE)
	root.add_child(scout)
	var tools := ToolEntry.build_for(scout)
	check(tools.size() == 5 and tools[3].kind == ToolEntry.Kind.DRONE and tools[4].kind == ToolEntry.Kind.RAM, "the toolbar follows the blueprint's actions: Move, RPG, Rifle, Drone, Ram")
	check(tools[3].cost() == scout.spotter_spec().ap_cost, "the spotter slot shows the spec's AP cost")
	scout.free()
	# a unit whose blueprint lists fewer actions can do fewer things
	var slim := UnitBlueprint.new()
	slim.stats = bp("tank").stats
	var move_spec := ActionSpec.new()
	move_spec.kind = ActionSpec.Kind.MOVE
	slim.actions = [move_spec] as Array[ActionSpec]
	var slim_unit := Unit.new()
	slim_unit.configure(slim, 0, Color.WHITE)
	root.add_child(slim_unit)
	check(ToolEntry.build_for(slim_unit).size() == 1 and not slim_unit.can_do(ActionSpec.Kind.SHOOT) and not slim_unit.can_do(ActionSpec.Kind.RAM), "a blueprint without Shoot / Ram gives a unit that can only move")
	slim_unit.free()

	# ---------- metadata ----------
	var meta := UnitProfile.create(bp("infantry"), [mod(&"unit.max_hp", StatModifier.Op.ADD, 3)]).meta()
	var params: Dictionary = meta["params"]
	check(params.has("unit.max_hp") and params.has("weapon:rpg.muzzle_velocity") and params.has("round:rpg/normal.weight") and params.has("ram.armor_wear") and params.has("spotter.reach"), "params() exposes every number under a unique key (unit / weapon / round / action)")
	check(params["unit.max_hp"] == 11 and meta["name"] == "Infantry" and meta["id"] == &"infantry" and meta["actions"].size() == 4 and meta["weapons"] == ["RPG", "Rifle"], "meta(): id, name, actions, weapons and the effective values")
	var rows := UnitProfile.create(bp("infantry"), [StatModifier.make(&"unit.max_hp", StatModifier.Op.ADD, 3, &"vitamins")]).describe_params()
	var hp_row: Dictionary
	for r in rows:
		if r["key"] == "unit.max_hp":
			hp_row = r
	check(hp_row["modified"] and hp_row["base"] == 8 and hp_row["value"] == 11 and hp_row["sources"] == [&"vitamins"] and hp_row["label"] == "Max Hp" and hp_row["min"] == 0.0, "describe_params(): base, value, who changed it, label, limits")
	check(rows.size() > 90, "the whole unit (%d numbers) is listed in one call" % rows.size())

	# ---------- upgrades and the run ----------
	RunState.reset()
	var plating := Upgrade.make(&"plating", "Plating", [mod(&"unit.armor_front", StatModifier.Op.ADD, 3)], [], ["tank"])
	var all_hp := Upgrade.make(&"vigor", "Vigor", [mod(&"unit.max_hp", StatModifier.Op.ADD, 2)])
	var rewinder := Upgrade.make(&"chrono", "Chrono core", [mod(&"rules.rewind_charges", StatModifier.Op.ADD, 2), mod(&"rules.rewind_window_sec", StatModifier.Op.SET, 20.0)], ["tank"])
	check(plating.applies_to(bp("tank")) and not plating.applies_to(bp("infantry")) and all_hp.applies_to(bp("infantry")) and rewinder.applies_to(bp("tank")), "upgrades select units by tag (tank) or apply to all")
	check(RunState.unit_modifiers(bp("tank")).is_empty() and RunState.rules().rewind_charges == 1, "no run, no upgrades: authored numbers and the stock single rewind")
	RunState.start()
	for up in [plating, all_hp, rewinder]:
		RunState.add(up)
	var tank_mods := RunState.unit_modifiers(bp("tank"))
	var tp := UnitProfile.create(bp("tank"), tank_mods)
	var ip := UnitProfile.create(bp("infantry"), RunState.unit_modifiers(bp("infantry")))
	check(tp.stat(&"unit.armor_front") == 15.0 and tp.stat(&"unit.max_hp") == 22 and ip.stat(&"unit.max_hp") == 10 and ip.stat(&"unit.armor_front") == 0.0, "a run's upgrades reach the right units (tank +3 armor +2 hp, infantry +2 hp)")
	check(tank_mods.all(func(m: StatModifier) -> bool: return m.source != &"" and StatCatalog.scope_of(m.stat) != &"rules"), "unit modifiers carry their upgrade as source and exclude rules.*")
	tp.remove_source(&"plating")
	check(tp.stat(&"unit.armor_front") == 12.0 and tp.stat(&"unit.max_hp") == 22, "an upgrade can be taken away again by its source")
	var rules := RunState.rules()
	check(rules.rewind_charges == 3 and rules.rewind_window_sec == 20.0, "rules.* upgrades fold into the side's BattleRules (1 + 2 rewinds, 20 s window)")
	RunState.reset()

	# ---------- a live battle hands the run's upgrades to the player's side only ----------
	BattleConfig.reset()
	Game.forced_seed = 7
	Game.flat_ground = true
	RunState.start()
	RunState.add(all_hp)
	RunState.add(rewinder)
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 6:
		await physics_frame
	var ctx: BattleContext = main._ctx
	check(ctx.units[0].stats.max_hp == 22 and ctx.units[1].stats.max_hp == 16 and ctx.units[2].stats.max_hp == 10 and ctx.units[3].stats.max_hp == 20 and ctx.units[5].stats.max_hp == 8,
		"in a 1P battle only the player's units get the upgrade (tank 20 -> 22, howitzer 14 -> 16, infantry 8 -> 10; the AI side stays 20 / 14 / 8)")
	check(ctx.rules_for(0).rewind_charges == 3 and ctx.rules_for(1).rewind_charges == 0, "the player's side gets the run's rewinds, the AI none")
	check(ctx.units[0].profile.modifiers.size() == 1 and ctx.units[3].profile.modifiers.is_empty(), "each unit carries its own profile (modifier list)")
	main.queue_free()
	await process_frame
	RunState.reset()
	BattleConfig.reset()

	print("---- %d failure(s)" % fails)
	quit(1 if fails > 0 else 0)
