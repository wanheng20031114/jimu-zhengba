shader_type spatial;
render_mode cull_disabled;

instance uniform float construction_progress : hint_range(0.0, 1.0) = 1.0;
uniform float metalness : hint_range(0.0, 1.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.84;
varying float sculpture_height;

void vertex() {
	sculpture_height = VERTEX.y;
}

void fragment() {
	if (sculpture_height > 6.0 * construction_progress) {
		discard;
	}
	ALBEDO = COLOR.rgb;
	METALLIC = metalness;
	ROUGHNESS = roughness;
}
