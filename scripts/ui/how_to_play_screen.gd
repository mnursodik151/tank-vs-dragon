class_name HowToPlayScreen
extends Control
## "How to play" overlay: three pages - the BASICS (goal, turns, AP, toolbar, keys, what you can see), MOVEMENT (the move tool, what steps
## cost, ramming, undo) and the GUNNERY screen (with a numbered miniature of the real panel). Opened from the start menu and with F1
## during a battle. Esc / Enter / BACK close it, Left / Right / Tab / 1-3 switch pages. Terrain costs are read from `Terrain`, so the text
## cannot drift from the rules; the key lists are written by hand - keep them in step with `PlayerController` / `GunneryPanel`.

signal closed

const PAGE_NAMES := ["BASICS", "MOVEMENT", "GUNNERY SCREEN"]
const SLATE := Color(0.62, 0.66, 0.78)
const SELECTED := Color(1.0, 0.78, 0.30)
const HEAD := "#ffd966"
const KEY := "#9fd8ff"
const DIM := "#9aa5c0"

var page := 0

var _tabs: Array[Button] = []
var _content: VBoxContainer
var _scroll: ScrollContainer


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.78)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)    # swallows clicks meant for whatever is behind

	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel_style(20))
	centre.add_child(panel)
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(800.0, 0.0)
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)

	col.add_child(UiTheme.label("HOW TO PLAY", Color(1.0, 0.85, 0.40), UiTheme.LARGE, HORIZONTAL_ALIGNMENT_CENTER))
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	col.add_child(tabs)
	for i in PAGE_NAMES.size():
		var b := UiTheme.button(PAGE_NAMES[i], SLATE, UiTheme.SMALL)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(show_page.bind(i))
		tabs.add_child(b)
		_tabs.append(b)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var room := maxf(get_viewport_rect().size.y - 250.0, 260.0)
	_scroll.custom_minimum_size = Vector2(0.0, minf(room, 410.0))
	col.add_child(_scroll)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 10)
	_scroll.add_child(_content)

	var back := UiTheme.button("BACK", Color(0.55, 0.85, 0.55), UiTheme.SMALL)
	back.pressed.connect(close)
	col.add_child(back)
	col.add_child(UiTheme.label("[Left / Right] page    [Esc] close", Color(0.6, 0.65, 0.75), UiTheme.SMALL, HORIZONTAL_ALIGNMENT_CENTER))
	show_page(0)


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		match key.keycode:
			KEY_ESCAPE, KEY_ENTER, KEY_KP_ENTER, KEY_F1:
				close()
			KEY_RIGHT, KEY_TAB:
				show_page((page + 1) % PAGE_NAMES.size())
			KEY_LEFT:
				show_page((page + PAGE_NAMES.size() - 1) % PAGE_NAMES.size())
			KEY_1, KEY_2, KEY_3:
				show_page(key.keycode - KEY_1)
	get_viewport().set_input_as_handled()    # modal: nothing reaches the menu / battle behind


func close() -> void:
	closed.emit()
	queue_free()


## Shows page `index` (0 basics, 1 movement, 2 gunnery screen).
func show_page(index: int) -> void:
	page = clampi(index, 0, PAGE_NAMES.size() - 1)
	for i in _tabs.size():
		var tint := SELECTED if i == page else SLATE
		_tabs[i].add_theme_stylebox_override("normal", UiTheme.box("Button01a_1" if i == page else "Button01a_4", 5, tint))
		_tabs[i].add_theme_stylebox_override("hover", UiTheme.box("Button01a_1" if i == page else "Button01a_4", 5, tint.lightened(0.25)))
	for child in _content.get_children():
		_content.remove_child(child)
		child.queue_free()
	if page == 2:
		var diagram := Diagram.new()
		diagram.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_content.add_child(diagram)
	_content.add_child(_text_block(_bbcode(page)))
	_scroll.scroll_vertical = 0


func _text_block(bbcode: String) -> RichTextLabel:
	var t := RichTextLabel.new()
	t.bbcode_enabled = true
	t.fit_content = true
	t.scroll_active = false
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.add_theme_font_override("normal_font", UiTheme.font)
	t.add_theme_font_size_override("normal_font_size", UiTheme.SMALL)
	t.add_theme_color_override("default_color", Color(0.85, 0.88, 0.95))
	t.add_theme_color_override("font_outline_color", Color.BLACK)
	t.add_theme_constant_override("outline_size", 4)
	t.text = bbcode
	return t


