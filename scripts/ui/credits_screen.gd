class_name CreditsScreen
extends Control
## Credits overlay of the start menu: the 3D models, animation / prop packs and UI art the game is built on, with their licences
## and source links (clickable; they open in a new browser tab on the web build). Keep it in step with CREDITS.md.
## Esc / Enter / the BACK button close it.

signal closed

const CC_BY := "[url=http://creativecommons.org/licenses/by/4.0/]CC-BY-4.0[/url]"
const CC_BY_SA := "[url=http://creativecommons.org/licenses/by-sa/4.0/]CC-BY-SA-4.0[/url]"
const CC0 := "[url=https://creativecommons.org/publicdomain/zero/1.0/]CC0[/url]"

## [title, author, author link, source link, licence (bbcode), used for]
const MODELS := [
	["Sherman Tank - Stylised Blender lowpoly WW2", "matthall", "https://sketchfab.com/matthall",
		"https://sketchfab.com/3d-models/sherman-tank-stylised-blender-lowpoly-ww2-7f9284c0405b45308df38e5c1dd5dd6a", CC_BY, "Tank"],
	["Stylized tank", "Andrew (clon6707)", "https://sketchfab.com/clon6707",
		"https://sketchfab.com/3d-models/stylized-tank-b5222c56e8304a5cbbc793c8ce87aae2", CC_BY, "Howitzer"],
	["Stylized Soldier2", "denj666", "https://sketchfab.com/denj666",
		"https://sketchfab.com/3d-models/stylized-soldier2-0c86c85834424270ba2669817cc6e9bf", CC_BY, "Infantry"],
	["Bazooka Stylized Toon", "Mora (MoraAzul)", "https://sketchfab.com/MoraAzul",
		"https://sketchfab.com/3d-models/bazooka-stylized-toon-3894c6b625cd4fa5a23cda477980ccf4", CC_BY, "Infantry RPG"],
	["M-16 Rifle", "iedalton", "https://sketchfab.com/iedalton",
		"https://sketchfab.com/3d-models/m-16-rifle-3ba5491cc8cd4722b663fa594faae608", CC_BY, "Infantry rifle"],
	["Octo Cannon", "Matt LeMoine", "https://sketchfab.com/Matt_LeMoine",
		"https://sketchfab.com/3d-models/octo-cannon-bedab0028eef4a8aba40f7d02d84fae0", CC_BY, "Fantasy artillery"],
	["Tank Shell (bullet)", "inether (xxadventusxx)", "https://sketchfab.com/xxadventusxx",
		"https://sketchfab.com/3d-models/tank-shell-bullet-f3bf44d02cf64d669e4e44ae8b95e803", CC_BY_SA, "Shells in flight"],
]

## [title, author, link, licence (bbcode), used for]
const PACKS := [
	["KayKit Adventurers Character Pack 2.0", "Kay Lousberg", "https://kaylousberg.com", CC0, "Mage, Ranger and Knight"],
	["KayKit Character Animations 1.1", "Kay Lousberg", "https://kaylousberg.com", CC0, "Soldier and hero animations"],
	["KayKit Fantasy Weapons Bits 1.0", "Kay Lousberg", "https://kaylousberg.com", CC0, "Staff, bow and arrows"],
	["KayKit Medieval Hexagon Pack 1.0", "Kay Lousberg", "https://kaylousberg.com", CC0, "Terrain tiles, trees, rocks, buildings"],
	["Flat Theme UI pack", "Crusenho", "https://crusenho.itch.io", CC_BY, "Buttons and panels"],
]

const FONT_NOTE := "Thaleah Fat pixel font."
const SHARE_ALIKE_NOTE := "The shell model is licensed CC-BY-SA-4.0: the game only scales and rotates it, and that model stays under the same licence."

var _text: RichTextLabel


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)    # swallows clicks meant for the menu behind

	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel_style(22))
	centre.add_child(panel)
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(760.0, 0.0)
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)

	col.add_child(UiTheme.label("CREDITS", Color(1.0, 0.85, 0.40), UiTheme.LARGE, HORIZONTAL_ALIGNMENT_CENTER))

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var room := maxf(get_viewport_rect().size.y - 230.0, 240.0)
	scroll.custom_minimum_size = Vector2(0.0, minf(room, 340.0))
	col.add_child(scroll)
	_text = RichTextLabel.new()
	_text.bbcode_enabled = true
	_text.fit_content = true
	_text.scroll_active = false
	_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text.add_theme_font_override("normal_font", UiTheme.font)
	_text.add_theme_font_size_override("normal_font_size", UiTheme.SMALL)
	_text.add_theme_color_override("default_color", Color(0.85, 0.88, 0.95))
	_text.add_theme_color_override("font_outline_color", Color.BLACK)
	_text.add_theme_constant_override("outline_size", 4)
	_text.meta_clicked.connect(func(meta: Variant) -> void: OS.shell_open(str(meta)))
	scroll.add_child(_text)
	_text.text = _bbcode()

	var back := UiTheme.button("BACK", Color(0.55, 0.85, 0.55), UiTheme.SMALL)
	back.pressed.connect(close)
	col.add_child(back)


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo \
			and (key.keycode == KEY_ESCAPE or key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER):
		close()
	get_viewport().set_input_as_handled()    # modal: nothing reaches the menu behind


func close() -> void:
	closed.emit()
	queue_free()


static func _bbcode() -> String:
	var s := "[color=#ffd966]3D MODELS[/color]\n"
	for m: Array in MODELS:
		s += "[color=#ffffff]%s[/color] by [url=%s]%s[/url] - %s - %s - [url=%s]source[/url]\n" % [m[0], m[2], m[1], m[5], m[4], m[3]]
	s += "\n[color=#ffd966]PACKS AND ART[/color]\n"
	for p: Array in PACKS:
		s += "[color=#ffffff]%s[/color] by [url=%s]%s[/url] - %s - %s\n" % [p[0], p[2], p[1], p[4], p[3]]
	s += "%s\n\n" % FONT_NOTE
	s += "[color=#9aa5c0]%s\nThank you to everyone above for sharing their work.[/color]" % SHARE_ALIKE_NOTE
	return s
