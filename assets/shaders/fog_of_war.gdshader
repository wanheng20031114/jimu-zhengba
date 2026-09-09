shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D visibility_mask : filter_linear, repeat_disable;
uniform vec2 battlefield_size = vec2(128.0, 112.0);
uniform vec4 unexplored_color : source_color = vec4(0.035, 0.042, 0.050, 0.98);
uniform vec4 remembered_color : source_color = vec4(0.085, 0.094, 0.110, 0.70);
varying vec2 world_xz;

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	vec2 uv = (world_xz + battlefield_size * 0.5) / battlefield_size;
	float state = texture(visibility_mask, uv).r * 255.0;
	float explored = smoothstep(0.10, 0.90, state);
	float visible = smoothstep(1.10, 1.90, state);
	vec4 fog = mix(unexplored_color, remembered_color, explored);
	ALBEDO = fog.rgb;
	ALPHA = fog.a * (1.0 - visible);
}
