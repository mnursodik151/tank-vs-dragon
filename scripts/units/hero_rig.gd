class_name HeroRig
extends SoldierRig
## An animated KayKit Adventurers character (res://assets/Players/Model/KayKit_Adventurers_2.0_FREE) for the fantasy faction: the mage, the ranger
## and the knight who pushes the octo cannon. Unlike the Stylized Soldier these glTF characters already carry the Rig_Medium skeleton, so
## there is nothing to rig: the model is instanced as it is, the clips of the Rig_Medium packs (res://assets/Animations, the same ones the soldier
## uses) are copied into one AnimationLibrary per profile, and the held item (staff / bow, from the Fantasy Weapons Bits pack) hangs on a
## BoneAttachment3D at the hand slot, so it follows the animation.
## Same interface as SoldierRig (it IS one, so `Unit` drives it unchanged): `set_state(State.X)`, plus AIM (draw / raise before a shot).
## Rig space is the character's own: feet on y 0, the character faces +Z, about 2.3 units tall (a Unit scales it).

const CHARACTERS := "res://assets/Players/Model/KayKit_Adventurers_2.0_FREE/Characters/gltf/%s.glb"
const WEAPON_BITS := "res://assets/Players/Weapons/KayKit_FantasyWeaponsBits_1.0_FREE/Assets/gltf/%s.gltf"

## profile -> {character, hand (bone the item hangs on), item (Weapon Bits stem), item_yaw (degrees), clips {State: [pack, clip, loops]},
## move_speed (ground speed the walk / run clip is made for, m/s at the unit's scale), push (arms forward, see PushPose)}
const PROFILES := {
	"mage": {
		"character": "Mage", "hand": "handslot.r", "item": "staff_B", "item_yaw": 0.0, "move_speed": 3.0,
		"clips": {
			State.IDLE: ["CombatRanged", "Ranged_1H_Aiming", true],
			State.MOVE: ["MovementBasic", "Running_A", true],
			State.AIM: ["CombatRanged", "Ranged_Magic_Raise", false],
			State.FIRE: ["CombatRanged", "Ranged_Magic_Shoot", false],
			State.HIT: ["General", "Hit_A", false],
			State.DEATH: ["General", "Death_A", false],
		},
	},
	"ranger": {
		"character": "Ranger", "hand": "handslot.l", "item": "bow_A_withString", "item_yaw": -90.0, "move_speed": 3.0,
		"clips": {
			State.IDLE: ["CombatRanged", "Ranged_Bow_Idle", true],
			State.MOVE: ["MovementAdvanced", "Running_HoldingBow", true],
			State.AIM: ["CombatRanged", "Ranged_Bow_Draw", false],
			State.FIRE: ["CombatRanged", "Ranged_Bow_Release", false],
			State.HIT: ["General", "Hit_A", false],
			State.DEATH: ["General", "Death_A", false],
		},
	},
	"knight": {
		"character": "Knight", "move_speed": 1.5, "push": true,
		"clips": {
			State.IDLE: ["General", "Idle_A", true],
			State.MOVE: ["MovementBasic", "Walking_B", true],
			State.FIRE: ["General", "Hit_B", false],   # the crew staggers with the recoil
			State.HIT: ["General", "Hit_A", false],
			State.DEATH: ["General", "Death_A", false],
		},
	},
}

static var _libraries := {}   # profile -> AnimationLibrary (shared by every rig of that profile)

var profile := ""
var _clips: Dictionary = {}
var _move_speed := 3.0
var _push: PushPose


## A rig for `profile` (a key of PROFILES): the character, its item and its animations. Add it to a unit and scale / position it.
static func build(p_profile: String) -> HeroRig:
	var cfg: Dictionary = PROFILES[p_profile]
	var rig := HeroRig.new()
	rig.name = "HeroRig"
	rig.profile = p_profile
	rig._clips = cfg["clips"]
	rig._move_speed = float(cfg["move_speed"])
	var root := (load(CHARACTERS % String(cfg["character"])) as PackedScene).instantiate() as Node3D
	rig.add_child(root)
	var sk := root.get_node("Rig_Medium/Skeleton3D") as Skeleton3D
	if cfg.has("hand"):
		var attach := BoneAttachment3D.new()
		attach.name = "Item"
		attach.bone_name = String(cfg["hand"])
		sk.add_child(attach)
		var item := (load(WEAPON_BITS % String(cfg["item"])) as PackedScene).instantiate() as Node3D
		item.rotation.y = deg_to_rad(float(cfg["item_yaw"]))
		attach.add_child(item)
	if cfg.get("push", false):
		rig._push = PushPose.new()
		rig._push.name = "PushPose"
		sk.add_child(rig._push)
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).extra_cull_margin = 1.0   # a posed arm / staff leaves the bind-pose box
	rig.player = AnimationPlayer.new()
	rig.player.name = "AnimationPlayer"
	rig.player.add_animation_library("", _profile_library(p_profile))
	root.add_child(rig.player)   # the clips' track paths ("Rig_Medium/Skeleton3D:bone") start at the character's root
	rig.player.animation_finished.connect(rig._on_finished)
	return rig


