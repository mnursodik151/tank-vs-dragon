class_name Meteor
extends RigidBody3D
## The rock of a meteor round after its impact: a real physics body (Jolt) that bounces across the ground, props and units. Each time it
## lands again `bounced(point, collider)` fires (Explosion.meteor turns that into a small burning blast); after `bounces` of them, when it
## has come to rest, fell off the map or ran out of time, `finished` fires and the node frees itself. It collides with terrain and units
## but is on no layer itself, so nothing else (shells, rays) ever hits it; frozen units are solid to it, a unit it hits is not pushed by
## the rock - only by the blast Explosion sets off.

signal bounced(point: Vector3, collider: Object)
signal finished

const RADIUS := 0.3
const MAX_TIME := 3.5            ## seconds of physics before it is removed whatever happens
const MIN_IMPACT_SPEED := 2.0    ## a change of velocity smaller than this is not a bounce
const BOUNCE_GAP := 0.15         ## seconds between two counted bounces (one landing can touch twice)
const REST_SPEED := 0.7          ## below this, once it has landed, the rock counts as stopped
const ROCK_LENGTH := 0.75        ## size of the model (UnitModel.make_projectile)

var bounces_left := 3

var _age := 0.0
var _last_bounce := -1.0
var _previous := Vector3.ZERO
var _landed := false
var _done := false
var _trail: ShotTrail
var _touching: Object


func _init() -> void:
	collision_layer = 0
	collision_mask = Unit.LAYER_TERRAIN | Unit.LAYER_UNITS
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 4
	mass = 4.0
	linear_damp = 0.05
	var shape := SphereShape3D.new()
	shape.radius = RADIUS
	var col := CollisionShape3D.new()
	col.shape = shape
	add_child(col)
	body_entered.connect(func(body: Node) -> void: _touching = body)


## Places the rock (already in the tree, at `at`) and throws it with `velocity`; `ammo` sets bounciness and how many landings count.
func start(at: Vector3, velocity: Vector3, ammo: RoundStats) -> void:
	bounces_left = ammo.bounces
	var mat := PhysicsMaterial.new()
	mat.bounce = clampf(ammo.restitution, 0.0, 1.0)
	mat.friction = 0.6
	physics_material_override = mat
	global_position = at
	linear_velocity = velocity
	_previous = velocity
	var look := UnitModel.make_projectile("meteor", ROCK_LENGTH)
	if look != null:
		add_child(look)
	_trail = ShotTrail.new()
	_trail.color = ammo.color
	get_parent().add_child(_trail)
	_trail.add_point(at)


func _physics_process(delta: float) -> void:
	if _done:
		return
	_age += delta
	var velocity := linear_velocity
	if _age - _last_bounce > BOUNCE_GAP and (velocity - _previous).length() > MIN_IMPACT_SPEED:
		var hit: Object = _touching
		var bodies := get_colliding_bodies()
		if not bodies.is_empty():
			hit = bodies[0]
		if hit != null:
			_last_bounce = _age
			_landed = true
			bounced.emit(global_position, hit)
			bounces_left -= 1
	_previous = velocity
	_trail.add_point(global_position)
	if bounces_left <= 0 or _age > MAX_TIME or global_position.y < Ballistics.MIN_Y or (_landed and velocity.length() < REST_SPEED and _age - _last_bounce > 0.3):
		_finish()


func _finish() -> void:
	_done = true
	freeze = true
	visible = false
	if _trail != null:
		_trail.finish()
	finished.emit()
	queue_free()