# --- the pages -----------------------------------------------------------------

static func _bbcode(index: int) -> String:
	match index:
		0:
			return _basics()
		1:
			return _movement()
	return _gunnery()


static func _h(title: String) -> String:
	return "[color=%s]%s[/color]\n" % [HEAD, title]


static func _c(text: String) -> String:
	return "[color=%s]%s[/color]" % [KEY, text]


static func _k(keys: String, what: String) -> String:
	return "[color=%s]%s[/color]  %s\n" % [KEY, keys, what]


static func _basics() -> String:
	var s := _h("THE GOAL")
	s += "Destroy every enemy unit. Each side has three: a main battle unit, an artillery piece and a scout. Units act one at a time in " \
		+ "initiative order, both sides mixed - the unit whose turn it is wears a bright ring and the camera glides to it.\n\n"
	s += _h("YOUR TURN")
	s += "Every unit starts its turn with action points (AP): the readout above the toolbar shows AP left / AP per turn. Everything costs AP - " \
		+ "walking, ramming, firing, sending a drone. Pick a tool on the toolbar, click in the world to use it, and carry on until you are " \
		+ "out of AP or press SPACE to end the turn early. Tools: MOVE, one slot per weapon, the scout's drone or eagle, and RAM. " \
		+ "A slot turns red when you cannot afford it. When only moving is left, a gentle popup reminds you that SPACE ends the turn.\n\n"
	s += _h("KEYS")
	s += _k("1 - 9 / click", "pick a tool from the toolbar")
	s += _k("Left click", "use the tool (walk, fire, ram, send the spotter)")
	s += _k("Space / Enter", "end this unit's turn")
	s += _k("Z / Backspace", "undo your last MOVE - free, as often as you like, back to where the unit started")
	s += _k("X", "rewind the whole turn: free if you only moved; a shot, ram or spotter in it uses one of your rewind charges (you get one per battle, none in hot seat)")
	s += _k("G", "show / hide the hex grid (with Move selected it also shades the hexes you can afford)")
	s += _k("L", "line-of-sight overlay")
	s += _k("V", "shot camera on / off")
	s += _k("P", "camera glides to the enemy's turns on / off")
	s += _k("H", "shot review: a map of every shot fired and its flight")
	s += _k("W A S D  /  Q E  /  wheel", "pan  /  rotate the camera  /  zoom")
	s += _k("R", "restart with a new map")
	s += _k("F1", "this help\n")
	s += _h("WHAT YOU CAN SEE")
	s += "Like a real battlefield you only see what your units see. Around every unit is a clear inner ring (enemies in it are seen and " \
		+ "their distance is measured well) and a hazier outer ring (seen, but their distance is only an estimate). Beyond that: nothing. " \
		+ "Trees, big rocks, buildings and hills hide whatever is behind them. A scout's drone or eagle lights up a patch of ground for a " \
		+ "while, and so does a shell that lands out of sight.\n\n"
	s += _h("READING A UNIT")
	s += "The label above a unit shows HP, AP and ARM front / side / rear. Armor stops part of a shell unless the shell's penetration beats it, " \
		+ "and wears down as it soaks damage; hits from behind meet the thin rear plate. BURNING means fire: 1 damage a turn and weaker armor.\n\n"
	s += _h("WIND")
	s += "The wind box at the top right shows its speed and direction. It changes a little every round and pushes shells in flight - light rounds " \
		+ "drift more than heavy ones."
	return s


