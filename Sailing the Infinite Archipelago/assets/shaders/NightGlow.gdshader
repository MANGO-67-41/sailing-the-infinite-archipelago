// NightGlow: lamp glass, lit windows and beacon fires.
//
// Unshaded and coloured by vertex colour (times the MultiMesh tint). By day the
// glass just reads as warm paint; as night_amount (published by DayNightCycle)
// rises it brightens past 1.0 so the environment's glow blooms around it.
shader_type spatial;
render_mode unshaded, cull_back;

global uniform float night_amount;

uniform vec3 tint : source_color = vec3(1.0);
uniform float day_level = 0.85;
uniform float night_level = 3.2;
// Small per-light flicker; 0 for steady lamps.
uniform float flicker = 0.08;

global uniform float ocean_time;

varying float v_seed;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void vertex() {
	vec3 origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	v_seed = fract(sin(dot(origin.xz, vec2(12.9898, 78.233))) * 43758.5453) * 6.28;
}

void fragment() {
	float level = mix(day_level, night_level, smoothstep(0.0, 1.0, night_amount));
	level *= 1.0 + flicker * night_amount * (sin(ocean_time * 7.3 + v_seed) * 0.6 + sin(ocean_time * 13.7 + v_seed * 2.0) * 0.4);
	ALBEDO = srgb_to_linear(COLOR.rgb) * tint * level;
}
