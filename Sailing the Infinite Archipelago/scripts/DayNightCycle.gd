class_name DayNightCycle
extends Node
## Turns the archipelago's day: dawn, morning, noon, golden hour, sunset, dusk,
## a starry night with a moon, and back.
##
## The clock runs in game hours (0-24). Each mood is a keyframe below; between
## keyframes every colour and level is blended. One DirectionalLight plays the
## sun by day and the moon by night (it switches while both are down near the
## horizon and nearly dark, so the handover is never seen). The cycle drives:
##   - the CozySky material (gradient, sun, moon, stars, clouds),
##   - the light's direction, colour and energy,
##   - the environment's ambient light, fog colour and glow,
##   - the ocean's colours and its glint (the moon lays a faint silver path at night),
##   - the global shader uniform `night_amount`, which every lamp and window
##     (NightGlow, BeamGlow) reads, and the static `night` that lights read.
##
## Time stands still while the game is paused, but the node keeps processing so
## the pause menu can still calm the sea's glint through glint_mute. The hour is
## kept in VoyageLog, so it is saved with the voyage.

## Real seconds per game hour by day, and at night (night passes quicker).
const DAY_SECONDS_PER_HOUR := 50.0
const NIGHT_SECONDS_PER_HOUR := 30.0
const SUNRISE := 6.0
const SUNSET := 18.5
## The sky material only needs to change a few times a second; each change
## re-renders its radiance map.
const SKY_REFRESH := 0.2

## 0 by day, 1 in the depth of night. Readable from anywhere.
static var night := 0.0

## Pause menu: 1 hides the sea's glint.
var glint_mute := 0.0

@export var environment_path: NodePath = ^"../WorldEnvironment"
@export var light_path: NodePath = ^"../Sun"
@export var ocean_path: NodePath = ^"../Ocean"

var _environment: Environment
var _light: DirectionalLight3D
var _sky: ShaderMaterial
var _ocean: ShaderMaterial
var _sky_timer := 0.0
var _cloud_offset := Vector2.ZERO

# hour, sky top, sky horizon, light colour, light energy, ambient colour, ambient energy, fog,
# sea deep, sea shallow, sea toward the horizon, night, cloud lit, cloud shade, glow
const KEYS := [
	[0.0, "0a1430", "22305c", "9db4e8", 0.38, "4a5a96", 0.55, "1d2a52", "07192b", "1a4658", "2b3d6c", 1.0, "3a4a78", "1a2244", 0.85],
	[4.6, "0a1430", "22305c", "9db4e8", 0.38, "4a5a96", 0.55, "1d2a52", "07192b", "1a4658", "2b3d6c", 1.0, "3a4a78", "1a2244", 0.85],
	[5.4, "1c2756", "7a5f8e", "a8b2e0", 0.25, "6c6a9e", 0.6, "5c5584", "0e2638", "2c5a68", "7a6a92", 0.75, "9a7f9e", "3d3a66", 0.75],
	[6.2, "557bb3", "f4a58c", "ffb592", 0.85, "cfa4ac", 0.75, "eaa99a", "123a4c", "3f8f94", "f0a896", 0.2, "ffd0b0", "b98a9c", 0.6],
	[7.6, "5b90d2", "fbdcbc", "ffe4c2", 1.15, "f0dccb", 0.85, "f2d6bf", "0f4357", "3fb2ab", "f6d9c2", 0.0, "fff3e6", "d6c1c4", 0.45],
	[12.0, "4a8bdc", "cfe4f0", "fff5e2", 1.2, "e6eef2", 0.7, "cfdde6", "0d4558", "3aa9a3", "cfe6ee", 0.0, "ffffff", "cdd6e2", 0.4],
	[15.8, "5487c7", "fcc499", "ffcc94", 1.3, "ffdbbd", 0.9, "fac9a3", "17505f", "61c2b3", "fcc99e", 0.0, "fff0dc", "dbb6b8", 0.45],
	[18.0, "4c4f94", "ff8a58", "ff9256", 1.05, "e9a58e", 0.8, "f29b78", "1a3a52", "4b8f98", "ff9a6c", 0.1, "ffb07a", "a86a86", 0.6],
	[18.9, "2b2c63", "c25f7c", "d98a8a", 0.35, "7c6aa0", 0.6, "8b5f88", "142640", "2e5d72", "b06a86", 0.6, "d77f86", "4e3e6e", 0.8],
	[19.9, "131c46", "3e417e", "9db4e8", 0.3, "44528c", 0.55, "2c3468", "0a1d31", "1e4a5e", "384a80", 0.95, "465484", "1e2550", 0.85],
]
const PHASES := [[5.0, "night"], [6.8, "dawn"], [11.0, "morning"], [14.5, "midday"], [17.6, "afternoon"],
	[18.7, "sunset"], [20.0, "dusk"], [24.0, "night"]]


func _enter_tree() -> void:
	add_to_group("day_night")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	VoyageLog.ensure_loaded()
	_environment = (get_node_or_null(environment_path) as WorldEnvironment).environment
	_light = get_node_or_null(light_path) as DirectionalLight3D
	_sky = _environment.sky.sky_material as ShaderMaterial if _environment and _environment.sky else null
	var ocean := get_node_or_null(ocean_path) as MeshInstance3D
	_ocean = ocean.get_surface_override_material(0) as ShaderMaterial if ocean else null
	_apply(true)


