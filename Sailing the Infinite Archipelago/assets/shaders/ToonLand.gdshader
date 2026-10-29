// ToonLand: warm cel-shaded material for island terrain and props.
//
// - Colour comes from vertex colours (authored in sRGB by IslandGenerator and
//   ProceduralMeshBuilder; already darkened in creases as baked AO), times the
//   MultiMesh instance tint when there is one.
// - Light falls in two crisp bands; shadowed sides keep a warm violet tint
//   instead of going grey, and sun-facing silhouettes get a sharp peach edge.
// - A soft painterly grain breaks up flat faces, sand darkens where waves wet it,
//   and foliage (sway > 0) bends gently with the wind from its base.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

global uniform float ocean_time;
global uniform vec2 ocean_drift;

uniform vec3 shadow_tint : source_color = vec3(0.58, 0.45, 0.6);
uniform float shadow_floor : hint_range(0.0, 1.0) = 0.38;
uniform float band_softness : hint_range(0.001, 0.2) = 0.035;
uniform vec3 rim_color : source_color = vec3(1.0, 0.84, 0.62);
uniform float rim_strength : hint_range(0.0, 2.0) = 0.45;
uniform float grain_strength : hint_range(0.0, 0.3) = 0.06;
uniform float wet_line = 0.45;            // sand below this height (world y) looks wet
uniform float wet_darkening : hint_range(0.0, 1.0) = 0.22;
uniform float sway = 0.0;                 // metres of bend per metre of height squared

varying vec3 v_world;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

float hash(vec2 p) {
	p = fract(p * vec2(234.34, 435.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

void vertex() {
	if (sway > 0.0) {
		// Bend grows with height above the prop's base, phase varies per position.
		vec3 origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
		float h = max(VERTEX.y, 0.0);
		float phase = ocean_time * 2.6 + origin.x * 0.31 + origin.z * 0.23;
		vec2 dir = normalize(ocean_drift + vec2(0.001, 0.0));
		float bend = (sin(phase) * 0.6 + sin(phase * 2.3 + 1.7) * 0.4) * sway * h * h;
		vec3 local_dir = (inverse(MODEL_MATRIX) * vec4(dir.x, 0.0, dir.y, 0.0)).xyz;
		VERTEX += local_dir * bend;
	}
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 c = srgb_to_linear(COLOR.rgb);

	// Painterly grain: two scales of soft noise, a few percent either way.
	float grain = value_noise(v_world.xz * 0.35 + v_world.y * 0.2) * 0.65
			+ value_noise(v_world.xz * 2.1) * 0.35;
	c *= 1.0 + (grain - 0.5) * 2.0 * grain_strength;

	// Wet sand band just above the waterline.
	float wet = (1.0 - smoothstep(wet_line - 0.15, wet_line, v_world.y)) * smoothstep(-0.6, -0.1, v_world.y);
	c *= 1.0 - wet * wet_darkening;

	ALBEDO = c;
	ROUGHNESS = 0.92;
	SPECULAR = 0.12;
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	if (LIGHT_IS_DIRECTIONAL) {
		// Cel bands: shadow, lit, and a brighter top band; cast shadows snap to the shadow band.
		float shadow = smoothstep(0.35, 0.55, ATTENUATION);
		float lit = smoothstep(0.0, band_softness, ndl) * shadow;
		float top = smoothstep(0.5, 0.5 + band_softness, ndl) * shadow;
		vec3 band = mix(shadow_tint * shadow_floor, vec3(1.0), lit * 0.8 + top * 0.2);
		DIFFUSE_LIGHT += band * LIGHT_COLOR / PI;

		// Sharp edge highlight on silhouettes that face the sun.
		float edge = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
		float rim = smoothstep(0.66, 0.7, edge) * smoothstep(-0.1, 0.3, ndl) * shadow;
		SPECULAR_LIGHT += rim * rim_color * rim_strength * LIGHT_COLOR / PI;
	} else {
		// Lanterns and other local lights: soft warm pools.
		DIFFUSE_LIGHT += smoothstep(0.0, 0.4, ndl) * ATTENUATION * LIGHT_COLOR / PI;
	}
}
