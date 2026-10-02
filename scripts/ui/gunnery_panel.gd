class_name GunneryPanel
extends Control
## Popup "gunnery screen" for GUNNERY weapons. The world only gave a coarse bearing; here the
## gunner sets up the shot:
##   * AMMO + CHARGES (top strip): pick the round (each has a weight that changes muzzle speed and
##     wind drift) and 1-3 charges (more charges = higher muzzle speed = longer reach, +AP each).
##   * ELEVATION (left): side view. Drag the dial, mouse wheel or Up/Down. A live ESTIMATED arc shows
##     how far the shell should fly in STILL AIR for the current round, charge, angle and power.
##   * TRAVERSE (right): top-down radar following the camera. Drag or Left/Right swing the barrel
##     a few degrees around the world bearing. It shows the line of sight, the reach of every charge
##     level (C1, C2, C3) and the enemies. Nothing is plotted for the shot itself: no flight path, no
##     landing mark - the gunner has to work out where it will fall.
##   * Only enemies the team can see are on the radar at all (Intel.sees); the rest are unknown - no blip, no distance.
##     Two sight rings: inside a unit's sight radius the distance is MEASURED with a small standard deviation
##     ("18m"); in the outer ring (Intel.OUTER_BAND beyond, amber outline) it is only an ESTIMATE ("~18m" + a ring
##     of one deviation that grows with the distance); beyond that nothing. The noise draw is kept until the next
##     turn, so re-opening the panel never averages it away.
##   * LAST SHOT (sidebar, far right): this unit's previous gunnery shot as a point of reference - its setup next
##     to the current one, and when it struck an enemy a top-down picture of the hit in the gun's own frame
##     (up = down-range): footprint and heading of the target, where the shell fell and every blast that reached it
##     (cluster bomblets, incendiary fire radius). Meant for correcting the next shot at the same target.
##   * WIND (far right): speed and direction relative to the barrel. Its effect is NOT in any estimate.
##   * POWER (bottom): hold Space (or press and hold on the bar) to charge, release to fire.
## Estimates follow the ground (a hill ends the arc early and is flagged BLOCKED, higher / lower targets change the
## landing) and the barrel cannot be depressed into ground just ahead of the muzzle (red part of the dial), but they
## ignore wind, props, round-to-round scatter and the gun's own aim error. The radar tints cells higher / lower
## than the gun and marks cliff edges.
## The whole panel is scaled up to fit the viewport (layout constants are in unscaled pixels).
## Keys: Up/Down elevation, Left/Right traverse, T round, C charge, Space charge/fire, Esc cancel.
## run() resolves to FireParams, or null when cancelled.

signal finished(params: FireParams)

const MAIN_WIDTH := 780.0               # the gunnery controls; the last-shot sidebar sits to their right
const PANEL_SIZE := Vector2(1004.0, 440.0)
const SIDEBAR_RECT := Rect2(786.0, 6.0, 212.0, 428.0)
const MAX_SCALE := 3.0                  # the panel grows to fit the viewport, up to this factor
const PIXEL_SNAP := false               # true = whole-number scales only (crisper pixels, but the panel stays small on 720p)
const SCREEN_MARGIN := 8.0
const BOTTOM_MARGIN := 132.0
const PIVOT_X := 84.0
const GROUND_Y := 298.0
const DIAL_RADIUS := 78.0
const SIDE_WIDTH := 330.0               # pixels available for the ruler (metres -> px)
const SIDE_MAX_HEIGHT := 175.0
const ELEV_RECT := Rect2(8.0, 92.0, 430.0, 222.0)
const RADAR_CENTER := Vector2(560.0, 208.0)
const RADAR_RADIUS := 104.0
const WIND_RECT := Rect2(676.0, 92.0, 96.0, 222.0)
const BAR_RECT := Rect2(24.0, 368.0, 732.0, 26.0)
const PITCH_RATE := deg_to_rad(18.0)    # keyboard elevation speed, rad/s
const YAW_RATE := deg_to_rad(8.0)       # keyboard traverse speed, rad/s
const RULER_BUCKETS := [8.0, 12.0, 16.0, 24.0, 32.0, 48.0, 64.0]
const RADAR_BUCKETS := [12.0, 18.0, 24.0, 32.0, 40.0]
const EST_STEP := 0.05                  # still-air flight sampling, seconds
const HIGHER_TINT := Color(0.95, 0.72, 0.30)
const LOWER_TINT := Color(0.30, 0.50, 0.90)

enum Drag { NONE, ELEVATION, TRAVERSE }

var _unit: Unit
var _weapon: WeaponStats
var _ctx: BattleContext
var _active := false
var _base_yaw := 0.0
var _yaw := 0.0
var _pitch := 0.0
var _power := 0.0
var _charging := false
var _drag := Drag.NONE
var _round_index := 0
var _charge := 1
var _choices: Array[RoundStats] = []
var _memory: Dictionary = {}   # WeaponStats -> {"round": int, "charge": int}


func _init() -> void:
	size = PANEL_SIZE
	custom_minimum_size = PANEL_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false


## Opens the panel for `unit`'s weapon with the world-chosen bearing `base_yaw`. Awaitable.
func run(unit: Unit, weapon: WeaponStats, ctx: BattleContext, base_yaw: float) -> FireParams:
	_unit = unit
	_weapon = weapon
	_ctx = ctx
	_base_yaw = base_yaw
	_yaw = base_yaw
	_pitch = clampf(deg_to_rad(weapon.default_pitch_deg), _pitch_floor(), deg_to_rad(weapon.pitch_max_deg))
	_power = 0.0
	_charging = false
	_drag = Drag.NONE
	_choices.clear()
	if weapon.rounds.is_empty():
		_choices.append(RoundStats.new())
	else:
		_choices.append_array(weapon.rounds)
	var mem: Dictionary = _memory.get(weapon, {"round": 0, "charge": 1})
	_round_index = clampi(mem["round"], 0, _choices.size() - 1)
	_charge = clampi(mem["charge"], 1, weapon.max_charges())
	while _charge > 1 and weapon.total_cost(_charge) > unit.ap + Action.AP_EPSILON:
		_charge -= 1
	_active = true
	visible = true
	_apply_turret()
	var result: FireParams = await finished
	_memory[weapon] = {"round": _round_index, "charge": _charge}
	_active = false
	visible = false
	unit.lower_barrel()
	return result


func _process(delta: float) -> void:
	if not _active:
		return
	_fit_to_viewport()

	var dp := float(Input.is_key_pressed(KEY_UP)) - float(Input.is_key_pressed(KEY_DOWN))
	if dp != 0.0:
		_set_pitch(_pitch + dp * PITCH_RATE * delta)
	var dy := float(Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_LEFT))
	if dy != 0.0:
		_set_yaw(_yaw + dy * _clockwise_sign() * YAW_RATE * delta)

	if _charging:
		_power = minf(1.0, _power + delta / maxf(_weapon.charge_time, 0.1))
		if _power >= 1.0:
			_fire()
	_apply_turret()
	queue_redraw()


## Scales the panel up to the room above the toolbar and centres it horizontally.
func _fit_to_viewport() -> void:
	var vp := get_viewport().get_visible_rect().size
	var k := minf((vp.x - 2.0 * SCREEN_MARGIN) / PANEL_SIZE.x, (vp.y - BOTTOM_MARGIN - SCREEN_MARGIN) / PANEL_SIZE.y)
	k = minf(UiTheme.snap_scale(k), MAX_SCALE) if PIXEL_SNAP else clampf(k, 1.0, MAX_SCALE)
	scale = Vector2(k, k)
	position = Vector2(floorf((vp.x - PANEL_SIZE.x * k) / 2.0), floorf(vp.y - PANEL_SIZE.y * k - BOTTOM_MARGIN))