func _process(delta: float) -> void:
	if not get_tree().paused:
		var per_hour := lerpf(DAY_SECONDS_PER_HOUR, NIGHT_SECONDS_PER_HOUR, night)
		VoyageLog.time_of_day = fposmod(VoyageLog.time_of_day + delta / per_hour, 24.0)
		# Clouds drift with the wind.
		var wind: Vector3 = WindManager.get_wind_vector()
		_cloud_offset += Vector2(wind.x, wind.z) * delta * 0.004
	_sky_timer -= delta
	_apply(_sky_timer <= 0.0)
	if _sky_timer <= 0.0:
		_sky_timer = SKY_REFRESH


## Jumps the clock (tests, and any future "sleep until dawn").
func set_hour(hour: float) -> void:
	VoyageLog.time_of_day = fposmod(hour, 24.0)
	_apply(true)


func get_hour() -> float:
	return VoyageLog.time_of_day


## "dawn", "morning", "midday", "afternoon", "sunset", "dusk" or "night".
func get_phase() -> String:
	var h := VoyageLog.time_of_day
	for p: Array in PHASES:
		if h < float(p[0]):
			return p[1]
	return "night"


## Where the sun is: rises in the east (+x), crosses the northern sky, sets west.
static func sun_direction(hour: float) -> Vector3:
	var theta := PI * (hour - SUNRISE) / (SUNSET - SUNRISE)
	return Vector3(cos(theta), sin(theta) * 0.65, -sin(theta) * 0.5).normalized()


## The moon rises at sunset and keeps to the southern sky.
static func moon_direction(hour: float) -> Vector3:
	var theta := PI * fposmod(hour - SUNSET, 24.0) / 12.0
	return Vector3(cos(theta), sin(theta) * 0.6, sin(theta) * 0.45).normalized()


func _apply(refresh_sky: bool) -> void:
	var hour := VoyageLog.time_of_day
	var k := _sample(hour)
	night = k["night"]
	RenderingServer.global_shader_parameter_set(&"night_amount", night)

	var sun := sun_direction(hour)
	var moon := moon_direction(hour)
	var sun_up := smoothstep(-0.07, 0.05, sun.y)
	var moon_up := smoothstep(-0.05, 0.08, moon.y)
	var use_sun := sun.y > -0.07
	var body := sun if use_sun else moon
	if _light:
		_light.global_basis = Basis.looking_at(-body, Vector3.UP if absf(body.y) < 0.99 else Vector3.FORWARD)
		_light.light_color = k["light"]
		_light.light_energy = float(k["energy"]) * (sun_up if use_sun else moon_up)

	if _environment:
		_environment.ambient_light_color = k["ambient"]
		_environment.ambient_light_energy = k["ambient_e"]
		_environment.fog_light_color = k["fog"]
		_environment.glow_intensity = k["glow"]

	if _ocean:
		var shallow: Color = k["shallow"]
		_ocean.set_shader_parameter(&"deep_color", k["deep"])
		_ocean.set_shader_parameter(&"shallow_color", shallow)
		_ocean.set_shader_parameter(&"crest_color", shallow.lightened(0.12))
		_ocean.set_shader_parameter(&"horizon_tint", k["sea_horizon"])
		# The moon's path on the water is a quieter silver than the sun's.
		_ocean.set_shader_parameter(&"glint_strength", lerpf(0.45, 0.22, night) * (1.0 - glint_mute))

	if _sky and refresh_sky:
		_sky.set_shader_parameter(&"top_color", k["top"])
		_sky.set_shader_parameter(&"horizon_color", k["horizon"])
		_sky.set_shader_parameter(&"below_color", k["fog"])
		_sky.set_shader_parameter(&"sun_dir", sun)
		_sky.set_shader_parameter(&"sun_color", k["light"] if use_sun else Color(k["horizon"]).lightened(0.2))
		_sky.set_shader_parameter(&"horizon_glow", lerpf(0.35, 0.75, smoothstep(0.5, 0.0, sun.y)))
		_sky.set_shader_parameter(&"moon_dir", moon)
		_sky.set_shader_parameter(&"moon_amount", smoothstep(0.25, 0.8, night) * moon_up)
		_sky.set_shader_parameter(&"stars", smoothstep(0.5, 0.95, night))
		_sky.set_shader_parameter(&"cloud_lit", k["cloud_lit"])
		_sky.set_shader_parameter(&"cloud_shade", k["cloud_shade"])
		_sky.set_shader_parameter(&"cloud_offset", _cloud_offset)


## The blended mood at an hour, as named colours and levels.
static func _sample(hour: float) -> Dictionary:
	var count := KEYS.size()
	var a: Array = KEYS[count - 1]
	var b: Array = KEYS[0]
	var span := 24.0 - float(a[0]) + float(b[0])
	var t := fposmod(hour - float(a[0]), 24.0) / span
	for i in count:
		var next: Array = KEYS[(i + 1) % count]
		var from_h := float(KEYS[i][0])
		var to_h := float(next[0]) + (24.0 if i == count - 1 else 0.0)
		var h := hour if hour >= from_h else hour + 24.0
		if h >= from_h and h < to_h:
			a = KEYS[i]
			b = next
			t = (h - from_h) / (to_h - from_h)
			break
	t = smoothstep(0.0, 1.0, t)
	var c := func(i: int) -> Color: return Color(a[i]).lerp(Color(b[i]), t)
	var f := func(i: int) -> float: return lerpf(float(a[i]), float(b[i]), t)
	return {
		"top": c.call(1), "horizon": c.call(2), "light": c.call(3), "energy": f.call(4),
		"ambient": c.call(5), "ambient_e": f.call(6), "fog": c.call(7),
		"deep": c.call(8), "shallow": c.call(9), "sea_horizon": c.call(10),
		"night": f.call(11), "cloud_lit": c.call(12), "cloud_shade": c.call(13), "glow": f.call(14),
	}
