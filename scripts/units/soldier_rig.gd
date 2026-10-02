class_name SoldierRig
extends Node3D
## Gives the (unrigged, T-pose) Stylized Soldier2 mesh a skeleton and plays the generic humanoid animations (KayKit Rig_Medium,
## res://Animations) on it. Nothing is baked: the first rig of a game
##   1. reads the 23-bone Rig_Medium skeleton out of an animation file (names, hierarchy, rest ROTATIONS - the animations are
##      authored against those) and moves its joints to the soldier's own (chibi) proportions, `JOINTS`;
##   2. skins the mesh: every vertex is weighted to the bones whose segment (`SEGMENTS`) is nearest to it (see `_skin_mesh`);
##   3. copies the wanted clips into one AnimationLibrary, rescaling their position tracks (hips / limb offsets, authored for a
##      taller mannequin) to the soldier's bone lengths.
## The mesh, skin and library are cached and shared by every soldier; each rig only owns a Skeleton3D, a MeshInstance3D and an
## AnimationPlayer. Everything is in the model's own space (the glTF root: y from -0.5 to 0.5, +Z forward, +X the soldier's left).
## Node layout matches the animations' track paths: SoldierRig / Rig_Medium / Skeleton3D / MeshInstance3D + AnimationPlayer.

enum State { IDLE, MOVE, FIRE, HIT, DEATH, AIM }   ## AIM (draw the bow / raise the staff before a shot) only exists for HeroRig

const TEMPLATE := "res://Animations/Animations/gltf/Rig_Medium/Rig_Medium_General.glb"
const ANIM_DIR := "res://Animations/Animations/gltf/Rig_Medium/Rig_Medium_%s.glb"

## State -> [animation pack, clip, loops]. The clip names are the KayKit ones.
const CLIPS := {
	State.IDLE: ["CombatRanged", "Ranged_2H_Aiming", true],
	State.MOVE: ["MovementAdvanced", "Running_HoldingRifle", true],
	State.FIRE: ["CombatRanged", "Ranged_2H_Shoot", false],
	State.HIT: ["General", "Hit_A", false],
	State.DEATH: ["General", "Death_A", false],
}
## Ground speed (m/s, soldier at 1.3 m) the running clip is made for; `set_state(MOVE, speed)` plays it at speed / this (clamped).
## The planted foot sweeps ~1.8 m/s at rate 1; 2.2 keeps the cadence calm at the price of a little foot slide.
const MOVE_CLIP_SPEED := 2.2
const MOVE_RATE_RANGE := Vector2(0.7, 1.8)
const BLEND := 0.12        ## cross-fade between states, seconds
const DEATH_LINGER := 2.5  ## seconds a body stays on the ground before the unit hides (Unit.die)

## The ready / firing stance (Ranged_2H_Aiming, Ranged_2H_Shoot) is a right-shoulder one: the rifle lies along a line from the right
## hand at the shoulder to the left hand ahead, 36.5 deg off the body's forward. So in those states the body is turned that much to
## the right of the aim, and the weapon mount (barrel node) sits where that line crosses the body's middle. Running carries the rifle
## across the chest (muzzle to the soldier's left) instead. All in model space, measured from the clips' hand slots.
const STANCE_YAW := -0.637       ## radians: body relative to the aim in IDLE / FIRE / HIT / DEATH (0 while running)
const READY_MOUNT := Vector3(-0.15, 0.058, 0.028)
const CARRY_MOUNT := Vector3(0.012, -0.03, 0.2)
const CARRY_YAW := PI / 2.0

## Bone -> position in model space. Mirrored (.l = +X) joints are filled in from the .l entries by `_joint`.
const JOINTS := {
	"root": Vector3(0.0, -0.5, 0.0),
	"hips": Vector3(0.0, -0.18, 0.0),
	"spine": Vector3(0.0, -0.03, 0.0),
	"chest": Vector3(0.0, 0.07, 0.0),
	"head": Vector3(0.0, 0.16, 0.0),
	"upperleg.l": Vector3(0.10, -0.09, 0.0),
	"lowerleg.l": Vector3(0.105, -0.26, 0.01),
	"foot.l": Vector3(0.105, -0.43, -0.015),
	"toes.l": Vector3(0.105, -0.485, 0.06),
	"upperarm.l": Vector3(0.13, 0.10, 0.0),
	"lowerarm.l": Vector3(0.235, 0.10, -0.005),
	"wrist.l": Vector3(0.325, 0.10, 0.0),
	"hand.l": Vector3(0.355, 0.105, 0.0),
}
const HEAD_TOP := Vector3(0.0, 0.5, 0.0)
const SNOUT := [Vector3(0.0, 0.20, 0.10), Vector3(0.0, 0.20, 0.22)]   ## the gas mask hangs out in front of the head
const FINGERTIP := Vector3(0.45, 0.11, 0.0)
const TOE_TIP := Vector3(0.105, -0.49, 0.13)
const HAND_SLOT_SCALE := 0.5   ## the mannequin's grip offset from the hand joint, scaled for the soldier's small hands
const BACKPACK := [Vector3(0.0, 0.12, -0.17), Vector3(0.0, 0.0, -0.17)]
const SKIN_BLEND := 0.04       ## a vertex also follows bones up to this much farther than its nearest bone (fading out)
const HEAD_MIN_Y := 0.13       ## everything above this height and inside HEAD_HALF_WIDTH is head (helmet flaps reach the shoulders)
const HEAD_HALF_WIDTH := 0.25
const PACK_MAX_Z := -0.11       ## the backpack (behind this z, inside PACK_HALF_WIDTH) is never moved by the arms
const PACK_HALF_WIDTH := 0.25
const MIRROR_SLACK := 0.02     ## a left bone may move vertices up to this far past the centre line (right bones: the other way)

