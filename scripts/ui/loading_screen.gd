class_name LoadingScreen
extends Control
## Opaque cover shown while `Game` builds a battle (map seeding, board, units). Game names the phase it is entering with
## `enter(key, progress)` and the screen picks a vanity line for that phase from its pool; a phase that takes long enough
## rotates through the pool. `await finish()` fades the cover out and frees it. Built with `LoadingScreen.attach(host)`.

const LAYER := 100
const ROTATE_EVERY := 1.8        ## seconds a vanity line stays up while a phase drags on
const FADE := 0.35
const BAR_WIDTH := 460.0
const BAR_SPEED := 2.5           ## how fast the bar catches up with its target (per second)
const GOLD := Color(1.0, 0.85, 0.40)
const SLATE := Color(0.70, 0.75, 0.88)

## phase key -> title and the vanity lines that may be shown while it runs
const PHASES := {
	"sky": {
		"title": "ROLLING OUT THE SKY",
		"lines": [
			"Inflating the clouds...",
			"Pointing the sun in a helpful direction...",
			"Checking the horizon for stray horizons...",
			"Persuading the wind to pick a side...",
		],
	},
	"terrain": {
		"title": "SEEDING THE MAP",
		"lines": [
			"Convincing the hills to stand up straight...",
			"Teaching the river to meander politely...",
			"Planting trees in tactically awkward places...",
			"Placing rocks exactly where you will want to shoot through...",
			"Asking the villagers to leave a few doors open...",
			"Rolling dice for the number of stumps...",
			"Laying roads that go roughly where they should...",
			"Negotiating a bridge permit...",
			"Counting hexes (twice)...",
			"Hiding a ruin behind a perfectly good tree...",
		],
	},
	"board": {
		"title": "LAYING THE BOARD",
		"lines": [
			"Tiling the grass, one hexagon at a time...",
			"Filling the river with slightly wet pixels...",
			"Fitting every prop with a collision hat...",
			"Sweeping the battlefield of last game's craters...",
			"Calibrating the shadows...",
			"Measuring the cliffs. They are, in fact, tall...",
		],
	},
	"units": {
		"title": "MUSTERING THE TROOPS",
		"lines": [
			"Polishing the barrels...",
			"Waking the howitzer crew...",
			"Telling the infantry to stop admiring the view...",
			"Painting team colours on everything that holds still...",
			"Loading shells. Mostly the right way round...",
			"Checking that the tank has all of its turret...",
		],
	},
	"final": {
		"title": "READYING THE GUNS",
		"lines": [
			"Wiring up the wind gauge...",
			"Tuning the radar to the local noise...",
			"Handing out the first turn...",
			"Drawing lots for who fires first...",
			"Unfolding the map. Pretending it was already folded...",
		],
	},
}

var _layer: CanvasLayer
var _title := UiTheme.label("", GOLD, UiTheme.LARGE, HORIZONTAL_ALIGNMENT_CENTER)
var _line := UiTheme.label("", SLATE, UiTheme.SMALL, HORIZONTAL_ALIGNMENT_CENTER)
var _seed := UiTheme.label("", Color(0.6, 0.65, 0.75), UiTheme.SMALL, HORIZONTAL_ALIGNMENT_CENTER)
var _bar := ProgressBar.new()
var _rng := RandomNumberGenerator.new()
var _phase := ""
var _last_line := ""
var _since_line := 0.0
var _target := 0.0
var _fading := false


## A loading screen on a top-most CanvasLayer under `host`.
static func attach(host: Node) -> LoadingScreen:
	var screen := LoadingScreen.new()
	screen._layer = CanvasLayer.new()
	screen._layer.layer = LAYER
	host.add_child(screen._layer)
	screen._layer.add_child(screen)
	return screen


func _ready() -> void:
	_rng.randomize()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   # nothing underneath may be clicked while it builds
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.07, 0.08, 0.11, 1.0)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel_style(26))
	centre.add_child(panel)
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(BAR_WIDTH, 0.0)
	col.add_theme_constant_override("separation", 12)
	panel.add_child(col)
	col.add_child(UiTheme.label("TACTICS PROTO", SLATE, UiTheme.SMALL, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(_title)
	_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_line.custom_minimum_size = Vector2(BAR_WIDTH, 40.0)   # two lines tall, so the panel does not jump when the text changes
	_line.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	col.add_child(_line)
	_bar.show_percentage = false
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.custom_minimum_size = Vector2(0.0, 14.0)
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0.13, 0.14, 0.19)
	var fill := StyleBoxFlat.new()
	fill.bg_color = GOLD
	_bar.add_theme_stylebox_override("background", back)
	_bar.add_theme_stylebox_override("fill", fill)
	col.add_child(_bar)
	col.add_child(_seed)


func _process(delta: float) -> void:
	_bar.value = move_toward(_bar.value, _target, BAR_SPEED * delta)
	_since_line += delta
	if _since_line >= ROTATE_EVERY and not _fading:
		_pick_line()


## Starts a phase: its title and a fresh vanity line show, and the bar heads for `progress` (0..1, the share done when it ends).
func enter(key: String, progress: float) -> void:
	_phase = key
	_target = clampf(progress, 0.0, 1.0)
	_title.text = PHASES[key]["title"]
	_pick_line()


## The map seed, once it is known.
func show_seed(value: int) -> void:
	_seed.text = "Map seed %d" % value


## Fills the bar, fades the cover out and frees it.
func finish() -> void:
	_fading = true
	_target = 1.0
	_bar.value = 1.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, FADE)
	await tween.finished
	_layer.queue_free()


func _pick_line() -> void:
	_since_line = 0.0
	var lines: Array = PHASES[_phase]["lines"]
	var next: String = lines[_rng.randi() % lines.size()]
	if lines.size() > 1:
		while next == _last_line:
			next = lines[_rng.randi() % lines.size()]
	_last_line = next
	_line.text = next