# --- selections ---------------------------------------------------------------

func _current_round() -> RoundStats:
	return _choices[_round_index]


func _set_round(i: int) -> void:
	_round_index = posmod(i, _choices.size())


func _set_charge(c: int) -> void:
	if c < 1 or c > _weapon.max_charges() or _weapon.total_cost(c) > _unit.ap + Action.AP_EPSILON:
		return
	_charge = c


func _cycle_charge() -> void:
	var c := _charge % _weapon.max_charges() + 1
	while c != _charge and _weapon.total_cost(c) > _unit.ap + Action.AP_EPSILON:
		c = c % _weapon.max_charges() + 1
	_set_charge(c)


func _set_pitch(value: float) -> void:
	_pitch = clampf(value, _pitch_floor(), deg_to_rad(_weapon.pitch_max_deg))


## Lowest usable elevation: the weapon's own limit, raised when ground just ahead of the muzzle would be in the way
## (never above the weapon's maximum).
func _pitch_floor() -> float:
	var dir := _aim_dir()
	return clampf(Ballistics.terrain_pitch_floor(_ctx.board, _unit.muzzle_position(dir), dir),
		deg_to_rad(_weapon.pitch_min_deg), deg_to_rad(_weapon.pitch_max_deg))


func _set_yaw(value: float) -> void:
	var limit := deg_to_rad(_weapon.traverse_deg)
	_yaw = _base_yaw + clampf(wrapf(value - _base_yaw, -PI, PI), -limit, limit)
	_pitch = maxf(_pitch, _pitch_floor())   # a new bearing may face a hill


func _apply_turret() -> void:
	_unit.aim(Vector3(sin(_yaw), 0.0, cos(_yaw)), _pitch)


func _camera() -> TacticsCamera:
	return get_viewport().get_camera_3d() as TacticsCamera


## +1 when increasing yaw turns the barrel clockwise on screen, -1 otherwise.
func _clockwise_sign() -> float:
	var cam := _camera()
	if cam == null:
		return 1.0
	var a := cam.to_screen_dir(Vector3(sin(_yaw), 0.0, cos(_yaw)))
	var b := cam.to_screen_dir(Vector3(sin(_yaw + 0.05), 0.0, cos(_yaw + 0.05)))
	return 1.0 if a.x * b.y - a.y * b.x > 0.0 else -1.0


# --- input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	var key := event as InputEventKey
	if key == null or key.echo:
		return
	if key.keycode == KEY_SPACE:
		get_viewport().set_input_as_handled()
		if key.pressed:
			_start_charge()
		else:
			_release_charge()
	elif key.pressed:
		match key.keycode:
			KEY_ESCAPE:
				get_viewport().set_input_as_handled()
				finished.emit(null)
			KEY_T:
				get_viewport().set_input_as_handled()
				_set_round(_round_index + (-1 if key.shift_pressed else 1))
			KEY_C:
				get_viewport().set_input_as_handled()
				_cycle_charge()


func _gui_input(event: InputEvent) -> void:
	if not _active:
		return
	var button := event as InputEventMouseButton
	if button != null:
		accept_event()
		if button.button_index == MOUSE_BUTTON_RIGHT and button.pressed:
			finished.emit(null)
		elif button.button_index == MOUSE_BUTTON_WHEEL_UP and button.pressed:
			_set_pitch(_pitch + deg_to_rad(1.0))
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN and button.pressed:
			_set_pitch(_pitch - deg_to_rad(1.0))
		elif button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				_on_press(button.position)
			else:
				_drag = Drag.NONE
				_release_charge()
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _drag != Drag.NONE:
		accept_event()
		_drag_to(motion.position)


func _round_rect(i: int) -> Rect2:
	return Rect2(16.0 + i * 102.0, 32.0, 96.0, 28.0)


func _charge_rect(i: int) -> Rect2:
	return Rect2(512.0 + i * 36.0, 32.0, 30.0, 28.0)


func _on_press(p: Vector2) -> void:
	if _choices.size() > 1:
		for i in _choices.size():
			if _round_rect(i).has_point(p):
				_set_round(i)
				return
	for i in _weapon.max_charges():
		if _charge_rect(i).has_point(p):
			_set_charge(i + 1)
			return
	if BAR_RECT.has_point(p):
		_start_charge()
	elif (p - RADAR_CENTER).length() <= RADAR_RADIUS:
		_drag = Drag.TRAVERSE
		_drag_to(p)
	elif ELEV_RECT.has_point(p):
		_drag = Drag.ELEVATION
		_drag_to(p)


func _drag_to(p: Vector2) -> void:
	if _drag == Drag.ELEVATION:
		_set_pitch(atan2(_pivot().y - p.y, p.x - PIVOT_X))
	elif _drag == Drag.TRAVERSE:
		var cam := _camera()
		var v := p - RADAR_CENTER
		if cam != null and v.length() > 6.0:
			var dir := cam.from_screen_dir(v)
			_set_yaw(atan2(dir.x, dir.z))


func _start_charge() -> void:
	if not _charging:
		_power = 0.0
		_charging = true


func _release_charge() -> void:
	if _charging:
		_fire()


func _fire() -> void:
	_charging = false
	var ammo: RoundStats = _current_round() if not _weapon.rounds.is_empty() else null
	finished.emit(FireParams.make(_weapon, _yaw, _pitch, maxf(_power, _weapon.min_power), _charge, ammo))


# --- estimation ---------------------------------------------------------------

func _speed_at(power: float, charge: int = -1) -> float:
	var c := _charge if charge < 0 else charge
	return _weapon.muzzle_velocity * _weapon.charge_scale(c) * _current_round().velocity_mult() * power


func _aim_dir() -> Vector3:
	return Vector3(sin(_yaw), 0.0, cos(_yaw))


## Still-air flight over the real ground (wind deliberately left out): the arc ends where it meets the terrain.
## Heights are relative to the ground the gun stands on. Returns {"t", "vh", "vy", "h0", "range", "apex",
## "land_y", "blocked"} (blocked = it struck rising ground before its apex) or {} if it never lands.
func _estimate(speed: float) -> Dictionary:
	if speed < 0.01:
		return {}
	var g := Ballistics.gravity()
	var dir := _aim_dir()
	var muzzle := _unit.muzzle_position(dir)
	var base := _ctx.board.surface_y(_unit.global_position)
	var vh := speed * cos(_pitch)
	var vy := speed * sin(_pitch)
	var gap := func(t: float) -> float:   # shell height above the ground under it
		return muzzle.y + vy * t - 0.5 * g * t * t - _ctx.board.surface_y(muzzle + dir * (vh * t))
	var prev := 0.0
	var land := -1.0
	var t := 0.0
	while t < Ballistics.MAX_TIME:
		t += EST_STEP
		if gap.call(t) <= 0.0:
			var lo := prev
			var hi := t
			if gap.call(lo) <= 0.0:
				hi = lo
			else:
				for i in 12:
					var mid := (lo + hi) * 0.5
					if gap.call(mid) > 0.0:
						lo = mid
					else:
						hi = mid
			land = hi
			break
		prev = t
	if land < 0.0:
		return {}
	var h0 := muzzle.y - base
	return {
		"t": land, "vh": vh, "vy": vy, "h0": h0,
		"range": vh * land,
		"apex": h0 + (vy * vy / (2.0 * g) if vy > 0.0 else 0.0),
		"land_y": muzzle.y + vy * land - 0.5 * g * land * land - base,
		"blocked": vy - g * land > 0.0,
	}