static var _template: Dictionary = {}      # names, parents, rest (local Transform3D), global_basis, joint (model space position)
static var _skinned: Dictionary = {}       # model id -> {"mesh": ArrayMesh, "skin": Skin}
static var _library: AnimationLibrary

var player: AnimationPlayer
var mesh_instance: MeshInstance3D
var state := State.IDLE
var barrel: Node3D                      ## the weapon mount (Unit's barrel node): `mount` tells where it sits in each stance
var mount_ready := Vector3.ZERO         ## barrel position (turret space) in the firing stance ...
var mount_carry := Vector3.ZERO         ## ... and while running
var _group: Node3D                      ## "Rig_Medium": turned by the stance yaw
var _speed := 1.0
var _tween: Tween


## A rig for `source` (the soldier's static mesh, `xf` = its transform in model space). Add it anywhere; position it as the model.
static func create(id: String, source: Mesh, xf: Transform3D) -> SoldierRig:
	var tmpl := _load_template()
	var rig := SoldierRig.new()
	rig.name = "SoldierRig"
	var group := Node3D.new()
	group.name = "Rig_Medium"
	rig.add_child(group)
	rig._group = group
	var sk := Skeleton3D.new()
	sk.name = "Skeleton3D"
	group.add_child(sk)
	var names: PackedStringArray = tmpl["names"]
	for i in names.size():
		sk.add_bone(names[i])
	for i in names.size():
		sk.set_bone_parent(i, (tmpl["parents"] as PackedInt32Array)[i])
		sk.set_bone_rest(i, (tmpl["rest"] as Array)[i])
	sk.reset_bone_poses()
	if not _skinned.has(id):
		_skinned[id] = _skin_mesh(source, xf, tmpl, sk)
	var mi := MeshInstance3D.new()
	mi.name = "Body"
	mi.mesh = _skinned[id]["mesh"]
	mi.skin = _skinned[id]["skin"]
	mi.extra_cull_margin = 1.0   # the skinned mesh is culled by its bind-pose box; a pose can leave it (arms up, falling over)
	sk.add_child(mi)
	rig.mesh_instance = mi
	rig.player = AnimationPlayer.new()
	rig.player.name = "AnimationPlayer"
	rig.player.add_animation_library("", _get_library())
	rig.add_child(rig.player)
	rig.player.animation_finished.connect(rig._on_finished)
	return rig


func _ready() -> void:
	_start()


## Initial pose (a subclass replaces this, not `_ready`).
func _start() -> void:
	_group.rotation.y = STANCE_YAW
	set_state(State.IDLE)
	player.seek(randf() * player.current_animation_length)   # soldiers standing together should not breathe in step


## Plays `new_state`'s clip (cross-faded) and moves body and weapon mount into that stance. `speed` is the ground speed for MOVE.
## FIRE and HIT are one-shots that fall back to IDLE (`_on_finished`), DEATH stays on its last frame.
func set_state(new_state: State, speed: float = 1.0) -> void:
	if (state == State.DEATH and new_state != State.DEATH) or not CLIPS.has(new_state):
		return
	var loops: bool = CLIPS[new_state][2]
	if new_state == state and loops and player.is_playing() and is_equal_approx(speed, _speed):
		return
	var was_moving := state == State.MOVE
	state = new_state
	_speed = speed
	var rate := clampf(speed / MOVE_CLIP_SPEED, MOVE_RATE_RANGE.x, MOVE_RATE_RANGE.y) if new_state == State.MOVE else 1.0
	player.play(String(CLIPS[new_state][1]), BLEND, rate)
	var carry := new_state == State.MOVE
	if carry != was_moving or not is_equal_approx(_group.rotation.y, 0.0 if carry else STANCE_YAW):
		_pose_mounts(carry)


