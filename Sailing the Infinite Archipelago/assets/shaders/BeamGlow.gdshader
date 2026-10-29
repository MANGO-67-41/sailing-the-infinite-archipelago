// BeamGlow: the lighthouse's sweeping beams. Additive, fading along the beam's
// length (UV.y) and across it, and only there after dark (night_amount).
// Fog is off: added on top of an additive beam it would paint a white cone by day.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

global uniform float night_amount;

uniform vec3 color : source_color = vec3(1.0, 0.85, 0.55);
uniform float strength = 0.55;

void fragment() {
	float along = 1.0 - UV.y;
	float fade = pow(clamp(along, 0.0, 1.0), 1.6);
	float edge = 1.0 - abs(dot(NORMAL, VIEW));
	float soft = 1.0 - smoothstep(0.55, 1.0, edge);
	ALBEDO = color * strength * fade * soft * smoothstep(0.35, 0.9, night_amount);
}