## Ground height (relative to the gun's own ground) every `step` metres along the aim line.
func _ground_profile(length: float, step: float) -> PackedFloat32Array:
	var dir := _aim_dir()
	var base := _ctx.board.surface_y(_unit.global_position)
	var origin := _unit.global_position
	var out := PackedFloat32Array()
	var d := 0.0
	while d <= length + 0.001:
		out.append(_ctx.board.surface_y(origin + dir * d) - base)
		d += step
	return out


# --- drawing ----------------------------------------------------------------

func _pivot() -> Vector2:
	return Vector2(PIVOT_X, GROUND_Y - 22.0)


func _draw() -> void:
	if not _active:
		return
	var font := UiTheme.font
	UiTheme.draw_panel(self, Rect2(Vector2.ZERO, size), 0)
	draw_string(font, Vector2(16.0, 22.0), "%s  -  GUNNERY" % _weapon.display_name.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.SMALL, Color(1.0, 0.82, 0.25))
	draw_string(font, Vector2(0.0, 428.0), "Up/Down elevation   Left/Right traverse   T ammo   C charge   Space power   Esc cancel",
		HORIZONTAL_ALIGNMENT_CENTER, MAIN_WIDTH, UiTheme.fs(10), Color(0.6, 0.63, 0.7))
	_draw_selectors(font)
	var power_for_est := _power if _power > 0.02 else 1.0
	var est := _estimate(_speed_at(power_for_est))
	_draw_side_view(font, est)
	_draw_radar(font)
	_draw_wind_box(font)
	_draw_power(font)
	_draw_last_shot(font)


func _draw_selectors(font: Font) -> void:
	var ammo := _current_round()
	if _choices.size() > 1:
		for i in _choices.size():
			var r := _round_rect(i)
			var c := _choices[i].color
			var selected := i == _round_index
			# raised cream key tinted with the round colour when selected, a flat dark key otherwise
			UiTheme.draw_box(self, "Button01a_4" if selected else "Button01a_1", r, 5, c.lightened(0.15) if selected else Color(0.30, 0.32, 0.38))
			draw_string(font, r.position + Vector2(0.0, 19.0), _choices[i].short_name, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, UiTheme.fs(14),
				Color(0.08, 0.09, 0.14) if selected else Color(0.7, 0.72, 0.78))
	else:
		draw_string(font, Vector2(16.0, 60.0), "Ammo: %s" % ammo.display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(14), ammo.color)

	draw_string(font, Vector2(442.0, 51.0), "CHARGE", HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(10), Color(0.7, 0.72, 0.8))
	for i in _weapon.max_charges():
		var r := _charge_rect(i)
		var affordable := _weapon.total_cost(i + 1) <= _unit.ap + Action.AP_EPSILON
		var filled := i < _charge
		var pip_tint := Color(1.0, 0.82, 0.25) if filled else Color(0.30, 0.32, 0.38)
		if not affordable:
			pip_tint = Color(0.85, 0.35, 0.3) if filled else Color(0.38, 0.22, 0.22)
		UiTheme.draw_box(self, "Button02a_4" if filled else "Button02a_1", r, 5, pip_tint)
		draw_string(font, r.position + Vector2(0.0, 19.0), str(i + 1), HORIZONTAL_ALIGNMENT_CENTER, r.size.x, UiTheme.fs(14),
			Color.BLACK if filled else (Color(0.8, 0.82, 0.9) if affordable else Color(0.8, 0.3, 0.25)))
	var cost := _weapon.total_cost(_charge)
	var over := cost > _unit.ap + Action.AP_EPSILON
	var cost_text := "COST %.1f AP" % cost
	if _charge > 1:
		cost_text = "COST %.1f (%.1f+%dch)" % [cost, _weapon.ap_cost, _charge - 1]
	draw_string(font, Vector2(0.0, 51.0), cost_text, HORIZONTAL_ALIGNMENT_RIGHT, MAIN_WIDTH - 14.0, UiTheme.fs(13),
		Color(1.0, 0.45, 0.4) if over else Color(0.75, 0.9, 1.0))
	draw_string(font, Vector2(0.0, 22.0), "AP %.1f" % _unit.ap, HORIZONTAL_ALIGNMENT_RIGHT, MAIN_WIDTH - 14.0, UiTheme.fs(12), Color(0.7, 0.72, 0.8))
	draw_string(font, Vector2(0.0, 76.0), "wt %.2f  spd x%.2f  wind x%.2f" % [ammo.weight, ammo.velocity_mult(), ammo.wind_mult()],
		HORIZONTAL_ALIGNMENT_RIGHT, MAIN_WIDTH - 14.0, UiTheme.fs(11), ammo.color.lightened(0.2))
	draw_multiline_string(font, Vector2(16.0, 88.0), "%s: %s" % [ammo.display_name, ammo.description], HORIZONTAL_ALIGNMENT_LEFT, 560.0, UiTheme.fs(12), 2, ammo.color.lightened(0.2))


# Side view -------------------------------------------------------------------