## Turns the body and moves / turns the weapon mount to the running carry (`carry`) or the firing stance.
func _pose_mounts(carry: bool) -> void:
	if _tween != null:
		_tween.kill()
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE)
	_tween.tween_property(_group, "rotation:y", 0.0 if carry else STANCE_YAW, BLEND * 1.5)
	if barrel != null:
		_tween.tween_property(barrel, "position", mount_carry if carry else mount_ready, BLEND * 1.5)
		_tween.tween_property(barrel, "rotation:y", CARRY_YAW if carry else 0.0, BLEND * 1.5)


func _on_finished(_clip: StringName) -> void:
	if state == State.FIRE or state == State.HIT:
		set_state(State.IDLE)


## True while a one-shot (FIRE, HIT) is still playing.
func is_busy() -> bool:
	return state == State.FIRE or state == State.HIT


# --- template skeleton ------------------------------------------------------------

## The Rig_Medium skeleton refit to the soldier: same bones, parents and rest rotations; rest positions from `JOINTS`.
static func _load_template() -> Dictionary:
	if not _template.is_empty():
		return _template
	var inst := (load(TEMPLATE) as PackedScene).instantiate()
	var src := inst.get_node("Rig_Medium/Skeleton3D") as Skeleton3D
	var count := src.get_bone_count()
	var names := PackedStringArray()
	var parents := PackedInt32Array()
	var rest: Array[Transform3D] = []
	var global_basis: Array[Basis] = []
	var joint := {}
	var original := {}   # bone -> the mannequin's local rest position (to scale animation tracks by)
	for i in count:
		var bone := src.get_bone_name(i)
		names.append(bone)
		parents.append(src.get_bone_parent(i))
		global_basis.append(src.get_bone_global_rest(i).basis)
		original[bone] = src.get_bone_rest(i).origin
	for i in count:
		joint[names[i]] = _joint(names[i], joint, src)
	for i in count:
		var p := parents[i]
		var offset: Vector3 = joint[names[i]] - (joint[names[p]] if p >= 0 else Vector3.ZERO)
		var local := offset if p < 0 else (global_basis[p].inverse() * offset)
		rest.append(Transform3D(src.get_bone_rest(i).basis, local))
	inst.free()
	_template = {"names": names, "parents": parents, "rest": rest, "global_basis": global_basis, "joint": joint, "original": original}
	return _template


## Model-space position of `bone` (the grip slots hang off the hand, everything else is in `JOINTS`, .r mirrors .l).
static func _joint(bone: String, done: Dictionary, src: Skeleton3D) -> Vector3:
	if JOINTS.has(bone):
		return JOINTS[bone]
	if bone.begins_with("handslot"):   # the mannequin's offset in its hand's frame, scaled
		var idx := src.find_bone(bone)
		var hand := src.get_bone_parent(idx)
		var local := src.get_bone_rest(idx).origin * HAND_SLOT_SCALE
		return done[src.get_bone_name(hand)] + src.get_bone_global_rest(hand).basis * local
	var l: Vector3 = JOINTS[bone.trim_suffix(".r") + ".l"]
	return Vector3(-l.x, l.y, l.z)


# --- skinning ---------------------------------------------------------------------

## bone -> segments (pairs of model-space points); a bone's distance to a vertex is the distance to its nearest segment.
static func _segments(joint: Dictionary) -> Dictionary:
	var out := {
		"hips": [[joint["hips"], joint["spine"]]],
		"spine": [[joint["spine"], joint["chest"]]],
		"chest": [[joint["chest"], joint["head"]], [Vector3(-0.09, 0.10, 0.0), Vector3(0.09, 0.10, 0.0)], BACKPACK],
		"head": [[joint["head"], HEAD_TOP], SNOUT],
		"root": [],
	}
	for side in [".l", ".r"]:
		var sgn := 1.0 if side == ".l" else -1.0
		var mirror := func(p: Vector3) -> Vector3: return Vector3(p.x * sgn, p.y, p.z)
		out["upperleg" + side] = [[joint["upperleg" + side], joint["lowerleg" + side]]]
		out["lowerleg" + side] = [[joint["lowerleg" + side], joint["foot" + side]]]
		out["foot" + side] = [[joint["foot" + side], joint["toes" + side]]]
		out["toes" + side] = [[joint["toes" + side], mirror.call(TOE_TIP)]]
		out["upperarm" + side] = [[joint["upperarm" + side], joint["lowerarm" + side]]]
		out["lowerarm" + side] = [[joint["lowerarm" + side], joint["wrist" + side]]]
		out["wrist" + side] = [[joint["wrist" + side], joint["hand" + side]]]
		out["hand" + side] = [[joint["hand" + side], mirror.call(FINGERTIP)]]
		out["handslot" + side] = []
	return out


