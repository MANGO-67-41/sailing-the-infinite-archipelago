// RiverWater: the great islands' rivers, lakes and falls.
//
// A ribbon mesh laid along each river: UV.x runs bank to bank, UV.y downstream in
// metres / width. Light streaks slide downstream, banks fringe with foam, and
// vertex alpha marks steep drops so cascades churn white. Lit like the sea (two
// toon steps and a hard glint), so it dims and silvers with the day/night cycle.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled;

global uniform float ocean_time;

uniform vec3 deep_color : source_color = vec3(0.16, 0.46, 0.5);
uniform vec3 shallow_color : source_color = vec3(0.42, 0.78, 0.72);
uniform vec3 foam_color : source_color = vec3(1.0, 0.96, 0.9);
uniform vec3 shadow_tint : source_color = vec3(0.62, 0.52, 0.66);
uniform float flow_speed = 0.9;
// 1 for still water (the lake): no streaks drifting.
uniform float still = 0.0;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

void fragment() {
	float across = abs(UV.x * 2.0 - 1.0);
	float t = ocean_time * flow_speed * (1.0 - still);
	vec3 water = mix(deep_color, shallow_color, smoothstep(0.35, 1.0, across));
	float n = value_noise(vec2(UV.x * 5.0, UV.y * 1.6 - t * 1.4));
	float streak = step(0.78, n) * (1.0 - across) * (1.0 - still);
	float bank = smoothstep(0.78, 0.97, across + (value_noise(vec2(UV.y * 3.0 - t, UV.x)) - 0.5) * 0.12);
	float fall = smoothstep(0.15, 0.6, COLOR.a) * step(0.42, value_noise(vec2(UV.x * 7.0, UV.y * 4.0 - t * 3.5)));
	float foam = max(bank * 0.85, max(streak * 0.55, fall));
	ALBEDO = mix(water, foam_color, foam);
	ALPHA = mix(0.82, 1.0, foam);
	ROUGHNESS = 0.5;
	SPECULAR = 0.3;
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	float lit = smoothstep(0.0, 0.05, ndl) * 0.45 + smoothstep(0.3, 0.36, ndl) * 0.55;
	DIFFUSE_LIGHT += mix(shadow_tint * 0.45, vec3(1.0), lit) * ATTENUATION * LIGHT_COLOR / PI;
	if (LIGHT_IS_DIRECTIONAL) {
		vec3 half_vec = normalize(LIGHT + VIEW);
		float spec = pow(max(dot(NORMAL, half_vec), 0.0), 180.0);
		SPECULAR_LIGHT += step(0.5, spec) * 0.35 * ATTENUATION * LIGHT_COLOR / PI;
	}
}
