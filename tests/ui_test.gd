extends SceneTree
## Headless test of the newer UI: the How to Play screen (pages, navigation, live terrain numbers, the gunnery diagram), its entry points
## (start menu button, F1 in a battle) and the gentle "press SPACE to end your turn" popup.
##   godot --headless --path . --script res://tests/ui_test.gd
## Exit code 1 when any check fails.

var fails := 0


func check(cond: bool, msg: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + msg)
	if not cond:
		fails += 1


func _initialize() -> void:
	_run()


func key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	return ev


func find_button(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text:
		return node as Button
	for child in node.get_children():
		var found := find_button(child, text)
		if found != null:
			return found
	return null


func tag_count(s: String, tag: String) -> int:
	return s.count(tag)


func _run() -> void:
	# ---------- the pages ----------
	for i in HowToPlayScreen.PAGE_NAMES.size():
		var text := HowToPlayScreen._bbcode(i)
		check(text.length() > 600 and not text.contains("%s") and not text.contains("%d"), "page %d (%s) is written out in full, with no unfilled placeholders (%d characters)" % [i, HowToPlayScreen.PAGE_NAMES[i], text.length()])
		check(tag_count(text, "[color=") == tag_count(text, "[/color]"), "page %d has balanced colour tags" % i)
	var basics := HowToPlayScreen._bbcode(0)
	check(basics.contains("Space / Enter") and basics.contains("Z / Backspace") and basics.contains("rewind") and basics.contains("F1") and basics.contains("AP"), "basics: turns, AP, the keys including undo, rewind and F1")
	var moves := HowToPlayScreen._bbcode(1)
	var live_numbers := true
	for t in [Terrain.Type.ROAD, Terrain.Type.GRASS, Terrain.Type.ROUGH, Terrain.Type.CRATER]:
		live_numbers = live_numbers and moves.contains(str(Terrain.weight(t)))
	check(live_numbers and moves.contains(str(Terrain.WATER_WEIGHT)) and moves.contains("RAM") and moves.contains("SPACE"), "movement: the terrain costs come from Terrain itself, plus ram and ending the turn")
	var gun := HowToPlayScreen._bbcode(2)
	var numbered := true
	for n in range(1, 8):
		numbered = numbered and gun.contains("(%d) " % n)
	check(numbered and gun.contains("AMMO") and gun.contains("CHARGES") and gun.contains("ELEVATION") and gun.contains("RADAR") and gun.contains("WIND") and gun.contains("LAST SHOT") and gun.contains("POWER"),
		"gunnery: all seven zones of the screen are explained, numbered like the picture")

	# ---------- the screen ----------
	var screen := HowToPlayScreen.new()
	var closed := [0]
	screen.closed.connect(func() -> void: closed[0] += 1)
	root.add_child(screen)
	await process_frame
	await process_frame
	check(screen.page == 0 and screen._tabs.size() == 3 and screen._content.get_child_count() == 1, "it opens on the basics with three page tabs")
	screen._unhandled_input(key(KEY_RIGHT))
	check(screen.page == 1, "Right switches to the next page")
	screen._unhandled_input(key(KEY_3))
	await process_frame
	var has_diagram := false
	for c in screen._content.get_children():
		has_diagram = has_diagram or c is HowToPlayScreen.Diagram
	check(screen.page == 2 and has_diagram and screen._content.get_child_count() == 2, "key 3 shows the gunnery page with the panel diagram above its text")
	await process_frame
	await process_frame   # (the diagram draws itself)
	check((screen._content.get_child(0) as Control).size.x > 500.0, "the diagram has a real size (%s)" % str((screen._content.get_child(0) as Control).size))
	screen._unhandled_input(key(KEY_RIGHT))
	check(screen.page == 0, "pages wrap around")
	screen._unhandled_input(key(KEY_LEFT))
	check(screen.page == 2, "Left goes back (and wraps)")
	screen._tabs[1].pressed.emit()
	check(screen.page == 1, "clicking a tab switches page")
	screen._unhandled_input(key(KEY_ESCAPE))
	await process_frame
	check(closed[0] == 1 and not is_instance_valid(screen), "Esc closes the screen")

	# ---------- start menu ----------
	BattleConfig.reset()
	var menu: Node = load("res://scenes/start_menu.tscn").instantiate()
	root.add_child(menu)
	await process_frame
	var button := find_button(menu, "HOW TO PLAY")
	check(button != null, "the start menu has a HOW TO PLAY button")
	button.pressed.emit()
	await process_frame
	var opened: Node = null
	for c in menu.get_children():
		if c is HowToPlayScreen:
			opened = c
	check(opened != null, "the button opens the how-to-play screen")
	(opened as HowToPlayScreen).close()
	await process_frame
	menu._unhandled_input(key(KEY_F1))
	await process_frame
	var via_f1 := false
	for c in menu.get_children():
		via_f1 = via_f1 or c is HowToPlayScreen
	check(via_f1, "F1 opens it from the menu too")
	menu.queue_free()
	await process_frame

	# ---------- inside a battle ----------
	Game.forced_seed = 7
	Game.flat_ground = true
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var pl: PlayerController = main._player
	var waited := 0.0
	while not (pl._active and main._turns.current_unit != null and main._turns.current_unit.team == 0) and waited < 20.0:
		await physics_frame
		waited += 1.0 / 60.0
	main._unhandled_input(key(KEY_F1))
	main._unhandled_input(key(KEY_F1))
	var layer := main.get_node_or_null("HowToPlayLayer")
	check(layer != null and layer.get_child_count() == 1 and layer.get_child(0) is HowToPlayScreen and layer.layer == 30, "F1 in a battle opens one how-to-play overlay on its own layer")
	(layer.get_child(0) as HowToPlayScreen).close()
	await process_frame
	await process_frame
	check(main.get_node_or_null("HowToPlayLayer") == null or main.get_node("HowToPlayLayer").is_queued_for_deletion(), "and closing it removes the layer")

	# ---------- the end-turn popup ----------
	var hero: Unit = main._turns.current_unit
	var cheapest := INF
	for t in pl.tools:
		if t.kind == ToolEntry.Kind.WEAPON or t.kind == ToolEntry.Kind.DRONE:
			cheapest = minf(cheapest, t.cost())
	check(cheapest < INF and cheapest > 0.5, "%s's cheapest weapon / spotter slot costs %.1f AP" % [hero.stats.display_name, cheapest])
	hero.ap = cheapest + 0.2
	check(not pl._only_move_or_ram_left(), "with AP for a weapon the unit is not 'stuck'")
	hero.ap = cheapest - 0.2
	check(pl._only_move_or_ram_left(), "below the cheapest weapon / spotter only moving or ramming is left")
	hero.ap = 0.0
	check(pl._only_move_or_ram_left(), "no AP at all counts too")
	pl._toolbar._popup_label.text = ""
	pl._end_turn_hinted = false
	await process_frame
	await process_frame
	check(pl._end_turn_hinted and pl._toolbar._popup_label.text == "Out of AP - press SPACE to end your turn", "at 0 AP the popup says so (%s)" % pl._toolbar._popup_label.text)
	pl._toolbar._popup_label.text = "(seen)"
	await process_frame
	await process_frame
	check(pl._toolbar._popup_label.text == "(seen)", "it shows once, not every frame")
	hero.ap = cheapest - 0.2
	hero.ap = maxf(hero.ap, 0.1)
	hero.refresh_label()
	hero.ap = cheapest + 1.0
	await process_frame
	await process_frame
	check(not pl._end_turn_hinted, "when options come back (an undo, more AP) the popup re-arms")
	hero.ap = maxf(cheapest - 0.3, 0.1)
	await process_frame
	await process_frame
	check(pl._end_turn_hinted and pl._toolbar._popup_label.text.begins_with("Only moving is left"), "and it shows again when they are used up (%s)" % pl._toolbar._popup_label.text)
	var fade_ok := pl._toolbar._popup.mouse_filter == Control.MOUSE_FILTER_IGNORE and pl._toolbar._popup_tween != null
	check(fade_ok, "the popup fades by itself and never takes mouse input")
	main.queue_free()
	await process_frame
	BattleConfig.reset()
	print("---- %d failure(s)" % fails)
	quit(1 if fails > 0 else 0)