func _start() -> void:
	set_state(State.IDLE)
	player.seek(randf() * player.current_animation_length)   # units standing together should not breathe in step


## Plays `new_state`'s clip (cross-faded). FIRE and HIT are one-shots that fall back to IDLE, AIM and DEATH hold their last frame.
## A state the profile has no clip for is ignored. `speed` is the ground speed for MOVE.
func set_state(new_state: State, speed: float = 1.0) -> void:
	if (state == State.DEATH and new_state != State.DEATH) or not _clips.has(new_state):
		return
	var clip: Array = _clips[new_state]
	if new_state == state and bool(clip[2]) and player.is_playing() and is_equal_approx(speed, _speed):
		return
	state = new_state
	_speed = speed
	var rate := clampf(speed / _move_speed, MOVE_RATE_RANGE.x, MOVE_RATE_RANGE.y) if new_state == State.MOVE else 1.0
	player.play(String(clip[1]), BLEND, rate)
	if _push != null:
		_push.active = new_state == State.IDLE or new_state == State.MOVE


func _on_finished(_clip: StringName) -> void:
	if state == State.FIRE or state == State.HIT:
		set_state(State.IDLE)


func is_busy() -> bool:
	return state == State.FIRE or state == State.HIT or state == State.AIM


## One library per profile: the clips of its PROFILES entry under their KayKit names.
static func _profile_library(p_profile: String) -> AnimationLibrary:
	if _libraries.has(p_profile):
		return _libraries[p_profile]
	var lib := AnimationLibrary.new()
	var packs := {}
	var clips: Dictionary = PROFILES[p_profile]["clips"]
	for st: int in clips:
		var clip: Array = clips[st]
		var clip_name := String(clip[1])
		if lib.has_animation(clip_name):
			continue
		var pack := String(clip[0])
		if not packs.has(pack):
			packs[pack] = (load(ANIM_DIR % pack) as PackedScene).instantiate()
		var anim := ((packs[pack] as Node).get_node("AnimationPlayer") as AnimationPlayer).get_animation(clip_name).duplicate() as Animation
		anim.loop_mode = Animation.LOOP_LINEAR if bool(clip[2]) else Animation.LOOP_NONE
		lib.add_animation(clip_name, anim)
	for pack: Node in packs.values():
		pack.free()
	_libraries[p_profile] = lib
	return lib


## Holds both arms out in front of the body, a little lowered, as if on the handle of the cart he pushes (the clips only
## swing arms the way a walker's do). Runs after the animation, so the legs still walk.
class PushPose extends SkeletonModifier3D:
	const UPPER := Vector3(0.20, -0.30, 1.0)   # x is mirrored per side (the character's left is +X)
	const LOWER := Vector3(0.08, -0.10, 1.0)

	func _process_modification_with_delta(_delta: float) -> void:
		var sk := get_skeleton()
		if sk == null:
			return
		for side in ["l", "r"]:
			var sgn := 1.0 if side == "l" else -1.0
			_point(sk, "upperarm." + side, "lowerarm." + side, Vector3(UPPER.x * sgn, UPPER.y, UPPER.z))
			_point(sk, "lowerarm." + side, "wrist." + side, Vector3(LOWER.x * sgn, LOWER.y, LOWER.z))

	## Turns `bone` (in skeleton space) so that the line from it to its child `tip` points along `dir`.
	func _point(sk: Skeleton3D, bone: String, tip: String, dir: Vector3) -> void:
		var b := sk.find_bone(bone)
		var t := sk.find_bone(tip)
		if b < 0 or t < 0:
			return
		var global := sk.get_bone_global_pose(b)
		var current := (sk.get_bone_global_pose(t).origin - global.origin).normalized()
		if current.length() < 0.5:
			return
		var turn := Quaternion(current, dir.normalized())
		var wanted := Basis(turn) * global.basis
		var parent := sk.get_bone_parent(b)
		var parent_basis := sk.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY
		sk.set_bone_pose_rotation(b, (parent_basis.inverse() * wanted).get_rotation_quaternion())