static func _movement() -> String:
	var s := _h("THE MOVE TOOL  (key 1)")
	s += "With Move selected, hover the ground: a dotted path, an end marker and a label such as [color=%s]3.0 / 6.0 AP[/color] show what the trip " % KEY \
		+ "costs and what you have. Blue = you can afford it, red = you cannot. Click to go. There is no snapping to hexes: the hexes only " \
		+ "price the trip, and the unit stops exactly where you clicked.\n\n"
	s += _h("WHAT A STEP COSTS")
	s += "AP = the weight of every hex you enter x your unit's cost per hex (infantry walk cheaply, tanks cost more, the big gun crawls). " \
		+ "Terrain weights:\n"
	s += "[color=%s]road[/color] %s   [color=%s]grass[/color] %s   [color=%s]scorched[/color] %s   [color=%s]rough[/color] %s   [color=%s]fire[/color] %s   " % [
		KEY, _w(Terrain.Type.ROAD), KEY, _w(Terrain.Type.GRASS), KEY, _w(Terrain.Type.SCORCH), KEY, _w(Terrain.Type.ROUGH), KEY, _w(Terrain.Type.FIRE)]
	s += "[color=%s]crater[/color] %s   [color=%s]river[/color] %s\n" % [KEY, _w(Terrain.Type.CRATER), KEY, str(Terrain.WATER_WEIGHT)]
	s += "Roads are the cheap way across the map and a bridge beats wading a river. Walking uphill costs extra, downhill a little, and a cliff " \
		+ "face costs a lot - going around is usually better. Shells leave craters, and fire spreads over grass: both make ground dearer.\n\n"
	s += _h("WHAT BLOCKS YOU")
	s += "Trees, big rocks, buildings, walls and other units cannot be walked through, so the path bends around them. Press G to see the grid; " \
		+ "with Move selected the hexes you can still afford are shaded blue.\n\n"
	s += _h("RAM  (last slot)")
	s += "A straight charge towards the mouse, as far as your AP allow (priced like walking). Hit something and both sides take damage equal to " \
		+ "the OTHER one's armor value; a weaker target is also shoved back. The preview shows [color=%s]RAM: deal x, take y[/color]. Rams smash trees " % KEY \
		+ "and rocks too, and a cliff face stops the run.\n\n"
	s += _h("TAKING A MOVE BACK")
	s += "[color=%s]Z[/color] or Backspace undoes your last move: the unit goes back and the AP come back - free, no limits, any number of times in a row. " % KEY \
		+ "Once you have fired, rammed or sent a spotter, Z only reaches back to that point; [color=%s]X[/color] rewinds the whole turn " % KEY \
		+ "(that costs a rewind charge).\n\n"
	s += _h("ENDING THE TURN")
	s += "When nothing but moving or ramming is affordable, a popup says so: press [color=%s]SPACE[/color] to hand over. You can always end early " % KEY \
		+ "to keep AP in reserve for units that carry some over."
	return s


static func _w(t: Terrain.Type) -> String:
	return str(Terrain.weight(t))


static func _gunnery() -> String:
	var s := _h("TWO KINDS OF WEAPON")
	s += "[color=%s]Burst weapons[/color] (machine gun, rifle, bolts, quick shot): click and they fire at once along the line to the mouse. " % KEY \
		+ "Direct fire - you need a clear line, and the spread widens with every round of the burst.\n"
	s += "[color=%s]Gunnery weapons[/color] (cannon, howitzer, rocket launcher, staff, bow): a click opens the GUNNERY SCREEN with the barrel " % KEY \
		+ "already pointing at the mouse. You need the weapon's AP just to open it, and cancelling (Esc / right click) costs nothing. Nothing is " \
		+ "worked out for you: you set up the shot, the physics and the wind decide where it falls.\n\n"
	s += _h("THE SCREEN  (numbers match the picture)")
	s += _num(1, "AMMO", "pick the round: T or click (Shift+T goes back). Each round has a weight: a heavy round leaves the barrel slower but wind pushes " \
		+ "it less. HE blasts, AP punches through armor with a small blast, incendiary sets ground and units alight, cluster scatters bomblets " \
		+ "(fantasy: fireball, meteor, ballista, hail).")
	s += _num(2, "CHARGES", "C or click. More charges = higher muzzle speed = longer reach, for +1 AP each. The COST line shows the total.")
	s += _num(3, "ELEVATION", "side view of the barrel: Up / Down, the mouse wheel, or drag the dial. The arc is an ESTIMATE of the flight in still " \
		+ "air for this round, charge, angle and power. It follows the ground: a hill in the way ends it early and says BLOCKED. The red part of the " \
		+ "dial is ground you cannot point the barrel into.")
	s += _num(4, "TRAVERSE and RADAR", "Left / Right or drag on the radar swing the barrel a few degrees either side of your bearing. The radar is a " 		+ "top-down view: rings show the reach of each charge (C1, C2, C3), enemies you can see appear as blips with their distance (" + _c("18m") 		+ " measured, " + _c("~18m") + " estimated). Enemies you cannot see are not there at all. It never shows where the shell will land.")
	s += _num(5, "WIND", "speed and direction relative to the barrel: tail or head wind, cross wind left or right. It is NOT in the estimates - " \
		+ "you correct for it yourself (aim into the wind, a heavier round helps).")
	s += _num(6, "LAST SHOT", "your previous shot with this gun next to the current setup, and if it hit an enemy a top-down picture of where it fell " \
		+ "(\"SHORT 0.5, LEFT 0.1\" of the target's centre). Use it to correct the next shot.")
	s += _num(7, "POWER", "hold SPACE (or press and hold on the bar) to charge, release to fire. Power scales the muzzle speed; a full bar fires by itself.\n")
	s += _h("A SHOT IN FIVE STEPS")
	s += "1  Find the target: it has to be inside your team's sight (use the scout's drone or eagle to look ahead).\n"
	s += "2  Select the weapon, aim roughly at the target with the mouse and click.\n"
	s += "3  Choose the round and the charge so the target sits inside the radar rings; set the elevation.\n"
	s += "4  Read the wind and nudge the traverse to compensate.\n"
	s += "5  Hold SPACE for power and release. Then look at LAST SHOT and correct.\n\n"
	s += "[color=%s]The gun has its own small aim error and every blast shoves units around and leaves a crater, so even a perfect setup never lands twice " % DIM \
		+ "on exactly the same spot. Fire a ranging shot, read where it fell, then correct.[/color]"
	return s


