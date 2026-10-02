class_name SightView
extends Node3D
## Ground overlay for the viewing team's line of sight (see Intel), three zones: inside any friendly sight radius
## or spotted area it stays clear with a thin mint edge (INNER ring, tight readings); the next Intel.OUTER_BAND metres
## around a unit get a light haze and an amber edge (OUTER ring, estimated readings); everything beyond is a dense shroud
## (hidden, nothing shown there). Trees and large rocks cast sight shadows (shrouded) from ground units, and so does
## higher ground (the ground height is baked into a texture, see GridBoard.terrain_blocks); drones and spotted areas
## see over them and have no outer ring. Follows units live. Toggle with `visible`.

const MAX_SOURCES := 24
const MAX_OCCLUDERS := 128
const HEIGHT_TEXELS := 4.0     # ground-height texture resolution, texels per metre
const TARGET_EYE := 0.55       # height above the ground of the point being looked at
const HEIGHT := 0.022          # above terrain patches (0.012) and the grid (0.02), below highlights (0.03)

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec4 src[24];          // x, z, radius, 1 = ground unit (its sight is blocked by occluders)
uniform int count = 0;
uniform vec4 occ[128];          // x, z, radius, unused: trees and large rocks
uniform int occ_count = 0;
uniform float src_y[24];       // eye height of each source
uniform sampler2D height_tex : filter_nearest;   // ground height, r channel
uniform vec4 height_rect;      // origin x, origin z, 1 / width, 1 / depth
uniform float band = 8.0;      // width of the outer (estimate) ring around a ground unit's radius
uniform vec4 haze : source_color = vec4(0.18, 0.20, 0.24, 0.72);        // beyond the outer ring: hidden
uniform vec4 haze_mid : source_color = vec4(0.45, 0.47, 0.50, 0.20);    // outer ring: estimates only
uniform vec4 edge : source_color = vec4(0.55, 0.95, 0.70, 0.85);        // inner ring edge
uniform vec4 edge_outer : source_color = vec4(1.0, 0.78, 0.35, 0.60);   // outer ring edge
varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float ground(vec2 p) {
	return texture(height_tex, (p - height_rect.xy) * height_rect.zw).r;
}