func _draw_side_view(font: Font, est: Dictionary) -> void:
	var col := Color(0.85, 0.88, 0.95)
	var ammo := _current_round()
	var full := _estimate(_speed_at(1.0))
	var full_range: float = full["range"] if not full.is_empty() else 8.0
	var bucket: float = RULER_BUCKETS[RULER_BUCKETS.size() - 1]
	for b: float in RULER_BUCKETS:
		if b >= full_range * 1.05:
			bucket = b
			break
	var apex: float = full["apex"] if not full.is_empty() else 1.0
	var s := minf(SIDE_WIDTH / bucket, SIDE_MAX_HEIGHT / maxf(apex, 1.0))
	var h0: float = est["h0"] if not est.is_empty() else 0.7
	var pivot := Vector2(PIVOT_X, GROUND_Y - clampf(h0 * s, 4.0, 40.0))

	draw_line(Vector2(16.0, GROUND_Y), Vector2(438.0, GROUND_Y), Color(0.4, 0.42, 0.48), 2.0)
	_draw_ground_profile(bucket, s)
	var step := bucket / 4.0
	var m := 0.0
	while m <= bucket + 0.01:
		var x := PIVOT_X + m * s
		draw_line(Vector2(x, GROUND_Y), Vector2(x, GROUND_Y + 6.0), Color(0.5, 0.53, 0.6), 1.0)
		draw_string(font, Vector2(x - 14.0, GROUND_Y + 18.0), "%d m" % roundi(m), HORIZONTAL_ALIGNMENT_CENTER, 28.0, UiTheme.fs(10), Color(0.55, 0.58, 0.66))
		m += step
	draw_rect(Rect2(pivot + Vector2(-26.0, 4.0), Vector2(52.0, maxf(GROUND_Y - pivot.y - 4.0, 2.0))), Color(0.28, 0.32, 0.40))

	# elevation dial
	var lo := deg_to_rad(_weapon.pitch_min_deg)
	var hi := deg_to_rad(_weapon.pitch_max_deg)
	var floor_angle := _pitch_floor()
	draw_arc(pivot, DIAL_RADIUS + 6.0, -hi, -lo, 32, Color(0.35, 0.38, 0.45), 2.0)
	if floor_angle > lo + 0.001:
		draw_arc(pivot, DIAL_RADIUS + 6.0, -floor_angle, -lo, 16, Color(0.85, 0.3, 0.25), 4.0)   # ground in the way
	var deg := ceili(_weapon.pitch_min_deg / 5.0) * 5
	while deg <= _weapon.pitch_max_deg:
		var a := deg_to_rad(deg)
		var d := Vector2(cos(a), -sin(a))
		var major := deg % 10 == 0
		draw_line(pivot + d * (DIAL_RADIUS + 6.0), pivot + d * (DIAL_RADIUS + (18.0 if major else 12.0)), Color(0.5, 0.53, 0.6), 2.0 if major else 1.0)
		if major:
			draw_string(font, pivot + d * (DIAL_RADIUS + 30.0) + Vector2(-8.0, 4.0), str(deg), HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(10), Color(0.6, 0.63, 0.7))
		deg += 5

	# estimated arc: the shell's still-air path in the plane of the barrel
	if not est.is_empty():
		var t: float = est["t"]
		var pts := PackedVector2Array()
		var n := 36
		var landing_x := 0.0
		for i in range(n + 1):
			var tt := t * float(i) / float(n)
			var x: float = est["vh"] * tt
			var y: float = est["h0"] + est["vy"] * tt - 0.5 * Ballistics.gravity() * tt * tt
			pts.append(Vector2(PIVOT_X + x * s, minf(GROUND_Y - y * s, GROUND_Y + 12.0)))
			landing_x = x
		draw_polyline(pts, Color(ammo.color, 0.35), 8.0, true)
		draw_polyline(pts, ammo.color, 3.0, true)
		var land := Vector2(PIVOT_X + landing_x * s, minf(GROUND_Y - float(est["land_y"]) * s, GROUND_Y + 12.0))
		draw_circle(land, 7.0, Color(ammo.color, 0.35))
		draw_arc(land, 7.0, 0.0, TAU, 20, ammo.color, 2.0)
		draw_line(land + Vector2(-5.0, -5.0), land + Vector2(5.0, 5.0), ammo.color, 2.0)
		draw_line(land + Vector2(-5.0, 5.0), land + Vector2(5.0, -5.0), ammo.color, 2.0)
		draw_string(font, land + Vector2(-60.0, -14.0), ("BLOCKED %.1f m" if est["blocked"] else "EST %.1f m") % landing_x,
			HORIZONTAL_ALIGNMENT_CENTER, 80.0, UiTheme.fs(13), Color(1.0, 0.5, 0.4) if est["blocked"] else ammo.color.lightened(0.3))

	var dir := Vector2(cos(_pitch), -sin(_pitch))
	draw_line(pivot, pivot + dir * (DIAL_RADIUS - 4.0), col, 9.0)
	draw_circle(pivot, 10.0, Color(0.38, 0.42, 0.52))
	var elev_text := "ELEVATION %.1f deg" % rad_to_deg(_pitch)
	if floor_angle > lo + 0.001:
		elev_text += "   (ground ahead: min %.1f)" % rad_to_deg(floor_angle)
	draw_string(font, Vector2(16.0, 340.0), elev_text, HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(15), col)
	var hint := "no landing at this setting"
	var hint_col := Color(0.65, 0.78, 0.7)
	if not est.is_empty():
		hint = "est ~%.1f m (%s, still air)" % [est["range"], "this charge" if _power > 0.02 else "full power"]
		if est["blocked"]:
			hint = "terrain stops it at ~%.1f m - raise" % est["range"]
			hint_col = Color(1.0, 0.55, 0.45)
	draw_string(font, Vector2(16.0, 356.0), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(12), hint_col)


## The ground along the aim line as a filled silhouette (only drawn when it is not flat).
func _draw_ground_profile(length: float, s: float) -> void:
	var step := length / 60.0
	var heights := _ground_profile(length, step)
	var flat := true
	for h in heights:
		if absf(h) > 0.001:
			flat = false
	if flat:
		return
	var top := PackedVector2Array()
	for i in heights.size():
		top.append(Vector2(PIVOT_X + float(i) * step * s, clampf(GROUND_Y - heights[i] * s, GROUND_Y - 70.0, GROUND_Y + 10.0)))
	var poly := top.duplicate()
	poly.append(Vector2(top[top.size() - 1].x, GROUND_Y + 10.0))
	poly.append(Vector2(top[0].x, GROUND_Y + 10.0))
	if not Geometry2D.triangulate_polygon(poly).is_empty():
		draw_colored_polygon(poly, Color(0.42, 0.34, 0.24, 0.55))
	draw_polyline(top, Color(0.72, 0.6, 0.42), 2.0)


# Radar -----------------------------------------------------------------------

func _radar_range() -> float:
	var need := maxf(_weapon.max_range * 1.1, 12.0)
	for b: float in RADAR_BUCKETS:
		if b >= need:
			return b
	return RADAR_BUCKETS[RADAR_BUCKETS.size() - 1]


