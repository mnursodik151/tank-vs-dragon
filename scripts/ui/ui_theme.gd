class_name UiTheme
extends RefCounted
## One place for the look of the UI: the pixel font (m6x11plus) and the Flat_Theme sprites (res://UI/Flat_Theme/Sprites),
## drawn as 9-slice boxes that can be tinted. Every custom `_draw` control goes through this.
##
## m6x11plus is a pixel font whose native grid is 16 px (and 32, 48 ...; other sizes smear): `fs()` folds every size the
## layout code asks for into SMALL or LARGE. Pixel art stays crisp only at whole-number scales too (see `snap_scale`).

const FONT_PATH := "res://UI/Fonts/ThaleahFat.ttf"
const SPRITE_PATH := "res://UI/Flat_Theme/Sprites/UI_Flat_%s.png"
const SMALL := 16
const LARGE := 32
const LARGE_FROM := 22     ## requested sizes at or above this become LARGE

static var font: Font = load(FONT_PATH)
static var _boxes := {}
static var _textures := {}


## Font size for a requested size (11 / 22 only - the font's native pixel grid).
static func fs(requested: int) -> int:
	return LARGE if requested >= LARGE_FROM else SMALL


## Largest whole-number scale <= `fit` (at least 1): pixel art and pixel fonts blur at fractional scales.
static func snap_scale(fit: float) -> float:
	return maxf(floorf(fit), 1.0)


static func texture(sprite: String) -> Texture2D:
	if not _textures.has(sprite):
		_textures[sprite] = load(SPRITE_PATH % sprite)
	return _textures[sprite]


## 9-slice box from a sprite ("Frame01a", "FrameSlot01b", "Button01a_4", "Bar05a" ...). `margin` is the border in sprite pixels.
## Cached per (sprite, margin, tint).
static func box(sprite: String, margin: int = 5, tint: Color = Color.WHITE) -> StyleBoxTexture:
	var key := "%s|%d|%s" % [sprite, margin, tint.to_html()]
	if not _boxes.has(key):
		var sb := StyleBoxTexture.new()
		sb.texture = texture(sprite)
		sb.set_texture_margin_all(margin)
		sb.modulate_color = tint
		_boxes[key] = sb
	return _boxes[key]


static func draw_box(canvas: CanvasItem, sprite: String, rect: Rect2, margin: int = 5, tint: Color = Color.WHITE) -> void:
	canvas.draw_style_box(box(sprite, margin, tint), rect)


## Dark panel: the grey frame tinted slate. `depth` 0 = the main window, 1 = an inset display (darker).
static func draw_panel(canvas: CanvasItem, rect: Rect2, depth: int = 0) -> void:
	var tint := Color(0.30, 0.33, 0.42, 0.97) if depth == 0 else Color(0.16, 0.17, 0.22, 0.98)
	canvas.draw_style_box(box("Frame01a", 5, tint), rect)


## A keyed Button in the Flat_Theme look: raised cream key tinted `tint`, lighter on hover, flat when pressed, dim when disabled.
static func button(text: String, tint: Color = Color(0.62, 0.66, 0.78), size: int = LARGE) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0.0, size * 2.0)
	b.add_theme_font_override("font", font)
	b.add_theme_font_size_override("font_size", fs(size))
	b.add_theme_color_override("font_color", Color(0.10, 0.11, 0.15))
	b.add_theme_color_override("font_hover_color", Color(0.10, 0.11, 0.15))
	b.add_theme_color_override("font_pressed_color", Color(0.10, 0.11, 0.15))
	b.add_theme_color_override("font_disabled_color", Color(0.10, 0.11, 0.15, 0.5))
	b.add_theme_stylebox_override("normal", box("Button01a_4", 5, tint))
	b.add_theme_stylebox_override("hover", box("Button01a_4", 5, tint.lightened(0.25)))
	b.add_theme_stylebox_override("pressed", box("Button01a_1", 5, tint.darkened(0.15)))
	b.add_theme_stylebox_override("disabled", box("Button01a_1", 5, Color(tint, 0.45)))
	return b


## Panel background for a PanelContainer: the slate frame with `pad` px of content margin.
static func panel_style(pad: int = 14, depth: int = 0) -> StyleBoxTexture:
	var sb: StyleBoxTexture = box("Frame01a", 5, Color(0.30, 0.33, 0.42, 0.97) if depth == 0 else Color(0.16, 0.17, 0.22, 0.98)).duplicate()
	sb.set_content_margin_all(pad)
	return sb


## A Label in the UI font with the usual dark outline.
static func label(text: String, color: Color = Color.WHITE, size: int = SMALL, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", fs(size))
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	return l


## Unshaded text in the UI font at a folded size. Same argument order as `draw_string` minus the font.
static func text(canvas: CanvasItem, pos: Vector2, s: String, color: Color, size: int = SMALL,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0) -> void:
	canvas.draw_string(font, pos, s, align, width, fs(size), color)


## Applies the pixel font to a 3D label (unit labels, popups) with crisp filtering.
static func style_label3d(label: Label3D, size: int) -> void:
	label.font = font
	label.font_size = size
	label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
