shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Shared by every rigid part of every soldier. Original vertex RGB is linear.
// COLOR.a stores material class: 0=matte, .502=metal, 1=heraldic cloth.
instance uniform vec4 team_color : source_color = vec4(0.180392, 0.392157, 0.545098, 1.0);

void fragment() {
	float heraldry = step(0.75, COLOR.a);
	float metal = step(0.25, COLOR.a) * (1.0 - heraldry);
	ALBEDO = mix(COLOR.rgb, team_color.rgb, heraldry);
	METALLIC = metal * 0.42;
	ROUGHNESS = mix(0.86, 0.58, metal);
}
