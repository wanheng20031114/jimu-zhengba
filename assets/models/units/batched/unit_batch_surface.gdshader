shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// INSTANCE_CUSTOM carries linear team RGB and opacity. Never multiply COLOR:
// the original vertex alpha is a material category, not transparency.
varying vec4 batch_color;

void vertex() {
	batch_color = INSTANCE_CUSTOM;
}

void fragment() {
	// Preserve the opaque material path, using a screen-door corpse fade.
	// Living instances have opacity 1, so this cannot discard any living pixel.
	float coverage = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	if (batch_color.a <= coverage) {
		discard;
	}
	float heraldry = step(0.75, COLOR.a);
	float metal = step(0.25, COLOR.a) * (1.0 - heraldry);
	ALBEDO = mix(COLOR.rgb, batch_color.rgb, heraldry);
	METALLIC = metal * 0.42;
	ROUGHNESS = mix(0.86, 0.58, metal);
}
