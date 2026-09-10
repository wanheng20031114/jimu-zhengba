shader_type canvas_item;
render_mode unshaded;

// Share the battlefield's R8 visibility texture. Terrain needs one quad,
// rather than thousands of CPU cell queries and CanvasItem draw commands.
void fragment() {
	float state = texture(TEXTURE, UV).r * 255.0;
	vec3 unknown = vec3(0.141176, 0.145098, 0.113725);
	vec3 explored = vec3(0.294118, 0.274510, 0.188235);
	vec3 visible = vec3(0.564706, 0.466667, 0.274510);
	COLOR = vec4(state > 1.5 ? visible : (state > 0.5 ? explored : unknown), 1.0);
}