func _draw_radar(font: Font) -> void:
	var cam := _camera()
	draw_circle(RADAR_CENTER, RADAR_RADIUS, Color(0.05, 0.12, 0.09, 0.95))
	if cam == null:
		return
	var radar_range := _radar_range()
	var px := RADAR_RADIUS / radar_range
	var aim_s := cam.to_screen_dir(_aim_dir())

	_draw_sight(cam, px)
	_draw_relief(cam, px)

	var ring_step := 5.0 if radar_range <= 24.0 else 10.0
	var ring := ring_step
	while ring < radar_range:
		draw_arc(RADAR_CENTER, ring * px, 0.0, TAU, 48, Color(0.2, 0.4, 0.3, 0.7), 1.0)
		draw_string(font, RADAR_CENTER + Vector2(3.0, -ring * px - 2.0), "%.0fm" % ring, HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(10), Color(0.35, 0.6, 0.45))
		ring += ring_step

	# allowed traverse fan and the world bearing
	var limit := deg_to_rad(_weapon.traverse_deg)
	var fan := PackedVector2Array([RADAR_CENTER])
	for i in 17:
		var y := _base_yaw - limit + 2.0 * limit * float(i) / 16.0
		fan.append(RADAR_CENTER + cam.to_screen_dir(Vector3(sin(y), 0.0, cos(y))) * RADAR_RADIUS)
	draw_colored_polygon(fan, Color(0.3, 0.8, 0.5, 0.14))
	draw_line(RADAR_CENTER, RADAR_CENTER + cam.to_screen_dir(Vector3(sin(_base_yaw), 0.0, cos(_base_yaw))) * RADAR_RADIUS, Color(0.5, 0.7, 0.6, 0.45), 1.0)

	# reach of every charge level along the line of sight (still air, this round, this elevation)
	var side := Vector2(-aim_s.y, aim_s.x)
	for c in range(1, _weapon.max_charges() + 1):
		var e := _estimate(_speed_at(1.0, c))
		if e.is_empty():
			continue
		var r: float = e["range"]
		var sel := c == _charge
		var affordable := _weapon.total_cost(c) <= _unit.ap + Action.AP_EPSILON
		var p := RADAR_CENTER + aim_s * minf(r * px, RADAR_RADIUS)
		var tick_col := Color(1.0, 0.82, 0.25) if sel else (Color(0.65, 0.68, 0.75) if affordable else Color(0.7, 0.3, 0.25))
		draw_line(p - side * (9.0 if sel else 6.0), p + side * (9.0 if sel else 6.0), tick_col, 3.0 if sel else 2.0)
		# short tag on the tick (the metre values are listed under the radar, away from the blips)
		var left := side if side.x < 0.0 else -side
		draw_string(font, p + left * 12.0 + Vector2(-20.0, 4.0), "C%d" % c, HORIZONTAL_ALIGNMENT_RIGHT, 20.0, UiTheme.fs(10), tick_col)
		var row_x := RADAR_CENTER.x - 78.0 + float(c - 1) * 54.0
		draw_string(font, Vector2(row_x, RADAR_CENTER.y + RADAR_RADIUS + 47.0), "C%d %.0fm" % [c, r], HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(11), tick_col)

	# line of sight
	draw_line(RADAR_CENTER, RADAR_CENTER + aim_s * RADAR_RADIUS, Color(1.0, 0.85, 0.3), 3.0)
	draw_arc(RADAR_CENTER, RADAR_RADIUS, 0.0, TAU, 56, Color(0.45, 0.6, 0.5), 2.0)

	# blips: friends blue at their true place; foes red at the MEASURED distance (true bearing)
	for u in _ctx.alive_units():
		if u == _unit:
			continue
		var rel := u.global_position - _unit.global_position
		rel.y = 0.0
		var foe := u.team != _unit.team
		if foe and not _ctx.intel.sees(_unit.team, _ctx.units, u):
			continue   # outside our line of sight: no blip, no distance, nothing
		var reading := {}
		var shown := rel
		if foe:
			reading = _ctx.intel.reading(_unit, u, _ctx.units)
			shown = rel.normalized() * float(reading["est"])
		var bp := cam.to_screen_dir(shown) * px
		var clipped := bp.length() > RADAR_RADIUS - 6.0
		if clipped:
			bp = bp.normalized() * (RADAR_RADIUS - 6.0)
		var bc := (Color(1.0, 0.35, 0.3) if foe else Color(0.4, 0.65, 1.0))
		if clipped:
			bc = bc.darkened(0.4)
		var blip := RADAR_CENTER + bp
		draw_circle(blip, 5.0, bc)
		if foe and reading["outer"]:
			# seen only in the outer ring: the distance is an estimate, the ring shows one standard deviation
			draw_arc(blip, maxf(float(reading["sigma"]) * px, 7.0), 0.0, TAU, 24, Color(bc, 0.55), 1.5)
			draw_string(font, blip + Vector2(8.0, 4.0), "~%.0fm" % reading["est"], HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(11), bc)
		elif foe:
			draw_string(font, blip + Vector2(8.0, 4.0), "%.0fm" % reading["est"], HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(11), bc)
	draw_circle(RADAR_CENTER, 5.0, Color.WHITE)

	var offset := rad_to_deg(wrapf(_yaw - _base_yaw, -PI, PI))
	draw_string(font, Vector2(RADAR_CENTER.x - 110.0, RADAR_CENTER.y + RADAR_RADIUS + 16.0), "TRAVERSE %+.1f (yaw %.1f)" % [offset, _yaw_deg(_yaw)], HORIZONTAL_ALIGNMENT_CENTER, 220.0, UiTheme.fs(15), Color(0.85, 0.88, 0.95))
	draw_string(font, Vector2(RADAR_CENTER.x - 110.0, RADAR_CENTER.y + RADAR_RADIUS + 30.0), "SHADE: SIGHT  TINT: RELIEF", HORIZONTAL_ALIGNMENT_CENTER, 220.0, UiTheme.fs(9), Color(0.6, 0.65, 0.72))


## Ground relief, kept faint: cells higher than the gun's own ground get a warm tint, lower ones a cool tint (a bit
## stronger per level), and only sheer cliff edges (2+ levels) are outlined. Level ground stays clean.
func _draw_relief(cam: TacticsCamera, px: float) -> void:
	var board := _ctx.board
	if board.elevated_cells().is_empty():
		return
	var disc := _circle_polygon(RADAR_CENTER, RADAR_RADIUS - 1.0)
	var here := board.level_of(_unit.cell)
	var origin := _unit.global_position
	var reach := RADAR_RADIUS / px + board.hex_size
	for c in board.all_cells():
		var centre := board.cell_to_world(c)
		if Vector2(centre.x - origin.x, centre.z - origin.z).length() > reach:
			continue
		var level := board.level_of(c)
		var corners := PackedVector2Array()
		for i in 6:
			var corner := board.corner(centre, i)
			corners.append(RADAR_CENTER + cam.to_screen_dir(Vector3(corner.x - origin.x, 0.0, corner.z - origin.z)) * px)
		if level != here:
			var tint := (HIGHER_TINT if level > here else LOWER_TINT)
			tint.a = clampf(0.06 + 0.05 * absf(level - here), 0.0, 0.3)
			for clipped: PackedVector2Array in Geometry2D.intersect_polygons(corners, disc):
				if clipped.size() >= 3 and not Geometry2D.is_polygon_clockwise(clipped):
					draw_colored_polygon(clipped, tint)
		for i in 6:
			var n: Vector2i = c + GridBoard.EDGE_NEIGHBORS[i]
			if board.in_bounds(n) and level - board.level_of(n) >= GridBoard.CLIFF_LEVELS:
				var a := corners[i]
				var b := corners[(i + 1) % 6]
				if (a - RADAR_CENTER).length() < RADAR_RADIUS - 2.0 and (b - RADAR_CENTER).length() < RADAR_RADIUS - 2.0:
					draw_line(a, b, Color(0.92, 0.9, 0.82, 0.5), 1.5)


## Faint shading where the team has clear line of sight (own sight radius, friends, drone / impact areas),
## clipped to the radar disc, plus an amber outline of every unit's outer ring (estimates only, see Intel).
## Trees and large rocks cast sight shadows out of ground units' circles (and are marked as grey discs).
## Everything beyond the outer ring is hidden.
func _draw_sight(cam: TacticsCamera, px: float) -> void:
	var disc := _circle_polygon(RADAR_CENTER, RADAR_RADIUS - 1.0)
	var me := Vector2(_unit.global_position.x, _unit.global_position.z)
	for s in _ctx.intel.sources(_unit.team, _ctx.units):
		var centre: Vector3 = s["center"]
		# work in flat world coordinates relative to the shooter, then map to the radar
		var pieces: Array[PackedVector2Array] = [_circle_polygon(Vector2(centre.x, centre.z) - me, float(s["radius"]))]
		if s["unit"] != null:
			for shadow: PackedVector2Array in _ctx.board.los_shadows(centre, float(s["radius"])):
				var moved := PackedVector2Array()
				for p in shadow:
					moved.append(p - me)
				var next: Array[PackedVector2Array] = []
				for piece in pieces:
					next.append_array(Geometry2D.clip_polygons(piece, moved))
				pieces = next
		var tint := Color(0.45, 0.9, 0.6, 0.08) if s["unit"] != null else Color(0.5, 0.85, 1.0, 0.10)
		for piece in pieces:
			if piece.size() < 3 or Geometry2D.is_polygon_clockwise(piece):
				continue   # clockwise = a hole, nothing to fill
			var poly := PackedVector2Array()
			for p in piece:
				poly.append(RADAR_CENTER + cam.to_screen_dir(Vector3(p.x, 0.0, p.y)) * px)
			for clipped: PackedVector2Array in Geometry2D.intersect_polygons(poly, disc):
				if clipped.size() >= 3:
					draw_colored_polygon(clipped, tint)
	_draw_outer_rings(cam, px, me)
	for o in _ctx.board.los_occluders():
		var rel := Vector3(o.x - me.x, 0.0, o.y - me.y)
		var at := cam.to_screen_dir(rel) * px
		if at.length() < RADAR_RADIUS - 2.0:
			draw_circle(RADAR_CENTER + at, maxf(o.z * px, 2.0), Color(0.55, 0.6, 0.55, 0.45))