static func _segment_distance(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.000001), 0.0, 1.0)
	return p.distance_to(a + ab * t)


## The mesh with ARRAY_BONES / ARRAY_WEIGHTS (4 influences per vertex) added, plus the Skin that binds it to `sk`'s rest pose.
## Vertices are weighted by closeness: the nearest bone gets 1, any bone within SKIN_BLEND of that distance fades in quadratically.
## Left/right bones only move their own half of the body (otherwise the legs drag each other along at the crotch).
static func _skin_mesh(source: Mesh, xf: Transform3D, tmpl: Dictionary, sk: Skeleton3D) -> Dictionary:
	var arrays := source.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var count := verts.size()
	var names: PackedStringArray = tmpl["names"]
	var segs := _segments(tmpl["joint"])
	var head := names.find("head")
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	bones.resize(count * 4)
	weights.resize(count * 4)
	var dist := PackedFloat32Array()
	dist.resize(names.size())
	for v in count:
		var p := xf * verts[v]
		verts[v] = p
		normals[v] = (xf.basis * normals[v]).normalized()
		if p.y >= HEAD_MIN_Y and absf(p.x) <= HEAD_HALF_WIDTH:
			bones[v * 4] = head
			weights[v * 4] = 1.0
			continue
		var on_pack := p.z <= PACK_MAX_Z and absf(p.x) <= PACK_HALF_WIDTH
		var nearest := INF
		for b in names.size():
			var bone := names[b]
			var d := INF
			var side_ok := true
			if bone.ends_with(".l"):
				side_ok = p.x >= -MIRROR_SLACK
			elif bone.ends_with(".r"):
				side_ok = p.x <= MIRROR_SLACK
			if on_pack and bone.contains("arm") or on_pack and bone.begins_with("wrist") or on_pack and bone.begins_with("hand"):
				side_ok = false
			if side_ok:
				for s: Array in segs[bone]:
					d = minf(d, _segment_distance(p, s[0], s[1]))
			dist[b] = d
			nearest = minf(nearest, d)
		var picks: Array = []
		for b in names.size():
			if dist[b] < nearest + SKIN_BLEND:
				var f := 1.0 - (dist[b] - nearest) / SKIN_BLEND
				picks.append([b, f * f])
		picks.sort_custom(func(x: Array, y: Array) -> bool: return x[1] > y[1])
		var total := 0.0
		for k in mini(4, picks.size()):
			total += float(picks[k][1])
		for k in 4:
			bones[v * 4 + k] = int(picks[k][0]) if k < picks.size() else 0
			weights[v * 4 + k] = float(picks[k][1]) / total if k < picks.size() else 0.0
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, source.surface_get_material(0))
	return {"mesh": mesh, "skin": sk.create_skin_from_rest_transforms()}


# --- animations -------------------------------------------------------------------

## One library (shared) with every clip in `CLIPS` under its KayKit name, position tracks refit to the soldier's bones.
static func _get_library() -> AnimationLibrary:
	if _library != null:
		return _library
	var tmpl := _load_template()
	var fit := {}   # bone -> [soldier local rest position, mannequin local rest position]
	var names: PackedStringArray = tmpl["names"]
	for i in names.size():
		fit[names[i]] = [((tmpl["rest"] as Array)[i] as Transform3D).origin, (tmpl["original"] as Dictionary)[names[i]]]
	_library = AnimationLibrary.new()
	var packs := {}
	for st: int in CLIPS:
		var clip: Array = CLIPS[st]
		var pack := String(clip[0])
		var clip_name := String(clip[1])
		if _library.has_animation(clip_name):
			continue
		if not packs.has(pack):
			packs[pack] = (load(ANIM_DIR % pack) as PackedScene).instantiate()
		var src := (packs[pack].get_node("AnimationPlayer") as AnimationPlayer).get_animation(clip_name)
		var anim := src.duplicate() as Animation
		anim.loop_mode = Animation.LOOP_LINEAR if bool(clip[2]) else Animation.LOOP_NONE
		for t in anim.get_track_count():
			if anim.track_get_type(t) != Animation.TYPE_POSITION_3D:
				continue
			var bone := String(anim.track_get_path(t).get_concatenated_subnames())
			if not fit.has(bone):
				continue
			var mine: Vector3 = fit[bone][0]
			var theirs: Vector3 = fit[bone][1]
			var k := mine.length() / theirs.length() if theirs.length() > 0.0001 else 1.0
			for key in anim.track_get_key_count(t):
				anim.track_set_key_value(t, key, mine + ((anim.track_get_key_value(t, key) as Vector3) - theirs) * k)
		_library.add_animation(clip_name, anim)
	for pack: Node in packs.values():
		pack.free()
	return _library
