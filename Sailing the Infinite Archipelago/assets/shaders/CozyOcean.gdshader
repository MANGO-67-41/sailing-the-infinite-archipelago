// CozyOcean: warm, low-poly watercolour sea.
//
// - Swell: four travelling sine waves, pulled toward height steps and drawn with
//   faceted normals. ocean_height() mirrors WindManager.wave_height() exactly; both
//   read the same global uniforms that WindManager publishes every frame.
// - Infinite: the grid recentres on the camera in whole cells, so put this on a
//   large subdivided PlaneMesh at the origin and give it a big extra_cull_margin.
// - Colour: depth-tinted shallows, slow watercolour pigment blooms and paper grain,
//   a peach fresnel toward the horizon, toon light bands and stepped sun glints.
// - Foam: a contact rim and rolling stepped lines wherever the sea meets geometry
//   (shorelines, rocks, the hull), plus speckled foam on the highest crests.
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, world_vertex_coords;

global uniform float ocean_time;
global uniform vec4 ocean_shape;   // x = swell, y = step height, z = step mix
global uniform vec2 ocean_drift;   // wind-driven offset for ripples and foam
global uniform vec4 ocean_wave_0;  // (dir.x, dir.z, wavelength, amplitude)
global uniform vec4 ocean_wave_1;
global uniform vec4 ocean_wave_2;
global uniform vec4 ocean_wave_3;
global uniform vec4 ocean_calm;    // (x, z, inner, outer): the swell stills inside (a massive island's rivers)

// Must equal the PlaneMesh cell size (size / (subdivisions + 1)).
uniform float grid_snap = 2.5;

group_uniforms colours;
uniform vec3 deep_color : source_color = vec3(0.09, 0.31, 0.38);
uniform vec3 shallow_color : source_color = vec3(0.38, 0.76, 0.70);
uniform vec3 crest_color : source_color = vec3(0.52, 0.82, 0.76);
uniform vec3 horizon_tint : source_color = vec3(0.99, 0.79, 0.62);
uniform vec3 foam_color : source_color = vec3(1.0, 0.95, 0.86);
uniform vec3 shadow_tint : source_color = vec3(0.62, 0.52, 0.66);
group_uniforms;

group_uniforms look;
uniform float clarity_depth = 4.5;            // metres until the water reads fully deep
uniform float min_alpha : hint_range(0.0, 1.0) = 0.62;
uniform float fresnel_amount : hint_range(0.0, 1.0) = 0.55;
uniform float pigment_strength : hint_range(0.0, 0.3) = 0.08;
uniform float glint_strength = 0.45;
uniform float glint_sharpness = 260.0;
group_uniforms;

group_uniforms foam;
uniform float shore_foam_distance = 2.8;      // metres of water depth that get foam lines
uniform float foam_band_spacing = 0.9;
uniform float foam_band_speed = 0.55;
uniform float contact_foam : hint_range(0.0, 1.0) = 0.28;
uniform float crest_foam : hint_range(0.0, 1.0) = 0.5;
group_uniforms;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;

varying vec3 v_world;
varying float v_height;

float wave(vec4 w, vec2 p, float index) {
	float k = 6.2831853 / w.z;
	float c = sqrt(9.81 / k);
	return w.w * sin(k * (dot(w.xy, p) - c * ocean_time) + index * 1.7);
}

// Mirrors WindManager.calm_factor().
float calm_factor(vec2 p) {
	if (ocean_calm.w <= 0.0) {
		return 1.0;
	}
	float t = clamp((length(p - ocean_calm.xy) - ocean_calm.z) / max(ocean_calm.w - ocean_calm.z, 0.001), 0.0, 1.0);
	return mix(0.12, 1.0, t);
}

float ocean_height(vec2 p) {
	float h = wave(ocean_wave_0, p, 0.0) + wave(ocean_wave_1, p, 1.0)
			+ wave(ocean_wave_2, p, 2.0) + wave(ocean_wave_3, p, 3.0);
	h *= ocean_shape.x * calm_factor(p);
	float step_h = max(ocean_shape.y, 0.001);
	return mix(h, round(h / step_h) * step_h, ocean_shape.z);
}

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

float fbm(vec2 p) {
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 3; i++) {
		sum += value_noise(p) * amp;
		p = p * 2.03 + vec2(17.1, 9.2);
		amp *= 0.5;
	}
	return sum / 0.875;
}