## Thin amber outline of each unit's outer sight ring (radius + Intel.OUTER_BAND): between it and the green inner
## ring enemies are seen but only estimated; beyond it they are hidden.
func _draw_outer_rings(cam: TacticsCamera, px: float, me: Vector2) -> void:
	for s in _ctx.intel.sources(_unit.team, _ctx.units):
		if s["unit"] == null:
			continue
		var centre: Vector3 = s["center"]
		var ring := _circle_polygon(Vector2(centre.x, centre.z) - me, float(s["radius"]) + float(s["band"]), 72)
		var pts: Array[Vector2] = []
		for p in ring:
			pts.append(RADAR_CENTER + cam.to_screen_dir(Vector3(p.x, 0.0, p.y)) * px)
		for i in pts.size():
			var a := pts[i]
			var b := pts[(i + 1) % pts.size()]
			if (a - RADAR_CENTER).length() < RADAR_RADIUS - 2.0 and (b - RADAR_CENTER).length() < RADAR_RADIUS - 2.0:
				draw_line(a, b, Color(1.0, 0.78, 0.35, 0.35), 1.5)


static func _circle_polygon(center: Vector2, radius: float, steps: int = 40) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in steps:
		var a := TAU * float(i) / float(steps)
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	return pts


# Wind ------------------------------------------------------------------------

func _draw_wind_box(font: Font) -> void:
	UiTheme.draw_panel(self, WIND_RECT, 1)
	var wind := _ctx.wind
	var t := wind.speed / Wind.MAX_SPEED
	var wcol := Color(0.4, 0.9, 0.5).lerp(Color(1.0, 0.45, 0.25), clampf(t * 1.4, 0.0, 1.0))
	draw_string(font, WIND_RECT.position + Vector2(0.0, 18.0), "WIND", HORIZONTAL_ALIGNMENT_CENTER, WIND_RECT.size.x, UiTheme.fs(13), Color(0.75, 0.78, 0.85))
	var c := WIND_RECT.position + Vector2(WIND_RECT.size.x / 2.0, 66.0)
	draw_arc(c, 34.0, 0.0, TAU, 36, Color(0.4, 0.43, 0.5), 2.0)
	var cam := _camera()
	if cam == null:
		return
	var aim_s := cam.to_screen_dir(_aim_dir())
	var w_s := cam.to_screen_dir(wind.direction())
	# barrel direction on the compass rim, wind arrow through the middle
	draw_line(c + aim_s * 28.0, c + aim_s * 38.0, Color(1.0, 0.85, 0.3), 4.0)
	var half := 8.0 + 20.0 * t
	var tip := c + w_s * half
	draw_line(c - w_s * half, tip, wcol, 5.0)
	var side := Vector2(-w_s.y, w_s.x)
	draw_colored_polygon(PackedVector2Array([tip + w_s * 9.0, tip + side * 7.0, tip - side * 7.0]), wcol)
	draw_string(font, WIND_RECT.position + Vector2(0.0, 128.0), "%.1f" % wind.speed, HORIZONTAL_ALIGNMENT_CENTER, WIND_RECT.size.x, UiTheme.fs(26), wcol)
	draw_string(font, WIND_RECT.position + Vector2(0.0, 146.0), "m/s", HORIZONTAL_ALIGNMENT_CENTER, WIND_RECT.size.x, UiTheme.fs(12), Color(0.7, 0.73, 0.8))

	var along := w_s.dot(aim_s) * wind.speed
	var right_s := Vector2(-aim_s.y, aim_s.x)
	var cross := w_s.dot(right_s) * wind.speed
	draw_string(font, WIND_RECT.position + Vector2(0.0, 168.0), "%s %.1f" % ["TAIL" if along >= 0.0 else "HEAD", absf(along)],
		HORIZONTAL_ALIGNMENT_CENTER, WIND_RECT.size.x, UiTheme.fs(12), Color(0.85, 0.88, 0.95))
	draw_string(font, WIND_RECT.position + Vector2(0.0, 184.0), "CROSS %s %.1f" % ["R" if cross >= 0.0 else "L", absf(cross)],
		HORIZONTAL_ALIGNMENT_CENTER, WIND_RECT.size.x, UiTheme.fs(12), Color(0.85, 0.88, 0.95))
	draw_string(font, WIND_RECT.position + Vector2(0.0, 206.0), "not in est.", HORIZONTAL_ALIGNMENT_CENTER, WIND_RECT.size.x, UiTheme.fs(10), Color(0.6, 0.63, 0.7))


# Power -----------------------------------------------------------------------

func _draw_power(font: Font) -> void:
	UiTheme.draw_box(self, "Bar07a", BAR_RECT, 4)          # blue track with a dark groove; the fill runs inside the groove
	var groove := BAR_RECT.grow(-5.0)
	draw_rect(groove, Color(0.07, 0.08, 0.12))
	var fill := groove
	fill.size.x *= _power
	var col := Color(0.35, 0.85, 0.4).lerp(Color(1.0, 0.35, 0.25), clampf((_power - 0.5) * 2.0, 0.0, 1.0))
	draw_rect(fill, col)
	for i in range(1, 4):
		var x := BAR_RECT.position.x + BAR_RECT.size.x * 0.25 * i
		draw_line(Vector2(x, groove.position.y), Vector2(x, groove.end.y), Color(0.0, 0.0, 0.0, 0.5), 1.0)
	var mx := groove.position.x + groove.size.x * _weapon.min_power
	draw_line(Vector2(mx, BAR_RECT.position.y - 4.0), Vector2(mx, BAR_RECT.end.y + 4.0), Color(1.0, 0.82, 0.25), 2.0)
	var label := "POWER %d%%  (charge %d)" % [roundi(_power * 100.0), _charge] if _charging \
		else "HOLD [SPACE] or press and hold here to charge - release to fire"
	draw_string(font, BAR_RECT.position + Vector2(1.0, 19.0), label, HORIZONTAL_ALIGNMENT_CENTER, BAR_RECT.size.x, UiTheme.fs(14), Color.BLACK)
	draw_string(font, BAR_RECT.position + Vector2(0.0, 18.0), label, HORIZONTAL_ALIGNMENT_CENTER, BAR_RECT.size.x, UiTheme.fs(14), Color.WHITE)


# Last shot sidebar -------------------------------------------------------------

const HIT_BOX := Rect2(796.0, 252.0, 192.0, 88.0)
const SAME_COLOR := Color(0.5, 0.9, 0.6)
const DIFF_COLOR := Color(1.0, 0.8, 0.35)
const DIM_TEXT := Color(0.6, 0.63, 0.7)
const FRONT_ARC := deg_to_rad(Unit.FRONT_ARC_DEG)
const REAR_ARC := deg_to_rad(180.0 - Unit.REAR_ARC_DEG)


## Degrees, -180..180, the same number the shot review prints as "yaw".
func _yaw_deg(yaw: float) -> float:
	return rad_to_deg(wrapf(yaw, -PI, PI))


