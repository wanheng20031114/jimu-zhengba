shader_type spatial;
render_mode cull_disabled;

// Alpha is an explicit authoring mask for heraldic cloth and painted blue roofs.
// Stone, wood, brass, canvas and roof shingles retain their modeled color variation.
instance uniform vec4 team_color : source_color = vec4(0.212, 0.494, 0.682, 1.0);
instance uniform float construction_progress : hint_range(0.0, 1.0) = 1.0;
uniform float building_height = 6.0;
uniform float metalness = 0.0;
uniform float surface_roughness = 0.84;
varying float sculpture_height;

void vertex() {
	sculpture_height = VERTEX.y;
}

void fragment() {
	if (construction_progress < 0.9999 && sculpture_height > building_height * construction_progress) {
		discard;
	}
	float dye_shade = clamp(dot(COLOR.rgb, vec3(0.2126, 0.7152, 0.0722)) / 0.085, 0.62, 1.30);
	ALBEDO = mix(COLOR.rgb, team_color.rgb * dye_shade, COLOR.a);
	METALLIC = metalness;
	ROUGHNESS = surface_roughness;
}
