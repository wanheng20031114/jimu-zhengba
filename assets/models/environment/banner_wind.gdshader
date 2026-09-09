shader_type spatial;
render_mode cull_disabled;

instance uniform vec4 team_color : source_color = vec4(0.212, 0.494, 0.682, 1.0);
uniform vec4 embroidery_color : source_color = vec4(0.82, 0.64, 0.26, 1.0);
uniform float cloth_height = 2.30;
uniform float wind_strength = 0.065;

void vertex() {
	float free_edge = clamp(0.5 - VERTEX.y / cloth_height, 0.0, 1.0);
	float wave = sin(TIME * 1.6 + VERTEX.y * 3.4 + VERTEX.x * 1.2);
	VERTEX.z += wave * wind_strength * free_edge;
	VERTEX.x += sin(TIME * 1.15 + VERTEX.y * 2.2) * 0.018 * free_edge;
}

void fragment() {
	float edge = min(UV.x, 1.0 - UV.x);
	float border = 1.0 - step(0.055, edge);
	border = max(border, 1.0 - step(0.033, UV.y));
	float sword = (1.0 - step(0.027, abs(UV.x - 0.5))) * step(0.27, UV.y) * (1.0 - step(0.66, UV.y));
	sword = max(sword, (1.0 - step(0.19, abs(UV.x - 0.5))) * (1.0 - step(0.022, abs(UV.y - 0.425))));
	float crest = 1.0 - step(0.105, abs(UV.x - 0.5) + abs(UV.y - 0.26) * 1.2);
	float gold = max(border, max(sword, crest));
	float weave = 0.97 + 0.03 * sin(UV.x * 150.0) * sin(UV.y * 300.0);
	ALBEDO = mix(team_color.rgb * weave, embroidery_color.rgb, gold);
	ROUGHNESS = 0.90;
	// A shallow swallowtail is cut into the free edge of the cloth.
	if (UV.y > 0.91 + abs(UV.x - 0.5) * 0.18) {
		discard;
	}
}