## Wind relative to a barrel bearing: x = tail wind (+) / head wind (-), y = cross wind (+ = R, same as the wind box).
func _wind_components(speed: float, angle: float, yaw: float) -> Vector2:
	return Vector2(cos(angle - yaw), -sin(angle - yaw)) * speed


func _wind_text(c: Vector2) -> String:
	return "%s %.1f  %s %.1f" % ["TAIL" if c.x >= 0.0 else "HEAD", absf(c.x), "R" if c.y >= 0.0 else "L", absf(c.y)]


func _draw_last_shot(font: Font) -> void:
	draw_line(Vector2(MAIN_WIDTH + 1.0, 4.0), Vector2(MAIN_WIDTH + 1.0, size.y - 4.0), Color(0.45, 0.48, 0.56), 1.0)
	UiTheme.draw_panel(self, SIDEBAR_RECT, 1)
	var x := SIDEBAR_RECT.position.x + 10.0
	var w := SIDEBAR_RECT.size.x - 20.0
	draw_string(font, Vector2(x, 28.0), "LAST SHOT", HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(14), Color(1.0, 0.82, 0.25))
	var rec: ShotRecord = _ctx.state.last_gunnery_shot_of(_unit) if _ctx.state != null else null
	if rec == null:
		draw_multiline_string(font, Vector2(x, 50.0), "No earlier shot from this %s.\n\nFire one and its setup and result stay here as a reference for the next." % _unit.stats.display_name,
			HORIZONTAL_ALIGNMENT_LEFT, w, UiTheme.fs(12), -1, DIM_TEXT)
		return

	var age := _ctx.round_number - rec.round_number
	draw_string(font, Vector2(x, 41.0), "%s - %s" % [rec.shooter_name, rec.weapon_name], HORIZONTAL_ALIGNMENT_LEFT, w, UiTheme.fs(11), Color(0.8, 0.83, 0.9))
	draw_string(font, Vector2(x, 57.0), "#%d  %s" % [rec.id, "this round" if age <= 0 else ("1 round ago" if age == 1 else "%d rounds ago" % age)],
		HORIZONTAL_ALIGNMENT_LEFT, w, UiTheme.fs(10), DIM_TEXT)

	# setup, last shot against what is set now
	var col_last := x + 54.0
	var col_now := x + 124.0
	draw_string(font, Vector2(col_last, 76.0), "LAST", HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(10), DIM_TEXT)
	draw_string(font, Vector2(col_now, 76.0), "NOW", HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(10), DIM_TEXT)
	var ammo := _current_round()
	var yaw_now := _yaw_deg(_yaw)
	var yaw_then := _yaw_deg(rec.yaw)
	var power_now := "%d%%" % roundi(_power * 100.0) if _charging else "-"
	# [label, last, now, same?, last colour, now colour]
	var rows := [
		["ROUND", rec.round_short, ammo.short_name, rec.round_name == ammo.display_name, rec.round_color, ammo.color],
		["CHARGE", str(rec.charges), str(_charge), rec.charges == _charge, Color.WHITE, Color.WHITE],
		["YAW", "%.1f" % yaw_then, "%.1f" % yaw_now, absf(wrapf(yaw_now - yaw_then, -180.0, 180.0)) < 0.05, Color.WHITE, Color.WHITE],
		["ELEV", "%.1f" % rad_to_deg(rec.pitch), "%.1f" % rad_to_deg(_pitch), absf(rad_to_deg(rec.pitch - _pitch)) < 0.05, Color.WHITE, Color.WHITE],
		["POWER", "%d%%" % roundi(rec.power * 100.0), power_now, power_now == "%d%%" % roundi(rec.power * 100.0), Color.WHITE, Color.WHITE],
	]
	var y := 92.0
	for row: Array in rows:
		draw_string(font, Vector2(x, y), row[0], HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(11), DIM_TEXT)
		draw_string(font, Vector2(col_last, y), row[1], HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(13), row[4])
		var now_col: Color = SAME_COLOR if row[3] else DIFF_COLOR
		if row[2] == "-":
			now_col = DIM_TEXT
		draw_string(font, Vector2(col_now, y), row[2], HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(13), now_col)
		y += 16.0

	# what the shot flew like and the conditions it flew in
	var landing := "RNG %.1f m  FLT %.1f s" % [rec.distance, rec.flight_time] if rec.landed else "LOST off the map"
	draw_string(font, Vector2(x, 180.0), landing, HORIZONTAL_ALIGNMENT_LEFT, w, UiTheme.fs(11), Color(0.85, 0.88, 0.95))
	var wind_then := _wind_components(rec.wind_speed, rec.wind_angle, rec.yaw)
	var wind_now := _wind_components(_ctx.wind.speed, _ctx.wind.angle, _yaw)
	draw_string(font, Vector2(x, 198.0), "wind  " + _wind_text(wind_then), HORIZONTAL_ALIGNMENT_LEFT, w, UiTheme.fs(10), Color(0.75, 0.78, 0.85))
	draw_string(font, Vector2(x, 214.0), "now   " + _wind_text(wind_now), HORIZONTAL_ALIGNMENT_LEFT, w, UiTheme.fs(10),
		SAME_COLOR if wind_then.distance_to(wind_now) < 0.5 else DIFF_COLOR)
	var moved := Vector2(rec.shooter_pos.x - _unit.global_position.x, rec.shooter_pos.z - _unit.global_position.z).length()
	if moved > 0.3:
		draw_string(font, Vector2(x, 232.0), "gun moved %.1f m" % moved, HORIZONTAL_ALIGNMENT_LEFT, w, UiTheme.fs(10), DIFF_COLOR)
	else:
		draw_string(font, Vector2(x, 232.0), "same firing spot", HORIZONTAL_ALIGNMENT_LEFT, w, UiTheme.fs(10), SAME_COLOR)

	_draw_hit(font, rec, x, w)


## The enemy this shot struck (the most damaged one) with every blast entry that reached it - the main blast, cluster
## bomblets, splash. Empty when it hit no enemy.
func _hit_group(rec: ShotRecord) -> Array[Dictionary]:
	var by_unit := {}
	for res in rec.results:
		if res["team"] != rec.shooter_team and res.has("point"):
			var id: int = res["unit_id"]
			if not by_unit.has(id):
				by_unit[id] = []
			by_unit[id].append(res)
	var best: Array = []
	var best_damage := -1.0
	for id: int in by_unit:
		var total := 0.0
		for res: Dictionary in by_unit[id]:
			total += float(res["damage"])
		if total > best_damage:
			best_damage = total
			best = by_unit[id]
	var out: Array[Dictionary] = []
	out.assign(best)
	return out


