class_name Atmosphere
extends RefCounted
## Sky, ambient light, tone mapping and the sun for the battlefield.
## The camera is orthographic and looks down at 45 degrees, so the sky itself is mostly a soft haze beyond
## the board edge; its real job is to tint the ambient and reflected light. The sun uses a single orthogonal
## shadow split fitted to the (orthographic) view, which keeps foliage shadows crisp at every zoom level
## (the default 4 split PSSM puts most of an orthographic view into a coarse far split).

const SUN_COLOR := Color(1.0, 0.94, 0.82)
const SUN_ENERGY := 1.15
const SUN_ROTATION_DEG := Vector3(-52.0, 32.0, 0.0)
const SHADOW_DISTANCE := 90.0   ## camera depth the sun shadow covers (camera sits 30 m out, board is ~40 m deep)

const SKY_TOP := Color(0.42, 0.58, 0.80)
const SKY_HORIZON := Color(0.74, 0.81, 0.87)
const GROUND_HORIZON := Color(0.74, 0.81, 0.87)
const GROUND_BOTTOM := Color(0.52, 0.60, 0.64)


## Adds a WorldEnvironment and the sun to `host`. Returns the sun so callers can tweak it.
static func build(host: Node) -> DirectionalLight3D:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = SKY_TOP
	sky_mat.sky_horizon_color = SKY_HORIZON
	sky_mat.sky_curve = 0.3
	sky_mat.ground_horizon_color = GROUND_HORIZON
	sky_mat.ground_bottom_color = GROUND_BOTTOM
	sky_mat.ground_curve = 0.2
	sky_mat.sun_angle_max = 25.0
	sky_mat.sun_curve = 0.1
	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.95
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	host.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = SUN_ROTATION_DEG
	sun.light_color = SUN_COLOR
	sun.light_energy = SUN_ENERGY
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.5
	sun.shadow_blur = 1.5
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = SHADOW_DISTANCE
	host.add_child(sun)
	return sun