void fragment() {
	float best = 1000.0;   // < 0 inner ring, 0..band outer ring, >= band hidden (signed distance to the radius)
	for (int i = 0; i < 24; i++) {
		if (i >= count) { break; }
		float sd = distance(wpos.xz, src[i].xy) - src[i].z;
		if (src[i].w < 0.5 && sd > 0.0) {
			sd += band + 0.3;   // drones / spotted areas have no outer ring
		}
		if (src[i].w > 0.5 && sd < band) {
			vec2 d = wpos.xz - src[i].xy;
			float len2 = max(dot(d, d), 0.0001);
			for (int j = 0; j < 128; j++) {
				if (j >= occ_count) { break; }
				vec2 o = occ[j].xy;
				float r = occ[j].z;
				if (distance(wpos.xz, o) < r || distance(src[i].xy, o) < r) { continue; }
				float t = clamp(dot(o - src[i].xy, d) / len2, 0.0, 1.0);
				if (distance(src[i].xy + d * t, o) < r) {
					sd = band + 1.0;   // hidden behind a tree / rock: shrouded, no edge line
					break;
				}
			}
		}
		if (src[i].w > 0.5 && sd < band) {
			float y1 = ground(wpos.xz) + 0.55;
			for (int k = 1; k < 16; k++) {
				float t = float(k) / 16.0;
				if (ground(mix(src[i].xy, wpos.xz, t)) > mix(src_y[i], y1, t)) {
					sd = band + 1.0;   // hidden behind higher ground
					break;
				}
			}
		}
		best = min(best, sd);
	}
	float beyond = smoothstep(band - 0.06, band + 0.06, best);                 // 1 = hidden
	float mid = smoothstep(-0.06, 0.06, best) * (1.0 - beyond);               // 1 = outer ring
	float deeper = mix(0.85, 1.0, clamp((best - band) / 10.0, 0.0, 1.0));      // darker the further out
	float line = 1.0 - smoothstep(0.0, 0.09, abs(best));
	float line_outer = 1.0 - smoothstep(0.0, 0.09, abs(best - band));
	vec3 col = mix(haze_mid.rgb, haze.rgb, beyond);
	col = mix(col, edge_outer.rgb, line_outer);
	col = mix(col, edge.rgb, line);
	float haze_a = mid * haze_mid.a + beyond * haze.a * deeper;
	ALBEDO = col;
	ALPHA = max(max(haze_a, line * edge.a), line_outer * edge_outer.a);
}
"""

var viewer_team := 0

var _ctx: BattleContext
var _mat := ShaderMaterial.new()
var _mesh := MeshInstance3D.new()
var _height_tex: ImageTexture


func setup(ctx: BattleContext, team: int) -> void:
	_ctx = ctx
	viewer_team = team
	# one flat hex per board cell, so the haze stops exactly at the board edge
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	for c in ctx.board.all_cells():
		var centre := ctx.board.cell_to_world(c, HEIGHT)
		for i in 6:
			st.add_vertex(centre)
			st.add_vertex(ctx.board.corner(centre, i))
			st.add_vertex(ctx.board.corner(centre, (i + 1) % 6))
	_mesh.mesh = st.commit()
	var shader := Shader.new()
	shader.code = SHADER_CODE
	_mat.shader = shader
	_mat.set_shader_parameter("band", Intel.OUTER_BAND)
	_bake_heights()
	_mesh.material_override = _mat
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)
	refresh()


func _process(_delta: float) -> void:
	if visible and _ctx != null:
		refresh()


## Bakes the board's ground heights into a texture the shader marches through to find hidden ground.
func _bake_heights() -> void:
	var board := _ctx.board
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in board.all_cells():
		var p := board.cell_to_world(c)
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.z))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.z))
	lo -= Vector2.ONE * board.hex_size * 2.0
	hi += Vector2.ONE * board.hex_size * 2.0
	var size := hi - lo
	var w := ceili(size.x * HEIGHT_TEXELS)
	var h := ceili(size.y * HEIGHT_TEXELS)
	var img := Image.create(w, h, false, Image.FORMAT_RF)
	for y in h:
		for x in w:
			var c := board.world_to_cell(Vector3(lo.x + (x + 0.5) / HEIGHT_TEXELS, 0.0, lo.y + (y + 0.5) / HEIGHT_TEXELS))
			img.set_pixel(x, y, Color(board.height_of(c), 0.0, 0.0, 1.0))
	_height_tex = ImageTexture.create_from_image(img)
	_mat.set_shader_parameter("height_tex", _height_tex)
	_mat.set_shader_parameter("height_rect", Vector4(lo.x, lo.y, 1.0 / size.x, 1.0 / size.y))


## Pushes the current sight sources of the viewing team to the shader. Returns how many were sent.
func refresh() -> int:
	var data := PackedVector4Array()
	data.resize(MAX_SOURCES)
	var eyes := PackedFloat32Array()
	eyes.resize(MAX_SOURCES)
	var n := 0
	for s in _ctx.intel.sources(viewer_team, _ctx.units):
		if n >= MAX_SOURCES:
			break
		var c: Vector3 = s["center"]
		data[n] = Vector4(c.x, c.z, float(s["radius"]), 1.0 if s["unit"] != null else 0.0)
		eyes[n] = c.y
		n += 1
	_mat.set_shader_parameter("src", data)
	_mat.set_shader_parameter("src_y", eyes)
	_mat.set_shader_parameter("count", n)

	var occluders := PackedVector4Array()
	occluders.resize(MAX_OCCLUDERS)
	var m := 0
	for o in _ctx.board.los_occluders():
		if m >= MAX_OCCLUDERS:
			push_warning("SightView: more than %d sight blockers, the rest cast no shadow" % MAX_OCCLUDERS)
			break
		occluders[m] = Vector4(o.x, o.y, o.z, 0.0)
		m += 1
	_mat.set_shader_parameter("occ", occluders)
	_mat.set_shader_parameter("occ_count", m)
	return n