func _draw_hit(font: Font, rec: ShotRecord, x: float, w: float) -> void:
	var group := _hit_group(rec)
	var friendly := 0.0
	for res in rec.results:
		if res["team"] == rec.shooter_team:
			friendly += float(res["damage"])
	draw_string(font, Vector2(x, 248.0), "RESULT", HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(10), DIM_TEXT)
	draw_string(font, Vector2(x + 64.0, 248.0), "fire goes up", HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(9), DIM_TEXT)
	if friendly > 0.0:
		draw_string(font, Vector2(x, 248.0), "FRIENDLY %.1f" % friendly, HORIZONTAL_ALIGNMENT_RIGHT, w, UiTheme.fs(10), Color(1.0, 0.45, 0.4))
	UiTheme.draw_panel(self, HIT_BOX, 1)
	var line_y := HIT_BOX.end.y + 18.0
	if group.is_empty():
		var msg := "No enemy hit.\nFell %.1f m out." % rec.distance if rec.landed else "Round lost off the map."
		draw_multiline_string(font, HIT_BOX.position + Vector2(10.0, 30.0), msg, HORIZONTAL_ALIGNMENT_LEFT, HIT_BOX.size.x - 20.0, UiTheme.fs(12), -1, DIM_TEXT)
		return

	var first: Dictionary = group[0]
	var turn := -PI * 0.5 - Vector2(sin(rec.yaw), cos(rec.yaw)).angle()   # rotates the map so the line of fire runs up
	var ref: Vector3 = first["unit_pos"]
	var target_r := float(first["unit_radius"])
	var shell_at := _rel_flat(rec.impact, ref, turn)
	var extent := maxf(target_r * 1.7, shell_at.length() + 0.5)
	for res in group:
		var at := _rel_flat(res["point"], res["unit_pos"], turn)
		extent = maxf(extent, at.length() + maxf(float(res["radius"]), float(res["fire_radius"])))
	extent = maxf(extent, 2.0)
	var s := minf(HIT_BOX.size.x, HIT_BOX.size.y) * 0.5 * 0.92 / extent
	var centre := HIT_BOX.get_center()

	# metre grid in the gun's frame, then the incendiary fire rings and blast areas (round colour)
	var grid_step := 1.0 if s >= 9.0 else 2.0
	var g := -floorf(extent / grid_step) * grid_step
	while g <= extent:
		draw_line(centre + Vector2(g * s, -extent * s), centre + Vector2(g * s, extent * s), Color(1, 1, 1, 0.05), 1.0)
		draw_line(centre + Vector2(-extent * s, g * s), centre + Vector2(extent * s, g * s), Color(1, 1, 1, 0.05), 1.0)
		g += grid_step
	for res in group:
		var at := centre + _rel_flat(res["point"], res["unit_pos"], turn) * s
		var bomblet: bool = res["bomblet"]
		if float(res["fire_radius"]) > 0.0:
			draw_arc(at, float(res["fire_radius"]) * s, 0.0, TAU, 40, Color(rec.round_color, 0.45), 1.0)
		draw_circle(at, float(res["radius"]) * s, Color(rec.round_color, 0.22 if bomblet else 0.16))
		draw_arc(at, float(res["radius"]) * s, 0.0, TAU, 28, Color(rec.round_color, 0.8 if bomblet else 0.95), 1.2 if bomblet else 2.0)
		draw_circle(at, 1.6 if bomblet else 2.2, rec.round_color.lightened(0.4))

	# the target: footprint, heading and the armor sides (gold front, grey rear)
	var ur := maxf(target_r * s, 4.0)
	draw_circle(centre, ur, Color(0.9, 0.35, 0.3, 0.35))
	draw_arc(centre, ur, 0.0, TAU, 24, Color(1.0, 0.45, 0.4), 1.5)
	var heading := Vector2(sin(float(first["hull_yaw"])), cos(float(first["hull_yaw"]))).rotated(turn)
	draw_arc(centre, ur + 3.0, heading.angle() - FRONT_ARC, heading.angle() + FRONT_ARC, 12, Color(1.0, 0.82, 0.25), 3.0)
	draw_arc(centre, ur + 3.0, heading.angle() + PI - REAR_ARC, heading.angle() + PI + REAR_ARC, 8, Color(0.55, 0.58, 0.65), 3.0)
	draw_line(centre, centre + heading * (ur + 7.0), Color(1.0, 0.82, 0.25), 2.0)
	draw_string(font, centre + heading * (ur + 11.0) + Vector2(-3.0, 4.0), "F", HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(9), Color(1.0, 0.82, 0.25))

	# where the shell itself fell
	var m := centre + shell_at * s
	draw_line(m + Vector2(-6.0, -6.0), m + Vector2(6.0, 6.0), Color.BLACK, 4.0)
	draw_line(m + Vector2(-6.0, 6.0), m + Vector2(6.0, -6.0), Color.BLACK, 4.0)
	draw_line(m + Vector2(-6.0, -6.0), m + Vector2(6.0, 6.0), Color.WHITE, 2.0)
	draw_line(m + Vector2(-6.0, 6.0), m + Vector2(6.0, -6.0), Color.WHITE, 2.0)

	# up arrow = direction of fire, bar = 1 m
	var corner := HIT_BOX.position + Vector2(10.0, 26.0)
	draw_line(corner, corner + Vector2(0.0, -16.0), DIM_TEXT, 1.5)
	draw_colored_polygon(PackedVector2Array([corner + Vector2(0.0, -20.0), corner + Vector2(-3.5, -14.0), corner + Vector2(3.5, -14.0)]), DIM_TEXT)
	draw_string(font, corner + Vector2(7.0, -6.0), "FIRE", HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.fs(9), DIM_TEXT)
	var bar := HIT_BOX.end - Vector2(10.0 + s, 9.0)
	draw_line(bar, bar + Vector2(s, 0.0), DIM_TEXT, 2.0)
	draw_string(font, bar + Vector2(-26.0, 4.0), "1 m", HORIZONTAL_ALIGNMENT_RIGHT, 24.0, UiTheme.fs(9), DIM_TEXT)

	# the numbers: damage, what the armor did, where the shell fell against the target's centre
	var total := 0.0
	var killed := false
	var primary: Dictionary = first
	for res in group:
		total += float(res["damage"])
		killed = killed or res["killed"]
		if res["direct"] or float(res["damage"]) > float(primary["damage"]):
			primary = res
	draw_string(font, Vector2(x, line_y), "%s  dmg %.1f%s" % [first["unit"], total, "  KILLED" if killed else ""], HORIZONTAL_ALIGNMENT_LEFT, w, UiTheme.fs(11), Color(1.0, 0.85, 0.5))
	var detail := "%s%s %s" % ["DIRECT  " if primary["direct"] else "", primary["sector"], String(primary["outcome"]).capitalize()]
	if group.size() > 1:
		detail += "  (%d blasts)" % group.size()
	draw_string(font, Vector2(x, line_y + 16.0), detail, HORIZONTAL_ALIGNMENT_LEFT, w, UiTheme.fs(10), Color(0.85, 0.88, 0.95))
	draw_string(font, Vector2(x, line_y + 32.0), "armor %.1f > %.1f" % [primary["armor_before"], primary["armor_after"]], HORIZONTAL_ALIGNMENT_LEFT, w, UiTheme.fs(10), Color(0.85, 0.88, 0.95))
	var along := -shell_at.y     # + beyond the target's centre, - short of it
	var across := shell_at.x     # + right of it
	var offset_text := "ON THE CENTRE"
	if absf(along) >= 0.05 or absf(across) >= 0.05:
		offset_text = "%s %.1f  %s %.1f" % ["LONG" if along >= 0.0 else "SHORT", absf(along), "RIGHT" if across >= 0.0 else "LEFT", absf(across)]
	draw_string(font, Vector2(x, line_y + 48.0), offset_text, HORIZONTAL_ALIGNMENT_LEFT, w, UiTheme.fs(10), Color(0.75, 0.9, 1.0))


## Flat offset (x, z) from `from` to `point`, turned by `turn` into the gun's frame (screen units: +x right, -y down-range).
static func _rel_flat(point: Vector3, from: Vector3, turn: float) -> Vector2:
	return Vector2(point.x - from.x, point.z - from.z).rotated(turn)