static func _num(n: int, title: String, text: String) -> String:
	return "[color=%s](%d) %s[/color]  %s\n" % [HEAD, n, title, text]


## A numbered miniature of the real gunnery panel (same layout, drawn from GunneryPanel's own rectangles).
class Diagram extends Control:
	const K := 0.64
	const BADGE := Color(1.0, 0.82, 0.25)

	func _init() -> void:
		custom_minimum_size = GunneryPanel.PANEL_SIZE * K
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _r(rect: Rect2) -> Rect2:
		return Rect2(rect.position * K, rect.size * K)

	func _p(v: Vector2) -> Vector2:
		return v * K

	func _badge(n: int, at: Vector2) -> void:
		draw_circle(at, 11.0, BADGE)
		draw_arc(at, 11.0, 0.0, TAU, 20, Color(0.1, 0.1, 0.12), 2.0)
		UiTheme.text(self, at + Vector2(-5.0, 5.0), str(n), Color(0.08, 0.08, 0.1))

	func _draw() -> void:
		var inset := Color(0.16, 0.17, 0.22, 0.98)
		UiTheme.draw_panel(self, Rect2(Vector2.ZERO, GunneryPanel.PANEL_SIZE * K), 0)
		UiTheme.draw_panel(self, _r(GunneryPanel.SIDEBAR_RECT), 1)
		# ammo buttons and charge pips
		for i in 4:
			UiTheme.draw_box(self, "Button01a_4" if i != 0 else "Button01a_1", _r(Rect2(16.0 + i * 102.0, 32.0, 96.0, 28.0)), 5, Color(1.0, 0.8, 0.35) if i == 0 else Color(0.5, 0.52, 0.6))
		for i in 3:
			UiTheme.draw_box(self, "Button02a_4", _r(Rect2(512.0 + i * 36.0, 32.0, 30.0, 28.0)), 5, Color(1.0, 0.8, 0.35) if i == 0 else Color(0.5, 0.52, 0.6))
		_badge(1, _p(Vector2(16.0, 24.0)))
		_badge(2, _p(Vector2(512.0, 24.0)))
		# elevation: ground, dial, barrel, estimated arc
		var elev := _r(GunneryPanel.ELEV_RECT)
		UiTheme.draw_panel(self, elev, 1)
		var pivot := _p(Vector2(GunneryPanel.PIVOT_X, GunneryPanel.GROUND_Y))
		draw_line(Vector2(elev.position.x + 4.0, pivot.y), Vector2(elev.end.x - 4.0, pivot.y), Color(0.45, 0.4, 0.3), 2.0)
		draw_arc(pivot, GunneryPanel.DIAL_RADIUS * K, -deg_to_rad(80.0), 0.0, 16, Color(0.7, 0.75, 0.85), 1.5)
		var aim := Vector2(cos(deg_to_rad(38.0)), -sin(deg_to_rad(38.0)))
		draw_line(pivot, pivot + aim * 60.0 * K * 1.3, Color(1.0, 0.85, 0.3), 3.0)
		var prev := pivot
		for i in range(1, 25):
			var t := float(i) / 24.0
			var pt := pivot + Vector2(t * 210.0, -sin(deg_to_rad(38.0)) * t * 170.0 + t * t * sin(deg_to_rad(38.0)) * 170.0)
			if i % 2 == 0:
				draw_line(prev, pt, Color(0.6, 0.9, 1.0, 0.9), 2.0)
			prev = pt
		UiTheme.text(self, elev.position + Vector2(8.0, 20.0), "ELEVATION", Color(0.8, 0.84, 0.92))
		_badge(3, elev.position + Vector2(elev.size.x - 18.0, 18.0))
		# radar
		var rc := _p(GunneryPanel.RADAR_CENTER)
		var rr := GunneryPanel.RADAR_RADIUS * K
		draw_circle(rc, rr, Color(0.07, 0.09, 0.12))
		for f in [0.34, 0.67, 1.0]:
			draw_arc(rc, rr * f, 0.0, TAU, 32, Color(0.35, 0.45, 0.55, 0.9), 1.0)
		draw_line(rc, rc + Vector2(0.0, -rr), Color(1.0, 0.85, 0.3, 0.9), 2.0)
		draw_line(rc, rc + Vector2(-rr * 0.2, -rr * 0.97), Color(1.0, 0.85, 0.3, 0.35), 1.0)
		draw_line(rc, rc + Vector2(rr * 0.2, -rr * 0.97), Color(1.0, 0.85, 0.3, 0.35), 1.0)
		draw_circle(rc + Vector2(rr * 0.07, -rr * 0.62), 5.0, Color(0.95, 0.35, 0.3))
		UiTheme.text(self, rc + Vector2(rr * 0.07 + 9.0, -rr * 0.62 + 5.0), "18m", Color(1.0, 0.8, 0.75))
		UiTheme.text(self, rc + Vector2(-rr, rr + 22.0), "TRAVERSE / RADAR", Color(0.8, 0.84, 0.92))
		_badge(4, rc + Vector2(-rr - 4.0, -rr + 6.0))
		# wind
		var wind := _r(GunneryPanel.WIND_RECT)
		UiTheme.draw_panel(self, wind, 1)
		draw_circle(wind.get_center() + Vector2(0.0, -10.0), wind.size.x * 0.32, Color(0.1, 0.12, 0.16))
		draw_line(wind.get_center() + Vector2(-16.0, 4.0), wind.get_center() + Vector2(16.0, -24.0), Color(0.55, 0.95, 0.65), 3.0)
		UiTheme.text(self, wind.position + Vector2(10.0, wind.size.y - 14.0), "WIND", Color(0.8, 0.84, 0.92))
		_badge(5, wind.position + Vector2(wind.size.x * 0.5, -14.0))
		# last-shot sidebar
		var side := _r(GunneryPanel.SIDEBAR_RECT)
		UiTheme.text(self, side.position + Vector2(10.0, 22.0), "LAST SHOT", Color(1.0, 0.82, 0.25))
		for i in 4:
			draw_line(side.position + Vector2(10.0, 40.0 + i * 16.0), side.position + Vector2(side.size.x - 10.0, 40.0 + i * 16.0), Color(0.45, 0.48, 0.56), 2.0)
		var target := side.position + Vector2(side.size.x * 0.5, side.size.y * 0.66)
		draw_circle(target, 16.0, Color(0.9, 0.35, 0.3, 0.4))
		draw_arc(target, 16.0, 0.0, TAU, 20, Color(1.0, 0.45, 0.4), 2.0)
		draw_line(target + Vector2(9.0, -22.0), target + Vector2(21.0, -10.0), Color.WHITE, 2.0)
		draw_line(target + Vector2(21.0, -22.0), target + Vector2(9.0, -10.0), Color.WHITE, 2.0)
		_badge(6, side.position + Vector2(side.size.x - 16.0, 16.0))
		# power bar
		var bar := _r(GunneryPanel.BAR_RECT)
		draw_rect(bar, Color(0.07, 0.08, 0.11))
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * 0.6, bar.size.y)), Color(0.95, 0.65, 0.2))
		draw_rect(bar, Color(0.5, 0.52, 0.6), false, 2.0)
		UiTheme.text(self, bar.position + Vector2(10.0, bar.size.y - 5.0), "POWER 60%", Color.WHITE)
		_badge(7, bar.position + Vector2(bar.size.x + 2.0 - 18.0, -14.0))
		draw_rect(Rect2(Vector2.ZERO, GunneryPanel.PANEL_SIZE * K), inset, false, 1.0)
