// CozySky: the painted sky behind the day/night cycle.
//
// - A two-tone gradient (zenith -> horizon) that DayNightCycle swaps through
//   dawn, noon, golden hour, sunset, dusk and night.
// - The sun as a soft disc with a warm halo, plus a wide glow along the horizon
//   under it that blooms into the sunset band when it is low.
// - A pale moon with a faint halo and shaded limb, and a field of stars that
//   only comes out at night.
// - Low-poly-friendly clouds: soft fbm puffs on a flat sky plane, lit on the
//   sun side and drifting by `cloud_offset` (set from script, so the sky needs
//   no TIME and the radiance map only refreshes when the cycle changes it).
shader_type sky;

uniform vec3 top_color : source_color = vec3(0.33, 0.53, 0.78);
uniform vec3 horizon_color : source_color = vec3(0.99, 0.77, 0.6);
uniform vec3 below_color : source_color = vec3(0.98, 0.76, 0.6);
uniform float gradient_curve = 0.45;

uniform vec3 sun_dir = vec3(-0.8, 0.4, -0.4);
uniform vec3 sun_color : source_color = vec3(1.0, 0.85, 0.6);
uniform float sun_size = 0.022;
uniform float sun_halo = 0.55;
uniform float horizon_glow = 0.5;

uniform vec3 moon_dir = vec3(0.8, 0.4, 0.4);
uniform vec3 moon_color : source_color = vec3(0.92, 0.94, 1.0);
uniform float moon_amount = 0.0;
uniform float stars = 0.0;

uniform float cloud_amount = 0.45;
uniform vec3 cloud_lit : source_color = vec3(1.0, 0.92, 0.84);
uniform vec3 cloud_shade : source_color = vec3(0.86, 0.7, 0.72);
uniform vec2 cloud_offset = vec2(0.0);

float hash3(vec3 p) {
	p = fract(p * vec3(443.897, 441.423, 437.195));
	p += dot(p, p.yzx + 19.19);
	return fract((p.x + p.y) * p.z);
}

float hash2(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash2(i), hash2(i + vec2(1.0, 0.0)), u.x),
			mix(hash2(i + vec2(0.0, 1.0)), hash2(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		sum += value_noise(p) * amp;
		p = p * 2.07 + vec2(13.7, 7.1);
		amp *= 0.5;
	}
	return sum / 0.9375;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float up = clamp(d.y, 0.0, 1.0);

	vec3 col = mix(horizon_color, top_color, pow(up, gradient_curve));
	col = mix(col, below_color, smoothstep(0.0, -0.18, d.y));

	// The sun's warmth: a tight halo, and a broad band along the horizon beneath it.
	vec3 sd = normalize(sun_dir);
	float toward_sun = max(dot(d, sd), 0.0);
	float low_sun = 1.0 - smoothstep(0.0, 0.5, sd.y);
	float band = pow(max(dot(normalize(vec3(d.x, 0.0, d.z) + 0.0001), normalize(vec3(sd.x, 0.0, sd.z) + 0.0001)), 0.0), 3.0);
	float near_horizon = pow(1.0 - abs(d.y), 7.0);
	float sun_visible = smoothstep(-0.25, 0.02, sd.y);
	col += sun_color * horizon_glow * band * near_horizon * (0.35 + 0.65 * low_sun) * sun_visible;
	col += sun_color * sun_halo * pow(toward_sun, 24.0) * sun_visible;

	// Night: stars above the horizon haze.
	if (stars > 0.001 && d.y > 0.0) {
		vec3 p = d * 180.0;
		vec3 cell = floor(p);
		float r = hash3(cell);
		if (r > 0.986) {
			vec3 centre = cell + 0.5 + (vec3(hash3(cell + 3.1), hash3(cell + 7.7), hash3(cell + 1.3)) - 0.5) * 0.6;
			float dist = length(p - centre);
			float star = smoothstep(0.32, 0.0, dist) * (0.4 + 0.6 * hash3(cell + 9.4));
			col += vec3(0.95, 0.93, 1.0) * star * stars * smoothstep(0.0, 0.25, d.y) * 1.6;
		}
	}

	// Clouds on a flat plane overhead, thinning toward the horizon.
	if (cloud_amount > 0.001 && d.y > 0.01) {
		vec2 uv = d.xz / (d.y + 0.12) * 0.55 + cloud_offset;
		float n = fbm(uv * 1.3);
		float density = smoothstep(1.0 - cloud_amount, 1.0 - cloud_amount + 0.28, n);
		density *= smoothstep(0.01, 0.2, d.y);
		float lit = clamp(dot(normalize(vec3(d.x, 0.2, d.z)), sd) * 0.5 + 0.5, 0.0, 1.0);
		vec3 cloud = mix(cloud_shade, cloud_lit, lit);
		// A little of the sky shows through, so clouds sit in the painting.
		col = mix(col, mix(cloud, col, 0.25), density * 0.85);
	}

	// Sun and moon discs drawn last, over the clouds' thin edges.
	float disc = smoothstep(1.0 - sun_size * 0.012, 1.0 - sun_size * 0.006, dot(d, sd));
	col = mix(col, sun_color * 1.6 + vec3(0.25), disc * sun_visible);

	vec3 md = normalize(moon_dir);
	float toward_moon = max(dot(d, md), 0.0);
	col += moon_color * 0.18 * pow(toward_moon, 60.0) * moon_amount;
	float moon_disc = smoothstep(0.99955, 0.9997, dot(d, md));
	// Soft grey seas on the face, from noise across the disc.
	vec3 face = (d - md) * 900.0;
	float seas = value_noise(face.xy + face.z * 0.7) * 0.6 + value_noise(face.xz * 2.1) * 0.4;
	col = mix(col, moon_color * (1.05 + 0.25 * (seas - 0.5)), moon_disc * moon_amount);

	COLOR = col;
}