void vertex() {
	// world_vertex_coords: VERTEX is already in world space here.
	vec3 camera_pos = INV_VIEW_MATRIX[3].xyz;
	VERTEX.xz += floor(camera_pos.xz / grid_snap) * grid_snap;
	v_height = ocean_height(VERTEX.xz);
	VERTEX.y += v_height;
	v_world = VERTEX;
	NORMAL = vec3(0.0, 1.0, 0.0);
}

void fragment() {
	// Faceted normal from the view-space position derivatives, turned to face the camera
	// (the derivative sign differs between renderers).
	vec3 n = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	if (dot(n, -VERTEX) < 0.0) {
		n = -n;
	}
	NORMAL = n;

	// How much water lies between this surface point and whatever is behind it.
	float raw_depth = texture(depth_tex, SCREEN_UV).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV, raw_depth) * 2.0 - 1.0;
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw_depth);
#endif
	vec4 behind = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	behind.xyz /= behind.w;
	float water_depth = max(-behind.z + VERTEX.z, 0.0);

	float swell = max(ocean_shape.x, 0.01);
	float depth_t = clamp(water_depth / clarity_depth, 0.0, 1.0);
	float crest_t = smoothstep(-0.15, 0.85, v_height / swell);

	vec3 water = mix(shallow_color, deep_color, depth_t);
	water = mix(water, crest_color, crest_t * 0.4 * depth_t);

	// Watercolour: big soft pigment blooms plus fine paper grain, drifting with the wind.
	vec2 wp = v_world.xz + ocean_drift * 0.35;
	float pigment = fbm(wp * 0.045) - 0.5;
	float grain = value_noise(wp * 1.9) - 0.5;
	water *= 1.0 + pigment * pigment_strength * 2.0 + grain * 0.03;

	// Warm sky reflected toward the horizon.
	float facing = clamp(dot(n, normalize(-VERTEX)), 0.0, 1.0);
	float fresnel = pow(1.0 - facing, 4.0);
	water = mix(water, horizon_tint, fresnel * fresnel_amount);

	// Shoreline foam: a solid rim at the contact line plus stepped bands rolling in.
	float shore = 1.0 - clamp(water_depth / shore_foam_distance, 0.0, 1.0);
	float wobble = value_noise(v_world.xz * 0.8 + vec2(ocean_time * 0.5, 0.0)) * 0.35;
	float contact = step(1.0 - contact_foam - wobble * 0.3, shore);
	float band_phase = fract(water_depth / foam_band_spacing + ocean_time * foam_band_speed + wobble);
	float bands = step(0.8, band_phase) * step(0.05, shore) * smoothstep(0.0, 0.6, shore);
	float crest_noise = value_noise(v_world.xz * 1.7 + ocean_drift * 1.5);
	float crest = step(1.0 - crest_foam * 0.3, crest_t) * step(0.7, crest_noise);
	float foam = max(contact, max(bands * 0.9, crest * 0.75));

	ALBEDO = mix(water, foam_color, foam);
	ALPHA = clamp(mix(min_alpha, 1.0, max(max(depth_t, foam), fresnel)), 0.0, 1.0);
	ROUGHNESS = 0.55;
	SPECULAR = 0.3;
}

void light() {
	// Two crisp toon steps; the unlit side keeps a soft warm-violet tint instead of going grey.
	float ndl = dot(NORMAL, LIGHT);
	float lit = smoothstep(0.0, 0.05, ndl) * 0.45 + smoothstep(0.3, 0.36, ndl) * 0.55;
	vec3 band = mix(shadow_tint * 0.4, vec3(1.0), lit);
	DIFFUSE_LIGHT += band * ATTENUATION * LIGHT_COLOR / PI;

	// Stepped sun glints: a hard-edged sparkle path toward the low sun.
	// Only the sun glints; a lantern's omni light would paint a blown-out oval instead.
	if (LIGHT_IS_DIRECTIONAL) {
		vec3 half_vec = normalize(LIGHT + VIEW);
		float spec = pow(max(dot(NORMAL, half_vec), 0.0), glint_sharpness);
		SPECULAR_LIGHT += step(0.45, spec) * glint_strength * ATTENUATION * LIGHT_COLOR / PI;
	}
}
